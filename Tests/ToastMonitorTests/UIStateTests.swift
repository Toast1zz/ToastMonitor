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
        XCTAssertTrue(failed.text.contains("异常"))
        let stale = TMHealthStatus(brokenCount: 0, staleCount: 1, lastScan: 1)
        XCTAssertTrue(stale.text.contains("过期"))
        let synced = TMHealthStatus(brokenCount: 0, staleCount: 0, lastScan: 1)
        XCTAssertEqual(synced.text, "已同步")
        let waiting = TMHealthStatus(brokenCount: 0, staleCount: 0, lastScan: 0)
        XCTAssertTrue(waiting.text.contains("首次扫描"))
    }
}
