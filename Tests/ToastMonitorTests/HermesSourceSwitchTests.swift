import XCTest
import SQLite3
@testable import ToastMonitor

final class HermesSourceSwitchTests: XCTestCase {
    private var database: Database!
    private var directory: String!
    private var previousHome: String?

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tm-hermes-switch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        database = Database.testInstance(path: directory + "/monitor.db")
        previousHome = ProcessInfo.processInfo.environment["HERMES_HOME"]
        setenv("HERMES_HOME", directory, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("HERMES_HOME", previousHome, 1) } else { unsetenv("HERMES_HOME") }
        database.close()
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func local(_ input: Int64, reasoning: Int64 = 0, write: Int64 = 0) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory + "/state.db", &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE IF NOT EXISTS session_model_usage (
              session_id TEXT PRIMARY KEY, model TEXT, billing_provider TEXT, billing_base_url TEXT,
              input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
              cache_read_tokens INTEGER, cache_write_tokens INTEGER, first_seen INTEGER, last_seen INTEGER);
            INSERT OR REPLACE INTO session_model_usage VALUES
              ('switch', 'model', 'provider', 'https://example.com', \(input), 10, \(reasoning), 0, \(write), \(now - 60), \(now));
            """, nil, nil, nil), SQLITE_OK)
        let result = CollectorEngine.prepareAndCommit(database: database, sourcePaths: [directory + "/state.db"]) {
            HermesParser.scan(database: $0)
        }
        XCTAssertTrue(result.committed)
    }

    private func remote(_ counts: [Int64]) {
        XCTAssertTrue(database.setSetting("src_hermes", "remote"))
        let now = Int64(Date().timeIntervalSince1970)
        let rows: [[String: Any]] = counts.map { count in
            ["tool": "hermes", "session_id": "switch", "model": "model",
             "billing_provider": "provider", "billing_base_url": "https://example.com/",
             "input_tokens": count, "output_tokens": 10, "first_seen": now - 60,
             "last_seen": now, "event_id": "switch-\(count)"]
        }
        HermesRemoteClient.shared.importFeed(["rows": rows], database: database)
    }

    private var inputTotal: Int64 {
        database.turns(sessionTool: "hermes", sessionID: "switch").reduce(0) { $0 + $1.input }
    }

    func testLocalRemoteLocalUsesSharedHighWater() throws {
        try local(100)
        remote([150])
        try local(150)
        XCTAssertEqual(inputTotal, 150)
    }

    func testRemoteLocalRemoteUsesSharedHighWater() throws {
        remote([100])
        try local(150)
        remote([150])
        XCTAssertEqual(inputTotal, 150)
    }

    func testRollbackRegrowAndDuplicateFeedRowsDoNotReplayHistory() throws {
        try local(100)
        remote([150, 150, 90, 160])
        try local(90)
        try local(160)
        try local(170)
        remote([170, 170])
        XCTAssertEqual(inputTotal, 170)
        let key = HermesUsageBaseline.key(session: "switch", model: "model", provider: "provider", baseURL: "https://example.com")
        XCTAssertEqual(HermesUsageBaseline.parse(database.setting(key)).first, 170)
        XCTAssertEqual(database.sessionTotals()[HermesUsageBaseline.localTotalsKey(key)]?.input, 170)
    }

    func testLegacyAndModernBaselinesMergeWithoutReplayingReasoning() {
        let current = HermesUsageBaseline.Counters(input: 100, output: 20, reasoning: 10, cacheRead: 3, cacheWrite: 4)
        let merged = HermesUsageBaseline.merge(current: current, baselines: [
            [110, 20, 3, 4, 0], [100, 20, 10, 3, 4, 0]
        ])
        XCTAssertEqual(merged, [100, 20, 10, 3, 4, 0])
        XCTAssertEqual(HermesUsageBaseline.advance(current: current, prev: merged).delta,
                       .init(input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testConcurrentRemoteBaselineChangeInvalidatesPreparedLocalScan() {
        let key = HermesUsageBaseline.key(session: "switch", model: "model", provider: nil, baseURL: nil)
        let staged = StagedParserStateStore(database: database, sourcePaths: [])
        XCTAssertNil(staged.setting(key))
        XCTAssertTrue(staged.setSetting(key, "100,0,0,0,0,0"))
        XCTAssertTrue(database.setSetting(key, "150,0,0,0,0,0"))
        XCTAssertFalse(staged.validateForCommit())
        XCTAssertEqual(database.setting(key), "150,0,0,0,0,0")
    }
}
