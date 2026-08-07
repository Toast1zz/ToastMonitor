import SwiftUI
import AppKit

/// Shared visual language for the menu bar surface and the dashboard.
///
/// The app intentionally avoids a web-style card stack. macOS already gives us
/// a strong window/material hierarchy, so the UI uses quiet surfaces, hairline
/// dividers, aligned numbers and a single warm accent instead.
enum TMDesign {
    // Palette rule: at most three families — one product accent, one danger
    // red for anomalies, and neutral grays. Tool/model distinction uses
    // lightness layers of the accent (accentShade), never extra hues.
    static let accent = Color(red: 0.78, green: 0.32, blue: 0.16)
    static let accentSoft = Color(red: 0.78, green: 0.32, blue: 0.16).opacity(0.12)
    static let accentWash = Color(red: 0.78, green: 0.32, blue: 0.16).opacity(0.06)
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

    /// Accent lightness layers for distinguishing sources/models without
    /// adding hues: 0 = pure accent, 1 = strongly lightened.
    static func accentShade(_ fraction: Double) -> Color {
        let base = NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.16, alpha: 1)
        let f = min(max(fraction, 0), 1)
        let light = base.blended(withFraction: f * 0.55, of: .white) ?? base
        return Color(nsColor: light)
    }

    /// Normal states are neutral; only anomalies get color (danger), and
    /// stale attention gets the accent.
    static func statusColor(isError: Bool, isStale: Bool) -> Color {
        if isError { return danger }
        if isStale { return accent }
        return quiet
    }
}

/// Type scale for the dashboard. Data-heavy surfaces keep the floor at 11pt;
/// nothing below that is used for readable copy.
enum TMType {
    /// Page title (26) — one per page, in TMPageHeader.
    static let pageTitle: CGFloat = 26
    /// Hero number (40+), for the single most important figure on a page.
    static let hero: CGFloat = 40
    /// Section heading inside a panel (13).
    static let section: CGFloat = 13
    /// Body text (12.5).
    static let body: CGFloat = 12.5
    /// Captions, labels, secondary info (11).
    static let caption: CGFloat = 11
    /// Micro metadata (10) — the floor; use sparingly.
    static let micro: CGFloat = 10
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

struct TMMetric: View {
    let title: String
    let value: String
    var detail: String?
    var emphasis: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(emphasis ? .system(size: 30, weight: .semibold, design: .rounded) : .system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(TMDesign.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TMKeyValue: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(TMDesign.quiet)
            Spacer(minLength: 8)
            Text(value)
                .fontDesign(.monospaced)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .font(.subheadline)
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
        }
        .font(.caption)
        .foregroundStyle(color)
    }
}

struct TMSourceIcon: View {
    let tool: ToolKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tool.color)
            .frame(width: size, height: size)
            .background(tool.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct TMEmptyState: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(TMDesign.faint)
            Text(title)
                .font(.subheadline.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TMDesign.quiet)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

extension View {
    /// A quiet section treatment that keeps the content flat and native.
    func tmSection() -> some View {
        self
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TMDesign.divider)
                    .frame(height: 1)
            }
    }

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

    /// Uses Liquid Glass on macOS 26+ and the closest native material on
    /// earlier supported systems. It is reserved for controls, never used as
    /// a full-page card background.
    @ViewBuilder
    func tmGlassControl(cornerRadius: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Let MenuBarExtra own the one native Liquid Glass popover surface. A
    /// second glass/rounded background here creates a nested rounded panel.
    @ViewBuilder
    func tmClearPopoverContainer() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }

    /// macOS 26 used the larger Tahoe window geometry; macOS 27 tightened it
    /// to the shared 20pt presentation shape. This is the presentation's one
    /// outer radius; child content must stay un-clipped and square-edged.
    @ViewBuilder
    func tmPopoverPresentation() -> some View {
        if #available(macOS 27.0, *) {
            self.presentationCornerRadius(20)
        } else if #available(macOS 26.0, *) {
            self.presentationCornerRadius(26)
        } else {
            self
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
