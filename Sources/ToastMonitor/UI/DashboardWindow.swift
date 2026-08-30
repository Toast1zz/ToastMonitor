import AppKit
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

    /// Setting key: "1" (default) shows a Dock icon while the dashboard is
    /// open; "0" keeps the app a pure menu-bar accessory even then.
    static let dockIconSetting = "dock_icon_on_dashboard"

    static var dockIconEnabled: Bool {
        Database.shared.setting(dockIconSetting) ?? "1" == "1"
    }

    /// The dashboard is a visible app window, so opening it promotes the app
    /// to a regular (Dock) application; closing or hiding demotes back to a
    /// menu-bar accessory. Guarding on the current policy makes repeated
    /// show/hide cheap and avoids AppKit policy churn.
    private func setDockPresence(_ visible: Bool) {
        applyPolicy(showDock: visible && Self.dockIconEnabled)
    }

    /// Applies the Dock policy for the current window visibility and the
    /// given Dock-icon preference (the setting itself is persisted by the
    /// caller, so this never blocks on a database read).
    func applyDockIconSetting(_ enabled: Bool) {
        applyPolicy(showDock: (window?.isVisible ?? false) && enabled)
    }

    /// Re-applies the Dock policy from the current window state and setting;
    /// called when the setting changes while the dashboard is open.
    func refreshDockPresence() {
        applyPolicy(showDock: (window?.isVisible ?? false) && Self.dockIconEnabled)
    }

    private func applyPolicy(showDock: Bool) {
        // The main menu is built once and keeps Cmd+W/Cmd+Q/Edit working even
        // when the Dock icon is disabled (accessory apps get no menu bar, but
        // the menu's key equivalents still route through the app).
        ensureMainMenu()
        let target: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        if target == .regular {
            NSApp.setActivationPolicy(.regular)
        } else {
            // UI-5: NSApp.hide 会静默收起 popover 面板但不触发可见性通知。
            // 面板可见时先补发 false，否则 AppState/CollectorEngine 会带着
            // foreground=true 空转（1s 定时器、quota 客户端全在跑）。
            if PanelController.isPanelVisible {
                NotificationCenter.default.post(name: TMNotifications.popoverVisibility, object: false)
            }
            NSApp.setActivationPolicy(.accessory)
            // Demoting is asynchronous on some macOS versions; without this
            // the app icon can linger in the app switcher for a second or two.
            // Hiding with no visible windows is a no-op for the menu-bar
            // surface but forces the switcher to drop us now.
            NSApp.hide(nil)
        }
    }

    /// Builds the standard application menu once. Built at launch (not only
    /// when the dashboard opens) so its key equivalents — Cmd+V/C/X in the
    /// popover's secure fields, Cmd+W, Cmd+Q — resolve even in accessory
    /// mode where the menu bar itself is hidden.
    func ensureMainMenu() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About ToastMonitor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ToastMonitor",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ToastMonitor",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")

        // Cmd+C/V/X/A and Undo/Redo resolve through the responder chain; the
        // dashboard's SwiftUI text fields need these menu items to exist.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
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
        // .fullSizeContentView extends content under the transparent titlebar
        // so the toolbar/titlebar region shows the window's own surface
        // instead of an opaque title bar (Ventura's titlebarAppearsTransparent
        // alone leaves a solid strip otherwise).
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
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

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
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

    /// The centered group is the macOS 14+ identity (Liquid Glass on 26/27).
    /// macOS 13 crashes inside `NSToolbarView _centeredItemViewers` when a
    /// grouped item is centered (NSCalendarDate decode during layout), so
    /// Ventura gets a plain item hosting an NSSegmentedControl instead.
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

    /// macOS 13 fallback: an ungrouped item whose view is an
    /// NSSegmentedControl. The 14+ path keeps `tabsGroup`; this exists only
    /// on Ventura where centered groups crash.
    private(set) lazy var tabsItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: Self.tabsIdentifier)
        let control = NSSegmentedControl(
            labels: DashboardView.Tab.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: self,
            action: #selector(legacySelectionChanged(_:))
        )
        control.selectedSegment = initialTabIndex
        item.view = control
        item.label = "Dashboard Page"
        item.paletteLabel = "Dashboard Page"
        return item
    }()

    private(set) lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "ToastMonitor.DashboardToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        if #available(macOS 14.0, *) {
            toolbar.centeredItemIdentifiers = [Self.tabsIdentifier]
        }
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
            if #available(macOS 14.0, *) {
                return tabsGroup
            } else {
                return tabsItem
            }
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

    @objc private func legacySelectionChanged(_ sender: NSSegmentedControl) {
        let tabs = DashboardView.Tab.allCases
        guard tabs.indices.contains(sender.selectedSegment) else { return }
        selectionHandler(tabs[sender.selectedSegment])
    }

    @objc private func refreshData(_ sender: Any?) {
        AppState.shared.refresh(manual: true)
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
        HermesRemoteClient.shared.maybePoll()
        CodexQuotaClient.shared.refresh()
        ClaudeQuotaClient.shared.refresh(force: true)
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
/// The dashboard canvas is a Core Animation layer, so assigning a dynamic
/// NSColor before the view belongs to a window can freeze the wrong
/// appearance.  That is what produced the mixed state of a light toolbar over
/// a dark canvas.  Re-resolve the semantic color after AppKit has attached the
/// view and whenever the window appearance changes.
private final class DashboardRootView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBackgroundColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackgroundColor()
    }

    func refreshBackgroundColor() {
        guard wantsLayer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// Internal (not private): the --render-dashboard screenshot hook in
/// ToastMonitorApp.swift builds one off-screen so it renders through the
/// exact same page-hosting machinery the real window uses, rather than a
/// separate SwiftUI reimplementation that could visually drift from it.
@MainActor
final class DashboardPageController: NSViewController {
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
        let root = DashboardRootView()
        root.wantsLayer = true
        root.refreshBackgroundColor()
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        attach(initialTab)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.window == self.view.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  let raw = event.charactersIgnoringModifiers
            else { return event }
            // Cmd+1…4 switch pages; Cmd+W closes the window. The menu-bar
            // equivalent may not route when the Dock icon is disabled, so
            // handle Cmd+W here as a fallback.
            if let number = Int(raw),
               (1...DashboardView.Tab.allCases.count).contains(number) {
                let tab = DashboardView.Tab.allCases[number - 1]
                self.select(tab)
                return nil
            }
            if raw.lowercased() == "w" {
                self.view.window?.performClose(nil)
                return nil
            }
            return event
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
        case .sessions:
            page = AnyView(SessionsView())
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

/// Namespace for the dashboard's page enumeration. Page hosting and
/// switching (both native-toolbar-driven and Cmd+1…4) live entirely in
/// DashboardPageController / DashboardToolbarController above — there used
/// to be a second, SwiftUI-only tab-switching implementation here (a
/// `DashboardView: View` with its own `tab` state, its own Cmd+1…4 hidden
/// buttons, and a selectTab/didSelectTab notification pair that nothing
/// outside this type ever posted or observed). That second implementation
/// was reachable only from the --render-dashboard screenshot hook, so a
/// screenshot and the real window were never guaranteed to look alike and
/// every navigation fix had to be made twice. Dead code and duplication
/// both removed; `renderDashboard` in ToastMonitorApp.swift now builds an
/// off-screen DashboardPageController directly.
enum DashboardView {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case analysis = "Analysis"
        case plans = "Plans"
        case sessions = "Sessions"
        case settings = "Settings"

        var id: String { rawValue }
    }
}
