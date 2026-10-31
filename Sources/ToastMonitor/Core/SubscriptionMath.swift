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
        return amortized(since: now.addingTimeInterval(-Double(days) * 86400),
                         subscriptions: subscriptions, now: now)
    }

    /// Same share for the time a period actually covers, so Spent matches the
    /// tokens beside it: "Weekly" on a Monday morning is a few hours, not 7 days.
    static func amortized(slot: UsagePeriodSlot, configuration: UsagePeriodConfiguration,
                          subscriptions: [Database.Subscription], now: Date = Date()) -> Double {
        // All: a 10-year window covers every subscription, ended ones included.
        if slot == .all { return amortized(days: 3650, subscriptions: subscriptions, now: now) }
        let start = configuration.range(for: slot, now: now).start
        return amortized(since: Date(timeIntervalSince1970: TimeInterval(start)),
                         subscriptions: subscriptions, now: now)
    }

    private static func amortized(since windowStart: Date, subscriptions: [Database.Subscription], now: Date) -> Double {
        guard windowStart < now else { return 0 }
        var total = 0.0
        for sub in subscriptions {
            for cycle in cycles(of: sub, overlapping: windowStart..<now) {
                let overlap = min(cycle.end, now).timeIntervalSince(max(cycle.start, windowStart))
                total += sub.price * overlap / cycle.end.timeIntervalSince(cycle.start)
            }
        }
        return total
    }

}
