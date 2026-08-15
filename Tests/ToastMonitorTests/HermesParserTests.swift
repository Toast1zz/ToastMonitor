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
}
