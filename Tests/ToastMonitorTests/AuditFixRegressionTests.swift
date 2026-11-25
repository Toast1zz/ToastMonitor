import XCTest
import SQLite3
@testable import ToastMonitor

final class AuditFixRegressionTests: XCTestCase {
    /// C-1: verifyCodesign must actually enforce Team ID and bundle identifier
    /// via Security.framework rather than being silently ignored by codesign.
    func testVerifyCodesignRejectsMismatchedTeamAndBundleID() {
        let appleBinary = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertFalse(
            UpdateManager.verifyCodesign(
                appleBinary,
                expectedTeamID: "ZZZZZZZZZZ",
                expectedBundleID: "com.toast.toastmonitor"
            )
        )
        XCTAssertFalse(
            UpdateManager.verifyCodesign(
                appleBinary,
                expectedTeamID: "invalid",
                expectedBundleID: "com.toast.toastmonitor"
            )
        )
    }

    /// M-1: RefreshBackoff.succeeded() must immediately lift any active wait
    /// window so re-provisioning credentials triggers a refresh right away.
    func testRefreshBackoffSucceededClearsNextAllowed() {
        var backoff = RefreshBackoff()
        backoff.failed(now: MonotonicClock.now())
        XCTAssertTrue(backoff.isWaiting)
        backoff.succeeded()
        XCTAssertFalse(backoff.isWaiting)
        XCTAssertEqual(backoff.nextAllowed, 0)
    }

    /// M-4: Zstd.decompressUncached must enforce maxBytes incrementally so
    /// oversized output cannot exhaust memory.
    func testZstdDecompressUncachedEnforcesMaxBytes() {
        let payload = Data(repeating: 0x41, count: 1024)
        // Use /bin/cat? Wait: decompressUncached passes ["-d", "-c"]; write a
        // tiny throwaway script that echoes stdin to stdout regardless of args.
        let fm = FileManager.default
        let script = fm.temporaryDirectory.appendingPathComponent("tm-zstd-cap-\(UUID().uuidString).sh")
        let body = "#!/bin/sh\nexec /bin/cat\n"
        XCTAssertNoThrow(try body.write(to: script, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path))
        defer { try? fm.removeItem(at: script) }

        let ok = Zstd.decompressUncached(payload, executable: script.path, timeout: 5, maxBytes: 2048)
        XCTAssertEqual(ok, payload)

        let capped = Zstd.decompressUncached(payload, executable: script.path, timeout: 5, maxBytes: 128)
        XCTAssertNil(capped)
    }

    /// H-5: PerfCollector.ompSample must return nil instead of trapping on
    /// non-finite or overflowing ttft / duration values.
    func testPerfCollectorOmpSampleGuardsNonFiniteAndOverflow() {
        let nanObj: [String: Any] = [
            "type": "message",
            "id": "m1",
            "message": [
                "role": "assistant",
                "timestamp": NSNumber(value: Int64(1_700_000_000_000)),
                "ttft": NSNumber(value: Double.nan),
                "duration": NSNumber(value: 100.0),
            ],
        ]
        XCTAssertNil(PerfCollector.ompSample(nanObj))

        let infObj: [String: Any] = [
            "type": "message",
            "id": "m2",
            "message": [
                "role": "assistant",
                "timestamp": NSNumber(value: Int64(1_700_000_000_000)),
                "ttft": NSNumber(value: 10.0),
                "duration": NSNumber(value: Double.infinity),
            ],
        ]
        XCTAssertNil(PerfCollector.ompSample(infObj))

        let hugeObj: [String: Any] = [
            "type": "message",
            "id": "m3",
            "message": [
                "role": "assistant",
                "timestamp": NSNumber(value: Int64.max - 10),
                "ttft": NSNumber(value: 100.0),
                "duration": NSNumber(value: 200.0),
            ],
        ]
        XCTAssertNil(PerfCollector.ompSample(hugeObj))
    }

    /// M-15: PerfCollector.parseMillis must accept both fractional and
    /// whole-second ISO-8601 timestamps.
    func testPerfCollectorParseMillisHandlesWholeSeconds() {
        XCTAssertNotNil(PerfCollector.parseMillis("2026-11-19T18:00:00.123Z"))
        XCTAssertNotNil(PerfCollector.parseMillis("2026-11-19T18:00:00Z"))
    }

