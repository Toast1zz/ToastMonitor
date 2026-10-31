import Foundation

/// Estimates Claude tokens used somewhere this Mac cannot see — Cowork
/// sessions that run server-side, claude.ai chat, Claude Code on another
/// machine. Those leave no local transcript, so their tokens can never be
/// counted; only their effect on the shared quota shows.
///
/// Method: every successful quota fetch is stored as a sample (weekly %, 5h %,
/// reset times). The quota follows API-equivalent cost far more closely than
/// tokens, so local Claude Code cost divided by the dollars one point takes
/// gives the rise this Mac explains. Whatever a rise exceeds that by is
/// non-local, converted to tokens at the local tokens per dollar. The quota
/// is only sampled while the popover or dashboard is open, so a window that
/// reset between two samples still loses its unseen tail.
enum ClaudeNonLocalEstimator {
    struct Sample: Equatable {
        let ts: Int64
        let weeklyPct: Int
        let weeklyReset: Int64?
        let fiveHourPct: Int?
        let fiveHourReset: Int64?
    }

    /// Aggregated local activity for one adjacent sample interval.
    struct LocalIntervalTotals: Equatable {
        let freshTokens: Int64
        let totalTokens: Int64
        /// API-equivalent USD of the interval's priced turns.
        var cost: Double = 0
        /// Tokens of turns without a price, such as a model newer than the
        /// price table. They still used quota.
        var unpricedTokens: Int64 = 0
    }


    /// "Basically no local activity": below one or two ordinary turns.
    static let idleTokenThreshold: Int64 = 5_000
    /// The usage endpoint aggregates with a delay, so local turns shortly
    /// *before* an interval can still move the quota inside it.
    static let serverLagSeconds: Int64 = 10 * 60
    /// The collector ingests transcripts on a short delay; an interval that
    /// ended moments ago may not have its local turns in the store yet.
    static let ingestMarginSeconds: Int64 = 3 * 60
    /// Two reset timestamps within this distance are the same window
    /// (the endpoint's reset time can jitter between responses).
    static let sameWindowTolerance: Int64 = 3600
    // MARK: - Token estimate

    /// Tokens attributed to non-local use, placed at the middle of the idle
    /// interval they were inferred from so period totals can bucket them.
    struct TokenEvent: Equatable {
        let ts: Int64
        let tokens: Int64
    }

    struct TokenEstimate: Equatable {
        /// Local tokens (headline metric) per quota point, from this Mac's
        /// own Claude Code activity.
        let tokensPerPoint: Double
        let events: [TokenEvent]

        func tokens(from start: Int64, to end: Int64) -> Int64 {
            events.reduce(0) { $0 + ($1.ts >= start && $1.ts < end ? $1.tokens : 0) }
        }
    }

    /// Label of the synthetic per-tool row carrying the estimate.
    static let estimateToolLabel = "Cowork & web"

    /// Quota points of local activity needed before a tokens-per-point rate
    /// is trusted.
    static let minCalibrationPoints = 5
    /// Calibration follows recent work so a plan change settles within weeks.
    static let calibrationWindowSeconds: Int64 = 30 * 86400
    /// A rise above the local share counts only past this much: one point of
    /// rounding, or the spread of dollars per point between intervals.
    static let minExcessPoints = 1.0
    static let excessShareOfExpected = 0.5

    /// Converts non-local quota rises into tokens using per-interval local
    /// totals. The 5h window is preferred because its percentage moves ~20×
    /// finer than the weekly one; weekly data is the fallback.
    ///
    /// Production interval totals are aggregated in SQLite rather than
    /// retaining every local turn.
    static func tokenEstimate(samples: [Sample], localIntervalTotals: [LocalIntervalTotals],
                              now: Int64) -> TokenEstimate? {
        let series: [(length: Int64, extract: (Sample) -> (pct: Int, reset: Int64?)?)] = [
            (5 * 3600, { s in s.fiveHourPct.map { ($0, s.fiveHourReset) } }),
            (7 * 86400, { s in (s.weeklyPct, s.weeklyReset) }),
        ]
        for (length, extract) in series {
            if let estimate = tokenEstimate(samples, localIntervalTotals, now: now,
                                            windowLength: length, series: extract) {
                return estimate
            }
        }
        return nil
    }


    /// One adjacent sample pair whose quota change could be read.
    private struct QuotaInterval {
        let start: Int64
        let end: Int64
        let points: Int
        let idle: Bool
        let local: LocalIntervalTotals

        func event(points: Double, tokensPerPoint: Double) -> TokenEvent {
            TokenEvent(ts: start + (end - start) / 2, tokens: Int64((points * tokensPerPoint).rounded()))
        }
    }

    private struct CostCalibration {
        let dollarsPerPoint: Double
        let tokensPerDollar: Double

        func expectedPoints(_ local: LocalIntervalTotals) -> Double {
            (local.cost + Double(local.unpricedTokens) / tokensPerDollar) / dollarsPerPoint
        }
    }

