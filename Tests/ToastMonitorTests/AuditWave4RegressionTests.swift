import XCTest
import AppKit
@testable import ToastMonitor

final class AuditWave4RegressionTests: XCTestCase {
    private var dbPath = ""
    private var db: Database!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-wave4-\(UUID().uuidString).sqlite").path
        db = Database.testInstance(path: dbPath)
    }

    override func tearDown() {
        db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    // MARK: - P1-6: Popover 60-day trend curve fills idle gaps with 0

    func testBuildTrendSeriesPadsIdleDaysWithZeroAndReturnsEmptyWhenInactive() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))!

        XCTAssertTrue(PopoverHomeView.buildTrendSeries(heatmap: [:], now: now, calendar: cal).isEmpty)

        // Only two active days inside a 60-day window (today + 10 days earlier).
        let active: [Int64: Int64] = [20260805: 4200, 20260815: 900]
        let series = PopoverHomeView.buildTrendSeries(heatmap: active, now: now, calendar: cal)
        XCTAssertEqual(series.count, 60)
        XCTAssertEqual(series.first?.key, 20260617)
        XCTAssertEqual(series.last?.key, 20260815)
        XCTAssertEqual(series.first(where: { $0.key == 20260805 })?.tokens, 4200)
        XCTAssertEqual(series.first(where: { $0.key == 20260806 })?.tokens, 0)
        XCTAssertEqual(series.last?.tokens, 900)
    }

    // MARK: - P1-16: AppState dataRevision increments on Database reset

    @MainActor
    func testAppStateDataRevisionIncrementsOnDatabaseResetNotification() {
        let app = AppState.shared
        let initial = app.dataRevision
        let exp = expectation(description: "dataRevision advances after Database.didResetState")
        NotificationCenter.default.post(name: Database.didResetState, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if app.dataRevision > initial {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - P1-17: Expired Codex subscription ignored & newest active selected

    func testActiveCodexSubscriptionSkipsEndedRowsAndPicksNewestActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowSec = Int64(now.timeIntervalSince1970)
        let ended = Database.Subscription(
            id: 1, name: "Old Codex Pro", plan: "openai",
            startDate: nowSec - 60 * 86_400, endDate: nowSec - 1,
            cycle: "monthly", price: 200, currency: "USD"
        )
        let activeOlder = Database.Subscription(
            id: 2, name: "Codex Plus Old", plan: "openai",
            startDate: nowSec - 30 * 86_400, endDate: 0,
            cycle: "monthly", price: 20, currency: "USD"
        )
        let activeNewer = Database.Subscription(
            id: 3, name: "Codex Pro New", plan: "openai",
            startDate: nowSec - 2 * 86_400, endDate: 0,
            cycle: "monthly", price: 200, currency: "USD"
        )

        XCTAssertNil(SubscriptionMath.activeCodexSubscription(in: [ended], now: now))
        let picked = SubscriptionMath.activeCodexSubscription(in: [ended, activeOlder, activeNewer], now: now)
        XCTAssertEqual(picked?.id, 3)
        XCTAssertEqual(picked.flatMap(CodexPlanName.tier(subscription:)), "Pro")
    }

    // MARK: - P1-18 & P3-8: Format unknown dates and money rounding boundaries

    func testFormatUnknownTimestampAndMoneyRoundingBoundaries() {
        XCTAssertEqual(Format.dateTime(0), "—")
        XCTAssertEqual(Format.dateTime(-5), "—")
        XCTAssertEqual(Format.day(0), "—")

        XCTAssertEqual(Format.money(99.995), "$100")
        XCTAssertEqual(Format.money(0.9995), "$1.00")
        XCTAssertEqual(Format.money(0.00995), "$0.010")
        XCTAssertEqual(Format.moneyShort(999.995), "$1.0k")
        XCTAssertEqual(Format.moneyShort(0.0096), "$0.01")
    }

    // MARK: - P2-4 & P2-5: Raw-provider brand color lookup & unified non-ToolKind tokens

    func testModelColorsUsesRawProviderBeforeStrippingPrefix() {
        let colors = TMDesign.modelColors(
            for: ["my-custom-a", "my-custom-b"],
            providersByDisplayName: [
                "my-custom-a": ModelProvider.name(for: "anthropic/my-custom-a"),
                "my-custom-b": ModelProvider.name(for: "openai/my-custom-b"),
            ]
        )
        XCTAssertEqual(colors["my-custom-a"], TMDesign.providerColor(for: "Anthropic"))
        XCTAssertEqual(colors["my-custom-b"], TMDesign.providerColor(for: "OpenAI"))

        XCTAssertEqual(
            ToolKind.totalTokens(tool: ClaudeNonLocalEstimator.estimateToolLabel,
                                 input: 100, output: 50, cacheRead: 999),
            150
        )
        XCTAssertEqual(
            ToolKind.totalTokens(tool: ToolKind.claude.rawValue,
                                 input: 100, output: 50, cacheRead: 25),
            175
        )
        XCTAssertEqual(
            ToolKind.totalTokens(tool: ToolKind.codex.rawValue,
                                 input: 100, output: 50, cacheRead: 25),
            150
        )
    }

    // MARK: - P2-16: SQL session sort and search work beyond top-500 recency window

    func testDatabaseSessionsSortAndSearchBeyondLatest500() {
        let baseTs: Int64 = 1_780_000_000
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        // Oldest session (#0) has the highest token count and cost and a distinctive search term.
        turns.append(TurnRecord(
            tool: .claude,
            sessionID: "old-needle-session",
            project: "NeedleProject",
            model: "claude-opus-4-6",
            ts: baseTs,
            inputTokens: 500_000,
            outputTokens: 100_000,
            cacheRead: 0,
            cacheWrite: 0,
            cost: 120.0,
            eventID: "wave4-old-needle"
        ))
        sessions.append(SessionInfo(
            tool: .claude,
            sessionID: "old-needle-session",
            title: "Needle Session",
            project: "NeedleProject",
            model: "claude-opus-4-6",
            created: baseTs,
            updated: baseTs
        ))
        // Insert 510 newer low-token sessions so "old-needle-session" falls outside latest 500.
        for i in 1...510 {
            let ts = baseTs + Int64(i * 10)
            turns.append(TurnRecord(
                tool: .claude,
                sessionID: "recent-\(i)",
                project: "Proj",
                model: "claude-sonnet-4-5",
                ts: ts,
                inputTokens: 10,
                outputTokens: 5,
                cacheRead: 0,
                cacheWrite: 0,
                cost: 0.001,
                eventID: "wave4-recent-\(i)"
            ))
            sessions.append(SessionInfo(
                tool: .claude,
                sessionID: "recent-\(i)",
                title: "Recent \(i)",
                project: "Proj",
                model: "claude-sonnet-4-5",
                created: ts,
                updated: ts
            ))
        }
        // Hermes unpriced session should mark hasKnownCost == false.
        turns.append(TurnRecord(
            tool: .hermes,
            sessionID: "hermes-unknown-cost",
            project: "H",
            model: "hermes-3",
            ts: baseTs + 5,
            inputTokens: 100,
            outputTokens: 50,
            cacheRead: 0,
            cacheWrite: 0,
            cost: 0,
            eventID: "wave4-hermes-unknown",
            costQuality: "unknown"
        ))
        sessions.append(SessionInfo(
            tool: .hermes,
            sessionID: "hermes-unknown-cost",
            title: "Hermes Session",
            project: "H",
            model: "hermes-3",
            created: baseTs + 5,
            updated: baseTs + 5
        ))
        XCTAssertTrue(db.insertTurns(turns))
        XCTAssertTrue(db.upsertSessions(sessions))

        let hermesRows = db.sessions(tool: .hermes, search: "", sort: .newest, limit: 10)
        XCTAssertEqual(hermesRows.first?.hasKnownCost, false)

        let newest500 = db.sessions(tool: nil, search: "", sort: .newest, limit: 500)
        XCTAssertFalse(newest500.contains { $0.sessionID == "old-needle-session" })

        let byTokens = db.sessions(tool: nil, search: "", sort: .tokens, limit: 5)
        XCTAssertEqual(byTokens.first?.sessionID, "old-needle-session")

        let byCost = db.sessions(tool: nil, search: "", sort: .cost, limit: 5)
        XCTAssertEqual(byCost.first?.sessionID, "old-needle-session")

        let searched = db.sessions(tool: nil, search: "NeedleProject", sort: .newest, limit: 500)
        XCTAssertEqual(searched.map(\.sessionID), ["old-needle-session"])
        XCTAssertEqual(db.sessionCount(tool: nil, search: "NeedleProject"), 1)
    }

    // MARK: - P3-7: ShareBar excludes 0-token items and stays bounded within availableWidth

    func testShareBarSegmentWidthsExcludeZerosAndStayWithinBounds() {
        XCTAssertEqual(ShareBar.segmentWidths(values: [0, 100], availableWidth: 200).count, 1)
        let widths = ShareBar.segmentWidths(values: [1_000_000, 1, 1, 1, 1], availableWidth: 100, gap: 2)
        XCTAssertEqual(widths.count, 5)
        let gapsTotal = CGFloat(widths.count - 1) * 2
        XCTAssertLessThanOrEqual(widths.reduce(0, +) + gapsTotal, 100.001)
    }

    // MARK: - P3-8: RefreshCoordinator watchdog clears pending rerun flags

    func testRefreshCoordinatorWatchdogClearsPendingRerunFlags() {
        var coord = RefreshCoordinator()
        let r1 = coord.request(manual: false, now: 100, watchdogSeconds: 10)
        XCTAssertNotNil(r1)
        // Coalesced requests mark pendingManual / pendingRefresh while in-flight.
        XCTAssertNil(coord.request(manual: true, now: 105, watchdogSeconds: 10))
        // Past watchdog triggers restart and clears stale pending flags.
        let r2 = coord.request(manual: false, now: 120, watchdogSeconds: 10)
        XCTAssertEqual(r2?.restartedByWatchdog, true)
        let rerun = coord.finish(generation: r2!.generation)
        XCTAssertEqual(rerun, RefreshCoordinator.Rerun(manual: false, requested: false))
    }

    // MARK: - P3-9: MenuBarTextFont distinguishes non-default system size & keeps display name

    func testMenuBarTextFontSystemSizeTriggersResetWithoutBlankDisplayName() {
        let resized = MenuBarTextFont(name: "", family: "", size: 15)
        XCTAssertTrue(resized.isSystemDefault)
        XCTAssertFalse(resized.isSystemDefaultSelection)
        XCTAssertTrue(resized.displayName.contains("System UI"))
        XCTAssertTrue(MenuBarTextFont.systemDefault.isSystemDefaultSelection)
    }
}
