import XCTest
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
