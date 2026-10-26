import XCTest
@testable import ToastMonitor

/// Drives `ClaudeCodeParser.scan(knownPaths:)` against the checked-in
/// fixture (Tests/ToastMonitorTests/Fixtures/claude-project-sample.jsonl):
/// a user message followed by two assistant messages carrying usage.
final class ClaudeCodeParserTests: XCTestCase {

    private var fixturePath: String {
        Bundle.module.url(forResource: "claude-project-sample", withExtension: "jsonl",
                          subdirectory: "Fixtures")!.path
    }

    private var createdClaudeRoot = false

    override func setUp() {
        super.setUp()
        // scan() bails early when ~/.claude/projects does not exist (e.g. a
        // fresh CI runner). Create it when missing so the fixture still
        // parses; tearDown removes exactly what we created.
        if !FileManager.default.fileExists(atPath: ClaudeCodeParser.root) {
            try? FileManager.default.createDirectory(atPath: ClaudeCodeParser.root,
                                                     withIntermediateDirectories: true)
            createdClaudeRoot = true
        }
    }

    override func tearDown() {
        if createdClaudeRoot {
            try? FileManager.default.removeItem(atPath: ClaudeCodeParser.root)
            try? FileManager.default.removeItem(
                atPath: (ClaudeCodeParser.root as NSString).deletingLastPathComponent)
            createdClaudeRoot = false
        }
        super.tearDown()
    }

