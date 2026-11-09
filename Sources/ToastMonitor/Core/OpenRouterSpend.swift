import Foundation

/// OpenRouter's `usage_daily` / `usage_weekly` / `usage_monthly` fields are
/// UTC windows (day, Monday–Sunday week, calendar month). The app's Today /
/// Week / Month periods use the local calendar, so those API fields must not
/// be added to local billed spend. Account `credits_usage` is a cumulative
/// counter; the spend in a local period is the rise since the last reading
/// before the period started.
///
/// The counter can drop mid-series when the account is replaced or the
/// lifetime total is reset. A decrease starts a new baseline so the drop
/// is not treated as zero spend for the rest of the period, and a later
/// rise is counted from the reset rather than from the previous account.
enum OpenRouterSpend {
    /// Credits spent at or after `start`. `samples` is the stored
    /// `credits_usage` series, oldest first. `current` is a newer live total
    /// when the latest poll has not been persisted yet.
    static func since(_ start: Int64, samples: [(ts: Int64, value: Double)],
                      current: Double? = nil) -> Double {
        var points = samples.filter { $0.value.isFinite }
        if let current, current.isFinite {
            if let last = points.last {
                points.append((ts: max(last.ts, start) + 1, value: current))
            } else if start <= 0 {
                points.append((ts: 1, value: current))
            } else {
                points.append((ts: start, value: current))
            }
        }
        guard let latest = points.last?.value else { return 0 }
        if start <= 0 {
            return max(latest, 0)
        }

        var spend = 0.0
        var baseline = points.last(where: { $0.ts < start })?.value
        for point in points where point.ts >= start {
            guard let prev = baseline else {
                baseline = point.value
                continue
            }
            if point.value < prev {
                baseline = point.value
                continue
            }
            spend += point.value - prev
            baseline = point.value
        }
        return max(spend, 0)
    }
}
