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
        XCTAssertEqual(remote.displayName, "远程 Feed")
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
        XCTAssertNil(PanelController.mergedHeight(
            header: 48, pinned: 0, body: 620, footer: 46,
            allowsZeroPinned: false))
        XCTAssertNil(PanelController.mergedHeight(
            header: 0, pinned: 48, body: 620, footer: 46,
            allowsZeroPinned: false))
        XCTAssertEqual(PanelController.mergedHeight(
            header: 48, pinned: 48, body: 620, footer: 46,
            allowsZeroPinned: false), 762)
    }

    func testPopoverSettingsHeightAllowsNoPinnedSelector() {
        XCTAssertEqual(PanelController.mergedHeight(
            header: 48, pinned: 0, body: 260, footer: 42,
            allowsZeroPinned: true), 350)
    }

    func testPopoverShortPageKeepsItsNaturalHeight() {
        XCTAssertEqual(PanelController.clampedHeight(
            natural: 146, available: 900), 146)
    }

    func testPopoverLongPageClampsToVisibleScreen() {
        XCTAssertEqual(PanelController.clampedHeight(
            natural: 1_200, available: 860), 860)
    }
}
