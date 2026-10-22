import Foundation

/// How long a prepaid balance lasts at the recent spending pace. Only shown
/// when it is running out ("~3.2d left"); a healthy balance says nothing.
enum BalanceRunway {
    /// History looked at for the pace.
    static let lookback: Int64 = 30 * 86_400
    /// Less history than this is too noisy to extrapolate from.
    static let minCoverage: Int64 = 86_400
    /// Below this daily spend the balance is effectively not being used.
    static let idleDailySpend = 0.0005

    /// Daily spend from a cumulative usage counter (OpenRouter's credit
    /// usage): last minus first over the time between them.
    static func dailySpend(cumulative samples: [(ts: Int64, value: Double)]) -> Double? {
        guard let first = samples.first, let last = samples.last,
              last.ts - first.ts >= minCoverage else { return nil }
        return max(last.value - first.value, 0) / Double(last.ts - first.ts) * 86_400
    }

    /// Daily spend from balance readings. Only drops count, so a top-up
    /// does not read as negative spend.
    static func dailySpend(balances samples: [(ts: Int64, value: Double)]) -> Double? {
        guard let first = samples.first, let last = samples.last,
              last.ts - first.ts >= minCoverage else { return nil }
        let spent = zip(samples, samples.dropFirst()).reduce(0) { $0 + max($1.0.value - $1.1.value, 0) }
        return spent / Double(last.ts - first.ts) * 86_400
    }

    /// Under this many days left, a balance needs attention.
    static let warnDays = 7.0

    /// "~3.2d left" when the balance runs out within `warnDays` at the
    /// recent pace; nil otherwise, including when the pace is unknown.
    static func lowText(balance: Double, dailySpend: Double?) -> String? {
        guard let dailySpend, dailySpend.isFinite, dailySpend >= idleDailySpend,
              balance.isFinite, balance > 0 else { return nil }
        let days = balance / dailySpend
        guard days < warnDays else { return nil }
        return "~\(Format.remaining(Int64(days * 86_400))) left"
    }
}
