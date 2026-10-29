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

    /// Expands a compressed managed backup so a test can open it.
    private func open(_ path: String) throws -> Database {
        let expanded = directory.appendingPathComponent("expanded-\(UUID().uuidString).db")
        XCTAssertTrue(DataMaintenance.expand(URL(fileURLWithPath: path), to: expanded))
        return Database.testInstance(path: expanded.path)
    }

    func testSameSecondBackupsPreserveEarlierContents() throws {
        XCTAssertTrue(database.setSetting("snapshot-marker", "first"))
        let first = try backup("pre-clear")
        XCTAssertTrue(database.setSetting("snapshot-marker", "second"))
        let second = try backup("pre-clear")
        XCTAssertNotEqual(first, second)
        let earlier = try open(first)
        defer { earlier.close() }
        XCTAssertEqual(earlier.setting("snapshot-marker"), "first")
    }

    func testOperationSnapshotsDoNotDisplaceWeeklySnapshots() throws {
        let weekly = try backup("weekly", date: Date(timeIntervalSince1970: 1_789_000_000))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: weekly)
        for index in 0..<8 {
            _ = try backup("pre-clear", date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: weekly))
        XCTAssertEqual(DataMaintenance.availableBackups(in: backups).count, 4)
    }

    func testRetentionKeepsFourWeeksThreeMonthsAndThreeOperations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // 26 weekly snapshots, newest first, one every 7 days (about six months).
        let weekly = (0..<26).map { i in
            DataMaintenance.BackupInfo(url: URL(fileURLWithPath: "/w\(i)"), date: start - Double(i) * 7 * day, isRoutine: true)
        }
        let operations = (0..<5).map { i in
            DataMaintenance.BackupInfo(url: URL(fileURLWithPath: "/o\(i)"), date: start - Double(i) * day, isRoutine: false)
        }
        let kept = DataMaintenance.retained(weekly + operations, calendar: calendar)
        XCTAssertTrue(Set(weekly.prefix(4).map(\.url)).isSubset(of: kept))
        XCTAssertEqual(Set(operations.prefix(3).map(\.url)), kept.filter { $0.path.hasPrefix("/o") })
        let older = weekly.dropFirst(4).filter { kept.contains($0.url) }
        XCTAssertEqual(older.count, 3)
        XCTAssertEqual(Set(older.map { calendar.component(.month, from: $0.date) }).count, 3)
    }

    func testBackupsAreCompressedAndLegacyOnesConverted() throws {
        let path = try backup("manual")
        XCTAssertTrue(path.hasSuffix(".db.lzfse"))
        XCTAssertTrue(DataMaintenance.isBackupFile(URL(fileURLWithPath: path)))
        XCTAssertEqual(DataMaintenance.managedBackupLabel(for: URL(fileURLWithPath: path)), "manual")

        let legacy = backups.appendingPathComponent("toastmonitor-weekly-20261026-133304-b83307c2.db")
        XCTAssertTrue(database.setSetting("snapshot-marker", "legacy"))
        XCTAssertTrue(database.backup(to: legacy.path))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: legacy.path)
        DataMaintenance.compressLegacyBackups(in: backups)
        let converted = legacy.appendingPathExtension("lzfse")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let values = try converted.resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(values.contentModificationDate, date)
        let restored = try open(converted.path)
        defer { restored.close() }
        XCTAssertEqual(restored.setting("snapshot-marker"), "legacy")
    }

    func testPrivateManagedBackupRetainsRecoverySecrets() throws {
        XCTAssertTrue(database.setSetting("openrouter_key", "fake-private-recovery-only"))
        let path = try backup("manual")
        let snapshot = try open(path)
        defer { snapshot.close() }
        XCTAssertEqual(snapshot.setting("openrouter_key"), "fake-private-recovery-only")
    }

    func testLegacyAndUniqueBackupLabelsAndExclusiveCreation() throws {
        for name in ["toastmonitor-pre-clear-20261003-120000.db", "toastmonitor-pre-clear-20261003-120000-deadbeef.db"] {
            XCTAssertEqual(DataMaintenance.managedBackupLabel(for: URL(fileURLWithPath: name)), "pre-clear")
        }
        let path = try backup("manual")
        XCTAssertFalse(database.backup(to: path, overwrite: false))
        XCTAssertTrue(DataMaintenance.isBackupFile(URL(fileURLWithPath: path)))
    }
}
