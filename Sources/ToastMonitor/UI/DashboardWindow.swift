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

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

/// The full surface is task-oriented rather than a collection of duplicated
/// provider pages. Tools and models are dimensions within analysis; sessions
/// are an audit view; plans are a financial context.
struct DashboardView: View {
    static let selectTab = Notification.Name("ToastMonitorDashboardSelectTab")
    @EnvironmentObject private var app: AppState
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var tab: Tab = .overview

    init(initialTab: Tab? = nil) {
        if let initialTab { _tab = State(initialValue: initialTab) }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概览"
        case analysis = "用量分析"
        case plans = "计划与余额"
        case sources = "来源与设置"

        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch tab {
            case .overview: OverviewView()
            case .analysis: UsageAnalysisView()
            case .plans: PlansView()
            case .sources: SourcesAndSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TMDesign.canvas)
        .toolbar {
            // Native macOS pattern (Calendar/Activity Monitor): page switch
            // is a text-only segmented control in the toolbar (HIG: avoid
            // mixing icons and text in one control).
            ToolbarItemGroup(placement: .principal) {
                Picker("页面", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                .help("刷新数据")
                .accessibilityLabel("刷新数据")
                .accessibilityValue(app.manualRefreshing ? "刷新中" : "已准备")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTab)) { note in
            if let requested = note.object as? Tab { tab = requested }
        }
    }
}
