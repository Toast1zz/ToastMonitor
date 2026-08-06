import Foundation
import SQLite3

/// Codex parser (2026 format):
///  - ~/.codex/state_5.sqlite  `threads` table: session metadata (title, model, cwd, timestamps)
///  - ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl  `event_msg` token_count events
///    carrying total_token_usage (cumulative) and last_token_usage (per-turn delta).
enum CodexParser {

    static var sessionsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions").path
    }
    static var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
    }

    /// Map rollout filename -> session UUID (P0-1).
    /// Format: rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid...>.jsonl
    /// The timestamp is fixed-width (19 chars); everything after is the UUID.
    static func sessionID(fromRolloutName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard let regex = try? NSRegularExpression(pattern: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(.+)$"#),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let r = Range(match.range(at: 1), in: stem)
        else { return nil }
        return String(stem[r])
    }

    /// Reads threads table into [sessionID: model] plus session metadata.
    static func readThreads() -> [String: (model: String?, provider: String?, title: String?, cwd: String?)] {
        var out: [String: (model: String?, provider: String?, title: String?, cwd: String?)] = [:]
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return out }
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return out }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, model, model_provider, title, cwd FROM threads;", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let model = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
            let provider = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2))
            let title = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let cwd = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            out[id] = (model, provider, title, cwd)
        }
        return out
    }

    static func scan() -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.codex.sourceIsRemote else { return ([], []) } // source = VPS feed
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot) else { return ([], []) }

        // Threads metadata first.
        let threadMeta = readThreads()

        // Rollout files: incremental per-file with persisted parse context
        // (session id / model / provider / cwd survive across scans).
        let files = FileScanner.listFiles(sessionsRoot, maxDepth: 4)
        for file in files {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = Database.shared.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }
            // Truncation can preserve an inode; a shorter file is still a
            // new byte stream and must be replayed from offset zero.
            let sameAppendOnlyFile = prev.identity == st.identity && st.size >= prev.size
            let offset = sameAppendOnlyFile ? prev.size : 0
            let (objs, newOffset) = FileScanner.readNewJSONLines(path: file, fromOffset: offset)
            if DebugLog.enabled {
                NSLog("[ToastMonitor][codex] %@ prev=(%lld,%lld) now=(%lld,%lld) objs=%d", (file as NSString).lastPathComponent, prev.size, prev.mtime, st.size, st.mtime, objs.count)
            }
            if objs.isEmpty {
                Database.shared.setScanState(file, size: newOffset, mtime: st.mtime, identity: st.identity)
                continue
            }

            // Parse context: reuse persisted state, then overlay new events.
            var sid = sessionID(fromRolloutName: (file as NSString).lastPathComponent) ?? ""
            var model: String?
            var provider: String?
            var cwd: String?
            var title: String?
            var created: Int64 = 0
            var updated: Int64 = 0
            let persistedContext = sameAppendOnlyFile ? prev.context : nil
            if let ctxData = persistedContext?.data(using: .utf8),
               let ctx = (try? JSONSerialization.jsonObject(with: ctxData)) as? [String: Any] {
                if let s = ctx["sid"] as? String, !s.isEmpty { sid = s }
                if let m = ctx["model"] as? String, !m.isEmpty { model = m }
                if let p = ctx["provider"] as? String, !p.isEmpty { provider = p }
                if let c = ctx["cwd"] as? String, !c.isEmpty { cwd = c }
                if let t = ctx["title"] as? String, !t.isEmpty { title = t }
                created = (ctx["created"] as? NSNumber)?.int64Value ?? 0
                updated = (ctx["updated"] as? NSNumber)?.int64Value ?? 0
            }

            let fileName = (file as NSString).lastPathComponent

            // A scan chunk may start with token_count rows whose turn_context
            // lives earlier in the stream (or arrived in a previous scan).
            // Prescan the chunk so those turns still get a model instead of
            // being inserted with model=NULL (which backfillCosts can never
            // repair because it requires model IS NOT NULL).
            var chunkModel: String?
            for item in objs {
                let obj = item.obj
                if obj["type"] as? String == "turn_context",
                   let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String, !m.isEmpty {
                    chunkModel = m
                }
            }

            for item in objs {
                let obj = item.obj
                let type = obj["type"] as? String
                if type == "session_meta", let payload = obj["payload"] as? [String: Any] {
                    if let s = payload["session_id"] as? String, !s.isEmpty { sid = s }
                    if let m = payload["model_provider"] as? String, !m.isEmpty { provider = m }
                    if let c = payload["cwd"] as? String { cwd = c }
                    if let ts = (obj["timestamp"] as? String).flatMap(FileScanner.parseISO) {
                        if created == 0 { created = ts }
                        updated = max(updated, ts)
                    }
                }
                // turn_context carries the authoritative per-turn model.
                if type == "turn_context", let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String, !m.isEmpty {
                    model = m
                }
                if type == "event_msg", let payload = obj["payload"] as? [String: Any],
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any] {
                    let input = (last["input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let output = (last["output_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cacheRead = (last["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cacheWrite = (last["cache_write_input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let ts = (obj["timestamp"] as? String).flatMap(FileScanner.parseISO)
                        ?? Int64(Date().timeIntervalSince1970)
                    // Threads metadata is a valid fallback when a rollout
                    // chunk does not contain turn_context before token_count.
                    let eventModel = model
                        ?? chunkModel
                        ?? threadMeta[sid]?.model
                        ?? threadMeta[sid]?.provider
                    let est = Pricing.estimate(model: eventModel, input: input, output: output,
                                                cacheRead: cacheRead, cacheWrite: cacheWrite)
                    if input + output + cacheRead + cacheWrite > 0 {
                        // Truncate-and-rewrite replays from offset 0: reuse
                        // the previous mtime so replayed fallback IDs collide
                        // with the originals and dedupe (no double count).
                        let idMtime = sameAppendOnlyFile ? st.mtime : prev.mtime
                        turns.append(TurnRecord(tool: .codex, sessionID: sid, project: nil,
                                                model: eventModel, ts: ts, inputTokens: input, outputTokens: output,
                                                cacheRead: cacheRead, cacheWrite: cacheWrite, cost: est ?? 0,
                                                eventID: "codex:\(fileName):\(st.identity):\(idMtime):\(item.offset)",
                                                costQuality: est == nil ? "unknown" : "estimated"))
                    }
                    updated = max(updated, ts)
                }
            }

            // Join with threads for model/title when available.
            if !sid.isEmpty {
                if let meta = threadMeta[sid] {
                    let threadModel = meta.model.flatMap { $0.isEmpty ? nil : $0 } ?? meta.provider
                    if model == nil { model = threadModel }
                    if title == nil { title = meta.title }
                    if cwd == nil { cwd = meta.cwd }
                }
                let project = cwd.map { ($0 as NSString).lastPathComponent }
                let sessionModel = model ?? (provider?.isEmpty == false ? provider : nil)
                sessions.append(SessionInfo(tool: .codex, sessionID: sid, title: title,
                                            project: project, model: sessionModel,
                                            created: created, updated: updated))
            }

            // Persist parse context so incremental scans never depend on
            // session_meta re-appearing (P0-1).
            let ctx: [String: Any] = ["sid": sid, "model": model ?? "", "provider": provider ?? "",
                                      "cwd": cwd ?? "", "title": title ?? "",
                                      "created": created, "updated": updated]
            let ctxJSON = (try? JSONSerialization.data(withJSONObject: ctx)).flatMap { String(data: $0, encoding: .utf8) }
            Database.shared.setScanState(file, size: newOffset, mtime: st.mtime, identity: st.identity, context: ctxJSON)
        }

        // Sessions from threads table that have no rollout data yet.
        for (id, meta) in threadMeta where !sessions.contains(where: { $0.sessionID == id }) {
            sessions.append(SessionInfo(tool: .codex, sessionID: id, title: meta.title,
                                        project: meta.cwd.map { ($0 as NSString).lastPathComponent },
                                        model: meta.model ?? meta.provider, created: 0, updated: 0))
        }
        return (turns, sessions)
    }
}