    func testParsesAssistantUsageTurnsFromFixture() {
        let (turns, sessions) = ClaudeCodeParser.scan(knownPaths: [fixturePath])
        // Only the two assistant messages carry usage; the user message is skipped.
        XCTAssertEqual(turns.count, 2, "only assistant usage events become turns")

        let first = turns[0]
        XCTAssertEqual(first.tool, .claude)
        XCTAssertEqual(first.sessionID, "e1f5c1a2-0000-4000-8000-000000000001")
        XCTAssertEqual(first.project, "sample-project") // cwd's last path component
        XCTAssertEqual(first.model, "claude-sonnet-4-6") // read from message.model
        XCTAssertEqual(first.inputTokens, 812)
        XCTAssertEqual(first.outputTokens, 96)
        XCTAssertEqual(first.cacheRead, 0)
        XCTAssertEqual(first.cacheWrite, 0)
        XCTAssertEqual(first.ts, 1_785_837_602) // 2026-08-04T10:00:02.500Z
        XCTAssertEqual(first.cost, 812.0 / 1e6 * 3 + 96.0 / 1e6 * 15, accuracy: 0.0001)
        XCTAssertEqual(first.costQuality, "estimated", "claude-sonnet-4-6 is in the price table")
        XCTAssertTrue(first.eventID?.hasPrefix("claude:e1f5c1a2-0000-4000-8000-000000000001:fallback:") == true)

        let second = turns[1]
        XCTAssertEqual(second.inputTokens, 901)
        XCTAssertEqual(second.outputTokens, 312)
        XCTAssertEqual(second.cacheRead, 120) // cache_read_input_tokens
        XCTAssertEqual(second.cacheWrite, 0)
        XCTAssertEqual(second.ts, 1_785_837_605) // 2026-08-04T10:00:05.000Z
        XCTAssertTrue(second.eventID?.hasPrefix("claude:e1f5c1a2-0000-4000-8000-000000000001:fallback:") == true)

        // One session summary over the real time range.
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].tool, .claude)
        XCTAssertEqual(sessions[0].sessionID, "e1f5c1a2-0000-4000-8000-000000000001")
        XCTAssertEqual(sessions[0].model, "claude-sonnet-4-6")
        XCTAssertEqual(sessions[0].created, 1_785_837_602)
        XCTAssertEqual(sessions[0].updated, 1_785_837_605)
    }

    func testEventIDStableAcrossReplay() {
        // Database.shared is never opened in tests, so scan state is not
        // persisted: every scan replays the whole file from offset 0. The
        // event ids (upstream uuids) must be identical across replays so the
        // (tool, event_id) unique index dedupes instead of double-counting.
        let (first, _) = ClaudeCodeParser.scan(knownPaths: [fixturePath])
        let (replay, replaySessions) = ClaudeCodeParser.scan(knownPaths: [fixturePath])
        XCTAssertEqual(first.count, replay.count)
        for (a, b) in zip(first, replay) {
            XCTAssertEqual(a.eventID, b.eventID, "replay must not change event identity")
            XCTAssertEqual(a, b, "replay must produce identical turns")
        }
        XCTAssertEqual(first.map(\.eventID), replay.map(\.eventID))
        XCTAssertEqual(replaySessions.count, 1)
    }

    func testRepeatedTranscriptRowsShareMessageIdentity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl")
        let first = #"{"type":"assistant","sessionId":"s1","uuid":"outer-1","timestamp":"2026-08-04T10:00:02Z","message":{"id":"msg_billable","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}}}"#
        let duplicate = #"{"type":"assistant","sessionId":"s1","uuid":"outer-2","timestamp":"2026-08-04T10:00:02Z","message":{"id":"msg_billable","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}}}"#
        try "\(first)\n\(duplicate)\n".write(to: path, atomically: true, encoding: .utf8)

        let (turns, _) = ClaudeCodeParser.scan(knownPaths: [path.path])
        XCTAssertEqual(turns.count, 1, "identical snapshots of one message are one turn")
        XCTAssertEqual(turns.first?.eventID, "claude:s1:msg_billable")
        XCTAssertEqual(turns.first?.inputTokens, 10)
        XCTAssertEqual(turns.first?.outputTokens, 5)
        XCTAssertEqual(turns.first?.usageMerge, .keepGreater)
    }

    /// A streaming transcript writes the same message.id several times as
    /// usage grows. The kept row is the largest snapshot, not the first.
    func testStreamingMessageKeepsGreatestUsage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl")
        let partial = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-04T10:00:02Z","cwd":"/Users/demo/dev/toast-translate","message":{"id":"msg_stream","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":5,"cache_creation_input_tokens":10}}}"#
        let done = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-04T10:00:03Z","cwd":"/Users/demo/dev/toast-translate","message":{"id":"msg_stream","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":4}}}}"#
        try "\(partial)\n\(done)\n".write(to: path, atomically: true, encoding: .utf8)

        let (turns, _) = ClaudeCodeParser.scan(knownPaths: [path.path])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].eventID, "claude:s1:msg_stream")
        XCTAssertEqual(turns[0].outputTokens, 40)
        XCTAssertEqual(turns[0].cacheWrite, 14)
        XCTAssertEqual(turns[0].project, "toast-translate")
        let fiveMinute = 10.0 / 1e6 * 3.75
        let oneHour = 4.0 / 1e6 * 3 * 2
        let expected = 100.0 / 1e6 * 3 + 40.0 / 1e6 * 15 + fiveMinute + oneHour
        XCTAssertEqual(turns[0].cost, expected, accuracy: 0.0000001)
    }

    func testKeepingGreaterRepricesTheMergedTokens() {
        let older = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-haiku-4-5",
                               ts: 1, inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                               cost: 1, eventID: "claude:s:m", usageMerge: .keepGreater)
        let newer = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-haiku-4-5",
                               ts: 2, inputTokens: 0, outputTokens: 1_000_000, cacheRead: 0, cacheWrite: 0,
                               cost: 5, eventID: "claude:s:m", usageMerge: .keepGreater)
        let merged = TurnRecord.keepingGreater(older, newer)
        XCTAssertEqual(merged.inputTokens, 1_000_000)
        XCTAssertEqual(merged.outputTokens, 1_000_000)
        XCTAssertEqual(merged.cost, 6, accuracy: 0.0001)
        XCTAssertEqual(merged.costQuality, "estimated")
        XCTAssertEqual(merged.pricingVersion, Pricing.version)

        let cached = TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "gpt-4o",
                                ts: 1, inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                                cost: 9, eventID: "codex:s:m", usageMerge: .keepGreater)
        let reads = TurnRecord(tool: .codex, sessionID: "s", project: nil, model: "gpt-4o",
                               ts: 2, inputTokens: 0, outputTokens: 0, cacheRead: 1_000_000, cacheWrite: 0,
                               cost: 9, eventID: "codex:s:m", usageMerge: .keepGreater)
        XCTAssertEqual(TurnRecord.keepingGreater(cached, reads).cost, 1.25, accuracy: 0.0001)

        let unknownOlder = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "no-such-model",
                                      ts: 1, inputTokens: 100, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                                      cost: 1.5, eventID: "claude:s:u", costQuality: "actual",
                                      usageMerge: .keepGreater)
        let unknownNewer = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "no-such-model",
                                      ts: 2, inputTokens: 0, outputTokens: 50, cacheRead: 0, cacheWrite: 0,
                                      cost: 4, eventID: "claude:s:u", costQuality: "actual",
                                      usageMerge: .keepGreater)
        let unknown = TurnRecord.keepingGreater(unknownOlder, unknownNewer)
        XCTAssertEqual(unknown.cost, 1.5, accuracy: 0.0001)
        XCTAssertEqual(unknown.costQuality, "actual")
        XCTAssertEqual(unknown.outputTokens, 50)
    }

    func testStoredPartialMessageIsUpgraded() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-upgrade-\(UUID().uuidString).sqlite").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let partial = TurnRecord(tool: .claude, sessionID: "s1", project: "p", model: "claude-sonnet-4-6",
                                 ts: 100, inputTokens: 10, outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                                 cost: 0.01, eventID: "claude:s1:msg_billable", usageMerge: .keepGreater)
        let complete = TurnRecord(tool: .claude, sessionID: "s1", project: "p", model: "claude-sonnet-4-6",
                                  ts: 101, inputTokens: 10, outputTokens: 50, cacheRead: 4, cacheWrite: 0,
                                  cost: 0.2, eventID: "claude:s1:msg_billable", usageMerge: .keepGreater)
        XCTAssertTrue(db.insertTurns([partial]))
        XCTAssertTrue(db.insertTurns([complete]))
        let stored = db.turns(sessionTool: "claude", sessionID: "s1")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].output, 50)
        XCTAssertEqual(stored[0].cacheRead, 4)
        XCTAssertEqual(stored[0].ts, 101)
    }

    func testSubagentTranscriptsAreListedOnlyAtDepthFour() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-sub-\(UUID().uuidString)").path
        // Real layout: projects/<encoded>/<session>.jsonl beside
        // projects/<encoded>/<session>/subagents/agent-*.jsonl.
        let project = "\(root)/-Users-demo-dev-app"
        let sub = "\(project)/sess/subagents"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: "\(project)/sess.jsonl", contents: Data())
        FileManager.default.createFile(atPath: "\(sub)/agent-1.jsonl", contents: Data())
        let shallow = Set(FileScanner.listFiles(root, maxDepth: 2))
        let deep = Set(FileScanner.listFiles(root, maxDepth: 4))
        XCTAssertTrue(shallow.contains("\(project)/sess.jsonl"))
        XCTAssertFalse(shallow.contains("\(sub)/agent-1.jsonl"))
        XCTAssertTrue(deep.contains("\(sub)/agent-1.jsonl"))
    }

    func testUntimestampedRowsGetDistinctStableOffsetIdentity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-no-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.jsonl").path
        // Two rows with NO timestamp and IDENTICAL usage. The fallback digest
        // must be anchored on the byte offset: Date().now would mint a new
        // digest on every scan (duplicate import) and identical rows would
        // collide without the offset.
        try """
        {"type":"assistant","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":5}}}
        {"type":"assistant","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":5}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let first = ClaudeCodeParser.scan(knownPaths: [path]).turns
        XCTAssertEqual(first.count, 2)
        XCTAssertNotEqual(first[0].eventID, first[1].eventID,
                          "identical untimestamped rows at different offsets must not collide")

        let replay = ClaudeCodeParser.scan(knownPaths: [path]).turns
        XCTAssertEqual(replay.count, 2)
        XCTAssertEqual(first.map(\.eventID), replay.map(\.eventID),
                       "rescanning the same file must yield identical ids (stable)")
    }

    func testIgnoresMalformedLinesAndNonAssistantMessages() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s.jsonl").path
        try? """
        not json at all
        {"type":"user","sessionId":"s1","timestamp":"2026-08-04T10:00:01.000Z","message":{"role":"user","content":[],"model":"m"}}
        {"type":"assistant","sessionId":"s1","timestamp":"2026-08-04T10:00:02.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","sessionId":"s1","timestamp":"2026-08-04T10:00:03.000Z","message":{"role":"assistant","model":"m","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let (turns, _) = ClaudeCodeParser.scan(knownPaths: [path])
        XCTAssertEqual(turns.count, 1, "malformed lines and zero-token events are skipped")
        XCTAssertEqual(turns[0].inputTokens, 10)
        XCTAssertEqual(turns[0].outputTokens, 5)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Cowork's "local agent mode" writes real Claude Code transcripts under a
/// separate tree (Claude Desktop's own data directory), one level below a
/// leading-dot `.claude` component that the ordinary file lister skips.
final class ClaudeCodeParserCoworkTests: XCTestCase {

    private func makeScratchRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-scan-\(UUID().uuidString)").path
    }

    func testListCoworkFilesFindsTranscriptPastTheDotClaudeComponent() throws {
        let root = makeScratchRoot()
        let sessionDir = "\(root)/org1/proj1/local_abc/.claude/projects/-encoded-cwd"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(sessionDir)/session1.jsonl", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: root) }

        let found = ClaudeCodeParser.listCoworkFiles(root: root)
        XCTAssertEqual(found, ["\(sessionDir)/session1.jsonl"])
    }

    func testListCoworkFilesIgnoresSessionDirsNotPrefixedLocal() throws {
        let root = makeScratchRoot()
        let sessionDir = "\(root)/org1/proj1/not-a-local-session/.claude/projects/-encoded"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(sessionDir)/session1.jsonl", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(ClaudeCodeParser.listCoworkFiles(root: root), [])
    }

    func testListCoworkFilesReturnsEmptyWhenRootMissing() {
        XCTAssertEqual(ClaudeCodeParser.listCoworkFiles(root: "/nonexistent/cowork/root"), [])
    }

    /// A real Cowork transcript is byte-for-byte the same JSONL shape as a
    /// standalone-CLI one, so it must parse through the same code path with
    /// no special-casing.
    func testCoworkTranscriptParsesLikeAnyOtherClaudeTranscript() throws {
        let root = makeScratchRoot()
        let sessionDir = "\(root)/org1/proj1/local_abc/.claude/projects/-encoded-cwd"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let line = """
        {"type":"assistant","sessionId":"cowork-session-1","timestamp":"2026-08-25T10:00:00Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        try line.write(toFile: "\(sessionDir)/cowork-session-1.jsonl", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let files = ClaudeCodeParser.listCoworkFiles(root: root)
        XCTAssertEqual(files.count, 1)
        let (turns, sessions) = ClaudeCodeParser.scan(knownPaths: files)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.inputTokens, 100)
        XCTAssertEqual(turns.first?.outputTokens, 50)
        XCTAssertEqual(sessions.first?.sessionID, "cowork-session-1")
    }
}
