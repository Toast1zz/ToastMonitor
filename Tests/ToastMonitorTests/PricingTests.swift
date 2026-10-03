import XCTest
@testable import ToastMonitor

final class PricingTests: XCTestCase {

    func testOfficialStandardPriceFixtureOctober2026() throws {
        // Standard USD/MTok, 2026-10-03: platform.claude.com/docs/en/about-claude/pricing
        // and developers.openai.com/api/docs/models/gpt-5.4; cache writes use five minutes.
        let fixtures: [(String, Double, Double, Double, Double)] = [
            ("claude-fable-5-1", 10, 50, 0.25, 12.5),
            ("claude-fable-5", 10, 50, 1, 12.5),
            ("claude-mythos-5-1", 10, 50, 0.25, 12.5),
            ("claude-mythos-5", 10, 50, 1, 12.5),
            ("claude-opus-5-5", 4, 20, 0.2, 5),
            ("claude-opus-5", 5, 25, 0.5, 6.25),
            ("claude-opus-4-8", 5, 25, 0.5, 6.25),
            ("claude-opus-4-7", 5, 25, 0.5, 6.25),
            ("claude-opus-4-6", 5, 25, 0.5, 6.25),
            ("claude-opus-4-5", 5, 25, 0.5, 6.25),
            ("claude-opus-4-1", 15, 75, 1.5, 18.75),
            ("claude-opus-4", 15, 75, 1.5, 18.75),
            ("claude-sonnet-5-5", 2, 10, 0.2, 2.5),
            ("claude-sonnet-5", 2, 10, 0.2, 2.5),
            ("claude-sonnet-4-6", 3, 15, 0.3, 3.75),
            ("claude-sonnet-4-5", 3, 15, 0.3, 3.75),
            ("claude-sonnet-4", 3, 15, 0.3, 3.75),
            ("claude-haiku-4-5", 1, 5, 0.1, 1.25),
            ("claude-3-5-haiku", 0.8, 4, 0.08, 1),
            ("gpt-5.4", 2.5, 15, 0.25, 0)
        ]
        for (model, input, output, read, write) in fixtures {
            XCTAssertEqual(try cost(model, input: 1_000_000), input, accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, output: 1_000_000), output, accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, cacheRead: 1_000_000), read, accuracy: 0.00001, model)
            if model.hasPrefix("claude") {
                XCTAssertEqual(try cost(model, cacheWrite: 1_000_000), write, accuracy: 0.00001, model)
                XCTAssertEqual(try cost(model.replacingOccurrences(of: "-", with: ".")
                    .replacingOccurrences(of: "claude.", with: "claude-"), input: 1_000_000), input,
                    accuracy: 0.00001, model)
                XCTAssertEqual(try cost(model + "-20251001", input: 1_000_000), input,
                    accuracy: 0.00001, model)
            }
        }
        for model in ["claude-future", "claude-opus-9", "claude-sonnet-4-9", "claude-haiku-5"] {
            XCTAssertNil(Pricing.estimate(model: model, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        }
    }

    /// Unwraps the estimate so the `accuracy:` overload applies; a nil
    /// estimate (unknown model) fails with a clear message.
    private func cost(_ model: String?, input: Int64 = 0, output: Int64 = 0,
                      cacheRead: Int64 = 0, cacheWrite: Int64 = 0) throws -> Double {
        try XCTUnwrap(Pricing.estimate(model: model, input: input, output: output,
                                       cacheRead: cacheRead, cacheWrite: cacheWrite))
    }

    func testFirstMatchWinsGPT54MiniOverBase() throws {
        // "gpt-5.4-mini" sits BEFORE "gpt-5.4"/"gpt-5" in the table: a mini
        // model must hit the mini rate (0.25/2), not the base rate (1.25/10).
        XCTAssertEqual(try cost("gpt-5.4-mini", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.4-mini", output: 1_000_000), 2.0, accuracy: 0.0001)
    }

    func testGPT54ResolvesBeforeGPT5() throws {
        // "gpt-5.4" precedes "gpt-5": a gpt-5.4.x model resolves to the
        // gpt-5 family rate via the "gpt-5.4" entry and never falls through
        // to unknown (or to the mini rate).
        XCTAssertEqual(try cost("gpt-5.4-pro", input: 1_000_000, output: 1_000_000),
                       2.5 + 15, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.4", input: 1_000_000), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.1", input: 1_000_000), 1.25, accuracy: 0.0001,
                       "other gpt-5.x models resolve via the gpt-5 entry")
    }

    func testDeepseekFlashMatchesFlashEntry() throws {
        // "deepseek-v4-flash" is listed before "deepseek-v4" and must resolve
        // (never nil); both share the same rate.
        XCTAssertEqual(try cost("deepseek-v4-flash", input: 1_000_000, output: 1_000_000,
                                cacheRead: 1_000_000, cacheWrite: 1_000_000),
                       0.28 + 0.42 + 0.028 + 0.28, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-v4.1", input: 1_000_000), 0.28, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-v4", input: 1_000_000), 0.28, accuracy: 0.0001)
    }

    func testDashedClaude35HaikuMapsToHaikuRate() throws {
        // "claude-3-5-haiku" contains neither "claude-3.5" nor
        // "claude-3-haiku"; the dashed entry must win over the catch-all
        // claude rate (3/15) — otherwise haiku prices ~12x too high.
        XCTAssertEqual(try cost("claude-3-5-haiku", input: 1_000_000), 0.8, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", output: 1_000_000), 4, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", cacheRead: 1_000_000), 0.08, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", cacheWrite: 1_000_000), 1, accuracy: 0.0001)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(Pricing.estimate(model: "not-a-model-xyz", input: 1000, output: 1000,
                                      cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: nil, input: 1000, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: "", input: 1000, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testModelLookupIsCaseInsensitive() throws {
        XCTAssertEqual(try cost("GPT-5.4-MINI", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("CLAUDE-3-5-HAIKU", input: 1_000_000), 0.8, accuracy: 0.0001)
    }

    // PR-1: o3-mini / deepseek-r1 have their own entries BEFORE the family
    // catch-alls — they must resolve to their own rates, not the family ones.
    func testO3MiniResolvesToOwnEntryBeforeOFamily() throws {
        XCTAssertEqual(try cost("o3-mini", input: 1_000_000, output: 1_000_000,
                                cacheRead: 1_000_000, cacheWrite: 1_000_000),
                       1.1 + 4.4 + 0.55 + 1.65, accuracy: 0.0001)
        XCTAssertEqual(try cost("o3-mini", input: 1_000_000), 1.1, accuracy: 0.0001)
        XCTAssertEqual(try cost("o3-mini", output: 1_000_000), 4.4, accuracy: 0.0001)
        XCTAssertEqual(try cost("o3-mini", cacheRead: 1_000_000), 0.55, accuracy: 0.0001)
        XCTAssertEqual(try cost("o3-mini", cacheWrite: 1_000_000), 1.65, accuracy: 0.0001)
    }

    func testDeepseekR1ResolvesToOwnEntry() throws {
        XCTAssertEqual(try cost("deepseek-r1", input: 1_000_000, output: 1_000_000,
                                cacheRead: 1_000_000, cacheWrite: 1_000_000),
                       0.55 + 2.19 + 0.055 + 0.55, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-r1", input: 1_000_000), 0.55, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-r1", output: 1_000_000), 2.19, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-r1", cacheRead: 1_000_000), 0.055, accuracy: 0.0001)
        XCTAssertEqual(try cost("deepseek-r1", cacheWrite: 1_000_000), 0.55, accuracy: 0.0001)
    }
}
