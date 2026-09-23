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

    /// Local Claude Code work inside interval `i` (between sample i and i+1).
    private func localWork(in i: Int, total: Int64, fresh: Int64 = 50_000) -> E.LocalEvent {
        E.LocalEvent(ts: start + Int64(i) * hour + 1800, tokens: fresh, total: total)
    }

    func testIdleRiseBecomesTokensAtLocalRate() {
        // Intervals 0–1: local work, 5h 10→15 (5 points) for 5M tokens → 1M/point.
        // Interval 2: nothing local, 5h 15→17 → 2 points ≈ 2M tokens.
        let s = samples(fiveHour: [10, 12, 15, 17])
        let events = [localWork(in: 0, total: 2_000_000), localWork(in: 1, total: 3_000_000)]
        let estimate = E.tokenEstimate(samples: s, localEvents: events, now: farFuture)
        XCTAssertEqual(estimate?.tokensPerPoint, 1_000_000)
        XCTAssertEqual(estimate?.events, [E.TokenEvent(ts: s[2].ts + hour / 2, tokens: 2_000_000)])
    }

    func testTooLittleLocalCalibrationGivesNoEstimate() {
        // Only 4 local points: the tokens-per-point rate is not trusted yet.
        let s = samples(fiveHour: [10, 14, 20])
        XCTAssertNil(E.tokenEstimate(samples: s, localEvents: [localWork(in: 0, total: 4_000_000)], now: farFuture))
    }

    func testLocalActivityJustBeforeIntervalKeepsItLocal() {
        let s = samples(fiveHour: [10, 15, 18])
        // Server aggregation lag: turns 5 min before the 15→18 interval.
        let events = [localWork(in: 0, total: 5_000_000),
                      E.LocalEvent(ts: s[1].ts - 300, tokens: 40_000, total: 100_000)]
        XCTAssertEqual(E.tokenEstimate(samples: s, localEvents: events, now: farFuture)?.events, [])
    }

    func testFallsBackToWeeklyWithoutFiveHourWindow() {
        let s = samples(fiveHour: [nil, nil, nil, nil], weekly: [10, 13, 16, 17])
        let events = [localWork(in: 0, total: 3_000_000), localWork(in: 1, total: 3_000_000)]
        let estimate = E.tokenEstimate(samples: s, localEvents: events, now: farFuture)
        XCTAssertEqual(estimate?.tokensPerPoint, 1_000_000)
        XCTAssertEqual(estimate?.events.map(\.tokens), [1_000_000])
    }

    func testWindowResetIsNotAnInterval() {
        var s = samples(fiveHour: [10, 15, 20])
        // Next sample belongs to a new 5h window: 20 → 3 is a reset, not use.
        s.append(E.Sample(ts: start + 3 * hour, weeklyPct: 40, weeklyReset: weeklyReset,
                          fiveHourPct: 3, fiveHourReset: fiveHourReset + 5 * hour))
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        XCTAssertEqual(E.tokenEstimate(samples: s, localEvents: events, now: farFuture)?.events, [])
    }

    func testRecentIntervalWaitsForIngestion() {
        let s = samples(fiveHour: [10, 15, 20, 24])
        let events = [localWork(in: 0, total: 5_000_000), localWork(in: 1, total: 5_000_000)]
        // The idle interval ended a minute ago: its local turns may not be ingested yet.
        let estimate = E.tokenEstimate(samples: s, localEvents: events, now: s.last!.ts + 60)
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
        XCTAssertTrue(db.insertClaudeQuotaSample(sample))
        XCTAssertEqual(db.claudeQuotaSamples(since: 0), [sample])
        let turn = TurnRecord(tool: .claude, sessionID: "s", project: nil, model: "claude-sonnet-5",
                              ts: 1_100, inputTokens: 10, outputTokens: 20, cacheRead: 250_000,
                              cacheWrite: 300, cost: 0, provider: nil, costQuality: "estimated")
        XCTAssertTrue(db.insertTurns([turn]))
        XCTAssertEqual(db.claudeLocalEvents(since: 0),
                       [E.LocalEvent(ts: 1_100, tokens: 330, total: 250_030)])
    }
}
