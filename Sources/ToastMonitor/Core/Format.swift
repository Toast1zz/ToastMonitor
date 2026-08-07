import Foundation

/// Compact human formatting for tokens and money.
enum Format {
    /// 1234 -> "1.2k", 1.2M, 4.15B, 1.02T（B/T 用两位小数保留精度）。
    static func compact(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1_000_000_000_000 { return String(format: "%.2fT", d / 1_000_000_000_000) }
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
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

    /// yyyymmdd 整数键（热力图/聚合图）→ "2026-08-05"。不要用 day(_:)——
    /// 那是 Unix 时间戳格式化，把 yyyymmdd 当秒会得到 1970 年的日期。
    static func dayKeyString(_ key: Int64) -> String {
        let y = Int(key) / 10_000
        let m = (Int(key) / 100) % 100
        let d = Int(key) % 100
        return String(format: "%04d-%02d-%02d", y, m, d)
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

    /// 1.2k / 34 这类计数缩写（与 compact 同单位体系）。
    static func count(_ n: Int64) -> String {
        if n >= 1_000_000_000_000 { return String(format: "%.2fT", Double(n) / 1_000_000_000_000) }
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
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
