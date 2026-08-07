import XCTest
@testable import ToastMonitor

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
