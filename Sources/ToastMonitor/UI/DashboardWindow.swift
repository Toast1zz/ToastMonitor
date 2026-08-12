import AppKit
import SwiftUI

/// Owns the dashboard window (single instance, close = hide).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?
    private var toolbarController: DashboardToolbarController?
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

        let initialTab = tab ?? .overview
        let content = NSHostingController(rootView: DashboardView(initialTab: initialTab).environmentObject(AppState.shared))
        let window = NSWindow(contentViewController: content)
        window.title = "ToastMonitor"
        // The page tabs are the centered toolbar identity. Repeating the app
        // name immediately beside them makes the native group look offset.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The regular unified toolbar lets macOS 26/27 supply its native
        // floating Liquid Glass geometry and current control height.
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 580)
        window.center()
        window.setFrameAutosaveName("ToastMonitorDashboard")
        let toolbarController = DashboardToolbarController(initialTab: initialTab)
        window.toolbar = toolbarController.toolbar
        self.toolbarController = toolbarController
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

    /// Test-only command-line capture used by the UI verification hook. The
    /// theme frame includes the titlebar and toolbar, unlike the existing
    /// off-screen DashboardView renderer.
    @discardableResult
    func captureWindow(to path: String) -> Bool {
        guard let window,
              let frameView = window.contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return false
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

}

/// A system toolbar item group. On macOS 27 the `.tabs` role is what gives
/// Activity Monitor its continuous outer glass capsule and morphing selected
/// glass island; putting an `NSSegmentedControl` in an arbitrary toolbar item
/// only produces the legacy divided bezel.
@MainActor
private final class DashboardToolbarController: NSObject, NSToolbarDelegate {
    private static let tabsIdentifier = NSToolbarItem.Identifier("ToastMonitor.DashboardTabs")
    private static let refreshIdentifier = NSToolbarItem.Identifier("ToastMonitor.Refresh")

    private var selectionObserver: NSObjectProtocol?

    private(set) lazy var tabsGroup: NSToolbarItemGroup = {
        let titles = DashboardView.Tab.allCases.map(\.rawValue)
        let group = NSToolbarItemGroup(
            itemIdentifier: Self.tabsIdentifier,
            titles: titles,
            selectionMode: .selectOne,
            labels: titles,
            target: self,
            action: #selector(selectionChanged(_:))
        )
        group.label = "Dashboard Page"
        group.paletteLabel = "Dashboard Page"
        group.isNavigational = true
        group.controlRepresentation = .expanded
        group.selectedIndex = initialTabIndex
        if #available(macOS 27.0, *) {
            group.role = .tabs
        }
        return group
    }()

    private(set) lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "ToastMonitor.DashboardToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.tabsIdentifier]
        return toolbar
    }()

    private let initialTab: DashboardView.Tab
    private var initialTabIndex: Int {
        DashboardView.Tab.allCases.firstIndex(of: initialTab) ?? 0
    }

    init(initialTab: DashboardView.Tab) {
        self.initialTab = initialTab
        super.init()
        selectionObserver = NotificationCenter.default.addObserver(
            forName: DashboardView.didSelectTab,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let tab = note.object as? DashboardView.Tab else { return }
            Task { @MainActor [weak self] in
                self?.select(tab)
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabsIdentifier, Self.refreshIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabsIdentifier, Self.refreshIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.tabsIdentifier:
            return tabsGroup
        case Self.refreshIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.paletteLabel = "Refresh"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh data")
            item.target = self
            item.action = #selector(refreshData(_:))
            item.toolTip = "Refresh data"
            return item
        default:
            return nil
        }
    }

    @objc private func selectionChanged(_ sender: NSToolbarItemGroup) {
        let tabs = DashboardView.Tab.allCases
        guard tabs.indices.contains(sender.selectedIndex) else { return }
        NotificationCenter.default.post(
            name: DashboardView.selectTab,
            object: tabs[sender.selectedIndex]
        )
    }

    @objc private func refreshData(_ sender: Any?) {
        AppState.shared.refresh(manual: true)
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        HermesRemoteClient.shared.maybePoll()
        CodexQuotaClient.shared.refresh()
    }

    private func select(_ tab: DashboardView.Tab) {
        guard let index = DashboardView.Tab.allCases.firstIndex(of: tab),
              tabsGroup.selectedIndex != index else { return }
        tabsGroup.selectedIndex = index
    }

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }
}

/// The full surface is task-oriented rather than a collection of duplicated
/// provider pages. Tools and models are dimensions within analysis; sessions
/// are an audit view; plans are a financial context.
struct DashboardView: View {
    static let selectTab = Notification.Name("ToastMonitorDashboardSelectTab")
    static let didSelectTab = Notification.Name("ToastMonitorDashboardDidSelectTab")
    @State private var tab: Tab = .overview

    init(initialTab: Tab? = nil) {
        if let initialTab { _tab = State(initialValue: initialTab) }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case analysis = "Analysis"
        case plans = "Plans"
        case settings = "Settings"

        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch tab {
            case .overview:
            OverviewView()
            case .analysis:
            UsageAnalysisView()
            case .plans:
            PlansView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TMDesign.canvas)
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTab)) { note in
            if let requested = note.object as? Tab { tab = requested }
        }
        .onAppear {
            NotificationCenter.default.post(name: Self.didSelectTab, object: tab)
        }
        .onChange(of: tab) { _, selected in
            NotificationCenter.default.post(name: Self.didSelectTab, object: selected)
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
