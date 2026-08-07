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
    static func scan(knownPaths: [String]) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.omp.sourceIsRemote else { return ([], []) } // local-only source
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return ([], []) }

        for file in knownPaths {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = Database.shared.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }

            let sameAppendOnlyFile = prev.identity == st.identity && st.size >= prev.size
            let offset = sameAppendOnlyFile ? prev.size : 0
            let (objs, newOffset) = FileScanner.readNewJSONLines(path: file, fromOffset: offset)
            if objs.isEmpty {
                // Record the offset so a file whose new content is only a
                // partial line is not re-read.
                Database.shared.setScanState(file, size: newOffset, mtime: st.mtime, identity: st.identity)
                continue
            }

            let fileName = (file as NSString).lastPathComponent
            let sessionID = (fileName as NSString).deletingPathExtension
            let project = FileScanner.lastComponentOfEncodedPath(
                ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent)
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
                // Message ids are unique within a transcript; the filename
                // carries the session uuid, so the composite id is global.
                let msgID = obj["id"] as? String ?? "x"
                let eventID = "omp:\(fileName):\(msgID)"
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
            Database.shared.setScanState(file, size: newOffset, mtime: st.mtime, identity: st.identity)
        }
        return (turns, sessions)
    }
}
