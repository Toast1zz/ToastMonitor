import Foundation

/// OMP (Oh My Pi) parser: ~/.omp/agent/sessions/**/*.jsonl
///
/// OMP transcripts are an event stream; assistant `message` events carry
/// `message.usage` with input/output/cacheRead/cacheWrite plus a provider
/// cost breakdown. The shape mirrors Claude Code's JSONL closely, so the
/// same incremental machinery applies (size/mtime/inode + byte offset).
enum OmpParser {

    static var root: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/sessions").path
    }

    /// Returns (turns, sessions) parsed from all changed files.
    /// Depth 3 covers both top-level transcripts (<cwd>/<session>.jsonl)
    /// and subagent transcripts (<cwd>/<session>/<agent>.jsonl).
    static func scan(knownPaths: [String], database: Database = .shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.omp.sourceIsRemote else { return ([], []) } // local-only source
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return ([], []) }

        for file in knownPaths {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = database.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }

            // mtime changed with size unchanged = in-place rewrite; replay
            // from 0 so edited events are not silently lost (dedupe handles
            // the already-imported ones).
            let pendingRewrite = FileScanner.contextNeedsFullRescan(prev.context)
            let sameAppendOnlyFile = prev.identity == st.identity
                && st.size > prev.size
                && prev.mtime != 0
                && !pendingRewrite
            let offset = sameAppendOnlyFile ? prev.size : 0
            let (objs, newOffset) = FileScanner.readNewJSONLines(path: file, fromOffset: offset)
            if objs.isEmpty {
                // Preserve header-derived identity while a trailing JSON line
                // is incomplete. `newOffset` remains before that line, so the
                // next append retries it instead of losing the record.
                let pending = st.size < prev.size || pendingRewrite
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithFullRescan(prev.context, pending: pending))
                continue
            }

            let fileName = (file as NSString).lastPathComponent
            // Session identity comes from the transcript's own `session`
            // event UUID — subagent files named e.g. "UIAudit.jsonl" share a
            // filename stem across top-level sessions, so using the stem
            // would merge distinct sessions and collide event ids. The UUID
            // lives in the file HEADER, which incremental scans never re-read,
            // so it is persisted in scan_state.context and restored here.
            let persistedContext = pendingRewrite ? nil : prev.context
            var sessionID = persistedContext.flatMap { ctxData in
                (try? JSONSerialization.jsonObject(with: Data(ctxData.utf8))) as? [String: Any]
            }?["sid"] as? String ?? (fileName as NSString).deletingPathExtension
            for item in objs {
                if let o = item.obj["type"] as? String, o == "session",
                   let sid = item.obj["id"] as? String, !sid.isEmpty {
                    sessionID = sid
                    break
                }
            }
            let project = FileScanner.lastComponentOfEncodedPath(
                ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            // Full relative path disambiguates subagent transcripts across
            // sessions; the message id is only 32-bit, so the path prefix is
            // what makes the composite id globally unique.
            let relKey = file.hasPrefix(OmpParser.root)
                ? String(file.dropFirst(OmpParser.root.count))
                : fileName
            var firstTs: Int64 = 0
            var lastTs: Int64 = 0
            var sessionModel: String?

            for item in objs {
                let obj = item.obj
                guard obj["type"] as? String == "message",
                      let msg = obj["message"] as? [String: Any],
                      msg["role"] as? String == "assistant",
                      let usage = msg["usage"] as? [String: Any] else { continue }
                let input = (usage["input"] as? NSNumber)?.int64Value ?? 0
                let output = (usage["output"] as? NSNumber)?.int64Value ?? 0
                let cacheRead = (usage["cacheRead"] as? NSNumber)?.int64Value ?? 0
                let cacheWrite = (usage["cacheWrite"] as? NSNumber)?.int64Value ?? 0
                guard input + output + cacheRead + cacheWrite > 0 else { continue }
                let ts = (obj["timestamp"] as? String).flatMap(FileScanner.parseISO)
                    ?? Int64(Date().timeIntervalSince1970)
                let model = msg["model"] as? String
                // Provider-computed cost (per-request breakdown); OMP billing
                // runs inside opencode-go plans, so treat it as an estimate.
                let cost = (usage["cost"] as? [String: Any])?["total"] as? NSNumber
                let eventID = EventIdentity.omp(relativePath: relKey, sessionID: sessionID,
                                                object: obj, usage: usage)
                turns.append(TurnRecord(tool: .omp, sessionID: sessionID, project: project,
                                        model: model, ts: ts,
                                        inputTokens: input, outputTokens: output,
                                        cacheRead: cacheRead, cacheWrite: cacheWrite,
                                        cost: cost?.doubleValue ?? 0,
                                        eventID: eventID, costQuality: "estimated"))
                if firstTs == 0 || ts < firstTs { firstTs = ts }
                if ts > lastTs { lastTs = ts }
                if sessionModel == nil { sessionModel = model }
            }

            if lastTs > 0 {
                sessions.append(SessionInfo(tool: .omp, sessionID: sessionID, title: nil,
                                            project: project, model: sessionModel,
                                            created: firstTs, updated: lastTs))
            }
            var ctx: [String: Any] = ["sid": sessionID]
            if st.size < prev.size {
                ctx["_full_rescan"] = true
            }
            let ctxJSON = (try? JSONSerialization.data(withJSONObject: ctx))
                .flatMap { String(data: $0, encoding: .utf8) }
            database.setScanState(file, size: newOffset, mtime: st.mtime,
                                 identity: st.identity, context: ctxJSON)
        }
        return (turns, sessions)
    }
}
