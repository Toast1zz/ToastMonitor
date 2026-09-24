import XCTest
@testable import ToastMonitor

final class CodexPlanNameTests: XCTestCase {
    private func sub(_ price: Double, cycle: String = "monthly") -> Database.Subscription {
        Database.Subscription(id: 1, name: "ChatGPT", plan: "openai", startDate: 0,
                              cycle: cycle, price: price, currency: "USD")
    }

    func testCustomNameWins() {
        XCTAssertEqual(CodexPlanName.resolve(custom: "  Work Codex ", apiPlan: "pro", subscription: sub(20)),
                       "Work Codex")
    }

    func testBlankCustomNameFallsBackToDetection() {
        XCTAssertEqual(CodexPlanName.resolve(custom: "   ", apiPlan: "pro", subscription: nil), "Codex Pro")
    }

    func testAPIPlanBeatsPrice() {
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: "pro", subscription: sub(20)), "Codex Pro")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: "team", subscription: sub(20)), "Codex Business")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: "free_workspace", subscription: nil),
                       "Codex Free Workspace")
    }

    func testPriceBandsWhenAPIUnknown() {
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(8)), "Codex Go")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(20)), "Codex Plus")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: "", subscription: sub(23.5)), "Codex Plus")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(200)), "Codex Pro")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(2_400, cycle: "yearly")),
                       "Codex Pro")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(240, cycle: "yearly")),
                       "Codex Plus")
    }

    func testNothingKnownIsPlainCodex() {
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: nil), "Codex")
        XCTAssertEqual(CodexPlanName.resolve(custom: nil, apiPlan: nil, subscription: sub(0)), "Codex")
    }
}
