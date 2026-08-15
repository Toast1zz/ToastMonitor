import XCTest
import SQLite3
@testable import ToastMonitor

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// P0-1: Codex rollout 文件名解析。真实文件名格式:
/// rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid>.jsonl
/// removeFirst(7) 会把 UUID 第一段当时间戳删掉 → session 无法 join threads。
final class CodexParserTests: XCTestCase {

    func testSessionIDFromRealRolloutName() {
        // 真实样本 (脱敏): ~/.codex/sessions/2026/08/04/
        let name = "rollout-2026-08-04T09-22-33-019fcb70-2990-7ae3-897a-826135c6b1c5.jsonl"
        let expected = "019fcb70-2990-7ae3-897a-826135c6b1c5"
        let got = CodexParser.sessionID(fromRolloutName: name)
        XCTAssertEqual(got, expected, "UUID 第一段被 removeFirst(7) 删除 (P0-1)")
    }

    func testSessionIDFromZeroPaddedDate() {
        // 日期/时间全是双位
        let name = "rollout-2026-01-05T00-03-09-019f0000-1111-2222-3333-444455556666.jsonl"
        XCTAssertEqual(CodexParser.sessionID(fromRolloutName: name),
                       "019f0000-1111-2222-3333-444455556666")
    }

    func testMalformedNamesReturnNil() {
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "rollout-not-a-timestamp.jsonl"))
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "random.txt"))
        XCTAssertNil(CodexParser.sessionID(fromRolloutName: "2026-08-04T09-22-33-nouuid.jsonl"))
    }
}

/// Fixture-driven JSON tests against Tests/ToastMonitorTests/Fixtures/
/// codex-rollout-sample.jsonl (a session_meta + turn_context + two
/// token_count event_msg lines).
final class CodexParserJSONTests: XCTestCase {

    private var fixturePath: String {
        Bundle.module.url(forResource: "codex-rollout-sample", withExtension: "jsonl",
                          subdirectory: "Fixtures")!.path
    }

    /// Returns the `info` dicts of every token_count event in the fixture.
    private func tokenCountInfos() throws -> [[String: Any]] {
        let lines = try String(contentsOfFile: fixturePath, encoding: .utf8).split(separator: "\n")
        return try lines.compactMap { line in
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard obj?["type"] as? String == "event_msg",
                  let payload = obj?["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { return nil }
            return info
        }
    }

    func testTokensComeFromLastTokenUsageNotCumulative() throws {
        let infos = try tokenCountInfos()
        XCTAssertEqual(infos.count, 2)
        let counts = infos.compactMap { CodexParser.tokenCounts(from: $0) }
        XCTAssertEqual(counts.count, 2)

        // First token_count event: per-turn delta equals the total.
        XCTAssertEqual(counts[0].input, 4120)
        XCTAssertEqual(counts[0].output, 318)
        XCTAssertEqual(counts[0].cacheRead, 2048)   // cached_input_tokens
        XCTAssertEqual(counts[0].cacheWrite, 150)   // cache_write_input_tokens

        // Second event's total_token_usage is 7620/3248/739/230 — the parser
        // must use last_token_usage (per-turn), so input is 3500, not 7620.
        XCTAssertEqual(counts[1].input, 3500)
        XCTAssertEqual(counts[1].output, 421)
        XCTAssertEqual(counts[1].cacheRead, 1200)
        XCTAssertEqual(counts[1].cacheWrite, 80)

        // Cache split: cached input is reported separately from fresh input.
        XCTAssertEqual(counts[1].input + counts[1].cacheRead, 4700)
    }

    func testReasoningTokensRemainSeparateFromOutput() {
        let counts = CodexParser.tokenCounts(from: [
            "last_token_usage": [
                "input_tokens": 10,
                "output_tokens": 5,
                "reasoning_output_tokens": 17,
            ]
        ])
        XCTAssertEqual(counts?.input, 10)
        XCTAssertEqual(counts?.output, 5)
        XCTAssertEqual(counts?.reasoning, 17)
    }

    func testTokenCountsRequiresLastTokenUsage() {
        XCTAssertNil(CodexParser.tokenCounts(from: ["total_token_usage": ["input_tokens": 5]]),
                     "cumulative totals alone must not produce a turn")
        XCTAssertNil(CodexParser.tokenCounts(from: [:]))
        XCTAssertNil(CodexParser.tokenCounts(from: ["last_token_usage": "nope"]))
    }

    func testFixtureResolvesSessionAndModel() throws {
        // scan() resolves the per-turn model as: turn_context model →
        // chunk prescan → threads table. The fixture must carry turn_context
        // BEFORE every token_count event so that resolution succeeds, and the
        // session id must come from session_meta.
        let lines = try String(contentsOfFile: fixturePath, encoding: .utf8).split(separator: "\n")
        var sessionID: String?
        var contextModel: String?
        var tokenCountEvents = 0
        for line in lines {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any]
            switch obj["type"] as? String {
            case "session_meta":
                sessionID = payload?["session_id"] as? String
                XCTAssertEqual(payload?["model_provider"] as? String, "openai")
            case "turn_context":
                contextModel = payload?["model"] as? String
                XCTAssertEqual(payload?["provider"] as? String, "openai")
            case "event_msg" where payload?["type"] as? String == "token_count":
                tokenCountEvents += 1
                XCTAssertEqual(contextModel, "gpt-5.6-sol",
                               "each token_count event must be preceded by its turn_context")
                XCTAssertEqual(sessionID, "019fcb70-2990-7ae3-897a-826135c6b1c5")
            default:
                break
            }
        }
        XCTAssertEqual(sessionID, "019fcb70-2990-7ae3-897a-826135c6b1c5")
        XCTAssertEqual(contextModel, "gpt-5.6-sol")
        XCTAssertEqual(tokenCountEvents, 2)

        // The resolved model must price via the gpt-5.6 entry (1.25/10).
        let est = Pricing.estimate(model: contextModel, input: 3500, output: 421,
                                   cacheRead: 1200, cacheWrite: 80)
        XCTAssertNotNil(est, "gpt-5.6-sol must resolve to the gpt-5.6 rate")
        XCTAssertEqual(est!, 3500.0 / 1e6 * 1.25 + 421.0 / 1e6 * 10 + 1200.0 / 1e6 * 0.125 + 80.0 / 1e6 * 1.875,
                       accuracy: 0.0001)
    }
}


