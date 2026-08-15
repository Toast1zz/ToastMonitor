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
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: TimeInterval(start))
        let endDate = end > 0 ? Date(timeIntervalSince1970: TimeInterval(end)) : nil
        if let endDate, now >= endDate { return nil } // ended subscription: no active cycle
        let step: Calendar.Component = cycle == "yearly" ? .year : (cycle == "weekly" ? .weekOfYear : .month)
        let stepCount = cycle == "yearly" ? 1 : (cycle == "weekly" ? 1 : 1)

        // Find the current cycle window: roll forward from start until end > now.
        // date(byAdding:) returns nil for out-of-range dates; bail out
        // instead of crashing the subscriptions list.
        guard var windowStart = Optional(startDate),
              var windowEnd = cal.date(byAdding: step, value: stepCount, to: windowStart) else { return nil }
        var guardCount = 0
        while windowEnd <= now && guardCount < 1200 {
            guard let next = cal.date(byAdding: step, value: stepCount, to: windowEnd) else { return nil }
            windowStart = windowEnd
            windowEnd = next
            guardCount += 1
        }
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
    /// - go: monthly quota % × $60 plan cap (×12 for yearly cycles)
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
        case "codex":
            // Codex Pro bills the Codex traffic; same API-list-price value.
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

    /// 订阅金额按「窗口与订阅期重叠天数 × 日均价」分摊（实际花费口径）。
    /// 已结束的订阅同样计入——它在窗口内覆盖过的天数就是你真实付过
    /// 的钱。日均价取真实周期长度（active 用 cycleInfo），已结束的
    /// 订阅无法再算周期，用 30/365 近似。
    static func amortized(days: Int, subscriptions: [Database.Subscription], now: Date = Date()) -> Double {
        var t = 0.0
        let windowStart = now.addingTimeInterval(-Double(days) * 86400)
        for sub in subscriptions {
            let start = Date(timeIntervalSince1970: TimeInterval(sub.startDate))
            let end = sub.endDate > 0 ? Date(timeIntervalSince1970: TimeInterval(sub.endDate)) : now
            let daily: Double
            if let info = cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle, now: now) {
                daily = sub.price / Double(info.totalDays)
            } else if sub.endDate > 0 {
                // Ended subscription: use its actual span so the full price
                // lands exactly when the window covers the whole period.
                let spanDays = max(end.timeIntervalSince(start) / 86400.0, 1.0)
                daily = sub.price / spanDays
            } else {
                daily = sub.price / Double(sub.cycle == "yearly" ? 365 : 30)
            }
            let overlap = min(end, now).timeIntervalSince(max(start, windowStart))
            if overlap > 0 {
                t += overlap / 86400 * daily
            }
        }
        return t
    }

    // MARK: - 用量预测（用完/用不完）

    struct Forecast {
        let used: Double          // 当前周期已用（美元，官方口径）
        let dailyRate: Double     // 日均消耗
        let limit: Double         // 额度上限（Go=$60）或余额（OR）
        let projectedEnd: Double? // 期末预测总消耗（Go；OR 为 nil）
        let exhaustDate: Date?    // 用尽/耗尽日期（nil=不会用完）
        let isBreakeven: Bool     // 价值参考线（已用价值 ≥ 订阅价）
    }

    /// 基于「已用总量 ÷ 已过天数」的日均速率外推。
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
        case "codex":
            // Codex Pro: value = Codex turns at API list prices.
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
