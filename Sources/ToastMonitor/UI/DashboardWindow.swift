import AppKit
import SwiftUI

/// Owns the dashboard window (single instance, close = hide).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?

    private init() {}

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show(tab: DashboardView.Tab? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        var icon: String {
            switch self {
            case .overview: "rectangle.3.group"
            case .analysis: "chart.xyaxis.line"
            case .plans: "creditcard"
            case .sources: "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(TMDesign.canvas)
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTab)) { note in
            if let requested = note.object as? Tab { tab = requested }
        }
    }

    private var sidebar: some View {
        List(selection: $tab) {
            ForEach(Tab.allCases) { item in
                Label {
                    Text(item.rawValue)
                        .font(.system(size: TMType.body))
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundStyle(item == tab ? TMDesign.accent : TMDesign.quiet)
                }
                .tag(item)
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle("ToastMonitor")
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    private var detail: some View {
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
        .navigationTitle(tab.rawValue)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                statusToolbar
                Button {
                    app.refresh()
                    CollectorEngine.shared.scheduleScan()
                    OpenRouterClient.shared.refresh()
                    OpenCodeGoClient.shared.refresh()
                } label: {
                    Image(systemName: app.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .symbolEffect(.pulse, isActive: app.isRefreshing)
                .disabled(app.isRefreshing)
                .help("刷新数据")
            }
        }
    }

    private var statusToolbar: some View {
        let broken = health.sources.filter { $0.error != nil }.count
        let stale = health.sources.filter { $0.error == nil && $0.isStale }.count
        if broken > 0 {
            return AnyView(TMStatusLabel(text: "\(broken) 个来源异常", color: .orange, symbol: "exclamationmark.triangle.fill"))
        }
        if stale > 0 {
            return AnyView(TMStatusLabel(text: "\(stale) 个来源过期", color: .orange, symbol: "clock.badge.exclamationmark"))
        }
        return AnyView(TMStatusLabel(text: app.lastScan > 0 ? "数据已同步" : "等待首次扫描", color: app.lastScan > 0 ? .green : TMDesign.quiet, symbol: app.lastScan > 0 ? "checkmark.circle.fill" : "circle.dashed"))
    }
}
