import AppKit
import SwiftUI

/// Owns the dashboard window (single instance, close = hide).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    static let visibilityNotification = TMNotifications.dashboardVisibility

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            NotificationCenter.default.post(name: Self.visibilityNotification, object: false)
        } else {
            show()
        }
    }

    func show(tab: DashboardView.Tab? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
            if let tab {
                NotificationCenter.default.post(name: DashboardView.selectTab, object: tab)
            }
            return
        }

        let content = NSHostingController(rootView: DashboardView(initialTab: tab).environmentObject(AppState.shared))
        let window = NSWindow(contentViewController: content)
        window.title = "ToastMonitor"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 580)
        window.center()
        window.setFrameAutosaveName("ToastMonitorDashboard")
        self.window = window
        // The close button (or Cmd-W) closes the window without going through
        // toggle(); without this the foreground timer keeps firing after the
        // dashboard is gone.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: TMNotifications.dashboardVisibility, object: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
    }

}

/// The full surface is task-oriented rather than a collection of duplicated
/// provider pages. Tools and models are dimensions within analysis; sessions
/// are an audit view; plans are a financial context.
struct DashboardView: View {
    static let selectTab = Notification.Name("ToastMonitorDashboardSelectTab")
    @EnvironmentObject private var app: AppState
    @State private var tab: Tab = .overview

    init(initialTab: Tab? = nil) {
        if let initialTab { _tab = State(initialValue: initialTab) }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case analysis = "Analysis"
        case plans = "Plans"
        case sources = "Sources"

        var id: String { rawValue }
    }

    var body: some View {
        // 页面常驻（ZStack + opacity）：切换标签不销毁子视图，保留查询
        // 结果、hover 状态与滚动位置；AppState 快照驱动的页面零闪烁。
        ZStack(alignment: .topLeading) {
            OverviewView()
                .opacity(tab == .overview ? 1 : 0)
                .allowsHitTesting(tab == .overview)
            UsageAnalysisView()
                .opacity(tab == .analysis ? 1 : 0)
                .allowsHitTesting(tab == .analysis)
            PlansView()
                .opacity(tab == .plans ? 1 : 0)
                .allowsHitTesting(tab == .plans)
            SourcesAndSettingsView()
                .opacity(tab == .sources ? 1 : 0)
                .allowsHitTesting(tab == .sources)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TMDesign.canvas)
        .toolbar {
            // Native macOS pattern (Calendar/Activity Monitor): page switch
            // is a text-only segmented control in the toolbar (HIG: avoid
            // mixing icons and text in one control).
            ToolbarItemGroup(placement: .principal) {
                Picker("Page", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Page")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    app.refresh(manual: true)
                    CollectorEngine.shared.scheduleScan()
                    OpenRouterClient.shared.refresh()
                    OpenCodeGoClient.shared.refresh()
                    HermesRemoteClient.shared.maybePoll()
                    CodexQuotaClient.shared.refresh()
                } label: {
                    Image(systemName: app.manualRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .symbolEffect(.pulse, isActive: app.manualRefreshing)
                .disabled(app.manualRefreshing)
                .help("Refresh data")
                .accessibilityLabel("Refresh data")
                .accessibilityValue(app.manualRefreshing ? "Refreshing" : "Ready")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTab)) { note in
            if let requested = note.object as? Tab { tab = requested }
        }
        // Cmd+1…4 快速切页（隐藏按钮注册快捷键）。
        .overlay(alignment: .bottomTrailing) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, item in
                Button("") { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .hidden()
            }
        }
    }
}
