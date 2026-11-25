import SwiftUI
import XCTest
@testable import ToastMonitor

final class AuditWave1And2RegressionTests: XCTestCase {
    private var dir: URL!
    private var db: Database!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-w12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = Database.testInstance(path: dir.appendingPathComponent("test.db").path)
    }

    override func tearDown() {
        db.close()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testHermesRemoteRejectsOctalAndDomainBypassIPv4() {
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://127.0.0.1.attacker.example/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://0100.0100.0.1/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://100.064.0.1/usage.json")!))
        XCTAssertFalse(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://127.0.1/usage.json")!))
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://LOCALHOST:8080/usage.json")!))
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://127.0.0.1:8080/usage.json")!))
        XCTAssertTrue(HermesRemoteClient.isAllowedFeedURL(URL(string: "http://100.116.140.74/usage.json")!))
    }

    func testClearAllDataRemovesLocalCursorsAndRefreshesCache() {
        XCTAssertTrue(db.setSetting("src_claude", "remote"))
        XCTAssertTrue(db.setSetting("opencode_row_watermark", "1790000000000"))
        XCTAssertTrue(db.setSetting("antigravity_gen_conv1", "42"))
        XCTAssertTrue(db.setSetting("remote_watermark_claude", "1790000000"))
        XCTAssertTrue(db.setSetting("or_credits_epoch", "1790000000"))
        XCTAssertTrue(db.setSetting("claude_quota_cache_v1", "{\"lastSync\":1}"))

        XCTAssertTrue(db.clearAllData())
        XCTAssertEqual(db.setting("src_claude"), "remote")
        XCTAssertNil(db.setting("opencode_row_watermark"))
        XCTAssertNil(db.setting("antigravity_gen_conv1"))
        XCTAssertNil(db.setting("remote_watermark_claude"))
        XCTAssertNil(db.setting("or_credits_epoch"))
        XCTAssertNil(db.setting("claude_quota_cache_v1"))
    }

    func testMixedKeepGreaterTurnsAndSplitUpgradesAreBackfilled() throws {
        // First run stamps pricing_correction_applied.
        db.setSetting("backfill_costs_last", nil)
        db.backfillCosts()
        db.setSetting("backfill_costs_last", nil)

        // Mix of two partial Claude snapshots: cacheWrite1h=nil so we keep split-known status if cacheWrite == 0.
        let s1 = TurnRecord(tool: .claude, sessionID: "mix", project: nil, model: "claude-sonnet-4-5",
                            ts: 100, inputTokens: 1_000_000, outputTokens: 0, cacheRead: 0, cacheWrite: 0,
                            cacheWrite1h: 0, cost: 3.0, eventID: "claude:mix:m1", usageMerge: .keepGreater)
        let s2 = TurnRecord(tool: .claude, sessionID: "mix", project: nil, model: "claude-sonnet-4-5",
                            ts: 101, inputTokens: 0, outputTokens: 1_000_000, cacheRead: 0, cacheWrite: 0,
                            cacheWrite1h: 0, cost: 15.0, eventID: "claude:mix:m1", usageMerge: .keepGreater)
        XCTAssertTrue(db.insertTurns([s1, s2]))
        db.backfillCosts()
        let repriced = try XCTUnwrap(db.turns(sessionTool: "claude", sessionID: "mix").first)
        XCTAssertEqual(repriced.cost, 18.0, accuracy: 0.0001)

        // Check ClaudeCodeParser leaves cacheWrite1h nil when split is absent and cacheWrite > 0.
        let transcript = dir.appendingPathComponent("claude.jsonl")
        let noSplit = #"{"type":"assistant","sessionId":"cs1","timestamp":"2026-08-04T10:00:02Z","message":{"id":"m_split","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":1000000}}}"#
        try "\(noSplit)\n".write(to: transcript, atomically: true, encoding: .utf8)
        let (firstTurns, _) = ClaudeCodeParser.scan(knownPaths: [transcript.path])
        XCTAssertNil(firstTurns.first?.cacheWrite1h)
    }

    func testCodexRollupPreservesPerTurnCacheClampEquivalence() {
        let normal = TurnRecord(tool: .codex, sessionID: "c1", project: nil, model: "gpt-5.3-codex",
                                ts: 900, inputTokens: 200_000, outputTokens: 0, cacheRead: 100_000, cacheWrite: 0,
                                cost: 0, eventID: "codex:c1:1")
        let inverted = TurnRecord(tool: .codex, sessionID: "c2", project: nil, model: "gpt-5.3-codex",
                                  ts: 905, inputTokens: 100_000, outputTokens: 0, cacheRead: 200_000, cacheWrite: 0,
                                  cost: 0, eventID: "codex:c2:1")
        XCTAssertTrue(db.insertTurns([normal, inverted]))
        XCTAssertEqual(db.rollupMismatchCount(), 0)
        db.aggregatesUseRollup = true
        let withRollup = db.apiValue(from: 0, to: 10_000, tool: "codex")
        db.aggregatesUseRollup = false
        let raw = db.apiValue(from: 0, to: 10_000, tool: "codex")
        db.aggregatesUseRollup = true
        XCTAssertEqual(withRollup, raw, accuracy: 1e-9)
    }

    func testPricingStripsModifiersAndResolvesVariantsAndDisplay() throws {
        let p = try XCTUnwrap(Pricing.estimate(model: "claude-opus-5-5-medium", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertEqual(p, 4.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "Claude Opus 5.5 (Medium)", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)), 4.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "claude-sonnet-4-5@20250929", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)), 3.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "gemini-3-flash", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "grok-3", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)), 3.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.estimate(model: "o1", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)), 15.0, accuracy: 0.0001)
        XCTAssertNil(Pricing.estimate(model: "claude-sonnet-4-extra", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricing.estimate(model: "claude-sonnet-4-9", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0))
        XCTAssertEqual(ModelName.display("claude-opus-4-6[1m]"), "Opus 4.6")
        XCTAssertEqual(ModelName.display("us.anthropic.claude-sonnet-4-5-20250929-v1:0"), "Sonnet 4.5")
        XCTAssertEqual(ModelProvider.name(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"), "Anthropic")
        XCTAssertEqual(ModelProvider.name(for: "o1-preview"), "OpenAI")
    }

    func testClaudeNonLocalEstimatorIgnoresUnpricedTokensInCalibration() throws {
        let baseTs: Int64 = 1_780_000_000
        let samples: [ClaudeNonLocalEstimator.Sample] = [
            .init(ts: baseTs, weeklyPct: 10, weeklyReset: baseTs + 86400, fiveHourPct: 10, fiveHourReset: baseTs + 10_000),
            .init(ts: baseTs + 2_000, weeklyPct: 15, weeklyReset: baseTs + 86400, fiveHourPct: 20, fiveHourReset: baseTs + 10_000),
            .init(ts: baseTs + 4_000, weeklyPct: 15, weeklyReset: baseTs + 86400, fiveHourPct: 30, fiveHourReset: baseTs + 10_000),
        ]
        // First interval has priced work (1M tokens, $10); plus 9M unpriced tokens (totalTokens = 10M, unpricedTokens = 9M).
        // Second interval is idle with +10 quota points.
        let locals: [ClaudeNonLocalEstimator.LocalIntervalTotals] = [
            .init(freshTokens: 1_000_000, totalTokens: 10_000_000, cost: 10.0, unpricedTokens: 9_000_000),
            .init(freshTokens: 0, totalTokens: 0, cost: 0.0, unpricedTokens: 0),
        ]
        let est = try XCTUnwrap(ClaudeNonLocalEstimator.tokenEstimate(samples: samples, localIntervalTotals: locals, now: baseTs + 10_000))
        // Priced tokens per point = (10M - 9M) / 10 pts = 100,000 (not 1,000,000!).
        XCTAssertEqual(est.tokensPerPoint, 100_000, accuracy: 1.0)
    }

    func testDSHLogRecoversWhenSessionHeaderArrivesAfterInitialEvent() throws {
        let log = dir.appendingPathComponent("session.jsonl")
        let initialData = Data("{\"type\":\"ping\",\"time\":1780000000}\n".utf8)
        try initialData.write(to: log)
        let first = DSHParser.scanLogs(knownPaths: [log.path], database: db) { $0 }
        XCTAssertTrue(first.turns.isEmpty)
        XCTAssertEqual(db.scanState(log.path).size, Int64(initialData.count))

        let tail = """
        {"type":"session","id":"dsh-late-sid","createdAt":1780000001}
        {"type":"assistant/message","time":1780000002,"data":{"turn":1,"step":1,"message":{"model":"deepseek-chat","usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":0,"cacheWriteTokens":0}}}}
        """
        let fh = try FileHandle(forWritingTo: log)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(tail.utf8))
        try fh.close()
        let second = DSHParser.scanLogs(knownPaths: [log.path], database: db) { $0 }
        XCTAssertEqual(second.turns.count, 1)
        XCTAssertEqual(second.turns.first?.sessionID, "dsh-late-sid")
        XCTAssertEqual(second.turns.first?.inputTokens, 100)
    }

    func testHermesRemotePreSumsRoutesDerivesDeltaEventIDsAndCountsChangedRows() {
        XCTAssertTrue(db.setSetting("src_hermes", "remote"))
        XCTAssertTrue(db.setSetting("src_opencode", "remote"))
        let now = Int64(Date().timeIntervalSince1970)
        // Duplicate snapshot of the same task ("") takes max, while distinct tasks ("" + "title_generation") sum;
        // plus one OpenCode cumulative row with static event_id.
        let batch1: [[String: Any]] = [
            ["tool": "hermes", "session_id": "h1", "model": "m", "billing_provider": "openrouter", "task": "",
             "first_seen": now - 10, "last_seen": now, "input_tokens": 1000, "output_tokens": 100, "event_id": "static-h"],
            ["tool": "hermes", "session_id": "h1", "model": "m", "billing_provider": "openrouter", "task": "",
             "first_seen": now - 10, "last_seen": now, "input_tokens": 1000, "output_tokens": 100, "event_id": "static-h-dup"],
            ["tool": "hermes", "session_id": "h1", "model": "m", "billing_provider": "openrouter", "task": "title_generation",
             "first_seen": now - 10, "last_seen": now, "input_tokens": 200, "output_tokens": 20, "event_id": "static-h2"],
            ["tool": "opencode", "session_id": "o1", "model": #"{"id":"gpt-5.4","providerID":"openrouter"}"#,
             "first_seen": now - 10, "last_seen": now, "input_tokens": 500, "output_tokens": 50,
             "cost_usd": 0.25, "event_id": "static-oc"]
        ]
        HermesRemoteClient.shared.importFeed(["rows": batch1], database: db)
        let hTurns1 = db.turns(sessionTool: "hermes", sessionID: "h1")
        XCTAssertEqual(hTurns1.reduce(Int64(0)) { $0 + $1.input }, 1200)
        let oTurns1 = db.turns(sessionTool: "opencode", sessionID: "o1")
        XCTAssertEqual(oTurns1.first?.model, "gpt-5.4")

        // Second cumulative update still carrying the exact same static event_id must NOT be dropped.
        let batch2: [[String: Any]] = [
            ["tool": "opencode", "session_id": "o1", "model": #"{"id":"gpt-5.4","providerID":"openrouter"}"#,
             "first_seen": now - 10, "last_seen": now + 5, "input_tokens": 800, "output_tokens": 90,
             "cost_usd": 0.40, "event_id": "static-oc"]
        ]
        HermesRemoteClient.shared.importFeed(["rows": batch2], database: db)
        let oTurns2 = db.turns(sessionTool: "opencode", sessionID: "o1")
        XCTAssertEqual(oTurns2.reduce(Int64(0)) { $0 + $1.input }, 800)
        XCTAssertEqual(db.costBreakdown(from: 0, to: Int64.max).openrouterActual, 0.40, accuracy: 0.0001)
    }

    func testAntigravityReadThroughStopsBeforeRecentIncompleteGeneration() {
        func row(_ idx: Int64, done: Bool, sentAt: Int64) -> AntigravityParser.Row {
            .init(idx: idx, gen: .init(usage: done ? .init(output: 1) : nil), sentAt: sentAt)
        }
        let now: Int64 = 1_780_000_000
        let rows = [
            row(1, done: true, sentAt: now - 20),
            row(2, done: false, sentAt: now - 10), // Active concurrent generation!
            row(3, done: true, sentAt: now - 5),
        ]
        XCTAssertEqual(AntigravityParser.readThrough(rows, previous: 0, now: now) { $0.usage != nil }, 1)
    }

    func testUsageAnalysisViewHandlesOtherModelCollisionWithoutDuplicateLabels() {
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let todayKey = Int64((c.year ?? 2026) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1))
        let aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)] = [
            (todayKey, "openrouter/other", 100, 50, 0, 1.0, 1, 150),
            (todayKey, "claude-sonnet-4-5", 200, 100, 0, 2.0, 1, 300),
            (todayKey, "gpt-5.4", 150, 50, 0, 1.0, 1, 200),
            (todayKey, "gpt-5.5", 140, 50, 0, 1.0, 1, 190),
            (todayKey, "gpt-5.6", 130, 50, 0, 1.0, 1, 180),
            (todayKey, "gemini-3-flash", 120, 50, 0, 1.0, 1, 170),
            (todayKey, "grok-3", 110, 50, 0, 1.0, 1, 160),
        ]
        let data = UsageAnalysisView.build(
            aggs: [], modelAggs: aggs, grouping: .byModel, range: .d7,
            modelColors: ["claude-sonnet-4-5": .orange])
        XCTAssertEqual(Set(data.labels).count, data.labels.count, "chart domain must never have duplicate labels")
        XCTAssertEqual(data.labels.filter { $0 == "Other" }.count, 1)
    }

    func testReadOnlyDatabaseSkipsRoutineBackup() throws {
        let roDir = dir.appendingPathComponent("ro-backup-test")
        let backupsDir = dir.appendingPathComponent("ro-backups")
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let roPath = roDir.appendingPathComponent("ro.db").path
        let setupDB = Database.testInstance(path: roPath)
        setupDB.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: roPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: roPath) }

        let roDB = Database.testInstance(path: roPath)
        defer { roDB.close() }
        XCTAssertNotNil(roDB.openProblem)
        DataMaintenance.maybeCreateRoutineBackupIfDue(database: roDB, backupDirectory: backupsDir)
        XCTAssertEqual(DataMaintenance.availableBackups(in: backupsDir).count, 0)
    }

    func testPerfCollectorClampsAbsurdClaudeOutputTokens() {
        let obj: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-11-25T10:00:00Z",
            "requestId": "req-huge",
            "message": [
                "model": "claude-sonnet-4-6",
                "usage": ["output_tokens": NSNumber(value: Int64.max)]
            ]
        ]
        let sample = PerfCollector.claudeSample(obj)
        XCTAssertEqual(sample?.outputTokens, 0, "tokens above ceiling are rejected safely")
    }

    func testOmpParserExtractsProviderFromMessage() throws {
        let log = dir.appendingPathComponent("omp-provider.jsonl")
        let content = """
        {"type":"session","id":"omp-s1"}
        {"type":"message","id":"m1","timestamp":"2026-11-25T10:00:00Z","message":{"role":"assistant","provider":"openrouter","model":"deepseek/deepseek-chat","usage":{"input":100,"output":50,"cost":{"total":0.12}}}}
        """
        try content.write(to: log, atomically: true, encoding: .utf8)
        let (turns, _) = OmpParser.scan(knownPaths: [log.path], database: db)
        XCTAssertEqual(turns.first?.provider, "openrouter")
        XCTAssertEqual(turns.first?.costQuality, "actual")
    }

    @MainActor
    func testClaudeRevokedTokenDoesNotResetRetryOnRepeated401() async throws {
        final class Stub401Protocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub401Protocol.self]
        let future = Int64(Date().timeIntervalSince1970) + 3600
        let client = ClaudeQuotaClient(
            forTestingWithConfiguration: cfg,
            credentialLoader: { .init(accessToken: "revoked-tok", expiresAt: future, subscriptionType: "max") },
            cliRefresher: { _ in .failed("CLI did not renew") }
        )
        defer { client.setEnabled(false) }

        client.refresh(force: true, renewing: false)
        for _ in 0..<200 {
            if client.renewalFailuresForTesting >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.rejectedTokenForTesting, "revoked-tok")
        XCTAssertEqual(client.renewalFailuresForTesting, 1)

        // Advance to failure #5 and retest the same still-revoked token -> must NOT reset to 0.
        for _ in 0..<4 {
            client.simulateRenewalFailureForTesting(outcome: .failed("still 401"))
        }
        XCTAssertEqual(client.renewalFailuresForTesting, 5)
        client.refresh(force: true, renewing: true, retestRejected: true)
        for _ in 0..<200 {
            if client.renewalFailuresForTesting >= 6 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(client.renewalFailuresForTesting, 6)
        XCTAssertEqual(client.rejectedTokenForTesting, "revoked-tok")
    }
}
