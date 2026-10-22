import XCTest
@testable import ToastMonitor

final class GrokQuotaTests: XCTestCase {
    private let now = GrokQuotaClient.isoDate("2026-10-05T12:00:00Z")!

    private func billing(_ json: String) -> GrokQuotaClient.Snapshot? {
        GrokQuotaClient.parseBilling(Data(json.utf8), now: now)
    }

    // MARK: - Billing

    func testParsesWeeklyPercentResetAndWindow() throws {
        let s = try XCTUnwrap(billing("""
        {"config":{"creditUsagePercent":12.5,
          "currentPeriod":{"start":"2026-10-01T00:00:00Z","end":"2026-10-08T00:00:00Z"},
          "billingPeriodStart":"2026-09-13T00:00:00Z","billingPeriodEnd":"2026-10-13T00:00:00Z"}}
        """))
        XCTAssertEqual(s.usedPercent, 12.5)
        XCTAssertEqual(s.resetAt, Int64(GrokQuotaClient.isoDate("2026-10-08T00:00:00Z")!.timeIntervalSince1970))
        XCTAssertEqual(s.windowSeconds, 7 * 86400)
    }

    func testFallsBackToBillingPeriodWithoutMixingPeriods() throws {
        let s = try XCTUnwrap(billing("""
        {"config":{"creditUsagePercent":40,
          "billingPeriodStart":"2026-10-01T00:00:00Z","billingPeriodEnd":"2026-10-08T00:00:00Z"}}
        """))
        XCTAssertEqual(s.windowSeconds, 7 * 86400)
        // currentPeriod end without start must not borrow billingPeriodStart.
        let mixed = try XCTUnwrap(billing("""
        {"config":{"creditUsagePercent":40,"currentPeriod":{"end":"2026-10-08T00:00:00Z"},
          "billingPeriodStart":"2026-09-01T00:00:00Z","billingPeriodEnd":"2026-10-13T00:00:00Z"}}
        """))
        XCTAssertNil(mixed.windowSeconds)
    }

    func testOmittedPercentInActivePeriodIsZero() throws {
        let s = try XCTUnwrap(billing("""
        {"config":{"currentPeriod":{"start":"2026-10-01T00:00:00Z","end":"2026-10-08T00:00:00Z"}}}
        """))
        XCTAssertEqual(s.usedPercent, 0)
    }