/// PARSER-1: two token_count events in the same second with identical
/// last_token_usage must still produce distinct event ids. The digest is
/// anchored on the byte offset, otherwise ON CONFLICT DO NOTHING silently
/// drops one of the turns.
final class CodexEventIdentityTests: XCTestCase {
    func testSameSecondSameUsageDistinctOffsetsKeepBothTurns() {
        let usage: [String: Any] = [
            "input_tokens": 4120, "output_tokens": 318,
            "cached_input_tokens": 2048, "cache_write_input_tokens": 150,
        ]
        let ts: Int64 = 1786628706
        let sid = "019f0000-0000-7000-0000-000000000001"
        let model = "gpt-5.6-sol"
        let first = EventIdentity.codex(sessionID: sid, timestamp: ts, model: model,
                                        usage: usage, offset: 1024)
        let second = EventIdentity.codex(sessionID: sid, timestamp: ts, model: model,
                                         usage: usage, offset: 3072)
        XCTAssertNotEqual(first, second,
                          "same second + same usage must not collide when the offsets differ")
        XCTAssertEqual(Set([first, second]).count, 2,
                       "both turns keep distinct event ids (2 distinct event IDs)")
        // Deterministic: identical inputs always yield the identical id, so
        // replays dedupe instead of double-counting.
        XCTAssertEqual(first, EventIdentity.codex(sessionID: sid, timestamp: ts, model: model,
                                                  usage: usage, offset: 1024))
        XCTAssertEqual(second, EventIdentity.codex(sessionID: sid, timestamp: ts, model: model,
                                                   usage: usage, offset: 3072))
    }
}


final class OpenCodeParserTests: XCTestCase {
    func testModelJSONPreservesProviderIdentity() {
        let raw = #"{"id":"gpt-5.6","providerID":"openai"}"#
        XCTAssertEqual(OpenCodeParser.normalizeModel(raw), "gpt-5.6")
        XCTAssertEqual(OpenCodeParser.normalizeProvider(raw), "openai")
        XCTAssertNil(OpenCodeParser.normalizeProvider("gpt-5.6"))
    }
}

