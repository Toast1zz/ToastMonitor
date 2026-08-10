import SwiftUI
import AppKit

/// Cross-surface notification names (foreground state, tab selection).
/// Defined at top level so non-main-actor code can reference them.
enum TMNotifications {
    static let popoverVisibility = Notification.Name("tmPopoverVisibility")
    static let dashboardVisibility = Notification.Name("tmDashboardVisibility")
}

/// Shared visual language for the menu bar surface and the dashboard.
///
/// The app intentionally avoids a web-style card stack. macOS already gives us
/// a strong window/material hierarchy, so the UI uses quiet surfaces, hairline
/// dividers, aligned numbers and a single warm accent instead.
enum TMDesign {
    // Palette rule: at most three families — one product accent, one danger
    // red for anomalies, and neutral grays. Tool/model distinction uses
    // lightness layers of the accent (accentShade), never extra hues.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        // 深色分支浅化：popover 现在永远深色玻璃，原 0.78/0.32/0.16 在
        // 深底上偏暗。同色相提亮（暖橙 → 亮铜橙），保持品牌色族。
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.92, green: 0.51, blue: 0.30, alpha: 1)
        }
        return NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.16, alpha: 1)
    })
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.92, green: 0.51, blue: 0.30, alpha: 0.16)
        }
        return NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.16, alpha: 0.12)
    })
    static let accentWash = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.92, green: 0.51, blue: 0.30, alpha: 0.08)
        }
        return NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.16, alpha: 0.06)
    })
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let secondaryCanvas = Color(nsColor: .underPageBackgroundColor)
    /// Card surface. The system controlBackgroundColor barely separates from
    /// windowBackground in dark mode (30 vs 38), which makes panels read as
    /// invisible boxes; dark mode gets a custom lift instead.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0.165, alpha: 1.0)
        }
        return NSColor.controlBackgroundColor
    })
    static let divider = Color.primary.opacity(0.13)
    static let quiet = Color.primary.opacity(0.58)
    static let faint = Color.primary.opacity(0.36)
    static let radius: CGFloat = 12

    /// The one semantic color: anomalies/danger. Dark mode uses a bright
    /// coral-red (WCAG: lightened reds read on dark/glass backgrounds; pure
    /// saturated red fails even when it looks bright). Critical status text
    /// also gets a filled capsule behind it (see TMStatusCapsule) so it
    /// stays legible over any backdrop, e.g. a black terminal behind the
    /// popover.
    static let danger = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.58, alpha: 1)
        }
        return NSColor(calibratedRed: 0.78, green: 0.24, blue: 0.27, alpha: 1)
    })
    /// Filled background for critical status text (readable on any backdrop).
    static let dangerFill = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.42, green: 0.10, blue: 0.12, alpha: 1)
        }
        return NSColor(calibratedRed: 0.94, green: 0.86, blue: 0.86, alpha: 1)
    })

    /// Brand hues share one saturation/brightness family so multi-product
    /// pages stay harmonious in both appearances.
    static func toolColor(hue: CGFloat, sat: CGFloat, bri: CGFloat) -> Color {
        Color(nsColor: NSColor(calibratedHue: hue / 360, saturation: sat, brightness: bri, alpha: 1))
    }

    /// Model category palette: evenly spaced hues, unified mid-lightness
    /// (same approach as OpenRouter's usage page). One model always maps to
    /// the same color across chart, legend and table.
    static let modelPalette: [Color] = [
        Color(red: 0.93, green: 0.55, blue: 0.30),   // orange
        Color(red: 0.88, green: 0.73, blue: 0.28),   // yellow
        Color(red: 0.32, green: 0.72, blue: 0.50),   // green
        Color(red: 0.25, green: 0.66, blue: 0.63),   // teal
        Color(red: 0.35, green: 0.55, blue: 0.88),   // blue
        Color(red: 0.63, green: 0.47, blue: 0.86),   // violet
        Color(red: 0.88, green: 0.45, blue: 0.60),   // pink
        Color(red: 0.60, green: 0.63, blue: 0.68),   // gray
    ]

    /// Accent lightness layers for distinguishing sources/models without
    /// adding hues: 0 = pure accent, 1 = strongly lightened.
    static func accentShade(_ fraction: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let base = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.92, green: 0.51, blue: 0.30, alpha: 1)
                : NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.16, alpha: 1)
            let f = min(max(fraction, 0), 1)
            return base.blended(withFraction: f * 0.55, of: .white) ?? base
        })
    }

    /// Normal states are neutral; only anomalies get color (danger), and
    /// stale attention gets the accent.
    static func statusColor(isError: Bool, isStale: Bool) -> Color {
        if isError { return danger }
        if isStale { return accent }
        return quiet
    }
}

