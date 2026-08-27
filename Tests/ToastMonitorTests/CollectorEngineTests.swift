import XCTest
@testable import ToastMonitor

final class CollectorEngineTests: XCTestCase {
    private var database: Database!
    private var databasePath = ""
    private var sourcePath = ""

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastmonitor-collector-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databasePath = root.appendingPathComponent("usage.sqlite").path
        sourcePath = root.appendingPathComponent("source.jsonl").path
        database = Database.testInstance(path: databasePath)
    }

    override func tearDown() {
        database?.close()
        if !databasePath.isEmpty {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: databasePath).deletingLastPathComponent())
        }
        database = nil
        super.tearDown()
    }

    func testParsingOutsideTransactionDoesNotBlockDatabaseReads() {
        let scanStarted = expectation(description: "scan started")
        let readFinished = expectation(description: "read finished")
        let commitFinished = expectation(description: "commit finished")
        let continueScan = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            _ = CollectorEngine.prepareAndCommit(database: self.database,
                                                 sourcePaths: []) { _ in
                scanStarted.fulfill()
                _ = continueScan.wait(timeout: .now() + 2)
                return ([], [])
            }
            commitFinished.fulfill()
        }

        wait(for: [scanStarted], timeout: 1)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.database.turnCount()
            readFinished.fulfill()
        }

        let readResult = XCTWaiter.wait(for: [readFinished], timeout: 0.25)
        continueScan.signal()
        wait(for: [commitFinished], timeout: 2)
        XCTAssertEqual(readResult, .completed,
                       "a database read must not wait for parser IO to finish")
    }

    func testSourceMutationDiscardsPreparedRowsAndCursor() throws {
        try Data("initial\n".utf8).write(to: URL(fileURLWithPath: sourcePath))
        let now = Int64(Date().timeIntervalSince1970)
        let turn = TurnRecord(tool: .claude, sessionID: "changed-source",
                              project: nil, model: "claude-sonnet-4-5", ts: now,
                              inputTokens: 10, outputTokens: 2,
                              cacheRead: 0, cacheWrite: 0, cost: 0,
                              eventID: "collector-source-change")

        let result = CollectorEngine.prepareAndCommit(database: database,
                                                       sourcePaths: [sourcePath]) { state in
            let stat = FileScanner.fileStat(self.sourcePath)!
            XCTAssertTrue(state.setScanState(self.sourcePath, size: stat.size,
                                             mtime: stat.mtime, identity: stat.identity,
                                             context: nil))
            let handle = FileHandle(forWritingAtPath: self.sourcePath)!
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(Data("changed\n".utf8))
            return ([turn], [])
        }

        XCTAssertFalse(result.committed)
        XCTAssertEqual(database.turnCount(), 0)
        XCTAssertEqual(database.scanState(sourcePath).size, 0)
    }

    func testPreparedRowsAndCursorCommitAtomically() throws {
        try Data("complete\n".utf8).write(to: URL(fileURLWithPath: sourcePath))
        let now = Int64(Date().timeIntervalSince1970)
        let turn = TurnRecord(tool: .codex, sessionID: "stable-source",
                              project: nil, model: "gpt-5.6-sol", ts: now,
                              inputTokens: 20, outputTokens: 4,
                              cacheRead: 0, cacheWrite: 0, cost: 0,
                              eventID: "collector-stable-source")
        let stat = FileScanner.fileStat(sourcePath)!

        let result = CollectorEngine.prepareAndCommit(database: database,
                                                       sourcePaths: [sourcePath]) { state in
            XCTAssertTrue(state.setScanState(self.sourcePath, size: stat.size,
                                             mtime: stat.mtime, identity: stat.identity,
                                             context: "stable"))
            return ([turn], [])
        }

        XCTAssertTrue(result.committed)
        XCTAssertEqual(database.turnCount(), 1)
        let cursor = database.scanState(sourcePath)
        XCTAssertEqual(cursor.size, stat.size)
        XCTAssertEqual(cursor.mtime, stat.mtime)
        XCTAssertEqual(cursor.identity, stat.identity)
        XCTAssertEqual(cursor.context, "stable")
    }
}
