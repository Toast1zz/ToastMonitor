import XCTest
import SQLite3
@testable import ToastMonitor

@MainActor
final class UsageQueryServiceTests: XCTestCase {
    private var database: Database!
    private var databasePath = ""
    private var service: UsageQueryService!

    override func setUp() {
        super.setUp()
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastmonitor-query-tests-\(UUID().uuidString).sqlite").path
        database = Database.testInstance(path: databasePath)
        service = UsageQueryService(database: database,
                                    queue: DispatchQueue(label: "toastmonitor.queries.tests"))
    }

    override func tearDown() {
        database?.close()
        try? FileManager.default.removeItem(atPath: databasePath)
        try? FileManager.default.removeItem(atPath: databasePath + "-wal")
        try? FileManager.default.removeItem(atPath: databasePath + "-shm")
        service = nil
        database = nil
        super.tearDown()
    }

    func testLightCacheInvalidatesForDataVersionAndPeriodConfiguration() async {
        let recent = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let first = await loadLight(recent)
        let second = await loadLight(recent)
        XCTAssertEqual(first.allTokens, second.allTokens)
        XCTAssertEqual(service.cacheDiagnostics().lightComputations, 1,
                       "identical cache keys should reuse the light snapshot")

        XCTAssertTrue(database.insertTurns([makeTurn(eventID: "query-cache-v1", input: 100)]))
        let afterInsert = await loadLight(recent)
        XCTAssertGreaterThan(afterInsert.allTokens, first.allTokens)
        XCTAssertEqual(service.cacheDiagnostics().lightComputations, 2,
                       "a committed data-version change must invalidate the cache")

        let calendar = UsagePeriodConfiguration(mode: .calendar, weekStart: .sunday)
        _ = await loadLight(calendar)
        XCTAssertEqual(service.cacheDiagnostics().lightComputations, 3,
                       "period mode and week start are part of the cache key")
    }
    func testBillingModeCacheInvalidationChangesVisibleCodexCost() async {
        let now = Int64(Date().timeIntervalSince1970)
        let turn = TurnRecord(tool: .codex, sessionID: "billing-cache", project: nil,
                              model: "gpt-5.6-sol", ts: now, inputTokens: 1_000,
                              outputTokens: 500, cacheRead: 0, cacheWrite: 0, cost: 12.5)
        XCTAssertTrue(database.insertTurns([turn]))
        let configuration = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let api = await loadLight(configuration)
        XCTAssertGreaterThan(api.costAll.estimated, 0)

        XCTAssertTrue(database.setSetting("codex_billing_mode", "subscription"))
        await invalidateBillingCaches()
        let subscription = await loadLight(configuration)
        XCTAssertEqual(subscription.costAll.estimated, 0, accuracy: 0.001)
        XCTAssertEqual(subscription.allTokens, api.allTokens)
    }
    func testRapidBillingToggleSuccessThenFailureReconcilesPersistedModeAndSnapshot() async {
        XCTAssertTrue(database.setSetting("codex_billing_mode", "api"))
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .codex, sessionID: "billing-rapid", project: nil,
                                                        model: "gpt-5.6-sol", ts: now, inputTokens: 1_000,
                                                        outputTokens: 500, cacheRead: 0, cacheWrite: 0, cost: 12.5)]))
        let configuration = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let initialAPI = await loadLight(configuration)
        XCTAssertGreaterThan(initialAPI.costAll.estimated, 0)

        let persistenceQueue = DispatchQueue(label: "billing-rapid-test.persistence")
        let releaseWrites = DispatchSemaphore(value: 0)
        let queueReady = DispatchSemaphore(value: 0)
        persistenceQueue.async {
            queueReady.signal()
            releaseWrites.wait()
        }
        XCTAssertEqual(queueReady.wait(timeout: .now() + 2), .success)
        let refreshes = expectation(description: "successful persisted mode refresh")
        let coordinator = CodexBillingModeCoordinator(database: database, queries: service,
                                                       queue: persistenceQueue,
                                                       onCommitted: { refreshes.fulfill() })
        var selectedMode = "api"
        let writes = expectation(description: "both write callbacks complete")
        writes.expectedFulfillmentCount = 2
        coordinator.set("subscription", restoreSelection: { selectedMode = $0 }, completion: { writes.fulfill() })
        // While A is pending, the user selects B=api. It equals the currently
        // persisted setting, but must still enqueue because A may commit first.
        selectedMode = "api"
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &raw), SQLITE_OK)
        defer { if let raw { sqlite3_close(raw) } }
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER fail_billing_update BEFORE UPDATE ON settings WHEN OLD.k='codex_billing_mode' AND NEW.v='api' BEGIN SELECT RAISE(ABORT, 'forced update failure'); END;", nil, nil, nil), SQLITE_OK)
        let bWasQueued = coordinator.set("api", restoreSelection: { selectedMode = $0 }, completion: { writes.fulfill() })
        XCTAssertTrue(bWasQueued, "a changed UI selection must enqueue while a prior write is pending even when it matches persisted mode")

        releaseWrites.signal()
        await fulfillment(of: [writes, refreshes], timeout: 5)
        XCTAssertEqual(database.setting("codex_billing_mode"), "subscription")
        XCTAssertEqual(selectedMode, "subscription", "latest failed toggle restores the committed selection")
        let final = await loadLight(configuration)
        XCTAssertEqual(final.costAll.estimated, 0, accuracy: 0.001,
                       "stale success must invalidate the cached API cost after the later write fails")
        XCTAssertEqual(final.allTokens, initialAPI.allTokens)
    }
    func testRapidBillingToggleSuccessThenSuccessReturnsToAPI() async {
        XCTAssertTrue(database.setSetting("codex_billing_mode", "api"))
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .codex, sessionID: "billing-rapid-success", project: nil,
                                                        model: "gpt-5.6-sol", ts: now, inputTokens: 1_000,
                                                        outputTokens: 500, cacheRead: 0, cacheWrite: 0, cost: 12.5)]))
        let configuration = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let initial = await loadLight(configuration)
        XCTAssertGreaterThan(initial.costAll.estimated, 0)

        let queue = DispatchQueue(label: "billing-rapid-success.persistence")
        let release = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        queue.async { ready.signal(); release.wait() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        let coordinator = CodexBillingModeCoordinator(database: database, queries: service,
                                                       queue: queue, onCommitted: {})
        let completions = expectation(description: "both writes commit and invalidate")
        completions.expectedFulfillmentCount = 2
        var selectedMode = "api"
        XCTAssertTrue(coordinator.set("subscription", restoreSelection: { selectedMode = $0 }, completion: { completions.fulfill() }))
        selectedMode = "api"
        XCTAssertTrue(coordinator.set("api", restoreSelection: { selectedMode = $0 }, completion: { completions.fulfill() }),
                      "API selection matching the old persisted value must queue behind pending subscription write")
        release.signal()
        await fulfillment(of: [completions], timeout: 5)

        XCTAssertEqual(database.setting("codex_billing_mode"), "api")
        XCTAssertEqual(selectedMode, "api")
        let final = await loadLight(configuration)
        XCTAssertEqual(final.costAll.estimated, initial.costAll.estimated, accuracy: 0.001,
                       "both successful commits must leave the recomputed snapshot in API mode")
    }



    private func invalidateBillingCaches() async {
        await withCheckedContinuation { continuation in
            service.invalidateBillingModeCaches { continuation.resume() }
        }
    }


    func testFailedBillingModeWriteKeepsCachedCostUnchanged() async {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(database.insertTurns([TurnRecord(tool: .codex, sessionID: "billing-failed", project: nil,
                                                        model: "gpt-5.6-sol", ts: now, inputTokens: 1_000,
                                                        outputTokens: 500, cacheRead: 0, cacheWrite: 0, cost: 12.5)]))
        let configuration = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let before = await loadLight(configuration)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &raw), SQLITE_OK)
        defer { if let raw { sqlite3_close(raw) } }
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER fail_billing_setting BEFORE INSERT ON settings WHEN NEW.k='codex_billing_mode' BEGIN SELECT RAISE(ABORT, 'forced setting failure'); END;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(database.setSetting("codex_billing_mode", "subscription"))
        let after = await loadLight(configuration)
        XCTAssertEqual(after.costAll.estimated, before.costAll.estimated, accuracy: 0.001)
        XCTAssertEqual(database.setting("codex_billing_mode"), nil)
    }

    func testFullAndDailyCachesHaveIndependentInvalidationKeys() async {
        let configuration = UsagePeriodConfiguration()
        _ = await loadSnapshot(configuration)
        _ = await loadSnapshot(configuration)
        var diagnostics = service.cacheDiagnostics()
        XCTAssertEqual(diagnostics.fullComputations, 1)

        _ = await loadDaily(days: 30)
        _ = await loadDaily(days: 30)
        _ = await loadDaily(days: 31)
        diagnostics = service.cacheDiagnostics()
        XCTAssertEqual(diagnostics.dailyComputations, 2,
                       "daily cache keys must distinguish requested day counts")

        XCTAssertTrue(database.insertTurns([makeTurn(eventID: "query-cache-v2", input: 200)]))
        _ = await loadSnapshot(configuration)
        _ = await loadDaily(days: 31)
        diagnostics = service.cacheDiagnostics()
        XCTAssertEqual(diagnostics.fullComputations, 2)
        XCTAssertEqual(diagnostics.dailyComputations, 3)
    }

    private func makeTurn(eventID: String, input: Int64) -> TurnRecord {
        TurnRecord(tool: .claude, sessionID: "query-cache", project: nil,
                   model: "claude-sonnet-4-5",
                   ts: Int64(Date().timeIntervalSince1970),
                   inputTokens: input, outputTokens: 10,
                   cacheRead: 5, cacheWrite: 0, cost: 0,
                   eventID: eventID)
    }

    private func loadLight(_ configuration: UsagePeriodConfiguration) async -> UsageQueryService.LightSnapshot {
        await withCheckedContinuation { continuation in
            service.loadLightSnapshot(configuration: configuration) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func loadSnapshot(_ configuration: UsagePeriodConfiguration) async -> UsageQueryService.Snapshot {
        await withCheckedContinuation { continuation in
            service.loadSnapshot(configuration: configuration) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func loadDaily(days: Int) async -> [Database.DayAgg] {
        await withCheckedContinuation { continuation in
            service.loadDailyAggs(days: days) {
                continuation.resume(returning: $0)
            }
        }
    }
}
