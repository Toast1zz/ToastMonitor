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
                    header
                    // 留白分区：不再横贯硬分割线，仅保留低对比 hairline。
                    Divider().opacity(0.25)
                    PopoverHomeView()
                    Divider().opacity(0.25)
                    footer
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(width: 400)
        // 全局数字/英文等宽（数据面板惯例）：.system(size:) 未显式指定
        // design 的 Text 继承此环境；中文没有等宽变体，自动回落系统苹方。
        .fontDesign(.monospaced)
        // Height slices (scroll body + pinned period selector) are posted as
        // notifications directly by PopoverHomeView's geometry readers —
        // SwiftUI preference propagation is unreliable across ScrollView
        // boundaries, which left the pinned slice stuck at 0 and cut the
        // bottom rows (OpenRouter) off.
        .environment(\.controlSize, .small)
        .onChange(of: showSettings) { _, open in
            NotificationCenter.default.post(
                name: PanelController.settingsVisibilityNotification,
                object: nil,
                userInfo: ["open": open]
            )
        }
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
            .help("刷新数据")
            .accessibilityLabel("刷新数据")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var status: some View {
        // 正常时右上角不占位：只有来源错误/过期才显示状态标签。
        let brokenSources = health.sources.filter { $0.error != nil }
        let staleSources = health.sources.filter { $0.error == nil && $0.isStale }
        if !brokenSources.isEmpty || !staleSources.isEmpty {
            let summary = TMHealthStatus(brokenCount: brokenSources.count,
                                         staleCount: staleSources.count,
                                         lastScan: app.lastScan)
            let detailSources = !brokenSources.isEmpty ? brokenSources : staleSources
            let detail = detailSources.map { $0.displayName }.joined(separator: "、")
            let text = detail.isEmpty ? summary.text : "\(summary.text) · \(detail)"
            TMStatusLabel(text: text, color: summary.color, symbol: summary.symbol)
                .accessibilityLabel(Text("数据源状态"))
                .accessibilityValue(Text(text))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            FooterIconButton(systemName: "power", help: "退出 ToastMonitor") {
                NSApp.terminate(nil)
            }

            FooterIconButton(systemName: "gearshape", help: "Popover 设置") {
                withAnimation(.snappy(duration: 0.25)) { showSettings = true }
            }

            Spacer()

            Button {
                WindowManager.shared.show()
                NotificationCenter.default.post(name: PanelController.hideNotification, object: nil)
            } label: {
                // Claude 风格：无图标、无边框，纯文字入口（参考 claude-statusbar
                // 的 statusLine —— 只有文字与细符号，从不使用外链箭头）。
                Text("打开主面板")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .help("打开完整面板")
            .accessibilityLabel("打开完整面板")
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
