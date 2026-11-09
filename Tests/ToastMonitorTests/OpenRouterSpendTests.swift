import XCTest
@testable import ToastMonitor

final class OpenRouterSpendTests: XCTestCase {

    func testAllTimeUsesTheLatestTotal() {
        let samples = [(ts: Int64(10), value: 2.0), (ts: Int64(20), value: 5.0)]
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples), 5)
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples, current: 6.5), 6.5)
        XCTAssertEqual(OpenRouterSpend.since(0, samples: []), 0)
        XCTAssertEqual(OpenRouterSpend.since(0, samples: [], current: 4), 4)
    }

    func testLocalPeriodSubtractsTheReadingBeforeStart() {
        // 21:00 previous local day (still previous UTC day in EAT) vs local midnight.
        let before = Int64(1_000)
        let start = Int64(1_800)
        let mid = Int64(2_000)
        let samples = [(ts: before, value: 10.0), (ts: mid, value: 12.0)]
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples), 2)
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples, current: 13.5), 3.5)
    }

    func testMissingPrePeriodBaselineDoesNotAttributeAllTimeSpend() {
        let start = Int64(1_800)
        let samples = [(ts: Int64(2_000), value: 40.0), (ts: Int64(2_100), value: 41.0)]
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples), 1)
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples, current: 41.5), 1.5)
    }

    func testNoSamplesInPeriodIsZeroUntilALiveRise() {
        XCTAssertEqual(OpenRouterSpend.since(1_800, samples: []), 0)
        XCTAssertEqual(OpenRouterSpend.since(1_800, samples: [], current: 9), 0)
        let prior = [(ts: Int64(100), value: 9.0)]
        XCTAssertEqual(OpenRouterSpend.since(1_800, samples: prior, current: 11), 2)
    }

    func testNonFiniteValuesAreIgnored() {
        let samples = [(ts: Int64(1), value: Double.nan), (ts: Int64(2), value: 3.0)]
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples), 3)
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples, current: Double.infinity), 3)
    }


    func testCounterResetStartsANewBaseline() {
        let start = Int64(1_800)
        let samples = [
            (ts: Int64(1_000), value: 10.0),
            (ts: Int64(2_000), value: 12.0),
            (ts: Int64(3_000), value: 1.0),
            (ts: Int64(4_000), value: 3.0),
        ]
        // Rise of 2 before the drop, then 2 after the new baseline — not 0.
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples), 4)
    }

    func testLiveCurrentDropDoesNotEraseEarlierPeriodSpend() {
        let start = Int64(1_800)
        let samples = [(ts: Int64(1_000), value: 10.0), (ts: Int64(2_000), value: 12.0)]
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples, current: 1.0), 2)
        // A drop is a new counter, not a continuation of the previous total.
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples, current: 3.0), 2)
        XCTAssertEqual(OpenRouterSpend.since(start, samples: samples, current: 15.0), 5)
    }

    func testAllTimeFollowsTheCurrentCounterAfterAReset() {
        let samples = [
            (ts: Int64(1), value: 10.0),
            (ts: Int64(2), value: 12.0),
            (ts: Int64(3), value: 1.0),
        ]
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples), 1)
        XCTAssertEqual(OpenRouterSpend.since(0, samples: samples, current: 3.0), 3)
    }

    func testUpwardJumpWithoutANewSeriesCountsAsSpend() {
        // A key change that is not isolated looks like a large rise; the
        // series epoch (tested on Database) is what prevents this.
        let samples = [(ts: Int64(1_000), value: 10.0), (ts: Int64(2_000), value: 5_000.0)]
        XCTAssertEqual(OpenRouterSpend.since(1_800, samples: samples), 4_990)
    }
}