/// 月份轴刻度：Overview 热力图与 Analysis 两个图表共用。
/// 输入按时间升序的 yyyymmdd 键（热力图取每周首键），输出
/// [(index, label)]——每个新月份的第一个位置一个刻度。一月附带两位年份，
/// 长跨度里年界可见。未来哨兵 0 等非日期键由调用方过滤，不进本函数。
enum MonthAxis {
    static let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func ticks(days: [Int64]) -> [(index: Int, label: String)] {
        var out: [(Int, String)] = []
        var lastMonth = -1
        var lastYear = -1
        for (i, d) in days.enumerated() {
            let year = Int(d) / 10_000
            let month = (Int(d) / 100) % 100
            guard month != lastMonth || year != lastYear else { continue }
            out.append((i, month == 1 ? String(format: "Jan '%02d", year % 100) : names[month - 1]))
            lastMonth = month
            lastYear = year
        }
        return out
    }
}

/// Shared wording and iconography for aggregate source freshness.
enum TMHealthStatus {
    case failed(Int)
    case stale(Int)
    case synced
    case waiting

    init(brokenCount: Int, staleCount: Int, lastScan: Int64) {
        if brokenCount > 0 {
            self = .failed(brokenCount)
        } else if staleCount > 0 {
            self = .stale(staleCount)
        } else if lastScan > 0 {
            self = .synced
        } else {
            self = .waiting
        }
    }

    var text: String {
        switch self {
        case .failed(let count): return "\(count) source\(count == 1 ? "" : "s") error"
        case .stale(let count): return "\(count) source\(count == 1 ? "" : "s") stale"
        case .synced: return "Synced"
        case .waiting: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .failed: return TMDesign.danger
        case .stale: return TMDesign.accent
        case .synced, .waiting: return TMDesign.quiet
        }
    }

    var symbol: String {
        switch self {
        case .failed: return "exclamationmark.triangle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .synced: return "checkmark.circle.fill"
        case .waiting: return "circle.dashed"
        }
    }
}

/// Type scale for the dashboard. Data-heavy surfaces keep the floor at 10.5pt;
/// readable copy stays at 11.5pt or above.
///
/// Font rules (whole app): regular UI copy is system SF Pro only — no third-
/// party fonts, no monospaced labels. Monospaced SF Mono is reserved for the
/// brand title and optional fine-print suffixes. Every number that can change
/// on refresh (tokens, money, percents, countdowns) gets .monospacedDigit()
/// so the width never jumps.
enum TMType {
    /// Hero metric — the primary number (Popover 34pt bold 同规格).
    static let hero: CGFloat = 34
    /// Section heading inside a panel.
    static let section: CGFloat = 14
    /// Body text.
    static let body: CGFloat = 13
    /// Captions, labels, secondary info.
    static let caption: CGFloat = 11.5
    /// Micro metadata — use sparingly.
    static let micro: CGFloat = 10.5

    // MARK: - Font helpers (SF Pro family by weight)

