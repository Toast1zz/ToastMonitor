import XCTest
@testable import ToastMonitor

@MainActor
final class UIStateTests: XCTestCase {
    func testSourceHealthIdleClearsPreviousError() {
        let uniqueTool = "ui-state-\(UUID().uuidString)"
        SourceHealthHub.shared.record(tool: uniqueTool, rows: 1, failed: 1,
                                      durationMs: 3, error: "temporary")
        XCTAssertEqual(SourceHealthHub.shared.sources.first(where: { $0.tool == uniqueTool })?.error, "temporary")
        SourceHealthHub.shared.recordIdle(tool: uniqueTool, durationMs: 1)
        let state = SourceHealthHub.shared.sources.first(where: { $0.tool == uniqueTool })
        XCTAssertNil(state?.error)
        XCTAssertEqual(state?.lastRows, 0)
        XCTAssertEqual(state?.failedRows, 0)
    }

    func testSourceHealthDisplayNameIdentifiesRemoteFeed() {
        let remote = SourceHealth(tool: "remote-feed", mode: "remote")
        XCTAssertEqual(remote.displayName, "Remote Feed")
        let omp = SourceHealth(tool: ToolKind.omp.rawValue, mode: "local")
        XCTAssertEqual(omp.displayName, ToolKind.omp.displayName)
    }

    func testHealthStatusPrecedenceIsStable() {
        let failed = TMHealthStatus(brokenCount: 1, staleCount: 5, lastScan: 1)
        XCTAssertEqual(failed.text, "1 source error")
        let stale = TMHealthStatus(brokenCount: 0, staleCount: 1, lastScan: 1)
        XCTAssertEqual(stale.text, "1 source stale")
        let synced = TMHealthStatus(brokenCount: 0, staleCount: 0, lastScan: 1)
        XCTAssertEqual(synced.text, "Synced")
        let waiting = TMHealthStatus(brokenCount: 0, staleCount: 0, lastScan: 0)
        XCTAssertEqual(waiting.text, "Idle")
    }

    func testOnlyCollectorsWithRemoteImplementationsExposeRemoteSource() {
        XCTAssertFalse(ToolKind.omp.supportsRemoteSource)
        XCTAssertFalse(ToolKind.openrouter.supportsRemoteSource)
        XCTAssertTrue(ToolKind.claude.supportsRemoteSource)
        XCTAssertTrue(ToolKind.codex.supportsRemoteSource)
        XCTAssertTrue(ToolKind.opencode.supportsRemoteSource)
        XCTAssertTrue(ToolKind.hermes.supportsRemoteSource)
    }

    func testPopoverHeightWaitsForEveryMeasuredSlice() {
        XCTAssertNil(PopoverHeightMeasurements(values: [
            .header: 48, .body: 620, .footer: 46,
        ]).naturalHeight(for: .home))
        XCTAssertNil(PopoverHeightMeasurements(values: [
            .pinned: 48, .body: 620, .footer: 46,
        ]).naturalHeight(for: .home))
        XCTAssertEqual(PopoverHeightMeasurements(values: [
            .header: 48, .pinned: 48, .body: 620, .footer: 46,
        ]).naturalHeight(for: .home), 762)
    }

    func testPopoverSettingsHeightAllowsNoPinnedSelector() {
        XCTAssertEqual(PopoverHeightMeasurements(values: [
            .header: 48, .body: 260, .footer: 42,
        ]).naturalHeight(for: .settings), 350)
    }

    func testPopoverShortPageKeepsItsNaturalHeight() {
        XCTAssertEqual(PanelController.clampedHeight(
            natural: 146, available: 900), 146)
    }

    func testPopoverLongPageClampsToVisibleScreen() {
        XCTAssertEqual(PanelController.clampedHeight(
            natural: 1_200, available: 860), 860)
    }

    // MARK: - UI-1: minute ticker + heatmap reload gated on panel visibility

    func testMinuteTickSkippedWhilePanelHidden() {
        XCTAssertFalse(PopoverHomeView.minuteTickAllowed(panelVisible: false))
        XCTAssertTrue(PopoverHomeView.minuteTickAllowed(panelVisible: true))
    }

    func testBackgroundRefreshCadenceIsSlowerButNeverDisabled() {
        XCTAssertEqual(TMRefreshPolicy.snapshotInterval(foreground: true), 5)
        XCTAssertEqual(TMRefreshPolicy.snapshotInterval(foreground: false), 30)
        XCTAssertEqual(TMRefreshPolicy.quotaInterval(foreground: true), 60)
        XCTAssertEqual(TMRefreshPolicy.quotaInterval(foreground: false), 300)
        XCTAssertGreaterThan(TMRefreshPolicy.backgroundSnapshotInterval,
                             TMRefreshPolicy.foregroundSnapshotInterval)
        XCTAssertGreaterThan(TMRefreshPolicy.backgroundQuotaInterval,
                             TMRefreshPolicy.foregroundQuotaInterval)
    }

