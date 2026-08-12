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
                    withAnimation(.snappy(duration: 0.25)) { showSettings = false }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                VStack(spacing: 0) {
                    fixedSlice(kind: "header") {
                        header
                    }
                    PopoverHomeView()
                    fixedSlice(kind: "footer") {
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
        .frame(width: 400)
        .environment(\.controlSize, .small)
        .onChange(of: showSettings) { _, open in
            NotificationCenter.default.post(
                name: PanelController.settingsVisibilityNotification,
                object: nil,
                userInfo: ["open": open]
            )
        }
    }

    private func fixedSlice<Content: View>(kind: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(kind: kind, page: "home")
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
                withAnimation(.snappy(duration: 0.25)) { showSettings = true }
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
        HermesRemoteClient.shared.maybePoll()
    }
}

/// Reports a view's natural vertical size without introducing another
/// material or background layer. A preference is ideal inside SwiftUI; the
/// final notification is emitted once, at the root of this modifier.
private struct PopoverHeightReporter: ViewModifier {
    let kind: String
    let page: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { post(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in post(height) }
            }
        )
    }

    private func post(_ height: CGFloat) {
        guard height > 0 else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: PanelController.contentHeightNotification,
                object: nil,
                userInfo: ["kind": kind, "page": page, "height": height]
            )
        }
    }
}

extension View {
    func reportPopoverHeight(kind: String, page: String) -> some View {
        modifier(PopoverHeightReporter(kind: kind, page: page))
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
