import XCTest
import SQLite3
@testable import ToastMonitor

final class RestoreSafetyTests: XCTestCase {
    private var database: Database!
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tm-restore-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        database = Database.testInstance(path: directory + "/live.db")
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .codex, sessionID: "live", project: nil,
            model: "gpt-4o", ts: 100, inputTokens: 100, outputTokens: 0, cacheRead: 0,
            cacheWrite: 0, cost: 0, eventID: "live")]))
    }

    override func tearDown() {
        database.close()
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func execute(_ sql: String, at path: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testRejectsSameTableNamesWithWrongColumnsBeforeReplacingData() {
        let path = directory + "/foreign.db"
        for table in ["turns", "sessions", "scan_state", "session_totals", "openrouter_snapshots",
                      "opencodego_snapshots", "subscriptions", "settings"] {
            execute("CREATE TABLE \(table)(foreign_column TEXT);", at: path)
        }
        XCTAssertFalse(database.restore(from: path))
        XCTAssertEqual(database.turnCount(), 1)
        XCTAssertEqual(database.turns(sessionTool: "codex", sessionID: "live").first?.input, 100)
    }

    func testRejectsMissingColumnsWrongTypesAndFutureSchema() {
        for (index, sql) in [
            "ALTER TABLE turns DROP COLUMN output_tokens;",
            "ALTER TABLE settings RENAME TO old_settings; CREATE TABLE settings(k INTEGER PRIMARY KEY, v BLOB);",
            "PRAGMA user_version=999;"
        ].enumerated() {
            let path = directory + "/invalid-\(index).db"
            XCTAssertTrue(database.backup(to: path))
            execute(sql, at: path)
            XCTAssertFalse(database.restore(from: path))
            XCTAssertEqual(database.turnCount(), 1)
        }
    }

    func testOldVersionSnapshotIsMigratedWithoutChangingSource() {
        let path = directory + "/old.db"
        XCTAssertTrue(database.backup(to: path))
        execute("PRAGMA user_version=1; ALTER TABLE turns DROP COLUMN reasoning_tokens;", at: path)
        XCTAssertTrue(database.clearAllData())
        XCTAssertTrue(database.restore(from: path))
        XCTAssertEqual(database.turnCount(), 1)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testValidatedRestoreRequiresSnapshotAndRetainsPreRestoreContents() {
        let source = directory + "/source.db"
        XCTAssertTrue(database.backup(to: source))
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .codex, sessionID: "later", project: nil,
            model: "gpt-4o", ts: 101, inputTokens: 200, outputTokens: 0, cacheRead: 0,
            cacheWrite: 0, cost: 0, eventID: "later")]))
        XCTAssertFalse(database.restore(from: source, beforeReplace: { nil }))
        XCTAssertEqual(database.turnCount(), 2)
        let snapshot = directory + "/pre-restore.db"
        XCTAssertTrue(database.restore(from: source, beforeReplace: {
            self.database.backup(to: snapshot) ? snapshot : nil
        }))
        XCTAssertEqual(database.turnCount(), 1)
        let recovery = Database.testInstance(path: snapshot)
        defer { recovery.close() }
        XCTAssertEqual(recovery.turnCount(), 2)
    }

    func testManagedRestoreCreatesPrivateRecoverySnapshot() throws {
        let backups = URL(fileURLWithPath: directory).appendingPathComponent("backups")
        let source = try XCTUnwrap(DataMaintenance.createBackup(label: "manual", database: database, backupDirectory: backups))
        XCTAssertTrue(database.clearAllData())
        let snapshot = try XCTUnwrap(DataMaintenance.restoreWithReceipt(backupPath: source,
            database: database, backupDirectory: backups))
        XCTAssertTrue((snapshot as NSString).lastPathComponent.hasPrefix("toastmonitor-pre-restore-"))
        let recovery = Database.testInstance(path: snapshot)
        defer { recovery.close() }
        XCTAssertEqual(recovery.turnCount(), 0)
        XCTAssertEqual(database.turnCount(), 1)
    }
}