    func testHeatmapReloadsOnlyOnHiddenToVisibleTransition() {
        // 隐藏 → 隐藏：不重载
        let (v1, r1) = PopoverHomeView.visibilityTransition(visible: false, wasVisible: false)
        XCTAssertEqual(v1, false)
        XCTAssertFalse(r1)
        // 隐藏 → 显示（关键转换）：必须重载
        let (v2, r2) = PopoverHomeView.visibilityTransition(visible: true, wasVisible: false)
        XCTAssertEqual(v2, true)
        XCTAssertTrue(r2)
        // 保持显示：不重复重载
        let (v3, r3) = PopoverHomeView.visibilityTransition(visible: true, wasVisible: true)
        XCTAssertEqual(v3, true)
        XCTAssertFalse(r3)
        // 显示 → 隐藏：不重载
        let (v4, r4) = PopoverHomeView.visibilityTransition(visible: false, wasVisible: true)
        XCTAssertEqual(v4, false)
        XCTAssertFalse(r4)
    }

    // MARK: - UI-10: AppState snapshot accessors are read-only getters

    /// UI-10 removed the dead per-property setters; every accessor must still
    /// read through to the backing snapshot. Touching each property here also
    /// fails the build if a getter is ever deleted or renamed. The only
    /// value-level assertion is on `tool == "all"`, which holds both for the
    /// zero-initialized state and after any refresh (totals always key "all").
    func testAppStateSnapshotGettersRemainExposed() {
        let app = AppState.shared
        XCTAssertEqual(app.today.tool, "all")
        XCTAssertEqual(app.week.tool, "all")
        XCTAssertEqual(app.month.tool, "all")
        XCTAssertEqual(app.all.tool, "all")
        _ = app.todayTokens
        _ = app.weekTokens
        _ = app.monthTokens
        _ = app.allTokens
        _ = app.byToolToday
        _ = app.byToolWeek
        _ = app.byToolMonth
        _ = app.byToolAll
        _ = app.apiValueToday
        _ = app.apiValueWeek
        _ = app.apiValueMonth
        _ = app.apiValueAll
        _ = app.costToday
        _ = app.costWeek
        _ = app.costMonth
        _ = app.costAll
        _ = app.modelAggs
        _ = app.modelAggsToday
        _ = app.modelAggsMonth
        _ = app.modelAggsAll
        _ = app.heatmap
        _ = app.heatmapCost
        _ = app.subscriptions
        _ = app.lastScan
        _ = app.snapshotFetchedAt
    }

    func testRefreshCoordinatorCoalescesPendingManualRequest() {
        var coordinator = RefreshCoordinator()
        let first = coordinator.request(manual: false, now: 100, watchdogSeconds: 10)
        XCTAssertEqual(first?.generation, 1)
        XCTAssertNil(coordinator.request(manual: true, now: 105, watchdogSeconds: 10))

        let rerun = coordinator.finish(generation: 1)
        XCTAssertEqual(rerun, .init(manual: true, requested: true))
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testRefreshCoordinatorWatchdogRejectsStaleCompletion() {
        var coordinator = RefreshCoordinator()
        let first = coordinator.request(manual: true, now: 100, watchdogSeconds: 10)!
        let replacement = coordinator.request(manual: false, now: 111, watchdogSeconds: 10)!

        XCTAssertTrue(replacement.restartedByWatchdog)
        XCTAssertEqual(replacement.generation, first.generation + 1)
        XCTAssertNil(coordinator.finish(generation: first.generation),
                     "a stale completion must not clear the replacement request")
        XCTAssertTrue(coordinator.isInFlight)
        XCTAssertNotNil(coordinator.finish(generation: replacement.generation))
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testRefreshCoordinatorUsesStrictWatchdogBoundary() {
        var coordinator = RefreshCoordinator()
        _ = coordinator.request(manual: false, now: 100, watchdogSeconds: 10)
        XCTAssertNil(coordinator.request(manual: false, now: 110, watchdogSeconds: 10),
                     "exactly at the threshold the active request is still valid")
        XCTAssertTrue(coordinator.request(manual: false, now: 110.001,
                                          watchdogSeconds: 10)?.restartedByWatchdog == true)
    }
}
