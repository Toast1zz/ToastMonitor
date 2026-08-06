import Foundation

/// Compact human formatting for tokens and money.
enum Format {
    /// 1234 -> "1.2k", 1234567 -> "1.2M", 123 -> "123" (k/M only)
    static func compact(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fk", d / 1_000) }
        return "\(n)"
    }

    /// Money in USD with adaptive precision.
    static func money(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v >= 100 { return String(format: "$%.0f", v) }
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

    /// "2026-08-05 14:23"
    static func dateTime(_ ts: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    static func day(_ ts: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 1.2k / 34 这类计数缩写。
    static func count(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// 相对剩余时间: "2.1h" / "45m" / "3d"。
    static func remaining(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        if s >= 86400 { return String(format: "%.1fd", Double(s) / 86400) }
        if s >= 3600 { return String(format: "%.1fh", Double(s) / 3600) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
