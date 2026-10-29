import XCTest
@testable import ToastMonitor

final class SourceRetryTests: XCTestCase {
    func testFirstFailuresRetryOnTheNextTick() {
        var retry = SourceRetry()
        for _ in 1..<SourceRetry.failuresBeforeBackoff {
            retry.failed("omp", now: 100)
            XCTAssertFalse(retry.isWaiting("omp", now: 100))
        }
    }

    func testRepeatedFailuresWaitWithGrowingDelay() {
        var retry = SourceRetry()
        for _ in 0..<SourceRetry.failuresBeforeBackoff { retry.failed("omp", now: 100) }
        XCTAssertTrue(retry.isWaiting("omp", now: 159))
        XCTAssertFalse(retry.isWaiting("omp", now: 160))
        retry.failed("omp", now: 160)
        XCTAssertTrue(retry.isWaiting("omp", now: 279))
        XCTAssertFalse(retry.isWaiting("omp", now: 280))
        XCTAssertFalse(retry.isWaiting("claude", now: 160))
    }

    func testSuccessClearsTheBackoff() {
        var retry = SourceRetry()
        for _ in 0..<SourceRetry.failuresBeforeBackoff { retry.failed("omp", now: 100) }
        retry.succeeded("omp")
        XCTAssertFalse(retry.isWaiting("omp", now: 100))
        retry.failed("omp", now: 200)
        XCTAssertFalse(retry.isWaiting("omp", now: 200))
    }

    func testUserRefreshRetriesNowAndKeepsTheSchedule() {
        var retry = SourceRetry()
        for _ in 0..<SourceRetry.failuresBeforeBackoff { retry.failed("omp", now: 100) }
        retry.retryNow()
        XCTAssertFalse(retry.isWaiting("omp", now: 100))
        retry.failed("omp", now: 100)
        XCTAssertTrue(retry.isWaiting("omp", now: 219))
    }
}
