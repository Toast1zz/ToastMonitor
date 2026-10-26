import Foundation

/// Cycle math + value attribution for user-recorded subscriptions.
enum SubscriptionMath {

    struct CycleInfo {
        let start: Date
        let end: Date        // next renewal
        let dayOfCycle: Int  // 1-based
        let totalDays: Int
        let progress: Double // 0...1
    }

    static func cycleInfo(start: Int64, end: Int64 = 0, cycle: String, now: Date = Date()) -> CycleInfo? {
        guard start > 0 else { return nil }
        // Only the supported cycles have defined math; anything else (old
        // rows, bad config) must not silently fall into the monthly window.
        guard cycle == "yearly" || cycle == "monthly" || cycle == "weekly" else { return nil }
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: TimeInterval(start))
        let endDate = end > 0 ? Date(timeIntervalSince1970: TimeInterval(end)) : nil
        if let endDate, now >= endDate { return nil } // ended subscription: no active cycle
        // Every boundary is anchored to the original billing date so short
        // months and non-leap years do not move later renewals permanently.
        var index = 0
        var windowStart = startDate
        guard var windowEnd = cycleBoundary(start: startDate, cycle: cycle, index: 1) else { return nil }
        while windowEnd <= now && index < 1200 {
            index += 1
            windowStart = windowEnd
            guard let next = cycleBoundary(start: startDate, cycle: cycle, index: index + 1) else { return nil }
            windowEnd = next
        }
        guard windowEnd > now else { return nil }
        // An end date inside the window truncates it (no amortization past
        // the end of the subscription).
        if let endDate, endDate < windowEnd {
            windowEnd = endDate
        }
        let totalDays = max(cal.dateComponents([.day], from: cal.startOfDay(for: windowStart),
                                               to: cal.startOfDay(for: windowEnd)).day ?? 30, 1)
        let elapsed = max(cal.dateComponents([.day], from: cal.startOfDay(for: windowStart),
                                             to: cal.startOfDay(for: now)).day ?? 0, 0)
        let dayOfCycle = min(elapsed + 1, totalDays)
        let progress = min(max(Double(elapsed) / Double(totalDays), 0), 1)
        return CycleInfo(start: windowStart, end: windowEnd,
                         dayOfCycle: dayOfCycle, totalDays: totalDays, progress: progress)
    }

    /// Value of usage consumed inside the current cycle, when a quota source is linked.
    /// - go: monthly quota % × $60 plan cap (monthly cycles only)
    /// - openrouter: sum of per-day OpenRouter spend since cycle start (from snapshots)
    static func cycleValue(plan: String, cycle: String, cycleStart: Date) -> Double? {
        switch plan {
        case "go":
            guard let pct = OpenCodeGoClient.shared.state.monthlyPct else { return nil }
            // Go exposes a monthly quota window. It cannot be multiplied into
            // a yearly subscription without a 12-month history, so keep the
            // value explicitly monthly rather than fabricating an annual one.
            guard cycle != "yearly" else { return nil }
            return pct / 100 * OpenCodeGoClient.monthlyLimitUSD
        case "openrouter":
            return Database.shared.orSpendSince(Int64(cycleStart.timeIntervalSince1970))
        case "claude":
            // Claude Pro bills the Claude Code traffic; value = what those
            // turns cost at API list prices inside the cycle.
            return Database.shared.apiValue(from: Int64(cycleStart.timeIntervalSince1970),
                                            to: Int64(Date().timeIntervalSince1970),
                                            tool: "claude")
        case "openai", "chatgpt", "codex":
            // OpenAI subscription (ChatGPT and Codex are the same monthly
            // plan under different names) bills the Codex traffic; value =
            // what those turns cost at API list prices inside the cycle.
            return Database.shared.apiValue(from: Int64(cycleStart.timeIntervalSince1970),
                                            to: Int64(Date().timeIntervalSince1970),
                                            tool: "codex")
        default:
            return nil
        }
    }

    static func dateStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func cycleBoundary(start: Date, cycle: String, index: Int) -> Date? {
        let step: Calendar.Component
        let stepCount: Int
        switch cycle {
        case "yearly": step = .year; stepCount = 1
        case "monthly": step = .month; stepCount = 1
        case "weekly": step = .day; stepCount = 7
        default: return nil
        }
        let (value, overflow) = index.multipliedReportingOverflow(by: stepCount)
        guard !overflow else { return nil }
        return Calendar.current.date(byAdding: step, value: value, to: start)
    }

    private static func cycles(of sub: Database.Subscription, overlapping window: Range<Date>) -> [(start: Date, end: Date)] {
        guard sub.startDate > 0 else { return [] }
        let start = Date(timeIntervalSince1970: TimeInterval(sub.startDate))
        let end = sub.endDate > 0 ? Date(timeIntervalSince1970: TimeInterval(sub.endDate)) : Date.distantFuture
        var result: [(start: Date, end: Date)] = []
        for index in 0..<1200 {
            guard let cycleStart = cycleBoundary(start: start, cycle: sub.cycle, index: index),
                  cycleStart < window.upperBound, cycleStart < end,
                  let next = cycleBoundary(start: start, cycle: sub.cycle, index: index + 1) else { break }
            let cycleEnd = min(next, end)
            guard cycleEnd > cycleStart else { break }
            if cycleEnd > window.lowerBound { result.append((cycleStart, cycleEnd)) }
        }
        return result
    }

    /// Each started cycle costs the full price, spread over its actual duration.
    /// An explicit end date truncates the final cycle before its daily rate is calculated.
    static func amortized(days: Int, subscriptions: [Database.Subscription], now: Date = Date()) -> Double {
        guard days > 0 else { return 0 }
        let windowStart = now.addingTimeInterval(-Double(days) * 86400)
        var total = 0.0
        for sub in subscriptions {
            for cycle in cycles(of: sub, overlapping: windowStart..<now) {
                let overlap = min(cycle.end, now).timeIntervalSince(max(cycle.start, windowStart))
                total += sub.price * overlap / cycle.end.timeIntervalSince(cycle.start)
            }
        }
        return total
    }

    // MARK: - Forecast

    struct Forecast {
        let used: Double          // used this cycle (USD, provider-reported)
        let dailyRate: Double     // average per day
        let limit: Double         // cap (Go: $60) or balance (OpenRouter)
        let projectedEnd: Double? // projected cycle total (Go; nil for OpenRouter)
        let exhaustDate: Date?    // when it runs out (nil = it won't)
        let isBreakeven: Bool     // used value ≥ subscription price
    }

    /// Extrapolates the daily rate (used so far ÷ days elapsed).
    static func forecast(plan: String, cycleStart: Date, cycleEnd: Date, now: Date = Date()) -> Forecast? {
        guard cycleStart <= now else { return nil }
        let cal = Calendar.current
        let s = cal.startOfDay(for: cycleStart)
        let n = cal.startOfDay(for: now)
        let e = cal.startOfDay(for: cycleEnd)
        let daysElapsed = max(cal.dateComponents([.day], from: s, to: n).day ?? 0, 1)
        let daysLeft = max(cal.dateComponents([.day], from: n, to: e).day ?? 0, 0)

        switch plan {
        case "go":
            guard let pct = OpenCodeGoClient.shared.state.monthlyPct else { return nil }
            // The provider only reports a monthly quota. A yearly fixed-cost
            // cycle needs a full historical series before it can be forecast;
            // returning nil is safer than projecting one month across a year.
            if cycleEnd.timeIntervalSince(cycleStart) > 370 * 86400 { return nil }
            let limit = OpenCodeGoClient.monthlyLimitUSD
            let used = pct / 100 * limit
            let rate = used / Double(daysElapsed)
            let projected = used + rate * Double(daysLeft)
            var exhaust: Date?
            if rate > 0 && projected > limit {
                let daysToExhaust = (limit - used) / rate
                exhaust = cal.date(byAdding: .day, value: Int(ceil(daysToExhaust)), to: now)
            }
            return Forecast(used: used, dailyRate: rate, limit: limit,
                            projectedEnd: projected, exhaustDate: exhaust,
                            isBreakeven: used >= 10)
        case "openrouter":
            guard let balance = OpenRouterClient.shared.state.accountBalance else { return nil }
            let used = Database.shared.orSpendSince(Int64(cycleStart.timeIntervalSince1970))
            let rate = used / Double(daysElapsed)
            var exhaust: Date?
            if rate > 0.0005 && balance > 0 {
                let daysToExhaust = balance / rate
                exhaust = cal.date(byAdding: .day, value: Int(ceil(daysToExhaust)), to: now)
            }
            return Forecast(used: used, dailyRate: rate, limit: balance,
                            projectedEnd: nil, exhaustDate: exhaust, isBreakeven: false)
        case "claude":
            // Claude Pro: value = Claude Code turns at API list prices.
            let used = Database.shared.apiValue(from: Int64(cycleStart.timeIntervalSince1970),
                                                to: Int64(now.timeIntervalSince1970),
                                                tool: "claude")
            let rate = used / Double(daysElapsed)
            let projected = used + rate * Double(daysLeft)
            return Forecast(used: used, dailyRate: rate, limit: projected,
                            projectedEnd: projected, exhaustDate: nil, isBreakeven: false)
        case "openai", "chatgpt", "codex":
            // OpenAI subscription: value = Codex turns at API list prices.
            let used = Database.shared.apiValue(from: Int64(cycleStart.timeIntervalSince1970),
                                                to: Int64(now.timeIntervalSince1970),
                                                tool: "codex")
            let rate = used / Double(daysElapsed)
            let projected = used + rate * Double(daysLeft)
            return Forecast(used: used, dailyRate: rate, limit: projected,
                            projectedEnd: projected, exhaustDate: nil, isBreakeven: false)
        default:
            return nil
        }
    }
}
