import XCTest
import SQLite3
@testable import ToastMonitor

/// The rollup is only an accelerator: every aggregate must return exactly
/// what the raw `turns` scan returns, after every kind of write.
final class TurnRollupTests: XCTestCase {
    private var tmpPath: String!
    private var db: Database!
    private let base: Int64 = 1_750_000_000 - 1_750_000_000 % 900

    override func setUp() {
        super.setUp()
        tmpPath = NSTemporaryDirectory() + "tm-rollup-\(UUID().uuidString).db"
        db = Database.testInstance(path: tmpPath)
    }

    override func tearDown() {
        db?.close()
        for suffix in ["", "-wal", "-shm", ".bak"] {
            try? FileManager.default.removeItem(atPath: tmpPath + suffix)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomTurns(_ count: Int, seed: UInt64, eventIDs: Bool = true) -> [TurnRecord] {
        var rng = SeededRNG(state: seed)
        let tools: [ToolKind] = [.claude, .codex, .opencode, .hermes, .omp]
        let models: [String?] = ["claude-sonnet-4-5", "gpt-5.6-sol", "deepseek-chat", nil, ""]
        let providers: [String?] = ["deepseek", " DeepSeek ", "openrouter", nil]
        let qualities = ["estimated", "actual", "unknown"]
        return (0..<count).map { i in
            // Spread over ~3 days, with many rows exactly on bucket edges.
            let offset = Int64.random(in: 0..<(3 * 86_400), using: &rng)
            let ts = Bool.random(using: &rng) ? base + offset - offset % 900 : base + offset
            return TurnRecord(tool: tools.randomElement(using: &rng)!,
                              sessionID: "s\(i % 7)", project: nil,
                              model: models.randomElement(using: &rng)!,
                              ts: ts,
                              inputTokens: Int64.random(in: 0...5_000, using: &rng),
                              outputTokens: Int64.random(in: 0...2_000, using: &rng),
                              cacheRead: Int64.random(in: 0...50_000, using: &rng),
                              cacheWrite: Int64.random(in: 0...3_000, using: &rng),
                              cost: Bool.random(using: &rng) ? 0 : Double.random(in: 0...2, using: &rng),
                              provider: providers.randomElement(using: &rng)!,
                              eventID: eventIDs ? "e-\(seed)-\(i)" : nil,
                              costQuality: qualities.randomElement(using: &rng)!)
        }
    }

    private var ranges: [(Int64, Int64)] {
        let end = base + 3 * 86_400
        return [(0, end + 10_000), (base, end), (base + 1, end - 1),
                (base + 899, base + 900), (base + 450, base + 7_321),
                (base + 900, base + 1_799), (base + 86_400 - 17, base + 2 * 86_400 + 5),
                (base + 5, base + 5), (end + 1, end + 100)]
    }

    private func r(_ x: Double) -> String { String(format: "%.6f", x) }

    /// Every aggregate the UI reads, rendered into one comparable string.
    private func fingerprint() -> String {
        var out: [String] = []
        for (from, to) in ranges {
            let t = db.totals(from: from, to: to)
            out.append("T \(from) \(to) \(t.input) \(t.output) \(t.cacheRead) \(t.cacheWrite) \(r(t.cost)) \(t.count)")
            let tc = db.totals(from: from, to: to, tool: .codex)
            out.append("TC \(tc.input) \(tc.count) \(r(tc.cost))")
            out += db.totalsByTool(from: from, to: to)
                .map { "BT \($0.tool) \($0.input) \($0.output) \($0.cacheRead) \($0.cacheWrite) \(r($0.cost)) \($0.count)" }
                .sorted()
            out += db.modelAggregates(from: from, to: to)
                .map { "M \($0.tool) \($0.model) \($0.input) \($0.output) \($0.cacheRead) \(r($0.cost)) \($0.count)" }
                .sorted()
            let c = db.costBreakdown(from: from, to: to)
            out.append("C \(r(c.estimated)) \(r(c.actual)) \(r(c.deepseekActual))")
            out.append("A \(r(db.apiValue(from: from, to: to))) \(r(db.apiValue(from: from, to: to, tool: "claude")))")
        }
        out += db.dailyAggregates(days: 100_000)
            .map { "D \($0.day) \($0.tool) \($0.input) \($0.output) \($0.cacheRead) \(r($0.cost)) \($0.count)" }
            .sorted()
        out += db.dailyAggregatesByModel(days: 100_000)
            .map { "DM \($0.day) \($0.model) \($0.input) \($0.output) \($0.cacheRead) \(r($0.cost)) \($0.count)" }
            .sorted()
        return out.joined(separator: "\n")
    }

    private func assertRollupMatchesRaw(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(db.rollupMismatchCount(), 0, "\(label): rollup drifted", file: file, line: line)
        db.aggregatesUseRollup = true
        let fast = fingerprint()
        db.aggregatesUseRollup = false
        let raw = fingerprint()
        db.aggregatesUseRollup = true
        XCTAssertEqual(fast, raw, "\(label): rollup and raw aggregates differ", file: file, line: line)
    }

    private func externalExec(_ sql: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tmpPath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    }

    private func reopen() {
        db.close()
        db = Database.testInstance(path: tmpPath)
    }

    // MARK: - Tests

    func testSpanSplitsWholeBucketsAndEdges() {
        XCTAssertEqual(Database.rollupSpan(from: 0, to: 1_799).lo, 0)
        XCTAssertEqual(Database.rollupSpan(from: 0, to: 1_799).hi, 1_800)
        XCTAssertEqual(Database.rollupSpan(from: 1, to: 1_799).lo, 900)
        XCTAssertEqual(Database.rollupSpan(from: 1, to: 2_698).hi, 1_800)
        // No whole bucket inside: everything goes to the raw branch.
        XCTAssertEqual(Database.rollupSpan(from: 1, to: 1_000).lo, 1_001)
        XCTAssertEqual(Database.rollupSpan(from: 1, to: 1_000).hi, 1_001)
        XCTAssertEqual(Database.rollupSpan(from: 0, to: 1_799, useRollup: false).lo, 1_800)
    }

    func testRollupMatchesRawAcrossWritePaths() {
        XCTAssertTrue(db.insertTurns(randomTurns(600, seed: 1)))
        assertRollupMatchesRaw("insert")

        // Rows without upstream ids get derived ids; re-inserting with a real
        // id deletes the derived duplicate (dedupe DELETE path).
        let derived = randomTurns(80, seed: 2, eventIDs: false)
        XCTAssertTrue(db.insertTurns(derived))
        assertRollupMatchesRaw("derived insert")
        let upgraded = derived.prefix(40).enumerated().map { i, t in
            TurnRecord(tool: t.tool, sessionID: t.sessionID, project: nil, model: t.model, ts: t.ts,
                       inputTokens: t.inputTokens, outputTokens: t.outputTokens,
                       cacheRead: t.cacheRead, cacheWrite: t.cacheWrite, cost: t.cost,
                       provider: t.provider, eventID: "real-\(i)", costQuality: t.costQuality)
        }
        XCTAssertTrue(db.insertTurns(upgraded))
        assertRollupMatchesRaw("derived dedupe")

        // Duplicate event ids are ignored and must not double-count.
        XCTAssertTrue(db.insertTurns(randomTurns(600, seed: 1)))
        assertRollupMatchesRaw("duplicate insert")

        db.backfillCosts()
        assertRollupMatchesRaw("cost backfill")

        // Direct UPDATEs from another connection move rows across buckets,
        // days, tools, models, providers and qualities.
        externalExec("""
        UPDATE turns SET ts = ts + 437 WHERE id % 5 = 0;
        UPDATE turns SET tool = 'codex', model = NULL WHERE id % 7 = 0;
        UPDATE turns SET provider = 'deepseek', cost_quality = 'actual' WHERE id % 11 = 0;
        UPDATE turns SET cost = cost * 3, input_tokens = input_tokens + 1 WHERE id % 13 = 0;
        UPDATE turns SET project = 'unrelated' WHERE id % 3 = 0;
        DELETE FROM turns WHERE id % 17 = 0;
        """)
        assertRollupMatchesRaw("external updates")

        XCTAssertTrue(db.resetLocalUsage([(tool: .opencode, roots: [])]))
        assertRollupMatchesRaw("reset one tool")

        let backupPath = tmpPath + ".bak"
        XCTAssertTrue(db.backup(to: backupPath))
        XCTAssertTrue(db.clearAllData())
        assertRollupMatchesRaw("clear all")
        XCTAssertEqual(db.totals(from: 0, to: .max).count, 0)
        XCTAssertTrue(db.restore(from: backupPath))
        assertRollupMatchesRaw("restore")
        XCTAssertGreaterThan(db.totals(from: 0, to: .max).count, 0)
    }

    func testDriftIsRepairedOnOpen() {
        XCTAssertTrue(db.insertTurns(randomTurns(200, seed: 3)))
        externalExec("UPDATE turn_rollup SET input_tokens = input_tokens + 5;")
        XCTAssertGreaterThan(db.rollupMismatchCount(), 0)
        reopen()
        assertRollupMatchesRaw("after repair")
    }

    func testMissingTriggersAreReinstalledOnOpen() {
        XCTAssertTrue(db.insertTurns(randomTurns(200, seed: 4)))
        externalExec("DROP TRIGGER turn_rollup_insert;")
        reopen()
        XCTAssertTrue(db.insertTurns(randomTurns(200, seed: 5)))
        assertRollupMatchesRaw("after reinstall")
    }

    func testLegacyStoreWithoutRollupIsBackfilled() {
        XCTAssertTrue(db.insertTurns(randomTurns(300, seed: 6)))
        externalExec("""
        DROP TRIGGER turn_rollup_insert;
        DROP TRIGGER turn_rollup_delete;
        DROP TRIGGER turn_rollup_update;
        DROP TABLE turn_rollup;
        DELETE FROM settings WHERE k = 'turn_rollup_schema';
        """)
        reopen()
        assertRollupMatchesRaw("legacy backfill")
    }
}
