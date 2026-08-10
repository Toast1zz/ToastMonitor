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
        case .failed(let count): return "\(count) 个来源错误"
        case .stale(let count): return "\(count) 个来源稍旧"
        case .synced: return "已同步"
        case .waiting: return "已停止"
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
    /// Page title (26) — one per page, in TMPageHeader.
    static let pageTitle: CGFloat = 26
    /// Hero metric — the primary number on overview.
    static let hero: CGFloat = 30
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
    /// SF Mono Semibold — brand title only.
    static func monoSemibold(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
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
            Text(title)
                .font(.system(size: TMType.section, weight: .semibold))
            Spacer(minLength: 12)
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

struct TMPageHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: TMType.pageTitle, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.top, 22)
            .padding(.bottom, 14)
    }
}

struct TMStatusPill: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
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
    func tmPanelSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(14)
            .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TMDesign.divider, lineWidth: 1)
            }
    }
}
import SwiftUI

/// 预测文案统一生成（Popover / 设置 / 计划与余额共用）。
enum ForecastText {
    enum Status { case ok, warn, danger, neutral }

    /// 主预测行 + 状态。
    static func line(for fc: SubscriptionMath.Forecast, plan: String) -> (text: String, status: Status) {
        switch plan {
        case "go":
            if let exhaust = fc.exhaustDate {
                let daysLeft = max(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                                   to: Calendar.current.startOfDay(for: exhaust)).day ?? 0, 0)
                return ("预计 \(date(exhaust)) 用尽 $60 额度 · 日均 \(Format.money(fc.dailyRate))",
                        daysLeft <= 5 ? .danger : .warn)
            }
            let remaining = max(fc.limit - (fc.projectedEnd ?? 0), 0)
            let util = fc.limit > 0 ? Int(((fc.projectedEnd ?? 0) / fc.limit) * 100) : 0
            return ("日均 \(Format.money(fc.dailyRate)) → 期末预计 \(Format.money(fc.projectedEnd ?? 0)) · 剩 \(Format.money(remaining))（利用率 \(util)%）", .ok)
        case "openrouter":
            if let exhaust = fc.exhaustDate {
                return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate)) → 约 \(date(exhaust)) 耗尽", .warn)
            }
            return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate)) · 无耗尽风险", .ok)
        case "claude":
            return ("Claude 用量价值 \(Format.money(fc.used)) · 日均 \(Format.money(fc.dailyRate)) → 期末 \(Format.money(fc.projectedEnd ?? 0))", .ok)
        default:
            return ("已付 \(Format.money(fc.used)) · 未关联用量源", .neutral)
        }
    }

    /// 紧凑单行（Popover / 设置行）。
    static func compact(for fc: SubscriptionMath.Forecast, plan: String) -> (text: String, status: Status) {
        switch plan {
        case "go":
            if let exhaust = fc.exhaustDate {
                return ("已用 \(Format.money(fc.used)) · 预计 \(date(exhaust)) 用尽", .warn)
            }
            let remaining = max(fc.limit - (fc.projectedEnd ?? 0), 0)
            return ("已用 \(Format.money(fc.used)) · 日均 \(Format.money(fc.dailyRate)) · 期末剩 \(Format.money(remaining))", .ok)
        case "openrouter":
            if let exhaust = fc.exhaustDate {
                return ("余额 \(Format.money(fc.limit)) · 约 \(date(exhaust)) 耗尽", .warn)
            }
            return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate))", .ok)
        case "claude":
            return ("Claude 价值 \(Format.money(fc.used)) · 日均 \(Format.money(fc.dailyRate))", .ok)
        default:
            return ("已付 \(Format.money(fc.used)) · 未关联用量源", .neutral)
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

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
}
