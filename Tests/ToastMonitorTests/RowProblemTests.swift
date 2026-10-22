import XCTest
@testable import ToastMonitor

final class RowProblemTests: XCTestCase {
    func testOfflineIsExplainedAsConnectionNotRawError() {
        let p = RowProblem.from(service: "X Subscription Premium", error: "The Internet connection appears to be offline.")
        XCTAssertEqual(p.title, "X Subscription Premium can’t connect")
        XCTAssertFalse(p.detail.contains("Internet connection appears"))
        XCTAssertFalse(p.opensSettings)
    }

    func testClaudeExpiredPointsToTerminal() {
        let p = RowProblem.from(service: "Claude Pro", error: "Login expired — run claude in Terminal")
        XCTAssertEqual(p.title, "Claude login expired")
        XCTAssertTrue(p.detail.contains("run claude"))
        XCTAssertFalse(p.opensSettings)
    }

    func testRejectedLoginOffersSettings() {
        let p = RowProblem.from(service: "OpenCode Go", error: "HTTP 401")
        XCTAssertTrue(p.opensSettings)
    }

    func testUnknownErrorKeepsItsText() {
        let p = RowProblem.from(service: "Codex", error: "Unexpected response shape")
        XCTAssertEqual(p.title, "Codex couldn’t refresh")
        XCTAssertTrue(p.detail.hasPrefix("Unexpected response shape"))
    }
}
