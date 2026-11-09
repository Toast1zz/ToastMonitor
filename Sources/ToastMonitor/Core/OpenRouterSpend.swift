import Foundation

/// OpenRouter's `usage_daily` / `usage_weekly` / `usage_monthly` fields are
/// UTC windows (day, Monday–Sunday week, calendar month). The app's Today /
/// Week / Month periods use the local calendar, so those API fields must not
/// be added to local billed spend. Account `credits_usage` is a cumulative
/// counter; the spend in a local period is the rise since the last reading
/// before the period started.
enum OpenRouterSpend {
    /// Credits spent at or after `start`. `samples` is the stored
    /// `credits_usage` series, oldest first. `current` is a newer live total
    /// when the latest poll has not been persisted yet.
    static func since(_ start: Int64, samples: [(ts: Int64, value: Double)],
                      current: Double? = nil) -> Double {
        let usable = samples.filter { $0.value.isFinite }
        let latest = usable.last.flatMap { sample -> Double in
            guard let current, current.isFinite else { return sample.value }
            return max(current, sample.value)
        } ?? current.flatMap { $0.isFinite ? $0 : nil }

        if start <= 0 {
            return max(latest ?? 0, 0)
        }
        guard let latest else { return 0 }

        let baseline: Double
        if let prior = usable.last(where: { $0.ts < start }) {
            baseline = prior.value
        } else if let first = usable.first(where: { $0.ts >= start }) {
            // No pre-period reading: do not treat the all-time total as this
            // period's spend. Count only the rise after the first sample.
            baseline = first.value
        } else {
            return 0
        }
        return max(latest - baseline, 0)
    }
}