/// PARSER-3: the opencode delta baseline is a per-counter HIGH-WATER MARK.
/// A source rollback (cumulative totals dropping) must not reset the origin,
/// or the regrowth beyond the old peak would be re-counted from the dip.
final class OpenCodeParserDeltaTests: XCTestCase {
    private var db: Database!
    private var dbPath = ""
    private var homeDir = ""

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-db-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-home-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        setenv("OPENCODE_HOME", homeDir, 1)
    }

    override func tearDown() {
        unsetenv("OPENCODE_HOME")
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        try? FileManager.default.removeItem(atPath: homeDir)
        super.tearDown()
    }

    /// Writes one row (id "s1") into a minimal opencode.db `session` table.
    private func writeRow(cost: Double, input: Int64, output: Int64, reasoning: Int64 = 0,
                          cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                          timeUpdated: Int64) {
        var raw: OpaquePointer?
        let path = OpenCodeParser.dbPath
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let schema = """
        CREATE TABLE IF NOT EXISTS session (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, directory TEXT NOT NULL,
          model TEXT, cost REAL NOT NULL, tokens_input INTEGER NOT NULL,
          tokens_output INTEGER NOT NULL, tokens_reasoning INTEGER NOT NULL,
          tokens_cache_read INTEGER NOT NULL, tokens_cache_write INTEGER NOT NULL,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
        """
        XCTAssertEqual(sqlite3_exec(raw, schema, nil, nil, nil), SQLITE_OK)
        let sql = "INSERT OR REPLACE INTO session VALUES (?,?,?,?,?,?,?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, ("s1" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, ("" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, ("/tmp/Proj" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, ("gpt-5.6" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, cost)
        sqlite3_bind_int64(stmt, 6, input)
        sqlite3_bind_int64(stmt, 7, output)
        sqlite3_bind_int64(stmt, 8, reasoning)
        sqlite3_bind_int64(stmt, 9, cacheRead)
        sqlite3_bind_int64(stmt, 10, cacheWrite)
        sqlite3_bind_int64(stmt, 11, 1786628000000)
        sqlite3_bind_int64(stmt, 12, timeUpdated)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    func testRollbackBaselineIsHighWaterMark() {
        writeRow(cost: 5.0, input: 1000, output: 500, timeUpdated: 1786628700000)
        let (first, _) = OpenCodeParser.scan(database: db)
        XCTAssertEqual(first.count, 1, "first sighting backfills the full totals")
        XCTAssertEqual(first[0].inputTokens, 1000)
        XCTAssertEqual(first[0].outputTokens, 500)
        XCTAssertEqual(first[0].cost, 5.0)

        // Source rolls back below the recorded baseline.
        writeRow(cost: 2.0, input: 400, output: 200, timeUpdated: 1786628800000)
        let (rolled, _) = OpenCodeParser.scan(database: db)
        XCTAssertTrue(rolled.isEmpty, "rollback must not emit negative deltas")
        let totals = db.sessionTotals()
        XCTAssertEqual(totals["opencode|s1"]?.input, 1000, "baseline input never drops")
        XCTAssertEqual(totals["opencode|s1"]?.output, 500, "baseline output never drops")

        // Regrowth beyond the old peak counts only the increase past the max.
        writeRow(cost: 7.5, input: 1200, output: 700, timeUpdated: 1786628900000)
        let (third, _) = OpenCodeParser.scan(database: db)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].inputTokens, 200, "1200 - max(1000, 400) = 200, not 800")
        XCTAssertEqual(third[0].outputTokens, 200, "700 - max(500, 200) = 200, not 500")
        XCTAssertEqual(third[0].cost, 2.5, accuracy: 0.0001, "7.5 - max(5.0, 2.0) = 2.5, not 5.5")
    }

    func testLegacyCombinedInputTransitionProducesNoDeltaAndRaisesBaseline() {
        // Older opencode versions folded reasoning into input: the baseline
        // is input = 1000 (combined), reasoning = 0.
        writeRow(cost: 5.0, input: 1000, output: 500, timeUpdated: 1786628700000)
        _ = OpenCodeParser.scan(database: db)

        // The split format reports input 900 + reasoning 100 (same total).
        writeRow(cost: 5.0, input: 900, output: 500, reasoning: 100, timeUpdated: 1786628800000)
        let (transition, _) = OpenCodeParser.scan(database: db)
        XCTAssertTrue(transition.isEmpty, "re-labeling input → reasoning is not new usage")

        // Later growth is measured from the max baseline (input 1000).
        writeRow(cost: 6.0, input: 1200, output: 500, reasoning: 150, timeUpdated: 1786628900000)
        let (grown, _) = OpenCodeParser.scan(database: db)
        XCTAssertEqual(grown.count, 1)
        XCTAssertEqual(grown[0].inputTokens, 200)
        XCTAssertEqual(grown[0].reasoningTokens, 50, "150 - max(0, 100) = 50")
    }
}