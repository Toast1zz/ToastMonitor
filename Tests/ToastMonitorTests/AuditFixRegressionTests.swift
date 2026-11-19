import XCTest
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
        backoff.failed(now: ProcessInfo.processInfo.systemUptime)
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
}
