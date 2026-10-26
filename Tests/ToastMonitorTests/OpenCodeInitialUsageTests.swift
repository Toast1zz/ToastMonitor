import XCTest
import SQLite3
@testable import ToastMonitor

final class OpenCodeInitialUsageTests: XCTestCase {
    private var database: Database!
    private var directory: String!
    private var previousHome: String?

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tm-opencode-initial-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        database = Database.testInstance(path: directory + "/monitor.db")
        previousHome = ProcessInfo.processInfo.environment["OPENCODE_HOME"]
        setenv("OPENCODE_HOME", directory, 1)
        execute("""
          CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, directory TEXT, model TEXT, cost REAL,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER, time_updated INTEGER);
          """)
    }

    override func tearDown() {
        if let previousHome { setenv("OPENCODE_HOME", previousHome, 1) } else { unsetenv("OPENCODE_HOME") }
        database.close()
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func execute(_ sql: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory + "/opencode.db", &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    @discardableResult
    private func scan() -> [TurnRecord] {
        var turns: [TurnRecord] = []
        let result = CollectorEngine.prepareAndCommit(database: database, sourcePaths: [directory + "/opencode.db"]) {
            let result = OpenCodeParser.scan(database: $0)
            turns = result.turns
            return result
        }
        XCTAssertTrue(result.committed)
        return turns
    }

    func testReadOnlyInitialUsageImportsOnceAndContinuesGrowing() {
        execute("INSERT INTO session VALUES('read', '', '', 'gpt-4o', 0.2, 0,0,0,100,0,1790000000,1790000001);")
        scan()
        scan()
        XCTAssertEqual(database.turnCount(), 1)
        execute("UPDATE session SET tokens_cache_read=150, time_updated=1790000002 WHERE id='read';")
        scan()
        scan()
        let rows = database.turns(sessionTool: "opencode", sessionID: "read")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.cacheRead }, 150)
    }

    func testWriteOnlyInitialUsageImportsOnce() {
        execute("INSERT INTO session VALUES('write', '', '', 'gpt-4o', 0.2, 0,0,0,0,100,1790000000,1790000001);")
        scan()
        scan()
        let rows = database.turns(sessionTool: "opencode", sessionID: "write")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cacheWrite, 100)
    }

    func testMissingSourceCostRemainsUnknownAndCanBeEstimated() {
        execute("INSERT INTO session VALUES('unknown', '', '', 'gpt-4o', NULL, 1000000,0,0,0,0,1790000000,1790000001);")
        scan()
        database.backfillCosts()
        XCTAssertEqual(database.costBreakdown(from: 0, to: 2_000_000_000).actual, 0)
        XCTAssertEqual(database.costBreakdown(from: 0, to: 2_000_000_000).estimated, 2.5)
    }
    func testLegacyCombinedBaselineMigratesOnceAndKeepsFutureGrowth() {
        XCTAssertTrue(database.setSessionTotals("opencode|legacy", tool: "opencode", input: 120, output: 0,
                                                reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, updated: 1790000000))
        execute("INSERT INTO session VALUES('legacy', '', '', 'gpt-4o', 0, 100,0,20,0,0,1790000000,1790000001);")
        scan()
        XCTAssertEqual(database.turnCount(), 0)
        XCTAssertEqual(database.sessionTotals()["opencode|legacy"]?.input, 100)
        XCTAssertEqual(database.sessionTotals()["opencode|legacy"]?.reasoning, 20)
        execute("UPDATE session SET tokens_input=110, tokens_reasoning=22, time_updated=1790000002 WHERE id='legacy';")
        let delta = scan()
        XCTAssertTrue(scan().isEmpty)
        var rows = database.turns(sessionTool: "opencode", sessionID: "legacy")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(delta.first?.inputTokens, 10)
        XCTAssertEqual(delta.first?.reasoningTokens, 2)
        execute("UPDATE session SET tokens_input=105, tokens_reasoning=21, time_updated=1790000003 WHERE id='legacy';")
        scan()
        XCTAssertEqual(database.turnCount(), 1)
        execute("UPDATE session SET tokens_input=112, tokens_reasoning=24, time_updated=1790000004 WHERE id='legacy';")
        let regrowth = scan()
        XCTAssertEqual(regrowth.first?.inputTokens, 2)
        XCTAssertEqual(regrowth.first?.reasoningTokens, 2)
        rows = database.turns(sessionTool: "opencode", sessionID: "legacy")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.input }, 12)
        XCTAssertEqual(database.sessionTotals()["opencode|legacy"]?.reasoning, 24)
    }

}
