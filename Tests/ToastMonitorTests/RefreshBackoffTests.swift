import XCTest
@testable import ToastMonitor

final class RefreshBackoffTests: XCTestCase {
    func testDelaysDoubleFromOneMinuteAndCapAtFifteen() {
        var backoff = RefreshBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.failed(now: 1_000)
            delays.append(backoff.nextAllowed - 1_000)
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 900, 900])
    }

    func testSuccessRestartsTheSchedule() {
        var backoff = RefreshBackoff()
        backoff.failed(now: 0)
        backoff.failed(now: 0)
        backoff.succeeded()
        backoff.failed(now: 5_000)
        XCTAssertEqual(backoff.nextAllowed, 5_060)
    }

    func testFreshBackoffDoesNotWait() {
        XCTAssertFalse(RefreshBackoff().isWaiting)
    }
}
