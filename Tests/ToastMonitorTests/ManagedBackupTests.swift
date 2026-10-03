import XCTest
@testable import ToastMonitor

final class ManagedBackupTests: XCTestCase {
    private var database: Database!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tm-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = Database.testInstance(path: directory.appendingPathComponent("live.db").path)
    }

    override func tearDown() {
        database.close()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var backups: URL { directory.appendingPathComponent("backups") }

    private func backup(_ label: String, date: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> String {
        try XCTUnwrap(DataMaintenance.createBackup(label: label, database: database, backupDirectory: backups, date: date))
    }

    func testSameSecondBackupsPreserveEarlierContents() throws {
        XCTAssertTrue(database.setSetting("snapshot-marker", "first"))
        let first = try backup("pre-clear")
        XCTAssertTrue(database.setSetting("snapshot-marker", "second"))
        let second = try backup("pre-clear")
        XCTAssertNotEqual(first, second)
        let earlier = Database.testInstance(path: first)
        defer { earlier.close() }
        XCTAssertEqual(earlier.setting("snapshot-marker"), "first")
    }

    func testOperationSnapshotsDoNotDisplaceLatestWeeklySnapshot() throws {
        let weekly = try backup("weekly", date: Date(timeIntervalSince1970: 1_789_000_000))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: weekly)
        for index in 0..<8 {
            _ = try backup("pre-clear", date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: weekly))
        XCTAssertEqual(DataMaintenance.availableBackups(in: backups).count, 7)
    }

    func testPrivateManagedBackupRetainsRecoverySecrets() throws {
        XCTAssertTrue(database.setSetting("openrouter_key", "fake-private-recovery-only"))
        let path = try backup("manual")
        let snapshot = Database.testInstance(path: path)
        defer { snapshot.close() }
        XCTAssertEqual(snapshot.setting("openrouter_key"), "fake-private-recovery-only")
    }

    func testLegacyAndUniqueBackupLabelsAndExclusiveCreation() throws {
        for name in ["toastmonitor-pre-clear-20261003-120000.db", "toastmonitor-pre-clear-20261003-120000-deadbeef.db"] {
            XCTAssertEqual(DataMaintenance.managedBackupLabel(for: URL(fileURLWithPath: name)), "pre-clear")
        }
        let path = try backup("manual")
        XCTAssertFalse(database.backup(to: path, overwrite: false))
        XCTAssertTrue(DataMaintenance.isSQLiteFile(URL(fileURLWithPath: path)))
    }
}
