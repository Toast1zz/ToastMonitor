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
            ("claude-sonnet-5-5", 2, 10, 0.1, 2.5),
            ("claude-sonnet-5", 2, 10, 0.2, 2.5),
            ("claude-sonnet-4-6", 3, 15, 0.3, 3.75),
            ("claude-sonnet-4-5", 3, 15, 0.3, 3.75),
            ("claude-sonnet-4", 3, 15, 0.3, 3.75),
            ("claude-haiku-4-5", 1, 5, 0.1, 1.25),
            ("claude-3-5-haiku", 0.8, 4, 0.08, 1),
            ("gpt-5.4", 2.5, 15, 0.25, 0)
        ]
        for (model, input, output, read, write) in fixtures {
            XCTAssertEqual(try cost(model, input: 1_000_000, longPrompt: false), input, accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, output: 1_000_000), output, accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, cacheRead: 1_000_000, longPrompt: false), read, accuracy: 0.00001, model)
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
                      cacheRead: Int64 = 0, cacheWrite: Int64 = 0, longPrompt: Bool? = nil) throws -> Double {
        try XCTUnwrap(Pricing.estimate(model: model, input: input, output: output,
                                       cacheRead: cacheRead, cacheWrite: cacheWrite, longPrompt: longPrompt))
    }

    func testHaiku55AndGPT6ShortContextRates() throws {
        // claude-haiku-5-5, prompts ≤100k: platform.claude.com/docs/en/about-claude/pricing
        // gpt-6.1-sol and gpt-6-astra short context: developers.openai.com/api/docs/pricing
        // (30-minute cache write; 12-hour writes are not modeled).
        XCTAssertEqual(try cost("claude-haiku-5-5", input: 100_000), 0.01, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", output: 1_000_000), 0.50, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", cacheRead: 100_000), 0.001, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", cacheWrite: 100_000), 0.0125, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6.1-sol", input: 1_000_000, longPrompt: false), 2, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6.1-sol", output: 1_000_000), 10, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6.1-sol", cacheRead: 1_000_000, longPrompt: false), 0.10, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6.1-sol", cacheWrite: 1_000_000, longPrompt: false), 2.50, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6-astra", input: 1_000_000, longPrompt: false), 10, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6-astra", output: 1_000_000), 50, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6-astra", cacheRead: 1_000_000, longPrompt: false), 1, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6-astra", cacheWrite: 1_000_000, longPrompt: false), 12.50, accuracy: 0.00001)
        XCTAssertNil(Pricing.estimate(model: "claude-haiku-5", input: 1, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertEqual(try cost("gpt-6-sol", cacheRead: 1_000_000, longPrompt: false), 0.20, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6-luna", output: 1_000_000), 0.50, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-6.1-terra", input: 1_000_000, longPrompt: false), 1, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-5.6-sol", input: 1_000_000, longPrompt: false), 4, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-5.6-terra", output: 1_000_000), 12, accuracy: 0.00001)
        XCTAssertEqual(try cost("gpt-5.6-luna", cacheRead: 1_000_000, longPrompt: false), 0.02, accuracy: 0.00001)
    }

    /// Official table: over 100,000 tokens every Haiku 5.5 rate is 5×, and the
    /// whole request pays it even when most of the prompt is a cache hit.
    func testHaiku55LongPromptTier() throws {
        XCTAssertEqual(try cost("claude-haiku-5-5", input: 1_000_000), 0.50, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", cacheRead: 1_000_000), 0.05, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", cacheWrite: 1_000_000), 0.625, accuracy: 0.00001)
        XCTAssertEqual(try cost("claude-haiku-5-5", input: 10, output: 1_000_000, cacheRead: 100_000),
                       (10.0 / 1e6 * 0.10 + 0.50 + 100_000.0 / 1e6 * 0.01) * 5, accuracy: 0.00001)
        let oneHour = try XCTUnwrap(Pricing.estimate(model: "claude-haiku-5-5", input: 0, output: 0, cacheRead: 0,
                                                     cacheWrite: 0, cacheWrite1h: 1_000_000))
        XCTAssertEqual(oneHour, 1, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "claude-haiku-5-5", input: 1_000_000, output: 0,
                                                      cacheRead: 0, cacheWrite: 0, longPrompt: false)),
                       0.10, accuracy: 0.00001, "aggregates pass the tier they were grouped by")
        // Other models have no tier.
        XCTAssertEqual(try cost("claude-sonnet-5-5", input: 1_000_000), 2, accuracy: 0.00001)
    }

    /// Official long rates, developers.openai.com/api/docs/pricing, 2026-10-31.
    func testGPTLongContextChargesTheWholeRequest() throws {
        let fixtures: [(String, Double, Double, Double, Double, Double, Double, Double, Double)] = [
            ("gpt-6.1-sol", 2, 0.10, 2.50, 10, 4, 0.20, 5, 15),
            ("gpt-6.1-terra", 1, 0.05, 1.25, 5, 2, 0.10, 2.50, 7.50),
            ("gpt-6-astra", 10, 1, 12.50, 50, 20, 2, 25, 75),
            ("gpt-6-sol", 2, 0.20, 2.50, 10, 4, 0.40, 5, 15),
            ("gpt-6-luna", 0.10, 0.01, 0.125, 0.50, 0.20, 0.02, 0.25, 0.75),
            ("gpt-5.6-sol", 4, 0.40, 5, 20, 8, 0.80, 10, 30),
            ("gpt-5.6-terra", 2, 0.20, 2.50, 12, 4, 0.40, 5, 18),
            ("gpt-5.6-luna", 0.20, 0.02, 0.25, 1.20, 0.40, 0.04, 0.50, 1.80),
            ("gpt-5.4", 2.50, 0.25, 1.875, 15, 5, 0.50, 3.75, 22.50)
        ]
        for (model, input, read, write, output, longInput, longRead, longWrite, longOutput) in fixtures {
            XCTAssertEqual(try cost(model, input: 272_000, output: 1_000_000),
                           0.272 * input + output, accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, input: 1, output: 1_000_000, cacheRead: 200_000, cacheWrite: 72_000),
                           1.0 / 1e6 * longInput + longOutput + 0.2 * longRead + 0.072 * longWrite,
                           accuracy: 0.00001, model)
            XCTAssertEqual(try cost(model, input: 1, cacheRead: 200_000, cacheWrite: 71_999),
                           1.0 / 1e6 * input + 0.2 * read + 0.071999 * write, accuracy: 0.00001, model)
        }
        // Over the threshold on cache hits alone, and with a provider prefix.
        XCTAssertEqual(try cost("openai/gpt-6.1-sol", output: 1_000_000, cacheRead: 300_000),
                       15 + 0.3 * 0.20, accuracy: 0.00001)
    }

    /// Codex counts cache reads inside input, so they must not count twice.
    func testGPTLongContextCountsCodexCachedInputOnce() throws {
        func codex(input: Int64, cacheRead: Int64) throws -> Double {
            try XCTUnwrap(Pricing.estimate(model: "gpt-6.1-sol", input: input, output: 0, cacheRead: cacheRead,
                                           cacheWrite: 0, inputIncludesCache: true))
        }
        XCTAssertEqual(try codex(input: 200_000, cacheRead: 150_000),
                       0.05 * 2 + 0.15 * 0.10, accuracy: 0.00001)
        XCTAssertEqual(try codex(input: 300_000, cacheRead: 290_000),
                       0.01 * 4 + 0.29 * 0.20, accuracy: 0.00001)
    }

    func testModelsWithoutAPublishedLongRateKeepTheirRate() throws {
        for (model, rate) in [("gpt-5.4-mini", 0.25), ("gpt-5.6", 1.25), ("gpt-5.6-cyber", 1.25), ("gpt-5", 1.25),
                              ("gpt-5.1-codex-mini", 0.25), ("gpt-4o", 2.5), ("o4", 2.0)] {
            XCTAssertEqual(try cost(model, input: 1_000_000), rate, accuracy: 0.00001, model)
        }
        XCTAssertEqual(try cost("claude-haiku-5-5", input: 272_000), 0.272 * 0.50, accuracy: 0.00001)
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
        XCTAssertEqual(try cost("gpt-5.4-pro", input: 1_000_000, output: 1_000_000, longPrompt: false),
                       2.5 + 15, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.4", input: 1_000_000, longPrompt: false), 2.5, accuracy: 0.0001)
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

    func testMiniNanoFlashDoNotInheritTheFullModelRate() throws {
        XCTAssertEqual(try cost("gpt-5-mini", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5-nano", input: 1_000_000), 0.05, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.1-codex-mini", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-4.1-nano", input: 1_000_000), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try cost("gemini-2.5-flash", input: 1_000_000), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try cost("gemini-2.0-flash", output: 1_000_000), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try cost("o4-mini", input: 1_000_000), 1.1, accuracy: 0.0001)
        XCTAssertNotEqual(try cost("gpt-5-mini", input: 1_000_000), try cost("gpt-5", input: 1_000_000))
        XCTAssertNotEqual(try cost("gemini-2.5-flash", input: 1_000_000), try cost("gemini-2.5", input: 1_000_000))
        XCTAssertNotEqual(try cost("o4-mini", input: 1_000_000), try cost("o4", input: 1_000_000))
    }

    func testSubstringIsNotAModelMatch() {
        XCTAssertNil(Pricing.estimate(model: "not-gpt-5", input: 1, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: "mygpt-5-mini", input: 1, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: "claude-sonnet-4-extra", input: 1, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testOneHourCacheWritesCostTwiceInput() throws {
        let cost = try XCTUnwrap(Pricing.estimate(model: "claude-sonnet-4-6", input: 0, output: 0,
                                                  cacheRead: 0, cacheWrite: 0, cacheWrite1h: 1_000_000))
        XCTAssertEqual(cost, 6, accuracy: 0.0001)
    }

    func testProviderPrefixedModelUsesTheLeaf() throws {
        XCTAssertEqual(try cost("openai/gpt-5-mini", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("anthropic/claude-sonnet-4-6", input: 1_000_000), 3, accuracy: 0.0001)
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