    func testOnDemandFallbackAndClamping() throws {
        XCTAssertEqual(billing("""
        {"config":{"onDemandCap":{"val":200},"onDemandUsed":{"val":50}}}
        """)?.usedPercent, 25)
        XCTAssertEqual(billing(#"{"config":{"creditUsagePercent":104.2,"billingPeriodEnd":"2026-10-08T00:00:00Z"}}"#)?
            .usedPercent, 100)
        XCTAssertEqual(billing(#"{"config":{"creditUsagePercent":-3}}"#)?.usedPercent, 0)
    }

    func testRejectsEmptyOrMalformedPayloads() {
        XCTAssertNil(billing(#"{"config":{}}"#))
        XCTAssertNil(billing(#"{"nope":1}"#))
        XCTAssertNil(billing("not json"))
        XCTAssertNil(billing(#"{"config":{"creditUsagePercent":true}}"#))
    }

    func testMicrosecondTimestamps() {
        let d = GrokQuotaClient.isoDate("2026-08-23T18:42:45.537749+00:00")
        XCTAssertEqual(d, GrokQuotaClient.isoDate("2026-08-23T18:42:45.537Z"))
        XCTAssertNotNil(GrokQuotaClient.isoDate("2026-08-23T18:42:45Z"))
    }

    // MARK: - Products

    func testProductBreakdownIncludesGrokBotSortedByShare() throws {
        let s = try XCTUnwrap(billing("""
        {"config":{"creditUsagePercent":30,"billingPeriodEnd":"2026-10-08T00:00:00Z",
          "productUsage":[{"product":"GrokChat","usagePercent":5},
                          {"product":"GrokBot","usagePercent":25},
                          {"product":"GrokImagine","usagePercent":0}]}}
        """))
        XCTAssertEqual(s.products.map(\.displayName), ["Grok Bot", "Grok Chat"])
        XCTAssertEqual(s.products.map(\.usedPercent), [25, 5])
    }

    func testProductBreakdownDroppedWhenItDoesNotAddUp() throws {
        let s = try XCTUnwrap(billing("""
        {"config":{"creditUsagePercent":30,
          "productUsage":[{"product":"GrokBuild","usagePercent":3}]}}
        """))
        XCTAssertTrue(s.products.isEmpty)
        XCTAssertTrue(GrokQuotaClient.products([["product": "GrokBuild"]], total: 0).isEmpty)
    }

    func testDisplayNames() {
        XCTAssertEqual(GrokQuotaClient.ProductUsage(product: "GrokAppBuilder", usedPercent: 1).displayName,
                       "Grok App Builder")
        XCTAssertEqual(GrokQuotaClient.ProductUsage(product: "API", usedPercent: 1).displayName, "API")
    }

    // MARK: - Plan and balance

    func testPlanNames() {
        XCTAssertEqual(GrokQuotaClient.parsePlanName(Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)),
                       "SuperGrok")
        XCTAssertEqual(GrokQuotaClient.planDisplayName("SUPER_GROK_HEAVY"), "SuperGrok Heavy")
        XCTAssertEqual(GrokQuotaClient.planDisplayName("  "), nil)
        XCTAssertNil(GrokQuotaClient.parsePlanName(Data("{}".utf8)))
    }

    func testPrepaidBalanceIsCents() {
        XCTAssertEqual(GrokQuotaClient.prepaidBalanceUSD(["val": 1250]), 12.5)
        XCTAssertEqual(GrokQuotaClient.prepaidBalanceUSD(["val": "300"]), 3)
        XCTAssertEqual(GrokQuotaClient.prepaidBalanceUSD([String: Any]()), 0)
        XCTAssertNil(GrokQuotaClient.prepaidBalanceUSD(["val": -1]))
        XCTAssertNil(GrokQuotaClient.prepaidBalanceUSD(nil))
        // A balance alone is a valid reading.
        XCTAssertEqual(billing(#"{"config":{"prepaidBalance":{"val":500}}}"#)?.prepaidBalanceUSD, 5)
    }

    // MARK: - Credentials

    func testPrefersOIDCEntryOverLegacy() {
        let json = """
        {"https://accounts.x.ai/sign-in":{"key":"legacy"},
         "https://auth.x.ai::client":{"key":"oidc","expires_at":"2026-10-06T00:00:00Z"}}
        """
        let c = GrokQuotaClient.parseCredentials(Data(json.utf8))
        XCTAssertEqual(c?.accessToken, "oidc")
        XCTAssertEqual(c?.expiresAt, GrokQuotaClient.isoDate("2026-10-06T00:00:00Z"))
    }

    func testEmptyOIDCKeyDoesNotShadowLegacy() {
        let json = """
        {"https://accounts.x.ai/sign-in":{"key":"legacy"},"https://auth.x.ai::client":{"key":""}}
        """
        XCTAssertEqual(GrokQuotaClient.parseCredentials(Data(json.utf8))?.accessToken, "legacy")
        XCTAssertNil(GrokQuotaClient.parseCredentials(Data(#"{"other":{"key":"x"}}"#.utf8)))
        XCTAssertNil(GrokQuotaClient.parseCredentials(Data("[]".utf8)))
    }

    func testAuthFileHonorsGrokHome() {
        XCTAssertEqual(GrokQuotaClient.authFileURL(env: ["GROK_HOME": "/tmp/g"]).path, "/tmp/g/auth.json")
        XCTAssertTrue(GrokQuotaClient.authFileURL(env: [:]).path.hasSuffix("/.grok/auth.json"))
    }

    func testUnauthorizedMessagePointsToLogin() {
        XCTAssertEqual(GrokQuotaClient.message(for: .status(401)), "Grok login expired — run grok login")
        XCTAssertEqual(GrokQuotaClient.message(for: .status(500)), "Grok billing API HTTP 500")
    }

    func testRecordedSubscriptionNamesThePlan() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func sub(_ plan: String, end: Int64 = 0) -> Database.Subscription {
            Database.Subscription(id: 1, name: "X Subscription Premium", plan: plan, startDate: 1_900_000_000,
                                  endDate: end, cycle: "monthly", price: 30, currency: "USD")
        }
        XCTAssertEqual(GrokQuotaClient.plan(subscriptions: [sub("grok")], apiPlan: "SuperGrok", now: now),
                       "X Subscription Premium")
        // Not a Grok subscription, or one that has ended: the API's tier.
        XCTAssertEqual(GrokQuotaClient.plan(subscriptions: [sub("claude")], apiPlan: "SuperGrok", now: now), "SuperGrok")
        XCTAssertEqual(GrokQuotaClient.plan(subscriptions: [sub("grok", end: 1_950_000_000)], apiPlan: "SuperGrok",
                                            now: now), "SuperGrok")
        XCTAssertEqual(GrokQuotaClient.plan(subscriptions: [sub("grok", end: 2_100_000_000)], apiPlan: nil, now: now),
                       "X Subscription Premium")
        XCTAssertNil(GrokQuotaClient.plan(subscriptions: [], apiPlan: nil, now: now))
    }
}
