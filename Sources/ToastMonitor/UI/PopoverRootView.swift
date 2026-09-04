import SwiftUI
import AppKit

/// The menu bar surface is deliberately a single decision surface. Detailed
/// tools, sessions and settings belong to the dashboard, not to a tiny window
/// opened for a quick glance.
struct PopoverRootView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var health = SourceHealthHub.shared

    /// Popover 内嵌设置页（Tusi 式第二页：同一面板切换，无新窗口）。
    /// 渲染快照钩子：环境变量 TM_POPOVER_SETTINGS=1 时直接落在设置页。
    @State private var showSettings = ProcessInfo.processInfo.environment["TM_POPOVER_SETTINGS"] == "1"

    var body: some View {
        ZStack(alignment: .top) {
            if showSettings {
                PopoverSettingsView {
                    // 14+ keeps the original spring; 13 falls back to the
                    // eased curve used by the hero number transitions.
                    if #available(macOS 14.0, *) {
                        withAnimation(.snappy(duration: 0.25)) { showSettings = false }
                    } else {
                        withAnimation(.easeOut(duration: 0.35)) { showSettings = false }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
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
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(width: TMLayout.popoverWidth)
        // NSHostingView otherwise centers an intrinsic-height root while the
        // AppKit panel is resizing. Fill the host and keep the entire page
        // pinned to the menu-bar edge so extra height is revealed downward.
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.controlSize, .small)
        .onPreferenceChange(PopoverHeightPreferenceKey.self) { pages in
            let page: PopoverPage = showSettings ? .settings : .home
            guard let naturalHeight = pages[page]?.naturalHeight(for: page) else { return }
            onNaturalHeightChange(naturalHeight)
        }
        .onChange(of: showSettings) { open in
            NotificationCenter.default.post(
                name: PanelController.settingsVisibilityNotification,
                object: nil,
                userInfo: ["open": open]
            )
        }
    }

    @Environment(\.popoverNaturalHeightChange) private var onNaturalHeightChange

    private func fixedSlice<Content: View>(_ slice: PopoverHeightSlice,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(slice, page: .home)
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
        .padding(.horizontal, 20)
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

    private var footer: some View {
        HStack(spacing: 12) {
            FooterIconButton(systemName: "power", help: "Quit ToastMonitor") {
                NSApp.terminate(nil)
            }

            FooterIconButton(systemName: "gearshape", help: "Popover Settings") {
                if #available(macOS 14.0, *) {
                    withAnimation(.snappy(duration: 0.25)) { showSettings = true }
                } else {
                    withAnimation(.easeOut(duration: 0.35)) { showSettings = true }
                }
            }

            Spacer()

            Button {
                WindowManager.shared.show()
                NotificationCenter.default.post(name: PanelController.hideNotification, object: nil)
            } label: {
                // Claude 风格：无图标、无边框，纯文字入口（参考 claude-statusbar
                // 的 statusLine —— 只有文字与细符号，从不使用外链箭头）。
                Text("Open Dashboard")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .help("Open the full dashboard")
            .accessibilityLabel("Open the full dashboard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func refresh() {
        app.refresh(manual: true)
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        CodexQuotaClient.shared.refresh()
        ClaudeQuotaClient.shared.refresh(force: true)
        HermesRemoteClient.shared.maybePoll()
    }
}

enum PopoverPage: Hashable, Sendable {
    case home
    case settings
}

enum PopoverHeightSlice: Hashable, Sendable {
    case header
    case pinned
    case body
    case footer
}

struct PopoverHeightMeasurements: Equatable, Sendable {
    var values: [PopoverHeightSlice: CGFloat] = [:]

    func naturalHeight(for page: PopoverPage) -> CGFloat? {
        guard let header = values[.header], header > 0,
              let body = values[.body], body > 0,
              let footer = values[.footer], footer > 0 else { return nil }
        if page == .settings { return header + body + footer }
        guard let pinned = values[.pinned], pinned > 0 else { return nil }
        return header + pinned + body + footer
    }
}

struct PopoverHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [PopoverPage: PopoverHeightMeasurements] = [:]

    static func reduce(value: inout [PopoverPage: PopoverHeightMeasurements],
                       nextValue: () -> [PopoverPage: PopoverHeightMeasurements]) {
        for (page, incoming) in nextValue() {
            var measurements = value[page] ?? .init()
            for (slice, height) in incoming.values {
                measurements.values[slice] = max(measurements.values[slice] ?? 0, height)
            }
            value[page] = measurements
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
/// page's single natural-height callback.
private struct PopoverHeightReporter: ViewModifier {
    let slice: PopoverHeightSlice
    let page: PopoverPage

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: PopoverHeightPreferenceKey.self,
                        value: [page: .init(values: [slice: proxy.size.height])]
                    )
            }
        )
    }
}

extension View {
    func reportPopoverHeight(_ slice: PopoverHeightSlice, page: PopoverPage) -> some View {
        modifier(PopoverHeightReporter(slice: slice, page: page))
    }
}


/// 底部工具栏图标按钮：静止无装饰，hover 轻填充。
private struct FooterIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.07) : .clear)
                )
                .contentShape(Rectangle())
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: pressed)
                .onHover { hovering = $0 }
        }
        .buttonStyle(.borderless)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity,
                            pressing: { pressing in pressed = pressing },
                            perform: {})
        .help(help)
        .accessibilityLabel(help)
    }
}
