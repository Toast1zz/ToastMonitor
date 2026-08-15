import AppKit
import CoreServices
import SwiftUI

/// Owns the dashboard window (single instance, close = hide).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?
    private var toolbarController: DashboardToolbarController?
    private var pageController: DashboardPageController?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    static let visibilityNotification = TMNotifications.dashboardVisibility

    /// The dashboard is a visible app window, so opening it promotes the app
    /// to a regular (Dock) application; closing or hiding demotes back to a
    /// menu-bar accessory. Guarding on the current policy makes repeated
    /// show/hide cheap and avoids AppKit policy churn.
    private func setDockPresence(_ visible: Bool) {
        let target: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        if visible {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
            // Demoting is asynchronous on some macOS versions; without this
            // the app icon can linger in the app switcher for a second or two.
            // Hiding with no visible windows is a no-op for the menu-bar
            // surface but forces the switcher to drop us now.
            NSApp.hide(nil)
            // The Dock's "Recent applications" list (right-click Dock →
            // Recent Applications) records any app that ran as a regular
            // application; demoting to .accessory does NOT clear that record,
            // so closing the dashboard removes it explicitly.
            removeSelfFromDockRecents()
        }
    }

    /// Removes this app from the Dock's "Recent applications" list via the
    /// public LaunchServices API (kLSSharedFileListRecentApplicationItems).
    /// The Dock persists that record independently of the activation policy,
    /// so the app must clean it up itself when the dashboard closes.
    private func removeSelfFromDockRecents() {
        let recentKey = kLSSharedFileListRecentApplicationItems.takeRetainedValue()
        guard let list = LSSharedFileListCreate(nil, recentKey, nil)?.takeRetainedValue(),
              let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue()
        else { return }
        let items = snapshot as? [LSSharedFileListItem] ?? []
        let myPath = Bundle.main.bundleURL.standardizedFileURL.path
        for item in items {
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(
                item, 0, &error)?.takeRetainedValue() else { continue }
            let itemPath = (resolved as URL).standardizedFileURL.path
            guard itemPath == myPath else { continue }
            LSSharedFileListItemRemove(list, item)
        }
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            setDockPresence(false)
            NotificationCenter.default.post(name: Self.visibilityNotification, object: false)
        } else {
            show()
        }
    }

    func show(tab: DashboardView.Tab? = nil) {
        setDockPresence(true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
            if let tab {
                pageController?.select(tab)
                toolbarController?.select(tab)
            }
            return
        }

        let initialTab = tab ?? .overview
        let pageController = DashboardPageController(initialTab: initialTab)
        let window = NSWindow(contentViewController: pageController)
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
        // Build and lay out all four pages before the window appears. This
        // moves each SwiftUI page's one-time construction cost out of toolbar
        // clicks, so the native tab island never shares a frame with Charts,
        // forms or the annual activity grid being initialized.
        pageController.prepareAllPages()
        let toolbarController = DashboardToolbarController(initialTab: initialTab) {
            [weak pageController] tab in
            pageController?.select(tab)
        }
        pageController.selectionDidChange = { [weak toolbarController] tab in
            toolbarController?.select(tab)
        }
        window.toolbar = toolbarController.toolbar
        self.toolbarController = toolbarController
        self.pageController = pageController
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
            self.setDockPresence(false)
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

    /// Hermetic performance hook: drive the same notification path as the
    /// toolbar, then force AppKit/SwiftUI to finish layout and drawing. This
    /// measures the main-thread work that can block the native tab animation.
    func benchmarkSwitch(to tab: DashboardView.Tab) -> TimeInterval? {
        guard let window, let contentView = window.contentView,
              let pageController else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        pageController.select(tab)
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        return CFAbsoluteTimeGetCurrent() - start
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

    private var selectionGeneration = 0
    private let selectionHandler: (DashboardView.Tab) -> Void

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

    init(initialTab: DashboardView.Tab,
         selectionHandler: @escaping (DashboardView.Tab) -> Void) {
        self.initialTab = initialTab
        self.selectionHandler = selectionHandler
        super.init()
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
        let selected = tabs[sender.selectedIndex]
        selectionGeneration += 1
        let generation = selectionGeneration

        // Let AppKit commit the native tab island's selection transaction
        // before SwiftUI tears down and builds a whole dashboard page. Doing
        // both inside the toolbar action blocked the first frames of the
        // Liquid Glass animation even on fast Apple silicon.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionGeneration == generation else { return }
            self.selectionHandler(selected)
        }
    }

    @objc private func refreshData(_ sender: Any?) {
        AppState.shared.refresh(manual: true)
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        HermesRemoteClient.shared.maybePoll()
        CodexQuotaClient.shared.refresh()
    }

    func select(_ tab: DashboardView.Tab) {
        guard let index = DashboardView.Tab.allCases.firstIndex(of: tab),
              tabsGroup.selectedIndex != index else { return }
        tabsGroup.selectedIndex = index
    }
}

