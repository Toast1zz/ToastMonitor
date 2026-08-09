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
        XCTAssertEqual(first.project, "Fixtures") // encoded parent dir last component
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
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.compactMap(\.eventID)), ["claude:s1:msg_billable"])
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
