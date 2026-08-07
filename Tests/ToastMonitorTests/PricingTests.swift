import XCTest
@testable import ToastMonitor

final class PricingTests: XCTestCase {

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
                       1.25 + 10, accuracy: 0.0001)
        XCTAssertEqual(try cost("gpt-5.4", input: 1_000_000), 1.25, accuracy: 0.0001)
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
        XCTAssertEqual(try cost("claude-3-5-haiku", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", output: 1_000_000), 1.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", cacheRead: 1_000_000), 0.03, accuracy: 0.0001)
        XCTAssertEqual(try cost("claude-3-5-haiku", cacheWrite: 1_000_000), 0.3, accuracy: 0.0001)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(Pricing.estimate(model: "not-a-model-xyz", input: 1000, output: 1000,
                                      cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: nil, input: 1000, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: "", input: 1000, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testModelLookupIsCaseInsensitive() throws {
        XCTAssertEqual(try cost("GPT-5.4-MINI", input: 1_000_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try cost("CLAUDE-3-5-HAIKU", input: 1_000_000), 0.25, accuracy: 0.0001)
    }
}
