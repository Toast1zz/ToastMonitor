import Foundation

/// Estimates how much of the Claude weekly quota was spent somewhere this
/// Mac cannot see — Cowork sessions that run server-side, claude.ai chat,
/// Claude Code on another machine. Those leave no local transcript, so their
/// tokens can never be counted; only their effect on the shared quota shows.
///
/// Method: every successful quota fetch is stored as a sample (weekly %, 5h %,
/// reset times). For each pair of consecutive samples in the current weekly
/// window, the weekly percentage rise is attributed to non-local use only
/// when this Mac recorded essentially no Claude Code tokens in that interval.
/// An interval with both local and non-local use counts as local, so the
/// result is a lower bound — and the quota is only sampled while the popover
/// or dashboard is open, which makes intervals long and mixed more often.
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
    }

    struct Result: Equatable {
        /// Percentage points of the weekly quota attributed to non-local use.
        let nonLocalPoints: Int
        /// Weekly quota used at the latest sample.
        let weeklyUsed: Int
        /// Sample intervals examined in the current weekly window.
        let intervals: Int
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
    /// Minimum evidence before showing anything.
    static let minIntervals = 4
    static let minSpanSeconds: Int64 = 6 * 3600

    static func estimate(samples: [Sample], localEvents: [LocalEvent], now: Int64) -> Result? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let latest = sorted.last, let currentReset = latest.weeklyReset else { return nil }
        let window = sorted.filter { sample in
            guard let reset = sample.weeklyReset else { return false }
            return abs(reset - currentReset) <= sameWindowTolerance
        }
        guard window.count >= 2 else { return nil }

        let events = localEvents.sorted { $0.ts < $1.ts }
        var prefix: [Int64] = [0]
        prefix.reserveCapacity(events.count + 1)
        for event in events { prefix.append(prefix[prefix.count - 1] + max(event.tokens, 0)) }
        func tokens(from start: Int64, through end: Int64) -> Int64 {
            let lo = lowerBound(events, start)
            let hi = lowerBound(events, end + 1)
            return hi > lo ? prefix[hi] - prefix[lo] : 0
        }

        var intervals = 0
        var nonLocal = 0
        for (a, b) in zip(window, window.dropFirst()) {
            guard b.ts <= now - ingestMarginSeconds else { continue }
            let delta = b.weeklyPct - a.weeklyPct
            guard delta >= 0 else { continue } // a reset slipped through
            intervals += 1
            guard delta > 0 else { continue }
            // Same 5h window and a flat 5h number means nothing was actually
            // used — the weekly tick is rounding of earlier usage.
            if let fa = a.fiveHourPct, let fb = b.fiveHourPct,
               let ra = a.fiveHourReset, let rb = b.fiveHourReset,
               abs(ra - rb) <= sameWindowTolerance, fb <= fa {
                continue
            }
            if tokens(from: a.ts - serverLagSeconds, through: b.ts) < idleTokenThreshold {
                nonLocal += delta
            }
        }

        guard intervals >= minIntervals,
              let first = window.first,
              latest.ts - first.ts >= minSpanSeconds else { return nil }
        return Result(nonLocalPoints: min(nonLocal, latest.weeklyPct),
                      weeklyUsed: latest.weeklyPct,
                      intervals: intervals)
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
