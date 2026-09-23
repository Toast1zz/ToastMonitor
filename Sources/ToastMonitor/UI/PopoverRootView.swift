import SwiftUI
import AppKit

/// The menu bar surface is deliberately a single decision surface. Detailed
/// tools, sessions and settings belong to the dashboard, not to a tiny window
/// opened for a quick glance.
struct PopoverRootView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var health = SourceHealthHub.shared

    var body: some View {
        VStack(spacing: 0) {
            fixedSlice(.header) {
                header
            }
            PopoverHomeView()
            fixedSlice(.footer) {
                VStack(spacing: 0) {
                    Divider().opacity(0.25)
                    footer
                }
            }
        }
        .frame(width: TMLayout.popoverWidth)
        // NSHostingView otherwise centers an intrinsic-height root while the
        // AppKit panel is resizing. Fill the host and keep the entire page
        // pinned to the menu-bar edge so extra height is revealed downward.
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.controlSize, .small)
        .onPreferenceChange(PopoverHeightPreferenceKey.self) { measurements in
            guard let naturalHeight = measurements.naturalHeight else { return }
            onNaturalHeightChange(naturalHeight)
        }
    }

    @Environment(\.popoverNaturalHeightChange) private var onNaturalHeightChange

    private func fixedSlice<Content: View>(_ slice: PopoverHeightSlice,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(slice)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("ToastMonitor")
                .font(.headline.weight(.semibold))
            Spacer()
            status
            Button(action: refresh) {
                if app.manualRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(app.manualRefreshing)
            .help("Refresh data")
            .accessibilityLabel("Refresh data")
        }
        // Title shares the card edge with the hero figure below it.
        .padding(.horizontal, TMLayout.popoverCardInset + 2)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var status: some View {
        // 正常时右上角不占位：只有来源错误/过期才显示状态标签。
        let brokenSources = health.sources.filter { $0.error != nil }
        let staleSources = health.sources.filter { $0.error == nil && $0.isStale }
        if !brokenSources.isEmpty || !staleSources.isEmpty {
            let count = brokenSources.count + staleSources.count
            let word = brokenSources.isEmpty ? "stale" : "error"
            let prefix = "\(count) source\(count == 1 ? "" : "s") \(word)"
            let detailSources = !brokenSources.isEmpty ? brokenSources : staleSources
            let detail = detailSources.map { $0.displayName }.joined(separator: ", ")
            let text = detail.isEmpty ? prefix : "\(prefix) · \(detail)"
            let color = brokenSources.isEmpty ? TMDesign.accent : TMDesign.danger
            let symbol = brokenSources.isEmpty ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill"
            TMStatusLabel(text: text, color: color, symbol: symbol)
                .accessibilityLabel(Text("Source status"))
                .accessibilityValue(Text(text))
        }
    }

    /// Menu-item rows, as in the system's own menu bar extras (Wi-Fi,
    /// Sound, Battery): full-width text rows with a hover highlight and the
    /// key equivalent on the trailing edge, instead of buttons on the glass.
    private var footer: some View {
        VStack(spacing: 0) {
            PopoverMenuRow("Open Dashboard") {
                WindowManager.shared.show()
                hidePanel()
            }
            PopoverMenuRow("Settings…", shortcut: "⌘,") { openSettings() }
            PopoverMenuRow("Quit ToastMonitor", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, TMLayout.popoverCardInset)
        .padding(.vertical, 6)
    }

    private func openSettings(_ pane: SettingsPane? = nil) {
        SettingsWindowController.shared.show(pane: pane)
        hidePanel()
    }

    private func hidePanel() {
        NotificationCenter.default.post(name: PanelController.hideNotification, object: nil)
    }

    private func refresh() {
        DeepSeekBillingClient.shared.refresh(force: true)
        app.refresh(manual: true)
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        CodexQuotaClient.shared.refresh()
        ClaudeQuotaClient.shared.refresh(force: true)
        HermesRemoteClient.shared.maybePoll()
    }
}


enum PopoverHeightSlice: Hashable, Sendable {
    case header
    case pinned
    case body
    case footer
}

struct PopoverHeightMeasurements: Equatable, Sendable {
    var values: [PopoverHeightSlice: CGFloat] = [:]

    var naturalHeight: CGFloat? {
        guard let header = values[.header], header > 0,
              let body = values[.body], body > 0,
              let footer = values[.footer], footer > 0,
              let pinned = values[.pinned], pinned > 0 else { return nil }
        return header + pinned + body + footer
    }
}

struct PopoverHeightPreferenceKey: PreferenceKey {
    static let defaultValue = PopoverHeightMeasurements()

    static func reduce(value: inout PopoverHeightMeasurements,
                       nextValue: () -> PopoverHeightMeasurements) {
        for (slice, height) in nextValue().values {
            value.values[slice] = max(value.values[slice] ?? 0, height)
        }
    }
}

private struct PopoverNaturalHeightChangeKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    var popoverNaturalHeightChange: @MainActor @Sendable (CGFloat) -> Void {
        get { self[PopoverNaturalHeightChangeKey.self] }
        set { self[PopoverNaturalHeightChangeKey.self] = newValue }
    }
}

/// Each slice contributes typed data to one PreferenceKey. SwiftUI completes
/// preference reduction for the whole tree before PopoverRootView emits the
/// single natural-height callback.
private struct PopoverHeightReporter: ViewModifier {
    let slice: PopoverHeightSlice

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: PopoverHeightPreferenceKey.self,
                        value: .init(values: [slice: proxy.size.height])
                    )
            }
        )
    }
}

extension View {
    func reportPopoverHeight(_ slice: PopoverHeightSlice) -> some View {
        modifier(PopoverHeightReporter(slice: slice))
    }
}

/// One menu-item row of the popover footer.
private struct PopoverMenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: TMType.body))
            .padding(.horizontal, TMLayout.popoverCardPadding)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
