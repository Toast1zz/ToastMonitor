import Foundation

/// Claude Code parser: ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
/// Assistant entries carry `usage` with input/output/cache tokens.
///
/// A second, separate tree also holds real Claude Code transcripts in the
/// exact same format: Claude Desktop's Cowork feature, when a task runs in
/// "local agent mode" (a sandboxed `claude` CLI on this Mac rather than in
/// Anthropic's cloud), writes one under Desktop's own data directory. Chat
/// and cloud-executed Cowork tasks leave no local file at all — this only
/// ever covers the subset that actually ran locally. See coworkLocalAgentRoot.
/// Since mid-2026 Desktop runs Cowork as cloud sessions (this Mac only hosts
/// their tool VM), so this tree holds history only; current Cowork use shows
/// up solely through ClaudeNonLocalEstimator.
enum ClaudeCodeParser {

    static var root: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
    }

    /// Cowork's local-agent-mode sandbox: `<root>/<org>/<project>/local_<uuid>/.claude/projects/...`.
    /// FileScanner.listFiles() deliberately skips dot-prefixed entries for
    /// ordinary project roots, which would silently skip the `.claude`
    /// component here — listCoworkFiles() starts its walk past that, so the
    /// dot-skip never applies to it.
    static var coworkLocalAgentRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions").path
    }

    /// Enumerates JSONL transcripts under coworkLocalAgentRoot. Best-effort:
    /// any directory that doesn't exist or can't be listed (no Claude
    /// Desktop, no Cowork use, a locked-down permission) is simply skipped
    /// rather than surfaced as an error — this is a bonus source, not a
    /// required one.
    static func listCoworkFiles(root: String = coworkLocalAgentRoot) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var out: [String] = []
        guard let orgs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for org in orgs {
            let orgPath = (root as NSString).appendingPathComponent(org)
            guard let projects = try? fm.contentsOfDirectory(atPath: orgPath) else { continue }
            for project in projects {
                let projectPath = (orgPath as NSString).appendingPathComponent(project)
                guard let sessions = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
                for session in sessions where session.hasPrefix("local_") {
                    let claudeProjectsPath = (projectPath as NSString)
                        .appendingPathComponent(session)
                        .appending("/.claude/projects")
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: claudeProjectsPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    // Depth 4 reaches <project>/<session>/subagents/*.jsonl.
                    // Depth 2 stops at the session directory and misses them.
                    out.append(contentsOf: FileScanner.listFiles(claudeProjectsPath, maxDepth: 4))
                }
            }
        }
        return out
    }

    /// Returns (turns, sessions) parsed from all changed files.
    static func scan(knownPaths: [String], database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.claude.sourceIsRemote else { return ([], []) }
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        var indexByEvent: [String: Int] = [:]
        let fm = FileManager.default

        func appendTurn(_ record: TurnRecord) {
            guard let id = record.eventID else {
                turns.append(record)
                return
            }
            if let idx = indexByEvent[id] {
                turns[idx] = TurnRecord.keepingGreater(turns[idx], record)
            } else {
                indexByEvent[id] = turns.count
                turns.append(record)
            }
        }
        // Either tree is enough: a Cowork-only user has no ~/.claude/projects.
        // Explicit paths are scanned even when neither tree exists.
        guard !knownPaths.isEmpty
            || fm.fileExists(atPath: root)
            || fm.fileExists(atPath: coworkLocalAgentRoot)
        else { return ([], []) }

        for file in knownPaths {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = database.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }

            let pendingRewrite = FileScanner.contextNeedsFullRescan(prev.context)
            let sameAppendOnlyFile = FileScanner.isAppendOnly(path: file, stat: st, previous: prev)
            let offset = sameAppendOnlyFile ? prev.size : 0
            var objectCount = 0
            var sessionID = (file as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            let encodedDir = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            var cwd: String?
            var lastTs: Int64 = 0
            var firstTs: Int64 = 0
            var sessionModel: String?
            let fallbackTs = st.mtime / 1_000_000_000
            let newOffset = FileScanner.forEachNewJSONLine(path: file, fromOffset: offset) { item in
                objectCount += 1
                let obj = item.obj
                guard let type = obj["type"] as? String else { return }
                if let recordSessionID = obj["sessionId"] as? String, !recordSessionID.isEmpty {
                    sessionID = recordSessionID
                }
                if let recorded = obj["cwd"] as? String, !recorded.isEmpty {
                    cwd = recorded
                }
                if type == "assistant" {
                    let message = obj["message"] as? [String: Any]
                    let usage = (obj["usage"] as? [String: Any]) ?? message?["usage"] as? [String: Any]
                    guard let usage else { return }
                    var ts: Int64 = 0
                    if let tstr = obj["timestamp"] as? String {
                        ts = FileScanner.parseISO(tstr) ?? 0
                    }
                    if ts == 0, let tstr = message?["timestamp"] as? String {
                        ts = FileScanner.parseISO(tstr) ?? 0
                    }
                    if ts == 0 { ts = fallbackTs }
                    guard ts > 0 else { return }
                    let model = obj["model"] as? String ?? message?["model"] as? String
                    let input = FileScanner.tokenCount(usage["input_tokens"])
                    let output = FileScanner.tokenCount(usage["output_tokens"])
                    let cacheRead = FileScanner.tokenCount(usage["cache_read_input_tokens"])
                    let creation = usage["cache_creation"] as? [String: Any]
                    let write5m: Int64
                    let write1h: Int64
                    if let creation,
                       creation["ephemeral_5m_input_tokens"] != nil || creation["ephemeral_1h_input_tokens"] != nil {
                        write5m = FileScanner.tokenCount(creation["ephemeral_5m_input_tokens"])
                        write1h = FileScanner.tokenCount(creation["ephemeral_1h_input_tokens"])
                    } else {
                        write5m = FileScanner.tokenCount(usage["cache_creation_input_tokens"])
                        write1h = 0
                    }
                    let cacheWrite = write5m + write1h
                    guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }
                    let est = Pricing.estimate(model: model, input: input, output: output,
                                               cacheRead: cacheRead, cacheWrite: write5m,
                                               cacheWrite1h: write1h)
                    let eventID = EventIdentity.claude(
                        sessionID: sessionID, object: obj, usage: usage,
                        model: model, timestamp: ts, offset: item.offset)
                    let messageID = (message?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (obj["messageId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let project = FileScanner.projectName(cwd: cwd, encodedDirectory: encodedDir)
                    appendTurn(TurnRecord(tool: .claude, sessionID: sessionID, project: project,
                                          model: model, ts: ts, inputTokens: input, outputTokens: output,
                                          cacheRead: cacheRead, cacheWrite: cacheWrite, cost: est ?? 0,
                                          eventID: eventID,
                                          costQuality: est == nil ? "unknown" : "estimated",
                                          usageMerge: messageID == nil ? .ignore : .keepGreater))
                    sessionModel = sessionModel ?? model
                    if firstTs == 0 || ts < firstTs { firstTs = ts }
                    if ts > lastTs { lastTs = ts }
                }
            }
            let project = FileScanner.projectName(cwd: cwd, encodedDirectory: encodedDir)
            if DebugLog.enabled {
                NSLog("[ToastMonitor][claude] %@ prev=(%lld,%lld) now=(%lld,%lld) objs=%d", (file as NSString).lastPathComponent, prev.size, prev.mtime, st.size, st.mtime, objectCount)
            }
            if objectCount == 0 {
                let pending = st.size < prev.size || pendingRewrite
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithFullRescan(prev.context, pending: pending))
                continue
            }


            if lastTs > 0 {
                sessions.append(SessionInfo(tool: .claude, sessionID: sessionID, title: nil,
                                            project: project, model: sessionModel, created: firstTs, updated: lastTs))
            }
            let pending = st.size < prev.size
            database.setScanState(file, size: newOffset, mtime: st.mtime,
                                  identity: st.identity,
                                  context: FileScanner.contextWithFullRescan(prev.context, pending: pending))
        }
        return (turns, sessions)
    }
}