    /// M-17: Format.moneyShort must handle NaN, Inf, and negative values safely.
    func testFormatMoneyShortHandlesEdgeValues() {
        XCTAssertEqual(Format.moneyShort(.nan), "$0.00")
        XCTAssertEqual(Format.moneyShort(.infinity), "$0.00")
        XCTAssertEqual(Format.moneyShort(-5.0), "-$5.00")
        XCTAssertEqual(Format.moneyShort(1500.0), "$1.5k")
    }

    /// M-18: SubscriptionMath.cycleInfo must return nil for future-dated subscriptions.
    func testSubscriptionCycleInfoReturnsNilBeforeStartDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let futureStart = Int64(now.timeIntervalSince1970) + 86_400 * 5
        XCTAssertNil(SubscriptionMath.cycleInfo(start: futureStart, cycle: "monthly", now: now))
    }

    /// M-14: BalanceRunway.dailySpend(cumulative:) must sum positive deltas
    /// across mid-series counter drops (e.g. account/key replacement).
    func testBalanceRunwayCumulativeHandlesCounterReset() {
        let samples: [(ts: Int64, value: Double)] = [
            (0, 100.0),
            (43_200, 110.0),  // +10
            (43_201, 2.0),    // key switch reset
            (86_400, 12.0),   // +10
        ]
        let daily = BalanceRunway.dailySpend(cumulative: samples)
        XCTAssertNotNil(daily)
        XCTAssertEqual(daily ?? 0, 20.0, accuracy: 0.01)
    }

    /// M-10 & M-14: Database.clearAllData() clears in-memory balance series and
    /// orCreditUsage respects beginOpenRouterCreditSeries epoch.
    func testDatabaseSeriesClearedAndEpochFiltered() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-db-\(UUID().uuidString).db").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        db.insertORSnapshot(Database.ORSnapshot(
            ts: 1_000, usage: 5, usageDaily: 5, usageWeekly: 5, usageMonthly: 5,
            limit: nil, limitRemaining: nil, limitReset: nil, isFreeTier: false,
            creditsTotal: 100, creditsUsage: 10, accountUsage: 10, accountBalance: 90,
            isManagementKey: false
        ))
        db.beginOpenRouterCreditSeries(at: 2_000)
        db.insertORSnapshot(Database.ORSnapshot(
            ts: 2_100, usage: 2, usageDaily: 2, usageWeekly: 2, usageMonthly: 2,
            limit: nil, limitRemaining: nil, limitReset: nil, isFreeTier: false,
            creditsTotal: 50, creditsUsage: 2, accountUsage: 2, accountBalance: 48,
            isManagementKey: false
        ))
        let usage = db.orCreditUsage(since: 0)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.ts, 2_100)

        db.insertDeepSeekBalance(currency: "USD", amount: 12.5, ts: 2_100)
        XCTAssertFalse(db.deepSeekBalances(currency: "USD", since: 0).isEmpty)

        XCTAssertTrue(db.clearAllData())
        XCTAssertTrue(db.orCreditUsage(since: 0).isEmpty)
        XCTAssertTrue(db.deepSeekBalances(currency: "USD", since: 0).isEmpty)
    }

    /// Low-3: OmpParser.billedOrEstimatedCost must reject JSON booleans and
    /// negative numbers as actual billed cost.
    func testOmpBilledCostRejectsBooleanAndNegative() {
        let boolUsage: [String: Any] = ["cost": ["total": NSNumber(value: true)]]
        let (_, boolQuality) = OmpParser.billedOrEstimatedCost(
            model: "unknown-model", usage: boolUsage, input: 100, output: 50, cacheRead: 0, cacheWrite: 0
        )
        XCTAssertNotEqual(boolQuality, "actual")

        let negUsage: [String: Any] = ["cost": ["total": NSNumber(value: -1.5)]]
        let (_, negQuality) = OmpParser.billedOrEstimatedCost(
            model: "unknown-model", usage: negUsage, input: 100, output: 50, cacheRead: 0, cacheWrite: 0
        )
        XCTAssertNotEqual(negQuality, "actual")
    }

    /// H-11: UsageQueryService.loadDailyAggs invalidates its cache across local
    /// calendar day rollover even when dataVersionKey is unchanged.
    func testUsageQueryServiceDailyAggsInvalidatesAcrossMidnight() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-daily-\(UUID().uuidString).db").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        var fakeNow = Date(timeIntervalSince1970: 1_700_000_000)
        let service = UsageQueryService(database: db, now: { fakeNow })

        let exp1 = expectation(description: "day1-a")
        service.loadDailyAggs(days: 7) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 5)

        let exp2 = expectation(description: "day1-b")
        service.loadDailyAggs(days: 7) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(service.cacheDiagnostics().dailyComputations, 1)

        fakeNow = fakeNow.addingTimeInterval(86_400)
        let exp3 = expectation(description: "day2")
        service.loadDailyAggs(days: 7) { _ in exp3.fulfill() }
        wait(for: [exp3], timeout: 5)
        XCTAssertEqual(service.cacheDiagnostics().dailyComputations, 2)
    }

    /// P0: A scan problem reported to StagedParserStateStore must abort commit so
    /// partial session_totals baselines cannot advance without their turns.
    func testStagedParserStateStoreRejectsCommitAfterScanProblem() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-staged-\(UUID().uuidString).db").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let result = CollectorEngine.prepareAndCommit(database: db, sourcePaths: []) { state in
            _ = state.setSessionTotals("opencode|s1", tool: "opencode",
                                       input: 100, output: 50, reasoning: 0,
                                       cacheRead: 0, cacheWrite: 0, cost: 0.1, updated: 10)
            state.noteScanProblem("SQLite BUSY mid-scan")
            return ([], [])
        }
        XCTAssertFalse(result.committed)
        XCTAssertEqual(result.problem, "SQLite BUSY mid-scan")
        XCTAssertTrue(db.sessionTotals().isEmpty)
    }

    /// P1: Routine cost backfill and recount session deletion must use their
    /// SQLite indexes instead of full-scanning `turns`.
    func testBackfillAndDeleteRecountedSessionsUseIndexes() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-plan-\(UUID().uuidString).db").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }

        func explain(_ sql: String) -> [String] {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(raw, "EXPLAIN QUERY PLAN " + sql, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            var details: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 3) {
                    details.append(String(cString: cStr))
                }
            }
            return details
        }

        let backfillPlan = explain(Database.routineBackfillSelectSQL)
        XCTAssertTrue(backfillPlan.contains { $0.contains("idx_turns_backfill") },
                      "Expected idx_turns_backfill in query plan, got: \(backfillPlan)")

        let deletePlan = explain("DELETE FROM turns WHERE tool = ? AND event_id >= ? AND event_id < ?;")
        XCTAssertTrue(deletePlan.contains { $0.contains("idx_turns_event") },
                      "Expected idx_turns_event in query plan, got: \(deletePlan)")
    }

    /// P1: CommandCodeQuotaClient must not advance lastSync or reset backoff on parse failure.
    @MainActor
    func testCommandCodeApplyFailureActivatesBackoffAndKeepsLastSyncZero() {
        let client = CommandCodeQuotaClient()
        XCTAssertEqual(client.state.lastSync, 0)
        XCTAssertFalse(client.isBackoffWaitingForTesting)

        client.applyForTesting(.failure(.parse))
        XCTAssertEqual(client.state.lastSync, 0)
        XCTAssertTrue(client.isBackoffWaitingForTesting)
        XCTAssertNotNil(client.state.error)

        let parsed = CommandCodeQuotaClient.Parsed(
            monthlyCreditsRemaining: 50,
            purchasedCredits: nil,
            planID: "individual-goat",
            subscriptionStatus: "active",
            billingPeriodEnd: nil
        )
        client.applyForTesting(.success(parsed))
        XCTAssertGreaterThan(client.state.lastSync, 0)
        XCTAssertFalse(client.isBackoffWaitingForTesting)
        XCTAssertNil(client.state.error)
    }

    /// P1: ClaudeQuotaClient must treat HTTP 403 as denied + backoff rather than
    /// marking the token rejected and looping CLI renewal.
    @MainActor
    func testClaudeQuotaHTTP403AppliesBackoffWithoutRejectingToken() {
        final class Stub403Protocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub403Protocol.self]
        let client = ClaudeQuotaClient(forTestingWithConfiguration: cfg)
        client.requestUsageForTesting(accessToken: "sk-ant-test-token")

        let deadline = Date().addingTimeInterval(3)
        while client.state.error == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(client.state.error, "Claude usage API denied (HTTP 403)")
        XCTAssertNil(client.rejectedTokenForTesting)
        XCTAssertGreaterThan(client.state.retryAt, Date().timeIntervalSince1970 + 60)
    }

    func testPricingClampsNegativesAvoidsOverflowAndStripsRouterSuffixes() throws {
        let clamped = try XCTUnwrap(Pricing.estimate(
            model: "claude-sonnet-4-5",
            input: -500, output: -10, cacheRead: -20, cacheWrite: -30, cacheWrite1h: -40
        ))
        XCTAssertEqual(clamped, 0, accuracy: 0.00001)

        // Large aggregate token counts with explicit longPrompt must not trap Int64 addition.
        let huge = try XCTUnwrap(Pricing.estimate(
            model: "claude-sonnet-4-5",
            input: Int64.max / 2, output: 0, cacheRead: Int64.max / 2,
            cacheWrite: 1_000_000, cacheWrite1h: 1_000_000, longPrompt: false
        ))
        XCTAssertGreaterThan(huge, 0)

        XCTAssertEqual(
            try XCTUnwrap(Pricing.estimate(model: "claude-sonnet-4-5:thinking", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)),
            3.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(Pricing.estimate(model: "claude-sonnet-4-5[1m]", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)),
            3.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(Pricing.estimate(model: "anthropic.claude-sonnet-4-5-20250929-v1:0", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)),
            3.0, accuracy: 0.0001
        )
    }

    func testEventIdentityCanonicalJSONHandlesTopLevelScalars() {
        XCTAssertEqual(EventIdentity.canonicalJSON("hello"), "str:hello")
        XCTAssertNotEqual(EventIdentity.canonicalJSON("a"), EventIdentity.canonicalJSON("b"))
        XCTAssertEqual(EventIdentity.canonicalJSON(NSNumber(value: true)), "bool:true")
        XCTAssertEqual(EventIdentity.canonicalJSON(NSNumber(value: false)), "bool:false")
        XCTAssertEqual(EventIdentity.canonicalJSON(NSNumber(value: 42)), "num:42")
    }

    func testBalanceRunwayAndOrCreditUsagePreserveCounterResetsAndFilterInfinity() {
        let balSamples: [(ts: Int64, value: Double)] = [
            (0, .infinity),
            (43_200, 100),
            (86_400, 90),
        ]
        let balDaily = BalanceRunway.dailySpend(balances: balSamples)
        XCTAssertEqual(balDaily ?? -1, 10, accuracy: 0.01)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-orseries-\(UUID().uuidString).db").path
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        func snap(_ ts: Int64, _ usage: Double) -> Database.ORSnapshot {
            Database.ORSnapshot(
                ts: ts, usage: usage, usageDaily: 0, usageWeekly: 0, usageMonthly: 0,
                limit: nil, limitRemaining: nil, limitReset: nil, isFreeTier: false,
                creditsTotal: 100, creditsUsage: usage, accountUsage: usage, accountBalance: 100 - usage,
                isManagementKey: false
            )
        }
        let baseTs = Int64(Date().timeIntervalSince1970) - 86_400
        db.insertORSnapshot(snap(baseTs, 100))
        db.insertORSnapshot(snap(baseTs + 43_200, 110))
        db.insertORSnapshot(snap(baseTs + 43_201, 2))
        db.insertORSnapshot(snap(baseTs + 86_400, 12))
        let series = db.orCreditUsage(since: 0)
        XCTAssertEqual(series.count, 4)
        XCTAssertEqual(BalanceRunway.dailySpend(cumulative: series) ?? -1, 20, accuracy: 0.01)
    }

    func testPerfStatsPercentileIgnoresNonFiniteAndModelProviderMapsO3O4() {
        XCTAssertEqual(PerfStats.percentile([10, .nan, 30, .infinity, 20], p: 0.5), 20)
        XCTAssertNil(PerfStats.percentile([.nan, .infinity], p: 0.5))

        XCTAssertEqual(ModelProvider.name(for: "o3"), "OpenAI")
        XCTAssertEqual(ModelProvider.name(for: "o3-mini"), "OpenAI")
        XCTAssertEqual(ModelProvider.name(for: "o4"), "OpenAI")
        XCTAssertEqual(ModelProvider.name(for: "o4-mini"), "OpenAI")
    }

    func testSQLiteReadOnlyRefusesImmutableFallbackWhenNonEmptyWALExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-audit-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("live.db").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA journal_mode=WAL; CREATE TABLE t(x INT); INSERT INTO t VALUES(1);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        // Simulate missing -shm with non-empty -wal (e.g. uncheckpointed live WAL).
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        try Data("uncheckpointed-wal-bytes".utf8).write(to: URL(fileURLWithPath: dbPath + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        if let opened = SQLiteReadOnly.open(dbPath) {
            sqlite3_close(opened)
            XCTFail("SQLiteReadOnly.open must not fall back to immutable=1 when non-empty -wal exists")
        }
    }
}
