import XCTest
import SQLite3
@testable import ToastMonitor

final class DatabaseExportTests: XCTestCase {
    private var database: Database!
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tm-export-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        database = Database.testInstance(path: directory + "/live.db")
        XCTAssertTrue(database.setSetting("ordinary-setting", "retained"))
    }

    override func tearDown() {
        database.close()
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    func testExportRemovesLegacySecretsButPreservesLiveRecoveryCopies() throws {
        let keys = ["or_keys", "openrouter_key", "go_auth_cookie", "go_workspace_id"]
        for key in keys { XCTAssertTrue(database.setSetting(key, "fake-secret-\(key)-only-test")) }
        let target = directory + "/export.db"
        XCTAssertTrue(DataMaintenance.exportDatabase(to: target, database: database))
        let exported = Database.testInstance(path: target)
        defer { exported.close() }
        for key in keys {
            XCTAssertNil(exported.setting(key))
            XCTAssertEqual(database.setting(key), "fake-secret-\(key)-only-test")
        }
        XCTAssertEqual(exported.setting("ordinary-setting"), "retained")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: target))
        for key in keys { XCTAssertNil(bytes.range(of: Data("fake-secret-\(key)-only-test".utf8))) }
    }

    func testDeletedSecretIsAbsentFromExportPages() throws {
        let secret = "test-only-deleted-secret-" + String(repeating: "Z", count: 7000)
        XCTAssertTrue(database.setSetting("openrouter_key", secret))
        XCTAssertTrue(database.setSetting("openrouter_key", nil))
        let target = directory + "/deleted-export.db"
        XCTAssertTrue(DataMaintenance.exportDatabase(to: target, database: database))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: target))
        XCTAssertNil(bytes.range(of: Data(secret.utf8)))
        XCTAssertNil(bytes.range(of: Data("test-only-deleted-secret-".utf8)))
    }

    func testOrdinaryExportOverwritesOnlySelectedDestination() throws {
        let target = directory + "/ordinary-export.db"
        XCTAssertTrue(DataMaintenance.exportDatabase(to: target, database: database))
        XCTAssertTrue(database.setSetting("ordinary-setting", "updated"))
        XCTAssertTrue(DataMaintenance.exportDatabase(to: target, database: database))
        XCTAssertFalse(DataMaintenance.exportDatabase(to: database.dbPath, database: database))
        let exported = Database.testInstance(path: target)
        defer { exported.close() }
        XCTAssertEqual(exported.setting("ordinary-setting"), "updated")
        let attributes = try FileManager.default.attributesOfItem(atPath: target)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExportRejectsDirectoryAliasToLiveDatabaseAndLeavesItWritable() throws {
        let alias = directory + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: directory)
        XCTAssertFalse(DataMaintenance.exportDatabase(to: alias + "/live.db", database: database))
        XCTAssertTrue(database.setSetting("after-rejected-export", "retained"))
        database.close()
        database = Database.testInstance(path: directory + "/live.db")
        XCTAssertEqual(database.setting("after-rejected-export"), "retained")
    }

    func testExportRejectsFileSymlinkAndHardLinkToLiveDatabase() throws {
        let alias = directory + "/file-alias.db"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: database.dbPath)
        XCTAssertFalse(DataMaintenance.exportDatabase(to: alias, database: database))
        let hardLink = directory + "/hard-link.db"
        try FileManager.default.linkItem(atPath: database.dbPath, toPath: hardLink)
        XCTAssertFalse(DataMaintenance.exportDatabase(to: hardLink, database: database))
    }

    func testExportRejectsLiveDatabaseSidecars() {
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(DataMaintenance.exportDatabase(to: database.dbPath + suffix, database: database))
        }
    }

    func testDirectRedactedExportRejectsLiveDatabaseAlias() throws {
        let alias = directory + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: directory)
        XCTAssertFalse(database.exportRedacted(to: alias + "/live.db"))
        XCTAssertTrue(database.setSetting("after-direct-rejection", "retained"))
    }

}
