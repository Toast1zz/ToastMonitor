import AppKit
import SwiftUI

/// Panes of the settings window, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general
    case appearance
    case sources
    case data
    case updates

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .sources: return "Sources"
        case .data: return "Data"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .sources: return "tray.full"
        case .data: return "externaldrive"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .sources: SourcesSettingsPane()
        case .data: DataSettingsPane()
        case .updates: UpdatesSettingsPane()
        }
    }
}

/// The app's settings window, laid out the way the macOS Human Interface
/// Guidelines describe: a noncustomizable toolbar of pane buttons that
/// always shows the active one, a title that names the visible pane, dimmed
/// minimize and zoom buttons, a window that fits the current pane, and the
/// last viewed pane restored on open. Opened with Command-Comma or the
/// popover's gear button.
///
/// Pane switching is done here rather than by NSTabViewController, which
/// resizes the window itself, instantly, and overrode the animated resize.
/// As in sindresorhus/Settings, one animation moves the window frame (top
/// edge fixed) and cross-fades the panes, which stay pinned to the top.
///
/// AppKit rather than a SwiftUI `Settings` scene: the app has no scenes (a
/// scene makes macOS reopen an empty window when the last one closes).
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    static let shared = SettingsWindowController()
    private static let lastPaneKey = "settingsLastPane"
    private static let switchDuration: TimeInterval = 0.25

    private var window: NSWindow?
    private var root: NSView?
    private var panes: [SettingsPane: SettingsPaneHost] = [:]
    private var current: SettingsPane?

    @objc func showSettings(_ sender: Any?) {
        show()
    }

    func show(pane: SettingsPane? = nil) {
        // Decided before makeWindow(): measuring the panes there leaves
        // `current` on the last pane, which is not the one to restore.
        let target = pane ?? current ?? Self.savedPane
        let window = self.window ?? makeWindow()
        let wasVisible = window.isVisible
        select(target, animated: wasVisible)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            // A window's first animator frame change lands without animating,
            // which made the first pane switch after opening a jump. Spend
            // that first change on a no-op.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                window.animator().setFrame(window.frame, display: false)
            }
        }
        clearInitialFocus()
    }

    private static var savedPane: SettingsPane {
        UserDefaults.standard.string(forKey: lastPaneKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    private func makeWindow() -> NSWindow {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: SettingsPaneView.width,
                                        height: SettingsPaneView.fallbackHeight))
        // No miniaturize or resize: AppKit dims those buttons, and the
        // window takes its size from the selected pane.
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "ToastMonitor.Settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        self.window = window
        self.root = root
        measureAllPanes(in: window)
        window.center()
        return window
    }

    /// Shows every pane once, invisibly, before the window first appears. A
    /// grouped form only lays out rows that are on screen, so a pane's height
    /// is an estimate until it has been displayed; without this the window
    /// resized a second time just after a pane was first opened.
    private func measureAllPanes(in window: NSWindow) {
        window.alphaValue = 0
        window.orderFront(nil)
        for pane in SettingsPane.allCases {
            select(pane, animated: false, remember: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.orderOut(nil)
        window.alphaValue = 1
    }

    private func host(for pane: SettingsPane) -> SettingsPaneHost {
        if let existing = panes[pane] { return existing }
        let host = SettingsPaneHost(pane: pane)
        host.onHeightChange = { [weak self] changed in
            self?.paneHeightDidChange(changed)
        }
        panes[pane] = host
        return host
    }

    private func select(_ pane: SettingsPane, animated: Bool, remember: Bool = true) {
        guard let window, let root else { return }
        window.toolbar?.selectedItemIdentifier = pane.itemIdentifier
        window.title = pane.title
        if remember {
            UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey)
        }
        let incoming = host(for: pane)
        guard pane != current else { return }
        let outgoing = current.flatMap { panes[$0] }
        current = pane
        incoming.install(in: root, below: window)
        let frame = frame(for: incoming, in: window)
        guard animated else {
            outgoing?.view.removeFromSuperview()
            incoming.view.alphaValue = 1
            window.setFrame(frame, display: true)
            return
        }
        incoming.view.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.switchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            outgoing?.view.animator().alphaValue = 0
            incoming.view.animator().alphaValue = 1
            window.animator().setFrame(frame, display: false)
        }, completionHandler: { [weak self, weak outgoing] in
            MainActor.assumeIsolated {
                // A quick second switch can bring the outgoing pane back.
                guard let outgoing, outgoing.pane != self?.current else { return }
                outgoing.view.removeFromSuperview()
                outgoing.view.alphaValue = 1
            }
        })
        clearInitialFocus()
    }

    /// A shown pane that changes height (a section appearing, a list
    /// loading) resizes the window; a hidden one is fitted when selected.
    private func paneHeightDidChange(_ host: SettingsPaneHost) {
        guard host.pane == current, let window else { return }
        let frame = frame(for: host, in: window)
        guard window.isVisible, window.alphaValue > 0 else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.switchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: false)
        }
    }

    /// The window frame that fits `host`, keeping the top edge in place.
    /// The content view runs under the toolbar on macOS 26+, so the window
    /// is the pane plus whatever the title bar and toolbar cover, measured
    /// from the window's content layout rect rather than assumed.
    private func frame(for host: SettingsPaneHost, in window: NSWindow) -> NSRect {
        let chrome = window.frame.height - window.contentLayoutRect.height
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maxHeight = max(120, screenHeight - 24)
        let contentHeight = min(host.height, max(120, maxHeight - chrome))
        host.setViewportHeight(contentHeight)
        let height = contentHeight + chrome
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: SettingsPaneView.width, height: 1)).width, height: height)
        return frame
    }

    /// Opening a pane must not drop a caret into its first text field; the
    /// window stays unfocused until a control is clicked, as in System
    /// Settings. SwiftUI assigns focus after layout, hence the async hop.
    private func clearInitialFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window,
                  window.firstResponder is NSText || window.firstResponder is NSTextField
            else { return }
            window.makeFirstResponder(nil)
        }
    }

    @objc private func paneClicked(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(pane, animated: true)
    }

    // MARK: NSToolbarDelegate

    private var itemIdentifiers: [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.itemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        itemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        itemIdentifiers
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        itemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(paneClicked(_:))
        return item
    }

    /// Test hook: captures the window frame, toolbar included.
    func captureWindow(pane: SettingsPane, to path: String) -> Bool {
        show(pane: pane)
        guard let frameView = window?.contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return false
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}

