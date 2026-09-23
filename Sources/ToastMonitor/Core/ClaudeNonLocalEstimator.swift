import Foundation

/// Estimates Claude tokens used somewhere this Mac cannot see — Cowork
/// sessions that run server-side, claude.ai chat, Claude Code on another
/// machine. Those leave no local transcript, so their tokens can never be
/// counted; only their effect on the shared quota shows.
///
/// Method: every successful quota fetch is stored as a sample (weekly %, 5h %,
/// reset times). A quota rise between two samples is attributed to non-local
/// use only when this Mac recorded essentially no Claude Code tokens in that
/// interval, then converted to tokens at the rate local Claude Code activity
/// consumes quota. An interval with both local and non-local use counts as
/// local, so the result is a lower bound — and the quota is only sampled
/// while the popover or dashboard is open, which makes intervals long and
/// mixed more often.
enum ClaudeNonLocalEstimator {
    struct Sample: Equatable {
        let ts: Int64
        let weeklyPct: Int
        let weeklyReset: Int64?
        let fiveHourPct: Int?
        let fiveHourReset: Int64?
    }

    /// One local Claude Code turn: timestamp and fresh tokens (input + output
    /// + cache writes). Cache reads are excluded — every turn re-reads the
    /// whole context (~250k tokens) and would drown the "idle" test.
    struct LocalEvent: Equatable {
        let ts: Int64
        let tokens: Int64
        /// Same turn in the app's headline metric (input + output + cache
        /// reads) — what the calibration converts quota points back into.
        var total: Int64 = 0
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
    static let estimateToolLabel = "Cowork & web (est.)"
    /// Quota points of local activity needed before a tokens-per-point rate
    /// is trusted.
    static let minCalibrationPoints = 5

    /// Converts non-local quota rises into tokens. The 5h window is used
    /// when available — its percentage moves ~20× finer than the weekly
    /// one — and the weekly window otherwise.
    ///
    /// Calibration: over intervals with real local activity, local tokens /
    /// quota points consumed. Intervals that also contained non-local use
    /// make the rate a little low, so the estimate stays conservative.
    static func tokenEstimate(samples: [Sample], localEvents: [LocalEvent], now: Int64) -> TokenEstimate? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let events = localEvents.sorted { $0.ts < $1.ts }
        let series: [(Sample) -> (pct: Int, reset: Int64)?] = [
            { s in s.fiveHourPct.flatMap { p in s.fiveHourReset.map { (p, $0) } } },
            { s in s.weeklyReset.map { (s.weeklyPct, $0) } },
        ]
        for extract in series {
            if let estimate = tokenEstimate(sorted, events, now: now, series: extract) {
                return estimate
            }
        }
        return nil
    }

    private static func tokenEstimate(_ samples: [Sample], _ events: [LocalEvent], now: Int64,
                                      series: (Sample) -> (pct: Int, reset: Int64)?) -> TokenEstimate? {
        var freshPrefix: [Int64] = [0], totalPrefix: [Int64] = [0]
        for e in events {
            freshPrefix.append(freshPrefix[freshPrefix.count - 1] + max(e.tokens, 0))
            totalPrefix.append(totalPrefix[totalPrefix.count - 1] + max(e.total, 0))
        }
        func sum(_ prefix: [Int64], _ start: Int64, _ end: Int64) -> Int64 {
            let lo = lowerBound(events, start), hi = lowerBound(events, end + 1)
            return hi > lo ? prefix[hi] - prefix[lo] : 0
        }

        var calibrationTokens: Int64 = 0
        var calibrationPoints = 0
        var idle: [(mid: Int64, points: Int)] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            guard b.ts <= now - ingestMarginSeconds,
                  let wa = series(a), let wb = series(b),
                  abs(wa.reset - wb.reset) <= sameWindowTolerance else { continue }
            let delta = wb.pct - wa.pct
            guard delta >= 0 else { continue }
            if sum(freshPrefix, a.ts - serverLagSeconds, b.ts) < idleTokenThreshold {
                if delta > 0 { idle.append((a.ts + (b.ts - a.ts) / 2, delta)) }
            } else {
                calibrationTokens += sum(totalPrefix, a.ts + 1, b.ts)
                calibrationPoints += delta
            }
        }
        guard calibrationPoints >= minCalibrationPoints, calibrationTokens > 0 else { return nil }
        let rate = Double(calibrationTokens) / Double(calibrationPoints)
        return TokenEstimate(
            tokensPerPoint: rate,
            events: idle.map { TokenEvent(ts: $0.mid, tokens: Int64((Double($0.points) * rate).rounded())) })
    }

    private static func lowerBound(_ events: [LocalEvent], _ ts: Int64) -> Int {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
