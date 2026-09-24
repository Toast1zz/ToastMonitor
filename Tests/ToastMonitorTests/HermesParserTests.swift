import XCTest
import SQLite3
@testable import ToastMonitor

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// PARSER-3: the Hermes local delta baseline is a per-counter HIGH-WATER
/// MARK. A source rollback (cumulative totals dropping) must not reset the
/// origin, or the regrowth beyond the old peak would be re-counted from the
/// dip.
final class HermesParserTests: XCTestCase {
    private var db: Database!
    private var dbPath = ""
    private var homeDir = ""

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-db-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-home-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        setenv("HERMES_HOME", homeDir, 1)
    }

    override func tearDown() {
        unsetenv("HERMES_HOME")
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        try? FileManager.default.removeItem(atPath: homeDir)
        super.tearDown()
    }

    /// Writes the per-message token usage rows for session "s1".
    private func writeMessages(_ input: Int64, _ output: Int64, ts: Int64) {
        var raw: OpaquePointer?
        let path = HermesParser.dbPath
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS messages (session_id TEXT PRIMARY KEY, input_tokens INTEGER, output_tokens INTEGER, created_at INTEGER);
        """
        XCTAssertEqual(sqlite3_exec(raw, schema, nil, nil, nil), SQLITE_OK)
        let sql = "INSERT OR REPLACE INTO messages (session_id, input_tokens, output_tokens, created_at) VALUES (?,?,?,?);"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, ("s1" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, input)
        sqlite3_bind_int64(stmt, 3, output)
        sqlite3_bind_int64(stmt, 4, ts)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    func testRollbackBaselineIsHighWaterMark() {
        writeMessages(1000, 500, ts: 1786628706)
        let (first, _) = HermesParser.scan(database: db)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].inputTokens, 1000)
        XCTAssertEqual(first[0].outputTokens, 500)

        // The source rolls back below the recorded baseline.
        writeMessages(400, 200, ts: 1786628806)
        let (rolled, _) = HermesParser.scan(database: db)
        XCTAssertTrue(rolled.isEmpty, "rollback must not emit negative deltas")
        let totals = db.sessionTotals()
        XCTAssertEqual(totals["hermes|s1"]?.input, 1000, "baseline input never drops")
        XCTAssertEqual(totals["hermes|s1"]?.output, 500, "baseline output never drops")

        // Regrowth beyond the old peak counts only the increase past the max.
        writeMessages(1200, 700, ts: 1786628906)
        let (third, _) = HermesParser.scan(database: db)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].inputTokens, 200, "1200 - max(1000, 400) = 200, not 800")
        XCTAssertEqual(third[0].outputTokens, 200, "700 - max(500, 200) = 200, not 500")
    }

    // MARK: - Profiles and session_model_usage (current Hermes schema)

    /// Writes one cumulative usage row into a profile's store ("" = default).
    private func writeUsage(profile: String = "", session: String, input: Int64, output: Int64,
                            cacheRead: Int64 = 0, firstSeen: Double = 1_790_000_000,
                            lastSeen: Double = 1_790_000_600) {
        let dir = profile.isEmpty ? homeDir : "\(homeDir)/profiles/\(profile)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2("\(dir)/state.db", &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, started_at REAL);
        CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session_id TEXT, token_count INTEGER, timestamp REAL);
        CREATE TABLE IF NOT EXISTS session_model_usage (
          session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT,
          input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
          cache_write_tokens INTEGER, reasoning_tokens INTEGER,
          first_seen REAL, last_seen REAL, PRIMARY KEY (session_id, model));
        """
        XCTAssertEqual(sqlite3_exec(raw, schema, nil, nil, nil), SQLITE_OK)
        let sql = """
        INSERT OR REPLACE INTO session_model_usage VALUES
          ('\(session)', 'deepseek/deepseek-v4.1-flash', 'custom', 'https://api.example.com/v1/',
           \(input), \(output), \(cacheRead), 0, 0, \(firstSeen), \(lastSeen));
        """
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK)
    }

    private func key(_ session: String) -> String {
        HermesUsageBaseline.key(session: session, model: "deepseek/deepseek-v4.1-flash",
                                provider: "custom", baseURL: "https://api.example.com/v1/")
    }

    func testEveryProfileIsScanned() {
        writeUsage(session: "default-s", input: 100, output: 10)
        writeUsage(profile: "hermesrp", session: "rp-s", input: 700, output: 70)
        try? FileManager.default.createDirectory(atPath: "\(homeDir)/profiles/empty",
                                                 withIntermediateDirectories: true)
        XCTAssertEqual(HermesParser.dbPaths.count, 2)

        let (turns, _) = HermesParser.scan(database: db)
        XCTAssertEqual(Set(turns.map(\.sessionID)), ["default-s", "rp-s"])
        XCTAssertEqual(turns.reduce(0) { $0 + $1.inputTokens }, 800)
    }

    func testUsageRowsYieldDeltasAgainstBaseline() {
        writeUsage(profile: "hermesrp", session: "s", input: 1_000, output: 100, cacheRead: 5_000)
        let (first, _) = HermesParser.scan(database: db)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].ts, 1_790_000_000, "first sighting is dated to the session start")
        XCTAssertEqual(first[0].cacheRead, 5_000)

        XCTAssertTrue(HermesParser.scan(database: db).turns.isEmpty, "unchanged counters emit nothing")

        writeUsage(profile: "hermesrp", session: "s", input: 1_300, output: 150, cacheRead: 9_000,
                   lastSeen: 1_790_001_000)
        let (grown, _) = HermesParser.scan(database: db)
        XCTAssertEqual(grown.count, 1)
        XCTAssertEqual(grown[0].inputTokens, 300)
        XCTAssertEqual(grown[0].outputTokens, 50)
        XCTAssertEqual(grown[0].cacheRead, 4_000)
        XCTAssertEqual(grown[0].ts, 1_790_001_000)
    }

    /// Switching remote -> local continues from the feed's baseline.
    func testLocalScanContinuesFromRemoteBaseline() {
        XCTAssertTrue(db.setSetting(key("s"), "1000,100,0,5000,0,0"))
        writeUsage(session: "s", input: 1_200, output: 130, cacheRead: 5_500)
        let (turns, _) = HermesParser.scan(database: db)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].inputTokens, 200)
        XCTAssertEqual(turns[0].outputTokens, 30)
        XCTAssertEqual(turns[0].cacheRead, 500)
    }

    /// Switching local -> remote continues from the local baseline.
    func testRemoteFeedContinuesFromLocalBaseline() {
        writeUsage(session: "s", input: 1_000, output: 100)
        XCTAssertEqual(HermesParser.scan(database: db).turns.count, 1)

        XCTAssertTrue(db.setSetting("src_hermes", "remote"))
        let row: [String: Any] = [
            "tool": "hermes", "session_id": "s", "model": "deepseek/deepseek-v4.1-flash",
            "billing_provider": "custom", "billing_base_url": "https://api.example.com/v1",
            "input_tokens": NSNumber(value: 1_250), "output_tokens": NSNumber(value: 140),
            "first_seen": NSNumber(value: 1_790_000_000), "last_seen": NSNumber(value: 1_790_002_000),
            "event_id": "hermes:s:deepseek/deepseek-v4.1-flash:1790002000"
        ]
        HermesRemoteClient.shared.importFeed(["rows": [row]], database: db)
        let remote = db.turns(sessionTool: "hermes", sessionID: "s").filter { $0.ts == 1_790_002_000 }
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.input, 250)
        XCTAssertEqual(remote.first?.output, 40)
    }
}