private extension SettingsPane {
    var itemIdentifier: NSToolbarItem.Identifier { .init(rawValue) }
}

/// One pane's form, pinned to the top of the window's content view with its
/// own height. The form reports that height itself.
@MainActor
private final class SettingsPaneHost {
    let pane: SettingsPane
    let view: NSView
    private(set) var height = SettingsPaneView.fallbackHeight
    /// The form's measured content height remains separate from the visible
    /// viewport. A short display caps the latter without losing scrollability.
    private var viewportHeight: CGFloat?
    private let heightConstraint: NSLayoutConstraint
    var onHeightChange: ((SettingsPaneHost) -> Void)?

    init(pane: SettingsPane) {
        self.pane = pane
        let hosting = NSHostingView(rootView: SettingsPaneView(pane: pane))
        hosting.sizingOptions = []
        view = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = hosting.heightAnchor.constraint(equalToConstant: height)
        heightConstraint.isActive = true
        self.hosting = hosting
        hosting.rootView = SettingsPaneView(pane: pane) { [weak self] height in
            self?.adopt(height)
        }
    }
    private let hosting: NSHostingView<SettingsPaneView>
    func setViewportHeight(_ height: CGFloat) {
        let clamped = max(120, height)
        viewportHeight = clamped
        hosting.rootView = SettingsPaneView(pane: pane, viewportHeight: clamped) { [weak self] height in
            self?.adopt(height)
        }
        guard abs(heightConstraint.constant - clamped) > 0.5 else { return }
        heightConstraint.constant = clamped
        view.superview?.layoutSubtreeIfNeeded()
    }

    /// Pinned to the top of the window's visible content area (below the
    /// toolbar), not of the content view, which extends under the toolbar.
    func install(in root: NSView, below window: NSWindow) {
        guard view.superview !== root else { return }
        root.addSubview(view)
        let top = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? root.topAnchor
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: top),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    private func adopt(_ height: CGFloat) {
        guard height > 0, height != self.height else { return }
        self.height = height
        let effectiveHeight = viewportHeight ?? height
        heightConstraint.constant = effectiveHeight
        onHeightChange?(self)
    }
}

/// A pane's grouped form, sized to its content: a short pane gets a short
/// window, and only a pane taller than `maxHeight` scrolls.
struct SettingsPaneView: View {
    static let width: CGFloat = 580
    static let maxHeight: CGFloat = 640
    /// Used until the form reports its content height, and on macOS 13–14
    /// where a scroll view's content size cannot be read.
    static let fallbackHeight: CGFloat = 520

    let pane: SettingsPane
    let viewportHeight: CGFloat?
    /// Receives the pane's measured content height whenever it changes.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 0

    init(pane: SettingsPane, viewportHeight: CGFloat? = nil,
         onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.pane = pane
        self.viewportHeight = viewportHeight
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        Form {
            pane.content
        }
        .formStyle(.grouped)
        .modifier(ScrollContentHeight(height: $contentHeight))
        .frame(width: Self.width, height: viewportHeight ?? height)
        .onChange(of: height) { onHeightChange($0) }
    }

    private var height: CGFloat {
        guard contentHeight > 0 else { return Self.fallbackHeight }
        return min(max(contentHeight, 120), Self.maxHeight)
    }
}

/// Reports a scroll view's content height (macOS 15+).
private struct ScrollContentHeight: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, new in
                height = ceil(new)
            }
        } else {
            content
        }
    }
}
