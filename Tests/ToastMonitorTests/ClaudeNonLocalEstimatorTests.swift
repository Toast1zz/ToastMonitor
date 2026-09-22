import XCTest
@testable import ToastMonitor

final class ClaudeNonLocalEstimatorTests: XCTestCase {
    private typealias E = ClaudeNonLocalEstimator
    private let reset: Int64 = 2_000_000
    private let hour: Int64 = 3600

    /// Hourly samples over 8h with the given weekly percentages.
    private func samples(_ pcts: [Int], start: Int64 = 1_000_000,
                         fiveHour: [Int]? = nil) -> [E.Sample] {
        pcts.enumerated().map { i, pct in
            E.Sample(ts: start + Int64(i) * hour, weeklyPct: pct, weeklyReset: reset,
                     fiveHourPct: fiveHour?[i], fiveHourReset: fiveHour == nil ? nil : reset - 86400)
        }
    }

    private var farFuture: Int64 { 10_000_000 }

    func testRiseWithNoLocalActivityCountsAsNonLocal() {
        let result = E.estimate(samples: samples([10, 12, 12, 15, 15, 15, 16]),
                                localEvents: [], now: farFuture)
        XCTAssertEqual(result, E.Result(nonLocalPoints: 6, weeklyUsed: 16, intervals: 6))
    }

    func testRiseWithLocalActivityCountsAsLocal() {
        let s = samples([10, 12, 12, 15, 15, 15, 16])
        // Local Claude Code work inside the 12→15 interval (samples 2→3).
        let events = [E.LocalEvent(ts: s[2].ts + 600, tokens: 40_000)]
        let result = E.estimate(samples: s, localEvents: events, now: farFuture)
        XCTAssertEqual(result?.nonLocalPoints, 3) // 2 + 1, the 3-point rise is local
    }

    func testLocalActivityJustBeforeIntervalCountsAsLocal() {
        let s = samples([10, 10, 10, 10, 14, 14, 14])
        // Server aggregation lag: turns 5 min before the 10→14 interval.
        let events = [E.LocalEvent(ts: s[3].ts - 300, tokens: 40_000)]
        XCTAssertEqual(E.estimate(samples: s, localEvents: events, now: farFuture)?.nonLocalPoints, 0)
    }

    func testTinyLocalActivityIsStillIdle() {
        let s = samples([10, 10, 13, 13, 13, 13, 13])
        let events = [E.LocalEvent(ts: s[1].ts + 60, tokens: 1_200)]
        XCTAssertEqual(E.estimate(samples: s, localEvents: events, now: farFuture)?.nonLocalPoints, 3)
    }

    func testFlatFiveHourMeansWeeklyTickIsRounding() {
        let s = samples([10, 11, 11, 11, 11, 11, 11], fiveHour: [30, 30, 30, 30, 30, 30, 30])
        XCTAssertEqual(E.estimate(samples: s, localEvents: [], now: farFuture)?.nonLocalPoints, 0)
    }

    func testTooFewSamplesShowsNothing() {
        XCTAssertNil(E.estimate(samples: samples([10, 20, 30]), localEvents: [], now: farFuture))
        // Enough intervals but under the minimum span.
        let dense = (0..<10).map { i in
            E.Sample(ts: 1_000_000 + Int64(i) * 300, weeklyPct: 10 + i, weeklyReset: reset,
                     fiveHourPct: nil, fiveHourReset: nil)
        }
        XCTAssertNil(E.estimate(samples: dense, localEvents: [], now: farFuture))
    }

    func testPreviousWeeklyWindowIsIgnored() {
        let old = (0..<5).map { i in
            E.Sample(ts: 900_000 + Int64(i) * hour, weeklyPct: 80 + i, weeklyReset: reset - 7 * 86400,
                     fiveHourPct: nil, fiveHourReset: nil)
        }
        let result = E.estimate(samples: old + samples([0, 2, 2, 2, 2, 2, 2]),
                                localEvents: [], now: farFuture)
        XCTAssertEqual(result?.nonLocalPoints, 2)
        XCTAssertEqual(result?.weeklyUsed, 2)
    }

    func testRecentIntervalWaitsForIngestion() {
        let s = samples([10, 10, 10, 10, 10, 10, 10, 18])
        // The last interval ended a minute ago: local turns may not be ingested yet.
        let result = E.estimate(samples: s, localEvents: [], now: s.last!.ts + 60)
        XCTAssertEqual(result?.nonLocalPoints, 0)
        XCTAssertEqual(result?.intervals, 6)
    }

    func testDatabaseRoundTrip() {
        let path = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let sample = E.Sample(ts: 1_000, weeklyPct: 42, weeklyReset: 5_000, fiveHourPct: nil, fiveHourReset: nil)
        XCTAssertTrue(db.insertClaudeQuotaSample(sample))
        XCTAssertEqual(db.claudeQuotaSamples(since: 0), [sample])
        let turn = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-sonnet-5",
                              ts: 1_100, inputTokens: 10, outputTokens: 20, cacheRead: 250_000,
                              cacheWrite: 300, cost: 0, provider: nil, costQuality: "estimated")
        XCTAssertTrue(db.insertTurns([turn]))
        XCTAssertEqual(db.claudeLocalEvents(since: 0), [E.LocalEvent(ts: 1_100, tokens: 330)])
    }
}
