import XCTest
@testable import ToastMonitor

final class ClaudeNonLocalEstimatorTests: XCTestCase {
    private typealias E = ClaudeNonLocalEstimator
    private let hour: Int64 = 3600
    private let start: Int64 = 1_000_000
    private let fiveHourReset: Int64 = 1_020_000
    private let weeklyReset: Int64 = 2_000_000
    private var farFuture: Int64 { 10_000_000 }

    /// Hourly samples; 5h percentages drive the estimate when present.
    private func samples(fiveHour: [Int?], weekly: [Int]? = nil) -> [E.Sample] {
        fiveHour.enumerated().map { i, pct in
            E.Sample(ts: start + Int64(i) * hour,
                     weeklyPct: weekly?[i] ?? 40,
                     weeklyReset: weeklyReset,
                     fiveHourPct: pct,
                     fiveHourReset: pct == nil ? nil : fiveHourReset)
        }
    }

    private typealias LocalTurn = (ts: Int64, fresh: Int64, total: Int64)

    /// Reference interval aggregation for checking database range assignment.
    private func intervalTotals(samples: [E.Sample], turns: [LocalTurn]) -> [E.LocalIntervalTotals] {
        zip(samples, samples.dropFirst()).map { a, b -> E.LocalIntervalTotals in
            let total: Int64 = turns.reduce(0) { $0 + ($1.ts > a.ts && $1.ts <= b.ts ? max($1.total, 0) : 0) }
            return E.LocalIntervalTotals(
                freshTokens: turns.reduce(0) { $0 + ($1.ts >= a.ts - E.serverLagSeconds && $1.ts <= b.ts ? max($1.fresh, 0) : 0) },
                totalTokens: total,
                unpricedTokens: total)
        }
    }

    /// Local Claude Code work inside interval `i` (between sample i and i+1).
    private func localWork(in i: Int, total: Int64, fresh: Int64 = 50_000) -> LocalTurn {
        (start + Int64(i) * hour + 1800, fresh, total)
    }

