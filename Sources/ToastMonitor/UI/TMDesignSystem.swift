import SwiftUI
import AppKit

/// Shared visual language for the menu bar surface and the dashboard.
///
/// The app intentionally avoids a web-style card stack. macOS already gives us
/// a strong window/material hierarchy, so the UI uses quiet surfaces, hairline
/// dividers, aligned numbers and a single warm accent instead.
enum TMDesign {
    // One product accent. Tool colours remain reserved for attribution and
    // source identity; they should not compete with navigation and actions.
    static let accent = Color(red: 0.78, green: 0.32, blue: 0.16)
    static let accentSoft = Color(red: 0.78, green: 0.32, blue: 0.16).opacity(0.12)
    static let accentWash = Color(red: 0.78, green: 0.32, blue: 0.16).opacity(0.06)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let secondaryCanvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let divider = Color.primary.opacity(0.11)
    static let quiet = Color.primary.opacity(0.58)
    static let faint = Color.primary.opacity(0.36)
    static let radius: CGFloat = 8

    static func statusColor(isError: Bool, isStale: Bool) -> Color {
        if isError { return .red }
        if isStale { return .orange }
        return .green
    }
}

struct TMSectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?
    var actionTitle: String?

    init(_ title: String, subtitle: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(TMDesign.quiet)
                }
            }
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
    let subtitle: String
    var eyebrow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(TMDesign.accent)
            }
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(TMDesign.quiet)
        }
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