/// Normal dashboard windows keep one mounted hosting controller per page.
/// Switching changes visibility only; it never reconstructs or reattaches a
/// large SwiftUI tree inside the toolbar's click event.
@MainActor
private final class DashboardPageController: NSViewController {
    private let initialTab: DashboardView.Tab
    private var selectedTab: DashboardView.Tab
    private var hosts: [DashboardView.Tab: NSViewController] = [:]
    private weak var visibleHost: NSViewController?
    private var keyMonitor: Any?
    var selectionDidChange: ((DashboardView.Tab) -> Void)?

    init(initialTab: DashboardView.Tab) {
        self.initialTab = initialTab
        self.selectedTab = initialTab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        attach(initialTab)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.window == self.view.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let raw = event.charactersIgnoringModifiers,
                  let number = Int(raw), (1...DashboardView.Tab.allCases.count).contains(number)
            else { return event }
            let tab = DashboardView.Tab.allCases[number - 1]
            self.select(tab)
            return nil
        }
    }

    func select(_ tab: DashboardView.Tab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        show(tab)
        selectionDidChange?(tab)
    }

    private func attach(_ tab: DashboardView.Tab) {
        let next = host(for: tab)
        install(next)
        next.view.isHidden = false
        visibleHost = next
    }

    private func show(_ tab: DashboardView.Tab) {
        let next = host(for: tab)
        install(next)
        guard visibleHost !== next else { return }
        visibleHost?.view.isHidden = true
        next.view.isHidden = false
        visibleHost = next
    }

    private func install(_ controller: NSViewController) {
        guard controller.parent !== self else { return }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        controller.view.isHidden = true
        view.addSubview(controller.view)
    }

    private func host(for tab: DashboardView.Tab) -> NSViewController {
        if let existing = hosts[tab] { return existing }
        let page: AnyView
        switch tab {
        case .overview:
            page = AnyView(OverviewView().environmentObject(AppState.shared))
        case .analysis:
            page = AnyView(UsageAnalysisView().environmentObject(AppState.shared))
        case .plans:
            page = AnyView(PlansView().environmentObject(AppState.shared))
        case .settings:
            page = AnyView(SettingsView().environmentObject(AppState.shared))
        }
        let host = NSHostingController(rootView: page)
        hosts[tab] = host
        return host
    }

    func prepareAllPages() {
        view.layoutSubtreeIfNeeded()
        for tab in DashboardView.Tab.allCases {
            let controller = host(for: tab)
            install(controller)
            controller.view.frame = view.bounds
            controller.view.layoutSubtreeIfNeeded()
        }
        visibleHost?.view.isHidden = false
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
            guard let requested = note.object as? Tab, requested != tab else { return }
            // The toolbar owns the polished native selection animation. Page
            // replacement must not inherit unrelated chart/control animations
            // and attempt to animate an entire, structurally different tree.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { tab = requested }
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
