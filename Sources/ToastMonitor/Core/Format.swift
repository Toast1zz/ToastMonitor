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
    /// Exactly three significant digits with the unit: 1.23k, 12.3M, 190M,
    /// 4.15B. Trailing zeros stay (1.00M, 20.0M) so the width barely moves
    /// as the count grows — the menu bar item is sized by this string.
    /// Rounding that reaches 1000 moves to the next unit (999.6M → 1.00B).
    /// Below 1,000 the raw count is shown.
    static func compact(_ n: Int64) -> String {
        guard n.magnitude >= 1_000 else { return "\(n)" }
        let units: [(suffix: String, scale: Double)] = [
            ("k", 1e3), ("M", 1e6), ("B", 1e9), ("T", 1e12),
        ]
        let magnitude = Double(n.magnitude)
        var index = units.lastIndex { magnitude >= $0.scale } ?? 0
        let sign = n < 0 ? "-" : ""
        while true {
            let value = magnitude / units[index].scale
            for decimals in [2, 1, 0] {
                let factor = pow(10, Double(decimals))
                let rounded = (value * factor).rounded() / factor
                // Three digits: below 10 with two decimals, below 100 with
                // one, below 1000 with none.
                if rounded < pow(10, Double(3 - decimals)) {
                    return sign + String(format: "%.\(decimals)f", rounded) + units[index].suffix
                }
            }
            guard index + 1 < units.count else {
                return sign + String(format: "%.0f", value.rounded()) + units[index].suffix
            }
            index += 1
        }
    }

    /// Full number with grouping: 1,234,567. en_US_POSIX keeps the
    /// separators independent of the system locale.
    static let fullFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// NumberFormatter is not thread-safe and money/full are called from both
    /// the query worker queue and the main thread — serialize all access.
    private static let formatterLock = NSLock()

    static func full(_ n: Int64) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return fullFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Whole-dollar amounts with grouping ($173,564; $123.45 keeps cents).
    private static let moneyWholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func moneyWholeString(_ v: Double) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return moneyWholeFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
    }

    /// Money in USD with adaptive precision. Non-finite values render as
    /// $0.00 (never "nan"); negatives format normally with a leading "-".
    static func money(_ v: Double) -> String {
        guard v.isFinite else { return "$0.00" }
        if v == 0 { return "$0.00" }
        if v < 0 { return "-" + money(-v) }
        if v >= 100 { return "$" + moneyWholeString(v) }
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

    /// yyyymmdd key -> "2026-08-05". Not day(_:), which formats a Unix
    /// timestamp and would read the key as seconds since 1970.
    static func dayKeyString(_ key: Int64) -> String {
        let y = Int(key) / 10_000
        let m = (Int(key) / 100) % 100
        let d = Int(key) % 100
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// yyyymmdd key -> English short date "Aug 5", regardless of the
    /// system locale.
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
    /// Count abbreviation (1.2k / 34), same units as compact.
    /// An estimated figure, never to be read as a measured one.
    static func approximate(_ n: Int64) -> String {
        "≈" + compact(n)
    }

    static func count(_ n: Int64) -> String {
        compact(n)
    }

    /// Relative remaining time: "2.1h" / "45m" / "3d".
    static func remaining(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        if s >= 86400 { return String(format: "%.1fd", Double(s) / 86400) }
        if s >= 3600 { return String(format: "%.1fh", Double(s) / 3600) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// File size, human units ("128 KB", "3.4 MB") — for backup listings.
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Reset countdown: "3d 2h" / "1h 5m" / "in 45m".
    static func countdown(_ secs: Int64) -> String {
        if secs <= 0 { return "resetting soon" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "in \(m)m"
    }
}
