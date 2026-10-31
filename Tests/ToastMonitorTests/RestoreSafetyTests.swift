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
        let expanded = directory + "/recovery.db"
        XCTAssertTrue(DataMaintenance.expand(URL(fileURLWithPath: snapshot), to: URL(fileURLWithPath: expanded)))
        let recovery = Database.testInstance(path: expanded)
        defer { recovery.close() }
        XCTAssertEqual(recovery.turnCount(), 0)
        XCTAssertEqual(database.turnCount(), 1)
    }

    func testDamagedStoreIsReportedAndRecoveredWithoutDeletingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tm-damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let goodPath = directory.appendingPathComponent("good.db").path
        let good = Database.testInstance(path: goodPath)
        XCTAssertNil(good.openProblem)
        XCTAssertTrue(good.insertTurns([TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "m", ts: 1,
                                                   inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0,
                                                   cost: 0, eventID: "e")]))
        let backups = directory.appendingPathComponent("backups")
        let backup = try XCTUnwrap(DataMaintenance.createBackup(label: "weekly", database: good, backupDirectory: backups))
        good.close()

        let badPath = directory.appendingPathComponent("bad.db").path
        try Data(repeating: 0x41, count: 8192).write(to: URL(fileURLWithPath: badPath))
        let bad = Database.testInstance(path: badPath)
        defer { bad.close() }
        guard case .damaged = bad.openProblem else { return XCTFail("a random file must read as damaged") }

        XCTAssertTrue(DataMaintenance.recover(from: URL(fileURLWithPath: backup), database: bad))
        XCTAssertNil(bad.openProblem)
        XCTAssertEqual(bad.turnCount(), 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("bad.db.damaged-") }, "the broken file must be kept")
    }

    func testStartingFreshFromADamagedStoreKeepsTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tm-damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("bad.db").path
        try Data(repeating: 0x41, count: 8192).write(to: URL(fileURLWithPath: path))
        let bad = Database.testInstance(path: path)
        defer { bad.close() }
        XCTAssertNotNil(bad.openProblem)
        XCTAssertTrue(DataMaintenance.recover(from: nil, database: bad))
        XCTAssertNil(bad.openProblem)
        XCTAssertEqual(bad.turnCount(), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("bad.db.damaged-") })
    }

    func testReadOnlyStoreIsReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tm-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("ro.db").path
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let writable = Database.testInstance(path: path)
        writable.close()
        // Opening re-asserts file modes, so only the immutable flag stays read-only.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        let store = Database.testInstance(path: path)
        defer { store.close() }
        XCTAssertNotNil(store.openProblem)
    }
}
