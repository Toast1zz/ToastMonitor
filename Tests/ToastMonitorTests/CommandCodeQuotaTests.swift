import XCTest
@testable import ToastMonitor

final class CommandCodeQuotaTests: XCTestCase {

    // MARK: - Plan catalog

    func testPlanCatalogKnownAllowances() {
        XCTAssertEqual(CommandCodePlanCatalog.allowance(forPlanID: "individual-go"), 10)
        XCTAssertEqual(CommandCodePlanCatalog.allowance(forPlanID: "individual-goat"), 70)
        XCTAssertEqual(CommandCodePlanCatalog.allowance(forPlanID: "individual-pro"), 30)
        XCTAssertNil(CommandCodePlanCatalog.allowance(forPlanID: "individual-unknown"))
    }

    // MARK: - Credits parsing

    private func creditsData(monthly: Any?, purchased: Any? = nil) -> Data {
        var obj: [String: Any] = ["credits": [:]]
        var credits: [String: Any] = [:]
        if let monthly { credits["monthlyCredits"] = monthly }
        if let purchased { credits["purchasedCredits"] = purchased }
        obj["credits"] = credits
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func subsData(plan: String?, status: String? = "active",
                          periodEnd: String? = "2026-09-18T12:00:00.000Z") -> Data {
        var data: [String: Any] = [:]
        var inner: [String: Any] = [:]
        if let plan { inner["planId"] = plan }
        if let status { inner["status"] = status }
        if let periodEnd { inner["currentPeriodEnd"] = periodEnd }
        if !inner.isEmpty { data["data"] = inner }
        return try! JSONSerialization.data(withJSONObject: ["success": true, "data": data["data"] ?? NSNull()])
    }

    func testParseNormalCreditsAndSubscription() throws {
        let result = CommandCodeQuotaClient.parse(
            creditsData: creditsData(monthly: 68.42, purchased: 5.0),
            subsData: subsData(plan: "individual-goat"))
        let parsed = try result.get()
        XCTAssertEqual(parsed.monthlyCreditsRemaining, 68.42)
        XCTAssertEqual(parsed.purchasedCredits, 5.0)
        XCTAssertEqual(parsed.planID, "individual-goat")
        XCTAssertEqual(parsed.subscriptionStatus, "active")
        XCTAssertNotNil(parsed.billingPeriodEnd)
    }

    func testParseDataNullNoSubscription() throws {
        let result = CommandCodeQuotaClient.parse(
            creditsData: creditsData(monthly: 10),
            subsData: Data("{\"success\":true,\"data\":null}".utf8))
        let parsed = try result.get()
        XCTAssertEqual(parsed.monthlyCreditsRemaining, 10)
        XCTAssertNil(parsed.planID)
        XCTAssertNil(parsed.subscriptionStatus)
    }

    func testParseStringAmounts() throws {
        let result = CommandCodeQuotaClient.parse(
            creditsData: creditsData(monthly: "68.42"),
            subsData: subsData(plan: "individual-goat"))
        let parsed = try result.get()
        XCTAssertEqual(parsed.monthlyCreditsRemaining, 68.42)
    }

    func testParseInvalidJSONFails() {
        let result = CommandCodeQuotaClient.parse(
            creditsData: Data("not json".utf8),
            subsData: Data("{}".utf8))
        XCTAssertEqual(result, .failure(.parse))
    }

    func testParseMissingMonthlyCredits() throws {
        let result = CommandCodeQuotaClient.parse(
            creditsData: creditsData(monthly: nil),
            subsData: subsData(plan: "individual-goat"))
        let parsed = try result.get()
        XCTAssertNil(parsed.monthlyCreditsRemaining)
    }

    func testComputeUsedClamps() {
        // Remaining 0 → used == total → 100%.
        let full = CommandCodeQuotaClient.computeUsed(remaining: 0, total: 70)
        XCTAssertEqual(full?.used ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(full?.percent ?? -1, 100, accuracy: 0.001)

        // Remaining 70 → used 0 → 0%.
        let zero = CommandCodeQuotaClient.computeUsed(remaining: 70, total: 70)
        XCTAssertEqual(zero?.used ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(zero?.percent ?? -1, 0, accuracy: 0.001)

        // Remaining 35 → 50%.
        let half = CommandCodeQuotaClient.computeUsed(remaining: 35, total: 70)
        XCTAssertEqual(half?.percent ?? -1, 50, accuracy: 0.001)

        // Clamp beyond bounds.
        let over = CommandCodeQuotaClient.computeUsed(remaining: -10, total: 70)
        XCTAssertEqual(over?.percent ?? -1, 100, accuracy: 0.001)

        // No total / no remaining → nil (never fabricate).
        XCTAssertNil(CommandCodeQuotaClient.computeUsed(remaining: nil, total: 70))
        XCTAssertNil(CommandCodeQuotaClient.computeUsed(remaining: 10, total: nil))
        XCTAssertNil(CommandCodeQuotaClient.computeUsed(remaining: 10, total: 0))
    }

    // MARK: - HTTP validation

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.commandcode.ai/internal/billing/credits")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testValidateStatusCodes() {
        // 200 OK
        if case .success(let data) = CommandCodeQuotaClient.validate(
            data: Data("{}".utf8), response: httpResponse(status: 200), error: nil) {
            XCTAssertEqual(data, Data("{}".utf8))
        } else {
            XCTFail("200 must succeed")
        }
        // 401 / 403 → session expired mapping.
        XCTAssertEqual(CommandCodeQuotaClient.validate(
            data: Data(), response: httpResponse(status: 401), error: nil),
            .failure(.status(401)))
        XCTAssertEqual(CommandCodeQuotaClient.message(for: .status(401)),
                       "Studio session expired — reconfigure")
        XCTAssertEqual(CommandCodeQuotaClient.message(for: .status(403)),
                       "Studio session expired — reconfigure")
        // 3xx → redirect rejected.
        XCTAssertEqual(CommandCodeQuotaClient.validate(
            data: Data(), response: httpResponse(status: 302), error: nil),
            .failure(.redirect(302)))
        XCTAssertEqual(CommandCodeQuotaClient.message(for: .redirect(302)),
                       "Redirect rejected (HTTP 302)")
        // 500 → generic.
        XCTAssertEqual(CommandCodeQuotaClient.message(for: .status(500)),
                       "Command Code billing API HTTP 500")
    }
}
