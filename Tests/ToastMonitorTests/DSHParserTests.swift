import XCTest
@testable import ToastMonitor

final class DSHParserTests: XCTestCase {
    private var dbPath = ""
    private var db: Database!
    private var tempDir = ""

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-db-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        // Point the parser's DSH root at the temp dir so path-based tests
        // never touch the real ~/.dsh.
        setenv("DSH_HOME", tempDir, 1)
    }

    override func tearDown() {
        unsetenv("DSH_HOME")
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private var fixturePath: String {
        Bundle.module.url(forResource: "dsh-sample", withExtension: "jsonl",
                          subdirectory: "Fixtures")!.path
    }

    private var projCacheFixturePath: String {
        Bundle.module.url(forResource: "dsh-projcache", withExtension: "json",
                          subdirectory: "Fixtures")!.path
    }

    private func copyFixture(to name: String) -> String {
        let dest = (tempDir as NSString).appendingPathComponent(name)
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.copyItem(atPath: fixturePath, toPath: dest)
        return dest
    }

    private func dshTurnCount() -> Int64 {
        db.totals(from: 0, to: Int64.max, tool: .dsh).count
    }

    // MARK: - Log mode (plain .jsonl path)

    func testLogModeParsesUsageSteps() {
        let path = copyFixture(to: "session.jsonl")
        let (turns, sessions) = DSHParser.scanLogs(knownPaths: [path], database: db)

        XCTAssertEqual(turns.count, 3, "two chunk usage steps + one message-usage step; zero-usage step skipped")
        // Step 1: usage chunk, model/provider from the finish replayState.
        let first = turns[0]
        XCTAssertEqual(first.tool, .dsh)
        XCTAssertEqual(first.inputTokens, 8045)
        XCTAssertEqual(first.outputTokens, 399)
        XCTAssertEqual(first.cacheRead, 0)
        XCTAssertEqual(first.cacheWrite, 0)
        XCTAssertEqual(first.model, "deepseek-v4-flash")
        XCTAssertEqual(first.provider, "opencodego")
        XCTAssertEqual(first.ts, 1786628706, "usage chunk ms timestamp → seconds")
        XCTAssertEqual(first.eventID, "dsh-log:session-test-0001:13")
        XCTAssertEqual(first.costQuality, "estimated")
        XCTAssertEqual(first.cost, 0.0024, accuracy: 0.0001)

        // Step 2: cache read bucket.
        XCTAssertEqual(turns[1].inputTokens, 895)
        XCTAssertEqual(turns[1].outputTokens, 198)
        XCTAssertEqual(turns[1].cacheRead, 8320)

        // Step 4: assistant/message.usage REPLACES the chunk sample for the
        // same (turn, step) instead of double counting.
        XCTAssertEqual(turns[2].inputTokens, 2600)
        XCTAssertEqual(turns[2].outputTokens, 420)
        XCTAssertEqual(turns[2].cacheRead, 9400)
        XCTAssertEqual(turns[2].eventID, "dsh-log:session-test-0001:21")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "session-test-0001")
        XCTAssertEqual(sessions[0].project, "/Users/toast1/Projects/ToastMonitor")
        XCTAssertEqual(sessions[0].model, "deepseek-v4-flash")
        XCTAssertEqual(sessions[0].created, 1786628702)
        XCTAssertEqual(sessions[0].updated, 1786628709)
    }

    func testLogModeIncrementalAppend() {
        let path = copyFixture(to: "session.jsonl")
        let (first, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(db.insertTurns(first))
        XCTAssertEqual(dshTurnCount(), 3)

        // Unchanged file → idle scan.
        let (idle, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertTrue(idle.isEmpty)

        // Append two more lines (step 5) — cursor resumes from the old EOF.
        let appended = """
        {"type":"assistant/chunk","seq":30,"time":1786628800000,"data":{"turn":1,"step":5,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":1000}}}}
        {"type":"assistant/chunk","seq":31,"time":1786628800001,"data":{"turn":1,"step":5,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(Data(appended.utf8))
        fh.closeFile()

        let (second, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(second.count, 1, "only the appended step is parsed")
        // Session id comes from the persisted scan_state context, not a re-read header.
        XCTAssertEqual(second[0].eventID, "dsh-log:session-test-0001:30")
        XCTAssertEqual(second[0].ts, 1786628800)
        XCTAssertTrue(db.insertTurns(second))
        XCTAssertEqual(dshTurnCount(), 4)

        let (third, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertTrue(third.isEmpty)
        XCTAssertEqual(dshTurnCount(), 4)
    }

    func testLogModeShrinkTriggersFullRescanDeduped() {
        let path = copyFixture(to: "session.jsonl")
        let (first, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(db.insertTurns(first))
        XCTAssertEqual(dshTurnCount(), 3)

        // Crash repair truncates mid-line: nothing consumable, the cursor
        // stays at 0 and a full-rescan marker is armed for the regrowth.
        let fh = FileHandle(forWritingAtPath: path)!
        fh.truncateFile(atOffset: 100)
        fh.closeFile()
        let (empty, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertTrue(empty.isEmpty)

        // The log regrows to its full original content (same inode): the
        // pending marker forces a replay from 0; event_id dedupe keeps totals.
        let original = try! Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let tail = original.subdata(in: 100..<original.count)
        let fh2 = FileHandle(forWritingAtPath: path)!
        fh2.seekToEndOfFile()
        fh2.write(tail)
        fh2.closeFile()

        let (again, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(again.count, 3, "full rescan re-reads everything")
        XCTAssertTrue(db.insertTurns(again))
        XCTAssertEqual(dshTurnCount(), 3, "dedupe prevents double counting")
    }

    func testLogModeIgnoresUnknownModelCost() {
        let path = copyFixture(to: "session.jsonl")
        // Overwrite the fixture with a step whose model is not in the price table.
        let lines = """
        {"type":"session","version":0,"id":"session-test-0002","createdAt":1786628702000,"cwd":"/tmp/x","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":5,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50}}}}
        {"type":"assistant/chunk","seq":6,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"x","provider":"unknown-provider","model":"mystery-model","stopReason":"toolUse"}}}}
        """
        try? FileManager.default.removeItem(atPath: path)
        try? Data(lines.utf8).write(to: URL(fileURLWithPath: path))

        let (turns, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].cost, 0)
        XCTAssertEqual(turns[0].costQuality, "unknown")
        XCTAssertEqual(turns[0].model, "mystery-model")
    }

    // MARK: - Log mode (.zstd frame path with injected decompressor)

    private static let zstdMagic = Data([0x28, 0xB5, 0x2F, 0xFD])

    /// Builds a fake `.zstd` transcript: each "frame" is the zstd magic on its
    /// own line followed by plain JSONL. With an identity decompressor the
    /// parsed lines stay clean — a real zstd decoder never emits magic bytes,
    /// so this exercises the frame-slicing logic with the same shape.
    private func fakeZstdFile(name: String, chunks: [String]) throws -> String {
        let dest = (tempDir as NSString).appendingPathComponent(name)
        var data = Data()
        for chunk in chunks {
            data.append(Self.zstdMagic)
            data.append(Data("\n".utf8))
            data.append(Data(chunk.utf8))
        }
        try data.write(to: URL(fileURLWithPath: dest))
        return dest
    }

    func testLogModeZstdFramesIncremental() throws {
        let step1 = """
        {"type":"session","version":0,"id":"session-zstd-1","createdAt":1786628702000,"cwd":"/tmp/z","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":3,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":1000}}}}
        {"type":"assistant/chunk","seq":4,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        let path = try fakeZstdFile(name: "session.jsonl.zstd", chunks: [step1])
        // Identity decompressor: the "frames" carry plain JSONL after the magic.
        let identity: (Data) -> Data? = { $0 }
        let (turns, sessions) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: identity)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].inputTokens, 100)
        XCTAssertEqual(turns[0].cacheRead, 1000)
        XCTAssertEqual(turns[0].model, "deepseek-v4-flash")
        XCTAssertEqual(turns[0].eventID, "dsh-log:session-zstd-1:3")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(db.insertTurns(turns))

        // Append a second independent frame.
        let step2 = """
        {"type":"assistant/chunk","seq":9,"time":1786628800000,"data":{"turn":1,"step":2,"chunk":{"type":"usage","usage":{"inputTokens":200,"outputTokens":80,"cacheReadTokens":2000}}}}
        {"type":"assistant/chunk","seq":10,"time":1786628800001,"data":{"turn":1,"step":2,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(Self.zstdMagic)
        fh.write(Data("\n".utf8))
        fh.write(Data(step2.utf8))
        fh.closeFile()

        let (more, _) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: identity)
        XCTAssertEqual(more.count, 1, "only the new frame's step is parsed")
        if more.count == 1 {
            XCTAssertEqual(more[0].eventID, "dsh-log:session-zstd-1:9")
            XCTAssertEqual(more[0].ts, 1786628800)
        }
    }

    func testLogModeZstdRealCompression() throws {
        guard let zstd = Zstd.executablePath() else {
            throw XCTSkip("zstd CLI not available on PATH")
        }
        // Compress the plain fixture into a real .zstd transcript.
        let outPath = (tempDir as NSString).appendingPathComponent("real.jsonl.zstd")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-c", fixturePath]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try out.write(to: URL(fileURLWithPath: outPath))

        let (turns, _) = DSHParser.scanLogs(knownPaths: [outPath], database: db)
        XCTAssertEqual(turns.count, 3, "real zstd frames decompress and parse like the plain log")
        XCTAssertEqual(turns[0].model, "deepseek-v4-flash")
        XCTAssertEqual(turns[2].inputTokens, 2600)
    }

    func testLogModeZstdCorruptTailKeepsGoodFrames() throws {
        // One good frame followed by a truncated second frame.
        let good = """
        {"type":"session","version":0,"id":"session-recover-1","createdAt":1786628702000,"cwd":"/tmp/z","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":3,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50}}}}
        {"type":"assistant/chunk","seq":4,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        var data = Self.zstdMagic
        data.append(Data("\n".utf8))
        data.append(Data(good.utf8))
        data.append(Self.zstdMagic)
        data.append(Data("{\"type\":\"assistant/chunk\",\"seq\":9".utf8)) // truncated line
        let path = (tempDir as NSString).appendingPathComponent("corrupt.jsonl.zstd")
        try data.write(to: URL(fileURLWithPath: path))

        let identity: (Data) -> Data? = { $0 }
        let (turns, _) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: identity)
        XCTAssertEqual(turns.count, 1, "the good frame before the truncated tail is kept")
        XCTAssertEqual(turns[0].eventID, "dsh-log:session-recover-1:3")
    }

    // MARK: - Cache mode

    func testCacheModeFirstScanFullSecondScanDelta() {
        try? FileManager.default.removeItem(atPath: DSHParser.projCachePath)
        try? FileManager.default.createDirectory(
            atPath: (DSHParser.projCachePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: projCacheFixturePath, toPath: DSHParser.projCachePath)

        let (first, sessions) = DSHParser.scanProjCache(database: db)
        XCTAssertEqual(first.count, 1, "only the non-zero session produces a delta turn")
        XCTAssertEqual(sessions.count, 2)
        let turn = first[0]
        XCTAssertEqual(turn.sessionID, "session-aaa")
        XCTAssertEqual(turn.inputTokens, 1000)
        XCTAssertEqual(turn.outputTokens, 500)
        XCTAssertEqual(turn.cacheRead, 8000)
        XCTAssertEqual(turn.cacheWrite, 10)
        XCTAssertEqual(turn.ts, 1786627600, "lastPromptAt drives the timestamp")
        XCTAssertEqual(turn.project, "/Users/me/ProjA")
        XCTAssertNil(turn.model)
        XCTAssertEqual(turn.cost, 0)
        XCTAssertEqual(turn.costQuality, "unknown")
        XCTAssertEqual(turn.eventID, "dsh-cache:session-aaa:100:1000:500:8000:10")
        let info = sessions.first { $0.sessionID == "session-aaa" }
        XCTAssertEqual(info?.title, "my task")
        XCTAssertEqual(info?.created, 1786627575)

        // Second scan: same totals → no delta turn.
        let (second, _) = DSHParser.scanProjCache(database: db)
        XCTAssertTrue(second.isEmpty)

        // Simulate growth in the cache: more usage for session-aaa.
        let raw = try? String(contentsOfFile: DSHParser.projCachePath, encoding: .utf8)
        let grown = raw?
            .replacingOccurrences(of: "\"uncachedInputTokens\": 1000",
                                  with: "\"uncachedInputTokens\": 1500")
            .replacingOccurrences(of: "\"outputTokens\": 500",
                                  with: "\"outputTokens\": 700")
        try? Data((grown ?? "").utf8).write(to: URL(fileURLWithPath: DSHParser.projCachePath))
        let (third, _) = DSHParser.scanProjCache(database: db)
        XCTAssertEqual(third.count, 1, "only the positive delta is emitted")
        XCTAssertEqual(third[0].inputTokens, 500)
        XCTAssertEqual(third[0].outputTokens, 200)
        XCTAssertEqual(third[0].cacheRead, 0)
        XCTAssertEqual(third[0].cacheWrite, 0)
    }

    // MARK: - Mode selection

    func testResolveModeFreshAndSticky() {
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: false), .cache)
        XCTAssertEqual(db.setting(DSHParser.modeSettingKey), "cache")
        // Sticky even when zstd becomes available — no dsh data yet, so the
        // fresh upgrade rule applies only on the NEXT resolve.
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: true), .log,
                       "empty-dsh upgrade cache → log applies")
        XCTAssertEqual(db.setting(DSHParser.modeSettingKey), "log")
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: true), .log)
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: false), .log,
                       "sticky: a later zstd loss never downgrades")
    }

    func testResolveModeDoesNotUpgradeWithExistingTurns() {
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: false), .cache)
        let turn = TurnRecord(tool: .dsh, sessionID: "s1", project: nil, model: nil,
                              ts: 1, inputTokens: 10, outputTokens: 10,
                              cacheRead: 0, cacheWrite: 0, cost: 0,
                              eventID: "dsh-cache:s1:1:10:10:0:0", costQuality: "unknown")
        XCTAssertTrue(db.insertTurns([turn]))
        // zstd is now available but dsh turns exist → the mode must NOT flip.
        XCTAssertEqual(DSHParser.resolveMode(database: db, zstdAvailable: true), .cache)
        XCTAssertEqual(db.setting(DSHParser.modeSettingKey), "cache")
    }

    // MARK: - Frame helper

    func testNextFrameOffset() {
        var data = Data([0x00, 0x01, 0x02])
        XCTAssertNil(Zstd.nextFrameOffset(in: data, fromOffset: 0))
        data.append(Self.zstdMagic)
        data.append(Data([0xAA, 0xBB]))
        XCTAssertEqual(Zstd.nextFrameOffset(in: data, fromOffset: 0), 3)
        XCTAssertEqual(Zstd.nextFrameOffset(in: data, fromOffset: 3), 3, "a cursor exactly on the boundary finds it")
        XCTAssertNil(Zstd.nextFrameOffset(in: data, fromOffset: 4), "magic before the cursor is not a match")
        XCTAssertNil(Zstd.nextFrameOffset(in: data, fromOffset: 7))
    }

    // MARK: - PARSER-2: truncate + regrow without an observed shrink

    func testLogModeTruncateRegrowWithoutObservedShrinkRescans() throws {
        // The log is rewritten to DIFFERENT, LARGER content in one shot: the
        // shrink happens between polls, so the parser never observes it. The
        // old cursor lands mid-line in the new file, which a genuine append
        // can never do → the file must be rescanned from 0.
        let path = (tempDir as NSString).appendingPathComponent("regrow.jsonl")
        let initial = """
        {"type":"session","version":0,"id":"session-regrow-1","createdAt":1786628702000,"cwd":"/tmp/z","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":3,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50}}}}
        {"type":"assistant/chunk","seq":4,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        try Data(initial.utf8).write(to: URL(fileURLWithPath: path))
        let (first, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(db.insertTurns(first))

        let replacement = """
        {"type":"session","version":0,"id":"session-regrow-2","createdAt":1786628702000,"cwd":"/tmp/z","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":20,"time":1786628800000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":500,"outputTokens":250}}}}
        {"type":"assistant/chunk","seq":21,"time":1786628800001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        {"type":"assistant/chunk","seq":22,"time":1786628800002,"data":{"turn":1,"step":2,"chunk":{"type":"usage","usage":{"inputTokens":600,"outputTokens":300}}}}
        {"type":"assistant/chunk","seq":23,"time":1786628800003,"data":{"turn":1,"step":2,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        XCTAssertGreaterThan(Data(replacement.utf8).count, Data(initial.utf8).count,
                             "regrown file must be larger than the old cursor")
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data(replacement.utf8))
        try fh.close()

        let (second, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertEqual(second.count, 2, "the rewritten file is fully re-read from 0")
        XCTAssertTrue(second.allSatisfy { $0.sessionID == "session-regrow-2" })
        XCTAssertTrue(db.insertTurns(second))
        XCTAssertEqual(dshTurnCount(), 3, "old step deduped by event id; both rewritten steps imported")
    }

    // MARK: - PARSER-3: delta baseline high-water mark (cache mode)

    func testCacheModeRollbackBaselineIsHighWaterMark() {
        try? FileManager.default.removeItem(atPath: DSHParser.projCachePath)
        try? FileManager.default.createDirectory(
            atPath: (DSHParser.projCachePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: projCacheFixturePath, toPath: DSHParser.projCachePath)

        let (first, _) = DSHParser.scanProjCache(database: db)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].inputTokens, 1000)
        XCTAssertEqual(first[0].outputTokens, 500)

        // The source rolls back below the recorded baseline.
        let raw = (try? String(contentsOfFile: DSHParser.projCachePath, encoding: .utf8)) ?? ""
        let lowered = raw
            .replacingOccurrences(of: "\"uncachedInputTokens\": 1000", with: "\"uncachedInputTokens\": 300")
            .replacingOccurrences(of: "\"outputTokens\": 500", with: "\"outputTokens\": 200")
            .replacingOccurrences(of: "\"cacheReadTokens\": 8000", with: "\"cacheReadTokens\": 4000")
            .replacingOccurrences(of: "\"cacheWriteTokens\": 10", with: "\"cacheWriteTokens\": 5")
        try? Data(lowered.utf8).write(to: URL(fileURLWithPath: DSHParser.projCachePath))
        let (rolled, _) = DSHParser.scanProjCache(database: db)
        XCTAssertTrue(rolled.isEmpty, "rollback must not emit negative deltas")
        let totals = db.sessionTotals()
        XCTAssertEqual(totals["dsh|session-aaa"]?.input, 1000, "baseline input never drops")
        XCTAssertEqual(totals["dsh|session-aaa"]?.output, 500, "baseline output never drops")
        XCTAssertEqual(totals["dsh|session-aaa"]?.cacheRead, 8000)
        XCTAssertEqual(totals["dsh|session-aaa"]?.cacheWrite, 10)

        // Regrowth beyond the old peak counts only the increase past the max.
        let grown = lowered
            .replacingOccurrences(of: "\"uncachedInputTokens\": 300", with: "\"uncachedInputTokens\": 1400")
            .replacingOccurrences(of: "\"outputTokens\": 200", with: "\"outputTokens\": 900")
            .replacingOccurrences(of: "\"cacheReadTokens\": 4000", with: "\"cacheReadTokens\": 9000")
            .replacingOccurrences(of: "\"cacheWriteTokens\": 5", with: "\"cacheWriteTokens\": 20")
        try? Data(grown.utf8).write(to: URL(fileURLWithPath: DSHParser.projCachePath))
        let (third, _) = DSHParser.scanProjCache(database: db)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].inputTokens, 400, "1400 - max(1000, 300) = 400, not 1100")
        XCTAssertEqual(third[0].outputTokens, 400, "900 - max(500, 200) = 400, not 700")
        XCTAssertEqual(third[0].cacheRead, 1000, "9000 - max(8000, 4000) = 1000")
        XCTAssertEqual(third[0].cacheWrite, 10, "20 - max(10, 5) = 10")
    }

    // MARK: - PARSER-4: zstd false-magic stall resets the cursor

    func testLogModeZstdFalseMagicStallResetsCursorAfterThreeNoProgressScans() throws {
        // A valid frame followed by a broken tail whose first bytes are a
        // false zstd magic. Every scan re-reads the tail, hits the false
        // magic, fails to decompress, and parks the cursor there — after 3
        // no-progress scans the parser must force a full rescan from 0.
        let good = """
        {"type":"session","version":0,"id":"session-stall-1","createdAt":1786628702000,"cwd":"/tmp/z","delegationDepth":0,"agentPreset":"standard"}
        {"type":"assistant/chunk","seq":3,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50}}}}
        {"type":"assistant/chunk","seq":4,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"opencodego","provider":"opencodego","model":"deepseek-v4-flash","stopReason":"toolUse"}}}}
        """
        // Simulates a zstd decoder that fails on the broken tail: accepts a
        // slice only when every complete line after the frame magic parses
        // as JSON — the garbage tail (no complete line) is rejected.
        let strict: (Data) -> Data? = { data in
            let bytes = [UInt8](data)
            guard let firstNL = bytes.firstIndex(of: 0x0a) else { return nil }
            var i = firstNL + 1
            while i < bytes.count {
                guard let nl = bytes[i...].firstIndex(of: 0x0a) else { return nil }
                guard nl > i,
                      (try? JSONSerialization.jsonObject(with: Data(bytes[i..<nl]))) != nil
                else { return nil }
                i = nl + 1
            }
            return data
        }

        var data = Self.zstdMagic
        data.append(Data("\n".utf8))
        // Swift multi-line strings drop the newline before the closing
        // delimiter; the strict decoder below requires every line (incl. the
        // last) to be newline-terminated, so append one explicitly.
        data.append(Data((good + "\n").utf8))
        data.append(Self.zstdMagic) // false magic the broken tail starts with
        data.append(Data("\n".utf8))
        data.append(Data("corrupt-garbage-no-newline".utf8))
        let path = (tempDir as NSString).appendingPathComponent("stall.jsonl.zstd")
        try data.write(to: URL(fileURLWithPath: path))

        // Scan 1: the good frame is recovered; the cursor parks on the false
        // magic (no progress is possible from there).
        let (first, _) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: strict)
        XCTAssertEqual(first.count, 1)
        let parked = db.scanState(path).size
        XCTAssertGreaterThan(parked, 0)
        XCTAssertEqual(FileScanner.contextStallCount(db.scanState(path).context), 0)

        // Three scans over a still-growing file make no progress: the stall
        // counter climbs to 3.
        for expected in 1...3 {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try fh.seekToEnd()
            try fh.write(contentsOf: Data("extra-garbage-\(expected)".utf8))
            try fh.close()
            let (turns, _) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: strict)
            XCTAssertTrue(turns.isEmpty)
            XCTAssertEqual(db.scanState(path).size, parked, "cursor stays parked at the false magic")
            XCTAssertEqual(FileScanner.contextStallCount(db.scanState(path).context), expected)
        }

        // The next scan (stall == 3) forces offset 0: the good frame is
        // re-recovered from the file start and the stall counter resets.
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("more-garbage".utf8))
        try fh.close()
        let (again, _) = DSHParser.scanLogs(knownPaths: [path], database: db, decompress: strict)
        XCTAssertEqual(again.count, 1, "full rescan re-recovers the good frame")
        XCTAssertEqual(again[0].eventID, "dsh-log:session-stall-1:3")
        XCTAssertEqual(FileScanner.contextStallCount(db.scanState(path).context), 0,
                       "progress resets the stall counter")
    }

    // MARK: - PARSER-5: headerless files advance the cursor

    func testLogModeHeaderlessFileAdvancesCursorInsteadOfReReading() throws {
        // A transcript without a `session` event can never be attributed to a
        // session: the parser must advance past it instead of re-reading and
        // re-decompressing the same tail on every scan.
        let path = (tempDir as NSString).appendingPathComponent("headerless.jsonl")
        let lines = """
        {"type":"assistant/chunk","seq":1,"time":1786628706000,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50}}}}
        {"type":"assistant/chunk","seq":2,"time":1786628706001,"data":{"turn":1,"step":1,"chunk":{"type":"finish","reason":{"kind":"tool-calls"},"replayState":{"kind":"pi-ai","version":1,"api":"x","provider":"x","model":"m","stopReason":"toolUse"}}}}
        """
        try Data(lines.utf8).write(to: URL(fileURLWithPath: path))
        let size1 = Int64(Data(lines.utf8).count)

        let (first, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertTrue(first.isEmpty, "content without a session header can never be attributed")
        XCTAssertEqual(db.scanState(path).size, size1,
                       "cursor must advance past unattributable content instead of re-reading it every scan")

        // Appending more content: only the new tail is read and skipped.
        let more = "\n{\"type\":\"assistant/chunk\",\"seq\":9,\"time\":1786628800000,\"data\":{\"turn\":1,\"step\":2,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":200,\"outputTokens\":80}}}}\n"
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(more.utf8))
        try fh.close()

        let (second, _) = DSHParser.scanLogs(knownPaths: [path], database: db)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(db.scanState(path).size, size1 + Int64(Data(more.utf8).count),
                       "the appended tail was consumed and the cursor advanced again")
    }
}
