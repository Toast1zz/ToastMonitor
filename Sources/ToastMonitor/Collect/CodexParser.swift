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

    /// Map rollout filename -> session UUID.
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

    /// Session id to rebuild during the v7 recount. A stored `sid` wins over
    /// the rollout filename, so a filename that names a different session is
    /// not deleted. No usable id means the file is left untouched.
    static func recountSessionID(path: String, context: String?) -> String? {
        switch recountContextSID(context) {
        case .value(let sid): return sid
        case .unusable: return nil
        case .absent:
            let name = (path as NSString).lastPathComponent
            return sessionID(fromRolloutName: name).flatMap(recountUsableSessionID)
        }
    }

    private enum RecountContextSID {
        case absent, unusable, value(String)
    }

    private static func recountContextSID(_ context: String?) -> RecountContextSID {
        guard let context,
              let data = context.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["sid"] else { return .absent }
        guard let sid = recountUsableSessionID(raw as? String ?? "") else { return .unusable }
        return .value(sid)
    }

    private static func recountUsableSessionID(_ id: String) -> String? {
        guard !id.isEmpty, !id.contains(":"), !id.contains(";") else { return nil }
        return id
    }

    /// Token counts for a single token_count event. Uses `last_token_usage`
    /// (the per-turn delta); `total_token_usage` is cumulative across the
    /// rollout and must never be used for an individual turn.
    /// Returns nil when the event carries no `last_token_usage`.
    static func tokenCounts(from info: [String: Any]) -> (input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64)? {
        guard let last = info["last_token_usage"] as? [String: Any] else { return nil }
        return (
            input: FileScanner.tokenCount(last["input_tokens"]),
            output: FileScanner.tokenCount(last["output_tokens"]),
            reasoning: FileScanner.tokenCount(last["reasoning_output_tokens"]),
            cacheRead: FileScanner.tokenCount(last["cached_input_tokens"]),
            cacheWrite: FileScanner.tokenCount(last["cache_write_input_tokens"])
        )
    }

    private struct TokenTotals: Equatable {
        var input: Int64 = 0
        var output: Int64 = 0
        var reasoning: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0

        static func from(_ raw: [String: Any]) -> TokenTotals {
            TokenTotals(input: FileScanner.tokenCount(raw["input_tokens"]),
                        output: FileScanner.tokenCount(raw["output_tokens"]),
                        reasoning: FileScanner.tokenCount(raw["reasoning_output_tokens"]),
                        cacheRead: FileScanner.tokenCount(raw["cached_input_tokens"]),
                        cacheWrite: FileScanner.tokenCount(raw["cache_write_input_tokens"]))
        }

        /// Positive per-field change. A rate-limit refresh repeats the same
        /// cumulative total and must not become another turn.
        func grew(beyond previous: TokenTotals) -> Bool {
            input > previous.input || output > previous.output || reasoning > previous.reasoning
                || cacheRead > previous.cacheRead || cacheWrite > previous.cacheWrite
        }

        /// Primary counters moved backwards: the stream restarted, it did not repeat.
        func restarted(from previous: TokenTotals) -> Bool {
            input < previous.input || output < previous.output
        }

        func delta(from previous: TokenTotals) -> TokenTotals {
            TokenTotals(input: max(input - previous.input, 0),
                        output: max(output - previous.output, 0),
                        reasoning: max(reasoning - previous.reasoning, 0),
                        cacheRead: max(cacheRead - previous.cacheRead, 0),
                        cacheWrite: max(cacheWrite - previous.cacheWrite, 0))
        }

        var json: [String: Int64] {
            ["in": input, "out": output, "reason": reasoning, "cr": cacheRead, "cw": cacheWrite]
        }

        static func fromContext(_ raw: [String: Any]?) -> TokenTotals? {
            guard let raw else { return nil }
            return TokenTotals(input: (raw["in"] as? NSNumber)?.int64Value ?? 0,
                               output: (raw["out"] as? NSNumber)?.int64Value ?? 0,
                               reasoning: (raw["reason"] as? NSNumber)?.int64Value ?? 0,
                               cacheRead: (raw["cr"] as? NSNumber)?.int64Value ?? 0,
                               cacheWrite: (raw["cw"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private typealias ThreadMeta = (model: String?, provider: String?, title: String?, cwd: String?)
    private static let threadsLock = NSLock()
    private static var threadsCache: (identity: Int64, mtime: Int64, value: [String: ThreadMeta])?

    /// Reads threads table into [sessionID: model] plus session metadata.
    /// The result is reused until the database inode or mtime changes.
    private static func readThreads() -> [String: ThreadMeta] {
        if let st = FileScanner.fileStat(stateDBPath) {
            threadsLock.lock()
            if let cache = threadsCache, cache.identity == st.identity, cache.mtime == st.mtime {
                let value = cache.value
                threadsLock.unlock()
                return value
            }
            threadsLock.unlock()
        }
        let value = loadThreads()
        threadsLock.lock()
        if let st = FileScanner.fileStat(stateDBPath) {
            threadsCache = (st.identity, st.mtime, value)
        } else {
            threadsCache = nil
        }
        threadsLock.unlock()
        return value
    }

    private static func loadThreads() -> [String: ThreadMeta] {
        var out: [String: ThreadMeta] = [:]
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return out }
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return out }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, model, model_provider, title, cwd FROM threads;", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = SQLiteText.column(stmt, 0), !id.isEmpty else { continue }
            out[id] = (SQLiteText.column(stmt, 1), SQLiteText.column(stmt, 2),
                       SQLiteText.column(stmt, 3), SQLiteText.column(stmt, 4))
        }
        return out
    }

    /// `files` overrides the sessions directory listing. Tests pass a fixture
    /// path; the collector passes the list it already walked.
    static func scan(files explicitFiles: [String]? = nil,
                     database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.codex.sourceIsRemote else { return ([], []) }
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let files: [String]
        if let explicitFiles {
            files = explicitFiles
        } else {
            guard FileManager.default.fileExists(atPath: sessionsRoot) else { return ([], []) }
            files = FileScanner.listFiles(sessionsRoot, maxDepth: 4)
        }

        let threadMeta = readThreads()

        // Rollout files: incremental per-file with persisted parse context
        // (session id / model / provider / cwd / cumulative total survive).
        for file in files {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = database.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }
            let pendingRewrite = FileScanner.contextNeedsFullRescan(prev.context)
            let sameAppendOnlyFile = FileScanner.isAppendOnly(path: file, stat: st, previous: prev)
            let offset = sameAppendOnlyFile ? prev.size : 0
            // Parse context before the single pass so an append resumes the
            // cumulative total and does not count a repeated snapshot again.
            var sid = sessionID(fromRolloutName: (file as NSString).lastPathComponent) ?? ""
            var model: String?
            var provider: String?
            var cwd: String?
            var title: String?
            var created: Int64 = 0
            var updated: Int64 = 0
            var lastTotal: TokenTotals?
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
                if (ctx["has_total"] as? Bool) == true || (ctx["has_total"] as? NSNumber)?.boolValue == true {
                    lastTotal = TokenTotals.fromContext(ctx["total"] as? [String: Any])
                }
            }

            var objectCount = 0
            var resumedWithoutBaseline = offset > 0 && lastTotal == nil
            let fallbackTs = st.mtime / 1_000_000_000
            let newOffset = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset) { item in
                objectCount += 1
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
                if type == "turn_context", let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String, !m.isEmpty {
                    model = m
                }
                if type == "event_msg", let payload = obj["payload"] as? [String: Any],
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any] {
                    let counted: TokenTotals?
                    let usageForID: [String: Any]?
                    if let totalRaw = info["total_token_usage"] as? [String: Any] {
                        let total = TokenTotals.from(totalRaw)
                        if let previous = lastTotal {
                            if total.restarted(from: previous) {
                                // A resumed or compacted rollout restarts its
                                // cumulative counters; count from the new baseline.
                                counted = total
                            } else {
                                guard total.grew(beyond: previous) else { return }
                                counted = total.delta(from: previous)
                            }
                        } else if resumedWithoutBaseline {
                            // Saved state predates the running total: adopt this
                            // total as the baseline and count only its own turn.
                            counted = (info["last_token_usage"] as? [String: Any]).map(TokenTotals.from)
                        } else {
                            counted = total
                        }
                        resumedWithoutBaseline = false
                        lastTotal = total
                        usageForID = info["last_token_usage"] as? [String: Any] ?? totalRaw
                    } else if let counts = tokenCounts(from: info) {
                        counted = TokenTotals(input: counts.input, output: counts.output,
                                              reasoning: counts.reasoning, cacheRead: counts.cacheRead,
                                              cacheWrite: counts.cacheWrite)
                        usageForID = info["last_token_usage"] as? [String: Any]
                    } else {
                        counted = nil
                        usageForID = nil
                    }
                    guard let counted, let usageForID,
                          [counted.input, counted.output, counted.reasoning, counted.cacheRead, counted.cacheWrite]
                            .contains(where: { $0 > 0 }) else { return }
                    let ts = (obj["timestamp"] as? String).flatMap(FileScanner.parseISO) ?? fallbackTs
                    guard ts > 0 else { return }
                    let eventModel = model ?? threadMeta[sid]?.model ?? threadMeta[sid]?.provider
                    let est = Pricing.estimate(model: eventModel, input: counted.input, output: counted.output,
                                               cacheRead: counted.cacheRead, cacheWrite: counted.cacheWrite,
                                               inputIncludesCache: true)
                    let eventID = EventIdentity.codex(
                        sessionID: sid, timestamp: ts, model: eventModel,
                        usage: usageForID, offset: item.offset)
                    turns.append(TurnRecord(tool: .codex, sessionID: sid, project: nil,
                                            model: eventModel, ts: ts,
                                            inputTokens: counted.input, outputTokens: counted.output,
                                            reasoningTokens: counted.reasoning,
                                            cacheRead: counted.cacheRead, cacheWrite: counted.cacheWrite,
                                            cost: est ?? 0,
                                            provider: provider ?? threadMeta[sid]?.provider,
                                            eventID: eventID,
                                            costQuality: est == nil ? "unknown" : "estimated"))
                    updated = max(updated, ts)
                }
            }
            if DebugLog.enabled {
                NSLog("[ToastMonitor][codex] %@ prev=(%lld,%lld) now=(%lld,%lld) objs=%d", (file as NSString).lastPathComponent, prev.size, prev.mtime, st.size, st.mtime, objectCount)
            }
            if objectCount == 0 {
                let pending = st.size < prev.size || pendingRewrite
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithFullRescan(prev.context, pending: pending))
                continue
            }


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
            // session_meta re-appearing.
            var ctx: [String: Any] = ["sid": sid, "model": model ?? "", "provider": provider ?? "",
                                      "cwd": cwd ?? "", "title": title ?? "",
                                      "created": created, "updated": updated]
            if let lastTotal {
                ctx["has_total"] = true
                ctx["total"] = lastTotal.json
            }
            if st.size < prev.size {
                ctx["_full_rescan"] = true
            }
            let ctxJSON = (try? JSONSerialization.data(withJSONObject: ctx)).flatMap { String(data: $0, encoding: .utf8) }
            database.setScanState(file, size: newOffset, mtime: st.mtime,
                                  identity: st.identity, context: ctxJSON)
        }

        // Sessions from threads table that have no rollout data yet.
        let seen = Set(sessions.map(\.sessionID))
        for (id, meta) in threadMeta where !seen.contains(id) {
            sessions.append(SessionInfo(tool: .codex, sessionID: id, title: meta.title,
                                        project: meta.cwd.map { ($0 as NSString).lastPathComponent },
                                        model: meta.model ?? meta.provider, created: 0, updated: 0))
        }
        return (turns, sessions)
    }
}