    func testIdleRiseBecomesTokensAtLocalRate() {
        // Intervals 0–1: local work, 5h 10→15 (5 points) for 5M tokens → 1M/point.
        // Interval 2: nothing local, 5h 15→17 → 2 points ≈ 2M tokens.
        let s = samples(fiveHour: [10, 12, 15, 17])
        let events = [localWork(in: 1, total: 3_000_000), localWork(in: 0, total: 2_000_000)]
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: farFuture)
        XCTAssertEqual(estimate?.tokensPerPoint, 1_000_000)
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: s[2].ts + hour / 2, tokens: 2_000_000)])
    }

    func testTooLittleLocalCalibrationGivesNoEstimate() {
        // Only 4 local points: the tokens-per-point rate is not trusted yet.
        let s = samples(fiveHour: [10, 14, 20])
        XCTAssertNil(E.tokenEstimate(samples: s,
                                     localIntervalTotals: intervalTotals(samples: s, turns: [localWork(in: 0, total: 4_000_000)]),
                                     now: farFuture))
    }

    func testLocalActivityJustBeforeIntervalKeepsItLocal() {
        let s = samples(fiveHour: [10, 15, 18])
        // Server aggregation lag: turns 5 min before the 15→18 interval.
        let turns = [localWork(in: 0, total: 5_000_000),
                     (s[1].ts - 300, 40_000, 100_000)]
        XCTAssertEqual(E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: turns),
                                       now: farFuture)?.events, [])
    }

    func testFallsBackToWeeklyWithoutFiveHourWindow() {
        let s = samples(fiveHour: [nil, nil, nil, nil], weekly: [10, 13, 16, 17])
        let totals = [
            E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 3_000_000),
            E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 3_000_000),
            E.LocalIntervalTotals(freshTokens: 0, totalTokens: 0),
        ]
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: totals, now: farFuture)
        XCTAssertEqual(estimate?.tokensPerPoint, 1_000_000)
        XCTAssertEqual(estimate?.events.map(\.tokens), [1_000_000])
    }

    func testIntervalAggregatePreservesBoundariesLagOverlapAndCloseSamples() {
        let path = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let sampleTimes: [Int64] = [1_000, 1_100, 1_200, 2_000]
        let s = sampleTimes.map {
            E.Sample(ts: $0, weeklyPct: 10, weeklyReset: weeklyReset,
                     fiveHourPct: 10, fiveHourReset: fiveHourReset)
        }
        let times: [Int64] = [399, 400, 999, 1_000, 1_001, 1_100, 1_101,
                              1_200, 1_201, 2_000, 2_001]
        let turns = times.enumerated().map { i, ts in
            TurnRecord(tool: .claude, sessionID: "s\(i)", project: nil, model: "claude-sonnet-5",
                       ts: ts, inputTokens: 1, outputTokens: 0, cacheRead: 10, cacheWrite: 2,
                       cost: 0, provider: nil, costQuality: "estimated")
        }
        XCTAssertTrue(db.insertTurns(turns))

        let expected = [
            E.LocalIntervalTotals(freshTokens: 15, totalTokens: 22, unpricedTokens: 22),
            E.LocalIntervalTotals(freshTokens: 18, totalTokens: 22, unpricedTokens: 22),
            E.LocalIntervalTotals(freshTokens: 24, totalTokens: 22, unpricedTokens: 22),
        ]
        let actual = db.claudeLocalIntervalTotals(samples: s)
        XCTAssertEqual(actual, expected)
        let referenceTurns: [LocalTurn] = times.map { ($0, 3, 11) }
        XCTAssertEqual(actual, intervalTotals(samples: s, turns: referenceTurns))
    }

    func testIdleIntervalSpanningResetCountsTheNewWindow() {
        let oldReset = start + 2 * hour + 300
        var s = samples(fiveHour: [10, 15, 20]).map {
            E.Sample(ts: $0.ts, weeklyPct: $0.weeklyPct, weeklyReset: $0.weeklyReset,
                     fiveHourPct: $0.fiveHourPct, fiveHourReset: oldReset)
        }
        // Nothing local; the old window expired and a new one opened inside
        // the interval and reached 7% — all of it used during the interval.
        s.append(E.Sample(ts: start + 3 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 7, fiveHourReset: oldReset + 600 + 5 * hour))
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: farFuture)
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: s[2].ts + hour / 2, tokens: 7_000_000)])
    }

    func testRiseFromAnUnopenedWindowCountsAsUse() {
        // The usage endpoint reports no reset time while the 5h window sits
        // at 0%; the first use afterwards must not vanish with that sample.
        var s = samples(fiveHour: [10, 15, 20])
        s.append(E.Sample(ts: start + 3 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 0, fiveHourReset: nil))
        s.append(E.Sample(ts: start + 4 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 7, fiveHourReset: start + 4 * hour + 4 * hour))
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: farFuture)
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: s[3].ts + hour / 2, tokens: 7_000_000)])
    }

    func testWindowClosingWithoutResetTimeIsNotUse() {
        var s = samples(fiveHour: [10, 15, 20])
        s.append(E.Sample(ts: start + 3 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 0, fiveHourReset: nil))
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        XCTAssertEqual(E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: farFuture)?.events, [])
    }

    func testWindowResetIsNotAnInterval() {
        var s = samples(fiveHour: [10, 15, 20])
        // Next sample belongs to a new 5h window: 20 → 3 is a reset, not use.
        s.append(E.Sample(ts: start + 3 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 3, fiveHourReset: fiveHourReset + 5 * hour))
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        XCTAssertEqual(E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: farFuture)?.events, [])
    }

    func testRecentIntervalWaitsForIngestion() {
        let s = samples(fiveHour: [10, 15, 20, 24])
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        // The idle interval ended a minute ago: its local turns may not be ingested yet.
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: intervalTotals(samples: s, turns: events),
                                       now: s.last!.ts + 60)
        XCTAssertEqual(estimate?.events, [])
    }

    func testTokensAreBucketedByPeriod() {
        let estimate = E.TokenEstimate(tokensPerPoint: 1, events: [
            E.TokenEvent(ts: 100, tokens: 5), E.TokenEvent(ts: 200, tokens: 7),
        ])
        XCTAssertEqual(estimate.tokens(from: 0, to: 150), 5)
        XCTAssertEqual(estimate.tokens(from: 150, to: 300), 7)
        XCTAssertEqual(estimate.tokens(from: 0, to: 300), 12)
    }

    func testDatabaseRoundTrip() {
        let path = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let sample = E.Sample(ts: 1_000, weeklyPct: 42, weeklyReset: 5_000, fiveHourPct: 7, fiveHourReset: 3_000)
        let nextSample = E.Sample(ts: 1_200, weeklyPct: 43, weeklyReset: 5_000, fiveHourPct: 8, fiveHourReset: 3_000)
        XCTAssertTrue(db.insertClaudeQuotaSample(sample))
        XCTAssertTrue(db.insertClaudeQuotaSample(nextSample))
        XCTAssertEqual(db.claudeQuotaSamples(since: 0), [sample, nextSample])
        let turn = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-sonnet-5",
                              ts: 1_100, inputTokens: 10, outputTokens: 20, cacheRead: 250_000,
                              cacheWrite: 300, cost: 0, provider: nil, costQuality: "estimated")
        XCTAssertTrue(db.insertTurns([turn]))
        XCTAssertEqual(db.claudeLocalIntervalTotals(samples: [sample, nextSample]),
                       [E.LocalIntervalTotals(freshTokens: 330, totalTokens: 250_030, unpricedTokens: 250_030)])
    }

    func testDatabaseSplitsPricedAndUnpricedTurns() {
        let path = NSTemporaryDirectory() + "tm-test-\(UUID().uuidString).db"
        let db = Database.testInstance(path: path)
        defer {
            db.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let s = [1_000, 1_200].map {
            E.Sample(ts: Int64($0), weeklyPct: 10, weeklyReset: 5_000, fiveHourPct: 7, fiveHourReset: 3_000)
        }
        XCTAssertTrue(db.insertTurns([
            TurnRecord(tool: .claude, sessionID: "a", project: nil, model: "claude-sonnet-5",
                       ts: 1_100, inputTokens: 10, outputTokens: 20, cacheRead: 1_000,
                       cacheWrite: 300, cost: 1.5, provider: nil, costQuality: "estimated"),
            TurnRecord(tool: .claude, sessionID: "b", project: nil, model: "claude-new",
                       ts: 1_150, inputTokens: 1, outputTokens: 2, cacheRead: 100,
                       cacheWrite: 3, cost: 0, provider: nil, costQuality: "estimated"),
        ]))
        XCTAssertEqual(db.claudeLocalIntervalTotals(samples: s),
                       [E.LocalIntervalTotals(freshTokens: 336, totalTokens: 1_133, cost: 1.5, unpricedTokens: 103)])
    }

    // MARK: - Cost-based attribution

    /// $0.50 per point and 4M tokens per dollar, so 2M tokens per point.
    private func costEstimate(fiveHour: [Int], dollars: [Double]) -> E.TokenEstimate? {
        let s = samples(fiveHour: fiveHour)
        let totals = dollars.map {
            E.LocalIntervalTotals(freshTokens: $0 > 0 ? 50_000 : 0, totalTokens: Int64($0 * 4_000_000), cost: $0)
        }
        return E.tokenEstimate(samples: s, localIntervalTotals: totals, now: s.last!.ts + hour)
    }

    private func middle(of interval: Int64) -> Int64 {
        start + interval * hour + hour / 2
    }

    func testRiseBeyondLocalCostCountsAsNonLocal() {
        let estimate = costEstimate(fiveHour: [0, 10, 20, 40], dollars: [5, 5, 5])
        XCTAssertEqual(estimate?.tokensPerPoint, 2_000_000)
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: middle(of: 2), tokens: 20_000_000)])
    }

    func testRiseWithinLocalSpreadIsNotAttributed() {
        XCTAssertEqual(costEstimate(fiveHour: [0, 10, 20, 34], dollars: [5, 5, 5])?.events, [])
    }

    func testLocalRiseThatShowsLateIsNotAttributed() {
        XCTAssertEqual(costEstimate(fiveHour: [0, 0, 20, 30, 40], dollars: [5, 5, 5, 5])?.events, [])
    }

    func testIdleRiseCountsInFullAfterLocalWork() {
        let estimate = costEstimate(fiveHour: [0, 10, 20, 20, 40], dollars: [5, 5, 5, 0])
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: middle(of: 3), tokens: 40_000_000)])
    }

    func testOldLocalOverestimateDoesNotHideALaterRise() {
        let estimate = costEstimate(fiveHour: [0, 0, 0, 30, 40, 50], dollars: [5, 5, 5, 5, 5])
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: middle(of: 2), tokens: 20_000_000)])
    }

    func testUnpricedTurnsStillExplainTheirRise() {
        let s = samples(fiveHour: [0, 10, 20, 30])
        let priced = E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 20_000_000, cost: 5)
        let unpriced = E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 20_000_000, unpricedTokens: 20_000_000)
        let estimate = E.tokenEstimate(samples: s, localIntervalTotals: [priced, priced, unpriced],
                                       now: s.last!.ts + hour)
        XCTAssertEqual(estimate?.events, [])
    }

    func testCalibrationFollowsRecentWork() {
        let gap = 40 * 86400 as Int64
        let points: [(ts: Int64, pct: Int)] = [
            (start, 0), (start + hour, 2), (start + 2 * hour, 4), (start + 3 * hour, 6),
            (start + 3 * hour + gap, 6), (start + 4 * hour + gap, 16), (start + 5 * hour + gap, 26),
        ]
        let s = points.map {
            E.Sample(ts: $0.ts, weeklyPct: 40, weeklyReset: weeklyReset, fiveHourPct: $0.pct, fiveHourReset: fiveHourReset)
        }
        let oldPlan = E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 40_000_000, cost: 10)
        let idle = E.LocalIntervalTotals(freshTokens: 0, totalTokens: 0)
        let current = E.LocalIntervalTotals(freshTokens: 50_000, totalTokens: 20_000_000, cost: 5)
        let estimate = E.tokenEstimate(samples: s,
                                       localIntervalTotals: [oldPlan, oldPlan, oldPlan, idle, current, current],
                                       now: s.last!.ts + hour)
        XCTAssertEqual(estimate?.tokensPerPoint, 2_000_000)
    }
}
