import XCTest
@testable import ToastMonitor

final class ReviewRegressionTests: XCTestCase {
    private var db: Database!
    private var dbPath = ""

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-regression-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
    }

    override func tearDown() {
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    private func write(_ name: String, _ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func tokenCount(_ time: String, last: Int, total: Int) -> String {
        #"{"timestamp":"2026-08-04T\#(time)Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(last),"output_tokens":1},"total_token_usage":{"input_tokens":\#(total),"output_tokens":1}}}}"#
    }

    private let rollout = "rollout-2026-08-04T09-22-33-019fcb70-2990-7ae3-897a-826135c6b1c5.jsonl"

    func testCodexRestartedTotalIsCountedFromTheNewBaseline() throws {
        let path = try write(rollout, [
            tokenCount("09:00:01", last: 500, total: 500),
            tokenCount("09:00:02", last: 20, total: 20),
            tokenCount("09:00:03", last: 30, total: 50),
            tokenCount("09:00:04", last: 40, total: 90),
        ].joined(separator: "\n") + "\n")
        let turns = CodexParser.scan(files: [path], database: db).turns
        XCTAssertEqual(turns.map(\.inputTokens), [500, 20, 30, 40])
    }

    func testCodexAppendWithoutSavedTotalCountsOnlyTheNewTurn() throws {
        let path = try write(rollout, tokenCount("09:00:01", last: 3_000_000, total: 3_000_000) + "\n")
        XCTAssertTrue(db.insertTurns(CodexParser.scan(files: [path], database: db).turns))

        let state = db.scanState(path)
        var ctx = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(state.context).utf8)) as? [String: Any])
        ctx.removeValue(forKey: "has_total")
        ctx.removeValue(forKey: "total")
        let old = String(data: try JSONSerialization.data(withJSONObject: ctx), encoding: .utf8)
        XCTAssertTrue(db.setScanState(path, size: state.size, mtime: state.mtime,
                                      identity: state.identity, context: old))

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((tokenCount("09:00:09", last: 10, total: 3_000_010) + "\n").utf8))
        handle.closeFile()

        let turns = CodexParser.scan(files: [path], database: db).turns
        XCTAssertEqual(turns.map(\.inputTokens), [10])
    }

    func testDSHMessagesWithoutTurnOrStepStayDistinct() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-regression-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        setenv("DSH_HOME", tempDir, 1)
        defer {
            unsetenv("DSH_HOME")
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let body = """
        {"type":"session","id":"sess-x","cwd":"/tmp/p"}
        {"type":"assistant/message","seq":1,"time":1786628800000,"data":{"message":{"model":"deepseek-v4-flash","usage":{"inputTokens":10,"outputTokens":1}}}}
        {"type":"assistant/message","seq":2,"time":1786628801000,"data":{"message":{"model":"deepseek-v4-flash","usage":{"inputTokens":20,"outputTokens":2}}}}
        """
        let path = try write("session.jsonl", body + "\n")
        let turns = DSHParser.scanLogs(knownPaths: [path], database: db).turns
        XCTAssertEqual(Set(turns.compactMap(\.eventID)).count, 2)
        XCTAssertTrue(db.insertTurns(turns))
        XCTAssertEqual(db.totals(from: 0, to: Int64.max, tool: .dsh).count, 2)
    }

    func testPricingAcceptsColonAndUnderscoreSuffixes() {
        for model in ["qwen3:8b", "kimi_k2", "gpt-5:latest", "glm_4.6"] {
            XCTAssertNotNil(Pricing.estimate(model: model, input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0), model)
        }
        XCTAssertNil(Pricing.estimate(model: "gpt-5x", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testMixedKeepGreaterClearsRevisionSoBackfillReprices() throws {
        func record(_ input: Int64, _ output: Int64) -> TurnRecord {
            TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-sonnet-4-5", ts: 1_786_000_000,
                       inputTokens: input, outputTokens: output, cacheRead: 0, cacheWrite: 0,
                       cost: Pricing.estimate(model: "claude-sonnet-4-5", input: input, output: output,
                                              cacheRead: 0, cacheWrite: 0)!,
                       eventID: "claude:s:m2", usageMerge: .keepGreater)
        }
        XCTAssertTrue(db.insertTurns([record(1_000_000, 500_000)]))
        XCTAssertTrue(db.insertTurns([record(900_000, 800_000)]))
        db.backfillCosts()
        let row = try XCTUnwrap(db.turns(sessionTool: "claude", sessionID: "s").first)
        XCTAssertEqual(row.cost, 3.0 + 12.0, accuracy: 0.000001)
    }

    func testRolledBackBalanceSnapshotLeavesNoPoint() {
        func snapshot(_ ts: Int64, _ value: Double) -> Database.ORSnapshot {
            Database.ORSnapshot(ts: ts, usage: 0, usageDaily: 0, usageWeekly: 0, usageMonthly: 0, limit: nil,
                                limitRemaining: nil, limitReset: nil, isFreeTier: false, creditsTotal: nil,
                                creditsUsage: value, accountUsage: nil, accountBalance: nil, isManagementKey: false)
        }
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(db.insertORSnapshot(snapshot(now - 300, 1)))
        _ = db.inTransaction { _ = db.insertORSnapshot(snapshot(now - 200, 99)); return false }
        XCTAssertEqual(db.orCreditUsage(since: 0).map(\.ts), [now - 300])
        XCTAssertTrue(db.inTransaction { db.insertORSnapshot(snapshot(now - 100, 5)) })
        XCTAssertEqual(db.orCreditUsage(since: 0).map(\.ts), [now - 300, now - 100])
    }
}