    /// SF Pro Regular — default copy.
    static func regular(_ size: CGFloat) -> Font { .system(size: size) }
    /// SF Pro Medium — names, controls, section labels.
    static func medium(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    /// SF Pro Semibold — section titles, emphasized numbers.
    static func semibold(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    /// SF Pro Bold — the single hero figure.
    static func bold(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    /// SF Mono Regular — fine-print suffixes (e.g. "resets in …").
    static func monoRegular(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

/// 板块标题（Quota / Activity / Overview 等）：全大写 + 小号 + 字距 + 灰，
/// 与内容行形成清晰层次。Popover 与主页面共用。
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(TMType.semibold(11))
            .kerning(0.6)
            .foregroundStyle(TMDesign.quiet)
    }
}

/// Applies .monospacedDigit() — every dynamic number (tokens, money, percents,
/// countdowns) must use it so refreshing values never shift the layout.
struct TMMonospacedDigit: ViewModifier {
    func body(content: Content) -> some View { content.monospacedDigit() }
}

extension View {
    /// Tabular numerals for dynamic figures. Not a font choice — the font
    /// stays whatever SF Pro weight the context already uses.
    func tmMonospacedDigit() -> some View { modifier(TMMonospacedDigit()) }
}

/// 板块标题（含可选右侧操作）。与 SectionTitle 同风格：全大写小号灰。
struct TMSectionHeader: View {
    let title: String
    var action: (() -> Void)?
    var actionTitle: String?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SectionTitle(title)
            Spacer(minLength: 12)
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.system(size: TMType.caption))
            }
        }
    }
}

/// 迷你指标：小标签 + 数值，Overview hero 与 Analysis 汇总条共用。
/// 标签固定 caption quiet；数值字体由调用方指定（Overview hero regular 16、
/// Analysis 汇总 semibold 16），一律 tmMonospacedDigit 防宽度跳动。
struct TMMiniMetric: View {
    let label: String
    let value: String
    let font: Font
    var spacing: CGFloat = 1
    /// 数值缩小时的最小缩放（1.0 = 不缩放）。
    var minimumScaleFactor: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(font)
                .tmMonospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(minimumScaleFactor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TMStatusPill: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(TMType.medium(TMType.caption))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }
}

struct TMPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TMDesign.divider, lineWidth: 1)
            }
    }
}

struct TMProgressBar: View {
    let value: Double
    var tint: Color = TMDesign.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityValue(Text("\(Int(min(max(value, 0), 1) * 100))%"))
    }
}

struct TMStatusLabel: View {
    let text: String
    var color: Color = TMDesign.quiet
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(color)
    }
}

extension View {
    /// A restrained elevated section for settings and service summaries.
    /// Use one surface per task group; avoid nesting these inside each other.
    /// 与 TMPanel 同规格（16pt padding、12 圆角、hairline 描边）。
    func tmPanelSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(16)
            .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TMDesign.divider, lineWidth: 1)
            }
    }
}
import SwiftUI

/// 预测状态语义 + 英文预测文案（计划页/设置页共用，避免逐字重复）。
enum ForecastText {
    enum Status { case ok, warn, danger, neutral }

    /// English forecast line for a subscription.
    static func line(for fc: SubscriptionMath.Forecast, plan: String) -> (text: String, status: Status) {
        switch plan {
        case "go":
            if let exhaust = fc.exhaustDate {
                return ("\(Format.money(fc.used)) used · exhausts \(Format.day(Int64(exhaust.timeIntervalSince1970)))", .warn)
            }
            let remaining = max(fc.limit - (fc.projectedEnd ?? 0), 0)
            return ("\(Format.money(fc.used)) used · \(Format.money(fc.dailyRate))/day · \(Format.money(remaining)) left at cycle end", .ok)
        case "openrouter":
            if let exhaust = fc.exhaustDate {
                return ("Balance \(Format.money(fc.limit)) · ~empty \(Format.day(Int64(exhaust.timeIntervalSince1970)))", .warn)
            }
            return ("Balance \(Format.money(fc.limit)) · \(Format.money(fc.dailyRate))/day", .ok)
        case "claude":
            return ("Claude value \(Format.money(fc.used)) · \(Format.money(fc.dailyRate))/day", .ok)
        default:
            return ("Paid \(Format.money(fc.used)) · no usage source linked", .neutral)
        }
    }

    static func color(_ status: Status) -> Color {
        switch status {
        case .ok: return TMDesign.quiet
        case .warn: return TMDesign.accent
        case .danger: return TMDesign.danger
        case .neutral: return .secondary
        }
    }
}
