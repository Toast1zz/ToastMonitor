import SwiftUI
import AppKit

enum TMLayout {
    static let popoverWidth: CGFloat = 400
    static let popoverHorizontalPadding: CGFloat = 20
    static let popoverContentWidth = popoverWidth - 2 * popoverHorizontalPadding
    /// Popover section cards: outer inset from the panel edge, inner padding.
    static let popoverCardInset: CGFloat = 12
    static let popoverCardPadding: CGFloat = 12
    static let popoverCardContentWidth = popoverWidth - 2 * (popoverCardInset + popoverCardPadding)
    static let quotaPrimaryLineHeight: CGFloat = 16
    static let quotaSecondaryLineHeight: CGFloat = 13
}

/// Cross-surface notification names (foreground state, tab selection).
/// Defined at top level so non-main-actor code can reference them.
enum TMNotifications {
    static let popoverVisibility = Notification.Name("tmPopoverVisibility")
    static let dashboardVisibility = Notification.Name("tmDashboardVisibility")
    static let usagePeriodSettingsChanged = Notification.Name("tmUsagePeriodSettingsChanged")
}

/// Shared refresh cadence. Foreground values preserve the existing live UI
/// behavior; background values keep the menu-bar state current without
/// polling at the same cadence when no panel is visible.
enum TMRefreshPolicy {
    static let foregroundSnapshotInterval: TimeInterval = 5
    static let backgroundSnapshotInterval: TimeInterval = 30
    static let foregroundQuotaInterval: TimeInterval = 60
    static let backgroundQuotaInterval: TimeInterval = 5 * 60

    static func snapshotInterval(foreground: Bool) -> TimeInterval {
        foreground ? foregroundSnapshotInterval : backgroundSnapshotInterval
    }

    static func quotaInterval(foreground: Bool) -> TimeInterval {
        foreground ? foregroundQuotaInterval : backgroundQuotaInterval
    }
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
    /// Card surface: one tonal step off the window background, opaque so a
    /// pinned list header can sit on it. The system controlBackgroundColor
    /// is no use here — in dark mode it barely separates from the window,
    /// and in light mode it is the same white as the window, so cards
    /// vanished entirely.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0.165, alpha: 1.0)
        }
        return NSColor(calibratedWhite: 0.955, alpha: 1.0)
    })
    static let divider = Color.primary.opacity(0.13)
    // System label colors, not fixed opacities: they follow Increase
    // Contrast and the vibrancy of the popover's material.
    static let quiet = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let radius: CGFloat = 12

    /// The one semantic color: anomalies/danger (quota past 80%, errors).
    /// The system red, which Apple tunes for light, dark and Increase
    /// Contrast; the earlier custom coral read as pink in dark mode rather
    /// than as a warning.
    static let danger = Color(nsColor: .systemRed)
    static let dangerFill = Color(nsColor: .systemRed).opacity(0.16)
    /// A usage window close to its limit. Orange is the system's warning
    /// color; red stays for errors and windows that are nearly exhausted.
    static let warning = Color(nsColor: .systemOrange)
    /// Command Code's brand is monochrome and it is not a usage source, so
    /// it gets a system color no source uses.
    static let commandCode = Color(nsColor: .systemBrown)

    /// A brand color from its hex value, with an optional dark-appearance
    /// variant for brands that specify one.
    static func brand(_ light: UInt32, dark: UInt32? = nil) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        guard let dark else { return Color(nsColor: color(light)) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }

    /// Model category palette: evenly spaced hues, unified mid-lightness
    /// (same approach as OpenRouter's usage page). One model always maps to
    /// the same color across chart, legend and table.
    static let modelPalette: [Color] = [
        adaptiveModelColor(light: (0.78, 0.36, 0.12), dark: (0.98, 0.62, 0.34)),
        adaptiveModelColor(light: (0.66, 0.50, 0.08), dark: (0.94, 0.78, 0.32)),
        adaptiveModelColor(light: (0.16, 0.56, 0.32), dark: (0.38, 0.78, 0.54)),
        adaptiveModelColor(light: (0.10, 0.52, 0.50), dark: (0.30, 0.73, 0.70)),
        adaptiveModelColor(light: (0.18, 0.42, 0.76), dark: (0.42, 0.64, 0.96)),
        adaptiveModelColor(light: (0.49, 0.30, 0.72), dark: (0.70, 0.55, 0.94)),
        adaptiveModelColor(light: (0.70, 0.25, 0.45), dark: (0.94, 0.50, 0.67)),
        adaptiveModelColor(light: (0.40, 0.43, 0.48), dark: (0.68, 0.71, 0.76)),
    ]

    private static func adaptiveModelColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

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
/// Font rules (whole app): UI copy is system SF Pro only — no third-party
/// fonts, no monospaced labels. Every number that can change
/// on refresh (tokens, money, percents, countdowns) gets .monospacedDigit()
/// so the width never jumps.
enum TMType {
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
    /// SF Pro with tabular digits — numbers that should not jitter in width
    /// but also should not switch typeface mid-sentence (Popover copy).
    static func number(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
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

    /// Counting transition for a hero figure. macOS 14+ takes the value so the
    /// digits roll in the direction the number actually moved; Ventura only has
    /// the value-less form, which still animates but without that direction.
    @ViewBuilder
    func tmNumericTextTransition(value: Double) -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText(value: value))
        } else {
            contentTransition(.numericText())
        }
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

struct TMStatusCapsule: View {
    let text: String
    var compact = false

    var body: some View {
        Label(text, systemImage: "exclamationmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: compact ? TMType.micro : TMType.caption,
                          weight: .medium, design: .monospaced))
            .foregroundStyle(TMDesign.danger)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background(TMDesign.dangerFill, in: Capsule(style: .continuous))
            .accessibilityLabel("Critical: \(text)")
    }
}

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

extension View {
    /// Liquid Glass button on macOS 26+, the same shapes as bordered buttons
    /// on 14–15. `extraLarge` matches the height of an extra-large segmented
    /// control so both can share one row.
    @ViewBuilder
    func tmGlassButton(circle: Bool, extraLarge: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if extraLarge {
                buttonStyle(.glass)
                    .buttonBorderShape(circle ? .circle : .capsule)
                    .controlSize(.extraLarge)
            } else {
                buttonStyle(.glass)
                    .buttonBorderShape(circle ? .circle : .capsule)
            }
        } else if #available(macOS 14.0, *) {
            buttonStyle(.bordered)
                .buttonBorderShape(circle ? .circle : .capsule)
        } else {
            buttonStyle(.bordered)
        }
    }
}