    /// Dollars per point is the cost-weighted median of recent intervals with
    /// local work. Non-local use only makes an interval look cheaper, and a
    /// median ignores those; the weighting favours heavy intervals, where
    /// rounding and server lag matter least.
    private static func costCalibration(_ intervals: [QuotaInterval]) -> CostCalibration? {
        let active = intervals.filter { !$0.idle && $0.local.cost > 0 }
        guard let newest = active.last?.end else { return nil }
        let recent = active.filter { $0.end >= newest - calibrationWindowSeconds }
        let readable = recent.filter { $0.points >= 2 }
        guard readable.reduce(0, { $0 + $1.points }) >= minCalibrationPoints else { return nil }
        let rates = readable.map { (dollars: $0.local.cost / Double($0.points), weight: $0.local.cost) }
            .sorted { $0.dollars < $1.dollars }
        let half = rates.reduce(0) { $0 + $1.weight } / 2
        var running = 0.0
        var median = 0.0
        for rate in rates {
            running += rate.weight
            median = rate.dollars
            if running >= half { break }
        }
        let tokens = recent.reduce(Int64(0)) { $0 + $1.local.totalTokens }
        let cost = recent.reduce(0) { $0 + $1.local.cost }
        guard median > 0, tokens > 0 else { return nil }
        return CostCalibration(dollarsPerPoint: median, tokensPerDollar: Double(tokens) / cost)
    }

    private static func nonLocalEvents(_ intervals: [QuotaInterval], _ calibration: CostCalibration,
                                       tokensPerPoint: Double) -> [TokenEvent] {
        // Local points not yet seen in the quota: the server shows them late.
        var owed = 0.0
        var previousEnd: Int64?
        var events: [TokenEvent] = []
        for interval in intervals {
            if interval.idle || interval.start != previousEnd { owed = 0 }
            previousEnd = interval.end
            let expected = interval.idle ? 0 : calibration.expectedPoints(interval.local)
            owed += expected
            let paid = min(owed, Double(interval.points))
            owed -= paid
            let excess = Double(interval.points) - paid
            let tolerance = interval.idle ? 0 : max(minExcessPoints, excessShareOfExpected * expected)
            if excess > tolerance {
                events.append(interval.event(points: excess, tokensPerPoint: tokensPerPoint))
            }
            // A long interval gave older work time to show; what is still
            // owed beyond this interval's own share was an overestimate.
            if interval.end - interval.start >= serverLagSeconds { owed = min(owed, expected) }
        }
        return events
    }

    private static func tokenEstimate(_ samples: [Sample], _ totals: [LocalIntervalTotals], now: Int64,
                                      windowLength: Int64,
                                      series: (Sample) -> (pct: Int, reset: Int64?)?) -> TokenEstimate? {
        guard totals.count == max(samples.count - 1, 0) else { return nil }
        var calibrationTokens: Int64 = 0
        var calibrationPoints = 0
        var intervals: [QuotaInterval] = []
        for index in totals.indices {
            let a = samples[index]
            let b = samples[index + 1]
            let intervalTotals = totals[index]
            guard b.ts <= now - ingestMarginSeconds,
                  let wa = series(a), let wb = series(b), let resetB = wb.reset else { continue }
            let idle = intervalTotals.freshTokens < idleTokenThreshold
            func record(delta: Int) {
                intervals.append(.init(start: a.ts, end: b.ts, points: delta, idle: idle, local: intervalTotals))
                if !idle {
                    calibrationTokens += intervalTotals.totalTokens
                    calibrationPoints += delta
                }
            }
            let delta: Int
            guard let resetA = wa.reset else {
                // The endpoint sends no reset time while a window sits at 0%:
                // none was open at `a`, so all `b` shows was used in between.
                guard wa.pct == 0 else { continue }
                record(delta: wb.pct)
                continue
            }
            if abs(resetA - resetB) <= sameWindowTolerance {
                delta = wb.pct - wa.pct
                guard delta >= 0 else { continue }
            } else {
                // A new window opened inside an idle interval: everything it
                // shows was used in the interval (the old window's tail is
                // unknown, so this stays a lower bound). Mixed intervals are
                // skipped — their local tokens straddle two windows.
                let opened = resetB - windowLength
                guard idle, opened >= a.ts, opened <= b.ts,
                      opened >= resetA - sameWindowTolerance else { continue }
                delta = wb.pct
            }
            record(delta: delta)
        }
        guard calibrationPoints >= minCalibrationPoints, calibrationTokens > 0 else { return nil }
        if let calibration = costCalibration(intervals) {
            let rate = calibration.dollarsPerPoint * calibration.tokensPerDollar
            return TokenEstimate(tokensPerPoint: rate,
                                 events: nonLocalEvents(intervals, calibration, tokensPerPoint: rate))
        }
        // Without priced local work, only idle rises can be told apart.
        let rate = Double(calibrationTokens) / Double(calibrationPoints)
        return TokenEstimate(
            tokensPerPoint: rate,
            events: intervals.filter { $0.idle && $0.points > 0 }
                .map { $0.event(points: Double($0.points), tokensPerPoint: rate) })
    }

}
