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
        XCTAssertEqual(s.models.map(\.name), ["Neon", "Others"])
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
        state.models = [.init(name: "A", remaining: 50, resetAt: 4_000_000_200),
                        .init(name: "B", remaining: 50, resetAt: 4_000_000_100),
                        .init(name: "C", remaining: 90, resetAt: 4_000_000_050)]
        XCTAssertEqual(state.tightest?.name, "B")
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

    func testModelsWithSameFractionAndResetShareOnePool() throws {
        let s = try XCTUnwrap(parse("""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 4 Neon (High)","quotaInfo":{"remainingFraction":0.98753834,"resetTime":"2026-11-19T16:59:52Z"}},
          {"label":"Gemini 4 Argon (High)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-26T12:02:52Z"}},
          {"label":"Gemini 4 Hydrogen (Low)","quotaInfo":{"remainingFraction":0.98753834,"resetTime":"2026-11-19T16:59:52Z"}},
          {"label":"Gemini 3.8 Flash (Low)","quotaInfo":{"remainingFraction":0.98753834,"resetTime":"2026-11-19T16:59:52Z"}},
          {"label":"Claude Opus 5.5 (Low)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-19T17:02:52Z"}},
          {"label":"GPT-OSS 120B (Medium)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-19T17:02:52Z"}}
        ]}}}
        """))
        XCTAssertEqual(s.models.map(\.name), ["Gemini", "Argon", "Others"])
        XCTAssertEqual(s.models[0].families, ["Gemini 4 Neon", "Gemini 4 Hydrogen", "Gemini 3.8 Flash"])
    }

    func testParsesQuotaSummaryGroupsAndWindows() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen, Gemini 3.8 Flash",
           "buckets":[
             {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.97,"resetTime":"2026-11-26T11:59:52Z"},
             {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9,"resetTime":"2026-11-19T16:59:52Z"}]},
          {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
           "buckets":[{"window":"5h","resetTime":"2026-11-19T17:24:26Z"}]},
          {"displayName":"Gemini 4 Argon","description":"For paid Pro plans, Argon quota is separate.",
           "buckets":[{"window":"weekly","remainingFraction":1,"resetTime":"2026-11-26T12:24:26Z"}]}
        ]}}
        """
        let buckets = try XCTUnwrap(AntigravityQuotaClient.parseQuotaSummary(Data(json.utf8)))
        XCTAssertEqual(buckets.map(\.label), ["Gemini 5h", "Gemini Weekly", "Others 5h", "Argon Weekly"])
        XCTAssertEqual(buckets[0].windowSeconds, 5 * 3600)
        XCTAssertEqual(buckets[1].windowSeconds, 7 * 86400)
        XCTAssertEqual(buckets[1].remaining, 97, accuracy: 0.001)
        XCTAssertEqual(buckets[2].remaining, 0, "an omitted fraction with a reset time is exhausted")
        XCTAssertEqual(buckets[0].families, ["Gemini 4 Neon", "Gemini 4 Hydrogen", "Gemini 3.8 Flash"])
        XCTAssertNil(AntigravityQuotaClient.parseQuotaSummary(Data("{}".utf8)))
    }

    func testDisplayLimitsKeepMainGroupAndHideUntouchedGroups() {
        var state = AntigravityQuotaClient.State()
        state.models = [
            .init(name: "Gemini", remaining: 89, resetAt: 4_000_000_010, window: "5h", windowSeconds: 18000),
            .init(name: "Gemini", remaining: 97, resetAt: 4_000_000_020, window: "Weekly", windowSeconds: 604800),
            .init(name: "Others", remaining: 100, resetAt: 4_000_000_030, window: "5h"),
            .init(name: "Others", remaining: 100, resetAt: 4_000_000_040, window: "Weekly"),
            .init(name: "Argon", remaining: 100, resetAt: 4_000_000_050, window: "Weekly"),
        ]
        XCTAssertEqual(state.displayLimits.map(\.label), ["5h", "Weekly"])
        state.models[3] = .init(name: "Others", remaining: 60, resetAt: 4_000_000_040, window: "Weekly")
        state.models[2] = .init(name: "Others", remaining: 80, resetAt: 4_000_000_030, window: "5h")
        XCTAssertEqual(state.displayLimits.map(\.label), ["5h", "Weekly", "Others"])
        XCTAssertEqual(state.displayLimits.last?.quota.remaining, 60)
    }

    func testReadingsPastTheirResetHaveRefilled() {
        var state = AntigravityQuotaClient.State()
        state.models = [
            .init(name: "Gemini", remaining: 0, resetAt: 1_000, window: "5h", windowSeconds: 18000),
            .init(name: "Gemini", remaining: 40, resetAt: 5_000, window: "Weekly", windowSeconds: 604800),
        ]
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(state.current(now: now).map(\.remaining), [100, 40])
        XCTAssertNil(state.current(now: now)[0].resetAt)
    }

    func testSummaryGroupsWithTheSameNameFallBackToBrands() throws {
        let json = """
        {"response":{"groups":[
          {"description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5",
           "buckets":[{"window":"5h","remainingFraction":0.5,"resetTime":"2026-11-19T17:24:26Z"}]},
          {"description":"Models within this group: GPT-OSS 120B",
           "buckets":[{"window":"5h","remainingFraction":0.8,"resetTime":"2026-11-19T17:24:26Z"},
                      {"window":"weekly","remainingFraction":0.9,"resetTime":"2026-11-26T17:24:26Z"}]}
        ]}}
        """
        let buckets = try XCTUnwrap(AntigravityQuotaClient.parseQuotaSummary(Data(json.utf8)))
        XCTAssertEqual(buckets.map(\.label), ["Claude 5h", "GPT-OSS 5h", "GPT-OSS Weekly"])
    }
}

final class AntigravityParserTests: XCTestCase {
    /// Minimal protobuf encoder for building fixtures.
    private func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    private func field(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    private func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ n: Int, _ s: String) -> [UInt8] { field(n, Array(s.utf8)) }

    func testParsesUsageModelAndStepIndices() {
        let usage = field(1, 1532) + field(2, 3220) + field(3, 307) + field(5, 8194) + field(6, 24)
            + field(7, "bot-1") + field(9, 97) + field(10, 210) + field(11, "resp-1")
        let chat = field(3, 1532) + field(4, usage) + field(19, "gemini-4-neon")
        let gen = AntigravityParser.parseGeneration(Data(field(1, chat) + field(2, [4, 5, 6]) + field(4, "exec")))
        XCTAssertEqual(gen.model, "gemini-4-neon")
        XCTAssertEqual(gen.stepIndices, [4, 5, 6])
        XCTAssertEqual(gen.usage, .init(input: 3220, output: 307, thinking: 97, cacheRead: 8194,
                                        messageID: "bot-1", responseID: "resp-1"))
    }

    func testTimingBecomesPerfSample() {
        let usage = field(2, 3220) + field(3, 307)
        let chat = field(4, usage) + field(11, field(1, 5) + field(2, 15_177_709))
            + field(12, field(1, 1) + field(2, 479_201_500)) + field(19, "gemini-4-neon")
        let gen = AntigravityParser.parseGeneration(Data(field(1, chat)))
        XCTAssertEqual(gen.timeToFirstTokenMs, 5015)
        XCTAssertEqual(gen.streamingMs, 1479)
        let sample = PerfCollector.antigravitySample(gen, key: "c:1", sentMs: 1_000_000)
        XCTAssertEqual(sample, PerfSample(tool: .antigravity, key: "c:1", model: "gemini-4-neon",
                                          requestMs: 1_000_000, firstTokenMs: 1_005_015,
                                          lastMs: 1_006_494, outputTokens: 307))
        XCTAssertNil(PerfCollector.antigravitySample(.init(usage: .init()), key: "c:2", sentMs: 0))
    }

    func testWatermarkStopsBeforeTrailingIncompleteRows() {
        func row(_ idx: Int64, done: Bool) -> AntigravityParser.Row {
            .init(idx: idx, gen: .init(usage: done ? .init(output: 1) : nil), sentAt: 0)
        }
        let rows = [row(3, done: true), row(4, done: false), row(5, done: true), row(6, done: false)]
        XCTAssertEqual(AntigravityParser.readThrough(rows, previous: 2) { $0.usage != nil }, 5)
        XCTAssertEqual(AntigravityParser.readThrough([row(7, done: false)], previous: 6) { $0.usage != nil }, 6)
        XCTAssertEqual(AntigravityParser.readThrough([], previous: 6) { $0.usage != nil }, 6)
    }

    func testStepCreatedAtAndMalformedInput() {
        let ts = field(1, 1_795_089_596) + field(2, 190_266_000)
        XCTAssertEqual(AntigravityParser.parseStepCreatedAt(Data(field(1, ts) + field(3, 2))), 1_795_089_596)
        XCTAssertNil(AntigravityParser.parseStepCreatedAt(Data([0xff, 0xff])))
        XCTAssertNil(AntigravityParser.parseGeneration(Data([0x0a, 0x50, 0x01])).usage)
    }

    func testProjectFromWorkspaceURIs() {
        XCTAssertEqual(AntigravityParser.project(fromWorkspaceURIs: #"["file:///Users/me/Projects/App"]"#), "App")
        XCTAssertEqual(AntigravityParser.project(fromWorkspaceURIs: "file:///Users/me/Work%20Dir"), "Work Dir")
        XCTAssertNil(AntigravityParser.project(fromWorkspaceURIs: "[]"))
        XCTAssertNil(AntigravityParser.project(fromWorkspaceURIs: ""))
    }

    func testDuplicateLabelsFallBackToBrands() {
        let pools = AntigravityQuotaClient.pools([
            .init(name: "Claude Opus 5.5", remaining: 50, resetAt: 1),
            .init(name: "GPT-OSS 120B", remaining: 90, resetAt: 2),
            .init(name: "Gemini 3.8 Flash", remaining: 70, resetAt: 3),
        ])
        XCTAssertEqual(pools.map(\.name), ["Claude", "GPT-OSS", "Flash"])
    }
}
