import XCTest
@testable import ToastMonitor

final class QuotaAlertTests: XCTestCase {
    func testOpeningPanelAcknowledgesQuotaEvenWhenItStaysExhausted() {
        var state = QuotaAlertPolicy.BadgeState()
        state.update(remaining: 10, threshold: 10, resetAt: 1000)
        XCTAssertTrue(state.unread)
        state.update(remaining: 10, threshold: 10, resetAt: 1000, viewed: true)
        XCTAssertFalse(state.unread)
        state.update(remaining: 0, threshold: 10, resetAt: 1000)
        XCTAssertFalse(state.unread)
    }

    func testReadStateSurvivesRestartAndNextCycleCanAlert() throws {
        var state = QuotaAlertPolicy.BadgeState()
        state.update(remaining: 5, threshold: 10, resetAt: 1000, viewed: true)
        let data = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(QuotaAlertPolicy.BadgeState.self, from: data)
        state.update(remaining: 0, threshold: 10, resetAt: 1000)
        XCTAssertFalse(state.unread)
        state.update(remaining: 5, threshold: 10, resetAt: 2000)
        XCTAssertTrue(state.unread)
    }

    func testSameCycleFluctuationAndCountdownDriftDoNotRealert() {
        var state = QuotaAlertPolicy.BadgeState()
        state.update(remaining: 10, threshold: 10, resetAt: 1000, viewed: true)
        state.update(remaining: 11, threshold: 10, resetAt: 1001)
        state.update(remaining: 9, threshold: 10, resetAt: 999)
        XCTAssertFalse(state.unread)
    }

    func testProviderWithoutResetRearmsAfterRecovery() {
        var state = QuotaAlertPolicy.BadgeState()
        state.update(remaining: 10, threshold: 10, resetAt: nil, viewed: true)
        state.update(remaining: 0, threshold: 10, resetAt: nil)
        XCTAssertFalse(state.unread)
        state.update(remaining: 100, threshold: 10, resetAt: nil)
        state.update(remaining: 10, threshold: 10, resetAt: nil)
        XCTAssertTrue(state.unread)
    }

    func testQuotaCrossingWhilePanelOpenIsAlreadyRead() {
        var state = QuotaAlertPolicy.BadgeState()
        state.update(remaining: 50, threshold: 10, resetAt: 1000)
        XCTAssertFalse(state.unread)
        state.update(remaining: 10, threshold: 10, resetAt: 1000, viewed: true)
        state.update(remaining: 5, threshold: 10, resetAt: 1000)
        XCTAssertFalse(state.unread)
    }

    func testLowQuotaOnlyFiresWhenCrossingIntoCriticalState() {
        XCTAssertEqual(QuotaAlertPolicy.transition(previous: nil, remaining: 20, threshold: 20), .low)
        XCTAssertNil(QuotaAlertPolicy.transition(previous: "low", remaining: 10, threshold: 20))
        XCTAssertNil(QuotaAlertPolicy.transition(previous: "ok", remaining: 50, threshold: 20))
    }

    func testQuotaRecoveryFiresAfterCriticalState() {
        XCTAssertEqual(QuotaAlertPolicy.transition(previous: "low", remaining: 21, threshold: 20), .recovered)
        XCTAssertNil(QuotaAlertPolicy.transition(previous: nil, remaining: 100, threshold: 20))
    }
}
