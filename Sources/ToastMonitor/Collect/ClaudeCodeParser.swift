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
                    out.append(contentsOf: FileScanner.listFiles(claudeProjectsPath, maxDepth: 2))
                }
            }
        }
        return out
    }

    /// Returns (turns, sessions) parsed from all changed files.
    static func scan(knownPaths: [String], database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.claude.sourceIsRemote else { return ([], []) } // source = VPS feed
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        let fm = FileManager.default
        // Either tree existing is enough to proceed — a Cowork-only user
        // (Claude Desktop, never the standalone CLI) has no ~/.claude/projects
        // at all, and must not be short-circuited out of the scan.
        // Concrete fixture paths are valid even when neither production tree
        // exists. This keeps parser tests hermetic on clean CI runners while
        // preserving the normal no-op behavior for an empty live scan.
        guard !knownPaths.isEmpty
            || fm.fileExists(atPath: root)
            || fm.fileExists(atPath: coworkLocalAgentRoot)
        else { return ([], []) }

        for file in knownPaths {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = database.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }

            // Truncation can preserve an inode; a shorter file is still a
            // new byte stream and must be replayed from offset zero.
            // mtime changed with size unchanged = in-place rewrite; replay
            // from 0 so edited events are not silently lost (dedupe handles
            // the already-imported ones).
            let pendingRewrite = FileScanner.contextNeedsFullRescan(prev.context)
            // The cursor must rest on a JSONL line boundary: a truncate +
            // regrow that happened entirely between polls leaves it mid-line
            // and the rewritten events would be skipped by the append path.
            let sameAppendOnlyFile = prev.identity == st.identity
                && st.size > prev.size
                && prev.mtime != 0
                && !pendingRewrite
                && (prev.size == 0 || FileScanner.isLineBoundary(path: file, offset: prev.size))
            let offset = sameAppendOnlyFile ? prev.size : 0
            let (objs, newOffset) = FileScanner.readNewJSONLines(path: file, fromOffset: offset)
            if DebugLog.enabled {
                NSLog("[ToastMonitor][claude] %@ prev=(%lld,%lld) now=(%lld,%lld) objs=%d", (file as NSString).lastPathComponent, prev.size, prev.mtime, st.size, st.mtime, objs.count)
            }
            if objs.isEmpty {
                // Still record the offset so we don't re-read a file whose new
                // content is only a partial line.
                let pending = st.size < prev.size || pendingRewrite
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithFullRescan(prev.context, pending: pending))
                continue
            }

            var sessionID = (file as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            let project = FileScanner.lastComponentOfEncodedPath(
                ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            var lastTs: Int64 = 0
            var firstTs: Int64 = 0
            var sessionModel: String?

            for item in objs {
                let obj = item.obj
                guard let type = obj["type"] as? String else { continue }
                if let recordSessionID = obj["sessionId"] as? String, !recordSessionID.isEmpty {
                    sessionID = recordSessionID
                }
                if type == "assistant" {
                    // usage lives at top level in classic transcripts, inside
                    // message.usage in the newer SDK format — accept both.
                    let usage = (obj["usage"] as? [String: Any])
                        ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    guard let usage else { continue }
                    var ts: Int64 = 0
                    if let tstr = obj["timestamp"] as? String {
                        ts = FileScanner.parseISO(tstr) ?? 0
                    }
                    if ts == 0, let msg = obj["message"] as? [String: Any],
                       let tstr = msg["timestamp"] as? String {
                        ts = FileScanner.parseISO(tstr) ?? 0
                    }
                    if ts == 0 { ts = Int64(Date().timeIntervalSince1970) }
                    let model = obj["model"] as? String
                        ?? (obj["message"] as? [String: Any])?["model"] as? String
                    let input = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let output = (usage["output_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
                    guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { continue }
                    let est = Pricing.estimate(model: model, input: input, output: output,
                                               cacheRead: cacheRead, cacheWrite: cacheWrite)
                    // A Claude response can be copied into several assistant/tool
                    // transcript rows with different outer UUIDs. The message id
                    // identifies the billable model call; the content hash is the
                    // stable fallback for older rows without one.
                    let eventID = EventIdentity.claude(
                        sessionID: sessionID, object: obj, usage: usage,
                        model: model, timestamp: ts, offset: item.offset)
                    turns.append(TurnRecord(tool: .claude, sessionID: sessionID, project: project,
                                            model: model, ts: ts, inputTokens: input, outputTokens: output,
                                            cacheRead: cacheRead, cacheWrite: cacheWrite, cost: est ?? 0,
                                            eventID: eventID, costQuality: est == nil ? "unknown" : "estimated"))
                    sessionModel = sessionModel ?? model
                    if firstTs == 0 || ts < firstTs { firstTs = ts }
                    if ts > lastTs { lastTs = ts }
                }
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
