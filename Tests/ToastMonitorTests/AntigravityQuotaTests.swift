import XCTest
@testable import ToastMonitor

final class AntigravityQuotaTests: XCTestCase {
    private func parse(_ json: String) -> AntigravityQuotaClient.Snapshot? {
        AntigravityQuotaClient.parseUserStatus(Data(json.utf8))
    }

    func testGroupsVariantsByFamilyKeepingLowestRemaining() throws {
        let s = try XCTUnwrap(parse("""
        {"userStatus":{"userTier":{"name":"Google AI Pro"},
          "planStatus":{"planInfo":{"planName":"Pro"}},
          "cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini 4 Neon (High)","quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-11-19T16:46:32Z"}},
            {"label":"Gemini 4 Neon (Low)","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-11-19T16:46:32Z"}},
            {"label":"Claude Opus 5.5 (High)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-26T11:46:32Z"}},
            {"label":"Gemini 4 Carbon","quotaInfo":{}},
            {"label":"No Quota"}
          ]}}}
        """))
        XCTAssertEqual(s.planName, "Google AI Pro")
        XCTAssertEqual(s.models.map(\.family), ["Gemini 4 Neon", "Claude Opus 5.5"])
        XCTAssertEqual(s.models[0].remaining, 60, accuracy: 0.001)
        XCTAssertEqual(s.models[0].resetAt,
                       Int64(GrokQuotaClient.isoDate("2026-11-19T16:46:32Z")!.timeIntervalSince1970))
        XCTAssertEqual(s.models[1].remaining, 100)
    }

    func testOmittedFractionWithResetMeansExhausted() throws {
        let s = try XCTUnwrap(parse("""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 3.8 Flash (Medium)","quotaInfo":{"resetTime":"2026-11-19T16:46:32Z"}}]}}}
        """))
        XCTAssertEqual(s.models.first?.remaining, 0)
    }

    func testFallsBackToPlanNameAndRejectsEmptyPayload() {
        XCTAssertEqual(parse(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"}}}}"#)?.planName, "Pro")
        XCTAssertNil(parse(#"{"userStatus":{}}"#))
        XCTAssertNil(parse("not json"))
    }

    func testTightestPicksLowestThenEarliestReset() {
        var state = AntigravityQuotaClient.State()
        state.models = [.init(family: "A", remaining: 50, resetAt: 200),
                        .init(family: "B", remaining: 50, resetAt: 100),
                        .init(family: "C", remaining: 90, resetAt: 50)]
        XCTAssertEqual(state.tightest?.family, "B")
    }

    func testFamilyStripsEffortSuffixOnly() {
        XCTAssertEqual(AntigravityQuotaClient.family(of: "Claude Sonnet 5.5 (Medium)"), "Claude Sonnet 5.5")
        XCTAssertEqual(AntigravityQuotaClient.family(of: "GPT-OSS 120B (Medium)"), "GPT-OSS 120B")
        XCTAssertEqual(AntigravityQuotaClient.family(of: "Gemini 4 Carbon"), "Gemini 4 Carbon")
    }

    func testParsesHubAndRejectsBadPort() {
        let hub = AntigravityQuotaClient.parseHub(Data(#"{"pid":72289,"httpsPort":64656,"httpPort":64652,"csrfToken":"abc-123"}"#.utf8))
        XCTAssertEqual(hub, .init(pid: 72289, httpPort: 64652, csrfToken: "abc-123"))
        XCTAssertNil(AntigravityQuotaClient.parseHub(Data(#"{"pid":1,"httpPort":0,"csrfToken":"x"}"#.utf8)))
        XCTAssertNil(AntigravityQuotaClient.parseHub(Data(#"{"pid":1,"httpPort":80,"csrfToken":""}"#.utf8)))
    }

    func testWindowLengthFromTimeToReset() {
        XCTAssertEqual(AntigravityQuotaClient.windowSeconds(resetAt: 1000 + 2 * 3600, now: 1000), 5 * 3600)
        XCTAssertEqual(AntigravityQuotaClient.windowSeconds(resetAt: 1000 + 6 * 86400, now: 1000), 7 * 86400)
        XCTAssertNil(AntigravityQuotaClient.windowSeconds(resetAt: 500, now: 1000))
    }

    func testRecordedGoogleSubscriptionNamesThePlan() {
        let sub = Database.Subscription(id: 1, name: "Google AI Pro (CN)", plan: "google",
                                        startDate: 0, cycle: "monthly", price: 20, currency: "USD")
        XCTAssertEqual(AntigravityQuotaClient.plan(subscriptions: [sub], apiPlan: "Google AI Pro"),
                       "Google AI Pro (CN)")
        XCTAssertEqual(AntigravityQuotaClient.plan(subscriptions: [], apiPlan: "Google AI Pro"), "Google AI Pro")
    }
}
