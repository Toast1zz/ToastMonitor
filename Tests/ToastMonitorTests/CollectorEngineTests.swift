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
            // A shrink is a rewrite of bytes the cursor already accepted.
            // An append past the cursor is kept: the next scan reads the tail.
            let handle = FileHandle(forWritingAtPath: self.sourcePath)!
            defer { handle.closeFile() }
            handle.truncateFile(atOffset: 0)
            handle.write(Data("x\n".utf8))
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

    /// One unterminated log must not stop its whole source from being stored.
    func testFinalLineWithoutNewlineCommits() throws {
        let line = #"{"type":"assistant","sessionId":"s","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":2}}}"#
        try Data(line.utf8).write(to: URL(fileURLWithPath: sourcePath))
        let first = CollectorEngine.prepareAndCommit(database: database, sourcePaths: [sourcePath]) { state in
            ClaudeCodeParser.scan(knownPaths: [self.sourcePath], database: state)
        }
        XCTAssertTrue(first.committed)
        XCTAssertEqual(database.turnCount(), 1)

        // A later append replays the file; the event id keeps it from doubling.
        let next = line.replacingOccurrences(of: #""id":"m""#, with: #""id":"m2""#)
        try Data((line + "\n" + next + "\n").utf8).write(to: URL(fileURLWithPath: sourcePath))
        let second = CollectorEngine.prepareAndCommit(database: database, sourcePaths: [sourcePath]) { state in
            ClaudeCodeParser.scan(knownPaths: [self.sourcePath], database: state)
        }
        XCTAssertTrue(second.committed)
        XCTAssertEqual(database.turnCount(), 2)
    }

    /// The whole rebuild: a session with a log comes back from it, one without stays.
    func testRebuildRereadsLogsAndKeepsTheRest() throws {
        let directory = (sourcePath as NSString).deletingLastPathComponent
        let log = directory + "/live.jsonl"
        let line = #"{"type":"assistant","sessionId":"live","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":2}}}"#
        try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: log))
        func scan() -> Bool {
            CollectorEngine.prepareAndCommit(database: database, sourcePaths: [log]) { state in
                ClaudeCodeParser.scan(knownPaths: [log], database: state)
            }.committed
        }
        XCTAssertTrue(scan())
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .claude, sessionID: "gone", project: nil, model: "m", ts: 1,
                                                       inputTokens: 7, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                                                       cost: 2, eventID: "claude:gone:m")]))
        XCTAssertEqual(database.turnCount(), 2)
        XCTAssertTrue(database.resetLocalUsage(claudePaths: [log], codexPaths: []))
        XCTAssertEqual(database.turnCount(), 1, "the session with a log waits for the scan")
        XCTAssertTrue(scan())
        XCTAssertEqual(database.turnCount(), 2)
        XCTAssertEqual(database.totals(from: 0, to: .max, tool: .claude).input, 10)
    }

    /// Manual: a copy of a real database, migrated and replayed against this
    /// Mac's Claude logs. Logs are only read. Prints totals per model.
    func testCacheSplitReplayOnARealCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["TM_REAL_DB_COPY"] else {
            throw XCTSkip("set TM_REAL_DB_COPY to a copy of a database")
        }
        // TM_REAL_DB_KEEP keeps the result for inspection; it must already be a copy.
        let keep = ProcessInfo.processInfo.environment["TM_REAL_DB_KEEP"] == "1"
        let path = keep ? source : (databasePath as NSString).deletingLastPathComponent + "/real.db"
        if !keep { try FileManager.default.copyItem(atPath: source, toPath: path) }
        let real = Database.testInstance(path: path)
        defer { real.close() }
        let files = (FileScanner.listFiles(ClaudeCodeParser.root, maxDepth: 4) + ClaudeCodeParser.listCoworkFiles())
            .filter { $0.hasSuffix(".jsonl") }
        let before = real.modelAggregates(from: 0, to: .max)
        let valueBefore = real.apiValue(from: 0, to: .max)
        real.replayClaudeForCacheSplit(paths: files)
        let result = CollectorEngine.prepareAndCommit(database: real, sourcePaths: files) { state in
            ClaudeCodeParser.scan(knownPaths: files, database: state)
        }
        XCTAssertTrue(result.committed)
        real.setSetting("backfill_costs_last", nil)
        real.backfillCosts()
        XCTAssertEqual(real.rollupMismatchCount(), 0)
        for row in real.modelAggregates(from: 0, to: .max) {
            let old = before.first { $0.tool == row.tool && $0.model == row.model }
            print(String(format: "REAL %@ %@ turns %lld -> %lld cost %.2f -> %.2f", row.tool, row.model,
                         old?.count ?? 0, row.count, old?.cost ?? 0, row.cost))
        }
        print(String(format: "REAL value %.2f -> %.2f", valueBefore, real.apiValue(from: 0, to: .max)))
        let hermes = CollectorEngine.prepareAndCommit(database: real, sourcePaths: []) { HermesParser.scan(database: $0) }
        real.setSetting("backfill_costs_last", nil)
        real.backfillCosts()
        print("REAL hermes missed input \(hermes.turns.reduce(0) { $0 + $1.inputTokens }) output \(hermes.turns.reduce(0) { $0 + $1.outputTokens }) cacheRead \(hermes.turns.reduce(0) { $0 + $1.cacheRead })")
    }
}
