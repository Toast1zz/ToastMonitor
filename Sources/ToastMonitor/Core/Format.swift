import Foundation

/// Compact human formatting for tokens and money.
enum Format {
    private final class DateFormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func string(_ date: Date, format: String) -> String {
            let timeZone = TimeZone.current
            let key = "\(timeZone.identifier)|\(format)"
            lock.lock()
            defer { lock.unlock() }
            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                let created = DateFormatter()
                created.locale = Locale(identifier: "en_US_POSIX")
                created.calendar = Calendar(identifier: .gregorian)
                created.timeZone = timeZone
                created.dateFormat = format
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }

    private static let dateFormatterCache = DateFormatterCache()

    /// Date formatters are expensive and are reused by format and chart
    /// refreshes. The time-zone identifier is part of the key so a system
    /// time-zone change cannot return strings from the old zone.
    private static func dateString(_ date: Date, format: String) -> String {
        dateFormatterCache.string(date, format: format)
    }
    /// 1234 -> "1.2k", 1.2M, 4.15B, 1.02T（B/T 用两位小数保留精度）。
    static func compact(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1_000_000_000_000 { return String(format: "%.2fT", d / 1_000_000_000_000) }
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fk", d / 1_000) }
        return "\(n)"
    }

    /// 完整数字（千分位分组）：1,234,567。流式刷新时看数字增长用。
    static let fullFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func full(_ n: Int64) -> String {
        fullFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 整数金额的千分位分组（$173,564，避免无逗号的 "$173564"）。
    private static let moneyWholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Money in USD with adaptive precision.
    static func money(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v >= 100 { return "$" + (moneyWholeFormatter.string(from: NSNumber(value: v)) ?? "\(Int(v))") }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.01 { return String(format: "$%.3f", v) }
        return String(format: "$%.4f", v)
    }

    static func moneyShort(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.01 { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    /// yyyymmdd 整数键（热力图/聚合图）→ "2026-08-05"。不要用 day(_:)——
    /// 那是 Unix 时间戳格式化，把 yyyymmdd 当秒会得到 1970 年的日期。
    static func dayKeyString(_ key: Int64) -> String {
        let y = Int(key) / 10_000
        let m = (Int(key) / 100) % 100
        let d = Int(key) % 100
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// yyyymmdd 整数键 → 英文短日期 "Aug 5"（Popover/主页面悬停统一格式，
    /// en_US_POSIX 强制英文，不受系统 locale 影响）。
    static func shortDayKey(_ key: Int64) -> String {
        var c = DateComponents()
        c.year = Int(key) / 10_000
        c.month = (Int(key) / 100) % 100
        c.day = Int(key % 100)
        guard let date = Calendar.current.date(from: c) else { return dayKeyString(key) }
        return dateFormatterCache.string(date, format: "MMM d")
    }

    /// "2026-08-05 14:23"
    static func dateTime(_ ts: Int64) -> String {
        dateString(Date(timeIntervalSince1970: TimeInterval(ts)), format: "MM-dd HH:mm")
    }

    static func day(_ ts: Int64) -> String {
        dateString(Date(timeIntervalSince1970: TimeInterval(ts)), format: "yyyy-MM-dd")
    }
    /// 1.2k / 34 这类计数缩写（与 compact 同单位体系）。
    static func count(_ n: Int64) -> String {
        compact(n)
    }

    /// 相对剩余时间: "2.1h" / "45m" / "3d"。
    static func remaining(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        if s >= 86400 { return String(format: "%.1fd", Double(s) / 86400) }
        if s >= 3600 { return String(format: "%.1fh", Double(s) / 3600) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// 重置倒计时: "3天2小时" / "45分后"（配额窗口重置）。
    static func countdown(_ secs: Int64) -> String {
        if secs <= 0 { return "即将重置" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分后"
    }
}
