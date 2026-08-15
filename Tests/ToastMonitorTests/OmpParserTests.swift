import XCTest
@testable import ToastMonitor

final class OmpParserTests: XCTestCase {
    private var dbPath = ""
    private var db: Database!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-db-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
    }

    override func tearDown() {
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    private var fixturePath: String {
        // swift-test-resources: Fixtures are copied into the test bundle
        // as a subdirectory (Package.swift resources: .copy("Fixtures")).
        Bundle.module.url(forResource: "omp-sample", withExtension: "jsonl",
                          subdirectory: "Fixtures")!.path
    }

    func testParsesAssistantUsageEvents() {
        let (turns, sessions) = OmpParser.scan(knownPaths: [fixturePath], database: db)
        // Two assistant messages carry usage; the user message is skipped.
        XCTAssertEqual(turns.count, 2, "only assistant usage events become turns")
        let first = turns[0]
        XCTAssertEqual(first.tool, .omp)
        XCTAssertEqual(first.inputTokens, 18585)
        XCTAssertEqual(first.outputTokens, 241)
        XCTAssertEqual(first.cacheRead, 0)
        XCTAssertEqual(first.model, "deepseek-v4-flash")
        XCTAssertEqual(first.cost, 0.0027, accuracy: 0.0001)
        XCTAssertEqual(first.costQuality, "estimated")
        // Session id derives from the transcript's session event UUID.
        XCTAssertEqual(first.sessionID, "019f0000-0000-7000-0000-000000000001")
        XCTAssertEqual(first.project, "Fixtures") // encoded parent dir last component
        // The second turn carries cacheRead separately from input.
        XCTAssertEqual(turns[1].cacheRead, 18816)
        XCTAssertEqual(turns[1].inputTokens, 22)
        // Stable per-message event ids.
        XCTAssertEqual(turns[0].eventID, "omp:omp-sample.jsonl:msg2")
        XCTAssertEqual(turns[1].eventID, "omp:omp-sample.jsonl:msg3")
        XCTAssertNotEqual(turns[0].eventID, turns[1].eventID)
        // One session summary with the real time range.
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].created, 1_786_096_805) // 2026-08-07T10:00:05Z
        XCTAssertEqual(sessions[0].updated, 1_786_096_808)
        XCTAssertEqual(sessions[0].model, "deepseek-v4-flash")
    }

    func testIgnoresMalformedLinesAndNonAssistantMessages() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s.jsonl").path
        try? """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-07T10:00:00.000Z","cwd":"/tmp"}
        not json at all
        {"type":"message","id":"a1","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}
        {"type":"message","id":"a2","timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","usage":{"input":0,"output":0}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let (turns, _) = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(turns.count, 1, "malformed lines and zero-token events are skipped")
        XCTAssertEqual(turns[0].inputTokens, 10)
        try? FileManager.default.removeItem(at: dir)
    }

    func testTrailingPartialLineRetainsSessionContextAndIsRetried() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-partial-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let header = #"{"type":"session","id":"stable-session","timestamp":"2026-08-07T10:00:00.000Z"}"# + "\n"
        let partial = #"{"type":"message","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10"#
        try (header + partial).write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(OmpParser.scan(knownPaths: [path], database: db).turns.isEmpty)
        XCTAssertTrue(db.scanState(path).context?.contains("stable-session") == true)

        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(#","output":5}}}"#.utf8))
        try fh.write(contentsOf: Data("\n".utf8))
        try fh.close()

        let retry = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(retry.turns.count, 1)
        XCTAssertEqual(retry.turns[0].sessionID, "stable-session")
        XCTAssertEqual(retry.turns[0].inputTokens, 10)
    }
    func testAppendedBatchReusesPersistedSessionIdentity() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-append-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let initial = """
        {"type":"session","id":"stable-session","timestamp":"2026-08-07T10:00:00.000Z"}
        {"type":"message","id":"a1","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","model":"m","usage":{"input":10,"output":5}}}
        """ + "\n" // newline-terminated so the append-only cursor sits on a line boundary
        try initial.write(toFile: path, atomically: true, encoding: .utf8)

        let first = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(first.turns.count, 1)
        XCTAssertEqual(first.turns[0].sessionID, "stable-session")

        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("""
        {"type":"message","id":"a2","timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","model":"m","usage":{"input":11,"output":6}}}
        """.utf8))
        try fh.close()

        let appended = OmpParser.scan(knownPaths: [path], database: db)
        let filename = (path as NSString).lastPathComponent
        // Append-only path: only the new event is parsed, with the session
        // identity restored from scan_state (not the filename stem).
        XCTAssertEqual(appended.turns.count, 1)
        XCTAssertEqual(appended.turns[0].sessionID, "stable-session")
        XCTAssertEqual(appended.turns[0].eventID, "omp:\(filename):a2")
    }
    func testShrinkThenRegrowRescansTranscriptHeader() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-regrow-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let initial = """
        {"type":"session","id":"old-session","timestamp":"2026-08-07T10:00:00.000Z"}
        {"type":"message","id":"old","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}
        {"type":"message","id":"old2","timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","usage":{"input":11,"output":6}}}
        """
        try initial.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(OmpParser.scan(knownPaths: [path], database: db).turns.count, 2)

        let replacement = """
        {"type":"session","id":"new-session","timestamp":"2026-08-07T11:00:00.000Z"}
        {"type":"message","id":"new","timestamp":"2026-08-07T11:00:01.000Z","message":{"role":"assistant","usage":{"input":20,"output":7}}}
        """
        let rewrite = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try rewrite.truncate(atOffset: 0)
        try rewrite.write(contentsOf: Data(replacement.utf8))
        try rewrite.close()

        let shrunk = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(shrunk.turns.count, 1)
        XCTAssertEqual(shrunk.turns[0].sessionID, "new-session")

        let append = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try append.seekToEnd()
        try append.write(contentsOf: Data(("\n" + """
        {"type":"message","id":"new2","timestamp":"2026-08-07T11:00:02.000Z","message":{"role":"assistant","usage":{"input":21,"output":8}}}
        """).utf8))
        try append.close()

        let regrown = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(regrown.turns.count, 2)
        XCTAssertTrue(regrown.turns.allSatisfy { $0.sessionID == "new-session" })
    }



    func testTruncateRegrowWithoutObservedShrinkImportsRewrittenEvents() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-regrow-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let initial = """
        {"type":"session","id":"s1","timestamp":"2026-08-07T10:00:00.000Z"}
        {"type":"message","id":"a1","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}
        {"type":"message","id":"a2","timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","usage":{"input":11,"output":6}}}
        """
        try initial.write(toFile: path, atomically: true, encoding: .utf8)
        let first = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(first.turns.count, 2)
        XCTAssertTrue(db.insertTurns(first.turns))

        // One-shot truncate + regrow to DIFFERENT, LARGER content: the shrink
        // happens between polls, so the parser never observes it. The old
        // cursor lands mid-line inside the new file — a genuine append can
        // never do that — so the file must be rescanned from 0.
        let replacement = """
        {"type":"session","id":"s1","timestamp":"2026-08-07T11:00:00.000Z"}
        {"type":"message","id":"b1","timestamp":"2026-08-07T11:00:01.000Z","message":{"role":"assistant","usage":{"input":20,"output":7}}}
        {"type":"message","id":"b2","timestamp":"2026-08-07T11:00:02.000Z","message":{"role":"assistant","usage":{"input":211,"output":8}}}
        {"type":"message","id":"b3","timestamp":"2026-08-07T11:00:03.000Z","message":{"role":"assistant","usage":{"input":22,"output":9}}}
        """
        XCTAssertGreaterThan(Data(replacement.utf8).count, Data(initial.utf8).count,
                             "regrown file must be larger than the old cursor")
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data(replacement.utf8))
        try fh.close()

        let second = OmpParser.scan(knownPaths: [path], database: db)
        XCTAssertEqual(second.turns.count, 3, "rewritten events must be re-read from 0, not skipped")
        XCTAssertTrue(second.turns.allSatisfy { $0.eventID?.contains(":b") == true })
        XCTAssertTrue(db.insertTurns(second.turns))
        XCTAssertEqual(db.totals(from: 0, to: Int64.max, tool: .omp).count, 5,
                       "old events deduped; all three rewritten events imported")
    }

    func testMissingMessageIDsUseDistinctContentIdentity() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-no-id-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try """
        {"type":"session","id":"s1","timestamp":"2026-08-07T10:00:00.000Z"}
        {"type":"message","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}
        {"type":"message","timestamp":"2026-08-07T10:00:01.000Z","message":{"role":"assistant","usage":{"input":11,"output":5}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let turns = OmpParser.scan(knownPaths: [path], database: db).turns
        XCTAssertEqual(turns.count, 2)
        XCTAssertNotEqual(turns[0].eventID, turns[1].eventID)
        XCTAssertTrue(turns.allSatisfy { $0.eventID?.contains(":fallback:") == true })
    }
}
