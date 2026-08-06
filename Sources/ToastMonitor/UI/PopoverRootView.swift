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

    /// Panel height = scroll body + pinned selector + fixed chrome
    /// (header ~46 + dividers ~4 + footer ~58 ≈ 108). Kept for reference.
    static let panelChromeHeight: CGFloat = 108

    private var header: some View {
        HStack(spacing: 10) {
            Text("ToastMonitor")
                .font(.headline.weight(.semibold))
            Spacer()
            status
            Button(action: refresh) {
                if app.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(app.isRefreshing)
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
            title = "\(broken) 个异常"
            symbol = "exclamationmark.triangle.fill"
        } else if stale > 0 {
            title = "\(stale) 个过期"
            symbol = "clock.badge.exclamationmark"
        } else if app.lastScan > 0 {
            title = "已同步"
            symbol = "checkmark.circle.fill"
        } else {
            title = "等待同步"
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
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("打开完整面板")
            .accessibilityLabel("打开完整面板")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func refresh() {
        app.refresh()
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        HermesRemoteClient.shared.maybePoll()
    }
}
