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
            header
            Divider().opacity(0.7)
            PopoverHomeView()
            Divider().opacity(0.7)
            footer
        }
        .frame(width: 400)
        // Height slices (scroll body + pinned period selector) are posted as
        // notifications directly by PopoverHomeView's geometry readers —
        // SwiftUI preference propagation is unreliable across ScrollView
        // boundaries, which left the pinned slice stuck at 0 and cut the
        // bottom rows (OpenRouter) off.
        .environment(\.controlSize, .small)
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

    private var status: some View {
        let broken = health.sources.filter { $0.error != nil }.count
        let stale = health.sources.filter { $0.error == nil && $0.isStale }.count
        let color = TMDesign.statusColor(isError: broken > 0, isStale: stale > 0)
        let title: String
        let symbol: String
        if broken > 0 {
            title = "\(broken) 个来源异常"
            symbol = "exclamationmark.triangle.fill"
        } else if stale > 0 {
            title = "\(stale) 个来源过期"
            symbol = "clock.badge.exclamationmark"
        } else if app.lastScan > 0 {
            title = "数据已同步"
            symbol = "checkmark.circle.fill"
        } else {
            title = "等待首次扫描"
            symbol = "circle.dashed"
        }
        return TMStatusLabel(text: title, color: color, symbol: symbol)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.borderless)
            .help("退出 ToastMonitor")
            .accessibilityLabel("退出 ToastMonitor")

            Spacer()

            Button {
                WindowManager.shared.show()
                NSApp.keyWindow?.close()
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
