import SQLite3
import XCTest
@testable import ToastMonitor

/// Another app's WAL database after that app has quit: SQLite checkpoints and
/// deletes `-wal`/`-shm` on the last close, and a plain read-only connection
/// then fails with SQLITE_CANTOPEN because it cannot create `-shm`.
final class SQLiteReadOnlyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-sqlite-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a WAL-mode database with one gen_metadata row, then closes it so
    /// the side files are gone, the way Antigravity leaves its conversations.
    private func makeClosedWALDatabase(name: String = "conv.db") throws -> String {
        let path = dir.appendingPathComponent(name).path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        for sql in ["PRAGMA journal_mode=WAL;",
                    "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);",
                    "INSERT INTO gen_metadata (idx, data) VALUES (1, x'00');",
                    "PRAGMA wal_checkpoint(TRUNCATE);"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)
        // Apple's SQLite keeps the side files (persistent WAL); the apps we
        // read use their own SQLite, which deletes them on close.
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        return path
    }

    func testClosedWALDatabaseIsReadable() throws {
        let path = try makeClosedWALDatabase()
        guard let db = SQLiteReadOnly.open(path) else { return XCTFail("open failed") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM gen_metadata;", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        sqlite3_finalize(stmt)
    }

    func testAntigravityReadsConversationAfterAppQuits() throws {
        let path = try makeClosedWALDatabase()
        XCTAssertNotNil(AntigravityParser.readGenerations(path: path, after: 0),
                        "a quit Antigravity must not read as a source error")
    }

    func testMissingFileStillFails() {
        XCTAssertNil(SQLiteReadOnly.open(dir.appendingPathComponent("absent.db").path))
    }
}
