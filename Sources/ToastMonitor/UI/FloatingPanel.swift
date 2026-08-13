import AppKit
import SwiftUI
import Combine

/// Borderless status-item panel. Unlike `NSPopover`, this has no arrow, while
/// still using AppKit's popover material, shadow and current rendering.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Single native Liquid Glass shell. On macOS 26+ the system owns the glass
/// rendering; older systems fall back to one AppKit popover visual effect.
/// Content is layered above the shell so no second glass surface is created.
private final class PanelContainerView: NSView {
    private var glass: NSView?
    private var effect: NSVisualEffectView?

    init(cornerRadius: CGFloat, content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            let nativeGlass = NSGlassEffectView()
            nativeGlass.style = .regular
            nativeGlass.cornerRadius = cornerRadius
            nativeGlass.translatesAutoresizingMaskIntoConstraints = false
            nativeGlass.contentView = NSView()

            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nativeGlass)
            addSubview(content)
            NSLayoutConstraint.activate([
                nativeGlass.leadingAnchor.constraint(equalTo: leadingAnchor),
                nativeGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
                nativeGlass.topAnchor.constraint(equalTo: topAnchor),
                nativeGlass.bottomAnchor.constraint(equalTo: bottomAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            glass = nativeGlass
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .popover
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.masksToBounds = true
            fallback.layer?.borderWidth = 0.5
            fallback.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            fallback.frame = bounds
            fallback.autoresizingMask = [.width, .height]
            addSubview(fallback)

            content.frame = bounds
            content.autoresizingMask = [.width, .height]
            addSubview(content)
            effect = fallback
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 400
    private static let cornerRadius: CGFloat = 20

    private let panel: FloatingPanel
    private weak var statusItem: NSStatusItem?
    private var contentHeightObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?
    private var settingsOpenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var settingsOpen = false
    private var desiredHeight: CGFloat

    /// SwiftUI reports the natural heights of its fixed chrome and document.
    /// AppKit clamps the resulting window to the current screen; only the
    /// middle SwiftUI scroll view can shrink.
    static let contentHeightNotification = Notification.Name("tmPopoverContentHeight")
    static let settingsVisibilityNotification = Notification.Name("tmPopoverSettingsVisibility")
    static let settingsBackNotification = Notification.Name("tmPopoverSettingsBack")
    static let hideNotification = Notification.Name("tmPopoverHide")
    static let visibilityNotification = TMNotifications.popoverVisibility

    private var headerSliceHeight: CGFloat = 0
    private var pinnedSliceHeight: CGFloat = 0
    private var bodySliceHeight: CGFloat = 0
    private var footerSliceHeight: CGFloat = 0

    init<Content: View>(statusItem: NSStatusItem, content: Content, size: NSSize) {
        self.statusItem = statusItem
        self.desiredHeight = size.height
        self.panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.panelWidth, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        settingsOpen = ProcessInfo.processInfo.environment["TM_POPOVER_SETTINGS"] == "1"

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.isExcludedFromWindowsMenu = true

        let hosting = NSHostingView(rootView: content)
        let container = PanelContainerView(cornerRadius: Self.cornerRadius, content: hosting)
        container.frame = panel.contentRect(forFrameRect: panel.frame)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        contentHeightObserver = NotificationCenter.default.addObserver(
            forName: Self.contentHeightNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let kind = note.userInfo?["kind"] as? String,
                  let page = note.userInfo?["page"] as? String,
                  let height = note.userInfo?["height"] as? CGFloat else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let expectedPage = self.settingsOpen ? "settings" : "home"
                guard page == expectedPage else { return }
                switch kind {
                case "header": self.headerSliceHeight = height
                case "pinned": self.pinnedSliceHeight = height
                case "footer": self.footerSliceHeight = height
                default: self.bodySliceHeight = height
                }
                NSObject.cancelPreviousPerformRequests(
                    withTarget: self,
                    selector: #selector(self.applyMeasuredContentSize),
                    object: nil
                )
                self.perform(#selector(self.applyMeasuredContentSize),
                             with: nil,
                             afterDelay: 0.05)
            }
        }

        settingsOpenObserver = NotificationCenter.default.addObserver(
            forName: Self.settingsVisibilityNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let open = (note.userInfo?["open"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsOpen = open
                self.headerSliceHeight = 0
                self.bodySliceHeight = 0
                self.pinnedSliceHeight = 0
                self.footerSliceHeight = 0
            }
        }

        hideObserver = NotificationCenter.default.addObserver(
            forName: Self.hideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel.isKeyWindow else {
                return event
            }
            if self.settingsOpen {
                self.settingsOpen = false
                NotificationCenter.default.post(name: Self.settingsBackNotification, object: nil)
                return nil
            }
            // The menu-bar button is the Popover's close control. Do not let
            // Escape or a focus change silently collapse the panel the user
            // deliberately left open.
            return event
        }
    }

    var isVisible: Bool { panel.isVisible }
    var panelContent: NSView? { panel.contentView }

    /// Legacy macOS 14–26 action and the hermetic UI verification hook.
    func toggle() {
        panel.isVisible ? dismiss() : show()
    }

    private func show() {
        guard !panel.isVisible else { return }
        applyMeasuredContentSize()
        position()
        // A non-activating panel does not need an application activation or a
        // full-surface alpha animation. Both force the entire SwiftUI/Glass
        // tree through another display pass and made opening intermittently
        // hitch on an otherwise idle machine.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        NotificationCenter.default.post(name: Self.visibilityNotification, object: false)
        if settingsOpen {
            settingsOpen = false
            NotificationCenter.default.post(name: Self.settingsBackNotification, object: nil)
        }
    }

    private func position() {
        let screen = statusItem?.button?.window?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var x = visible.midX - Self.panelWidth / 2
        if let buttonWindow = statusItem?.button?.window,
           buttonWindow.screen == screen,
           screen.frame.intersects(buttonWindow.frame) {
            x = buttonWindow.frame.midX - Self.panelWidth / 2
        }
        x = min(max(x, visible.minX + 8), visible.maxX - Self.panelWidth - 8)
        let height = Self.clampedHeight(
            natural: desiredHeight,
            available: visible.height - 12
        )
        desiredHeight = height
        panel.setFrame(
            NSRect(x: x, y: visible.maxY - 6 - height,
                   width: Self.panelWidth, height: height),
            display: false
        )
    }

    @objc private func applyMeasuredContentSize() {
        guard let naturalHeight = Self.mergedHeight(
            header: headerSliceHeight,
            pinned: settingsOpen ? 0 : pinnedSliceHeight,
            body: bodySliceHeight,
            footer: footerSliceHeight,
            allowsZeroPinned: settingsOpen
        ) else { return }

        let screen = statusItem?.button?.window?.screen ?? panel.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 12
        let target = Self.clampedHeight(natural: naturalHeight, available: available)
        guard abs(desiredHeight - target) > 1 else { return }
        desiredHeight = target
        guard panel.isVisible else { return }

        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.panelWidth, height: target)
        frame.origin.y = top - target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Wait for a complete measurement before resizing. This prevents an
    /// intermediate partial sum from moving fixed navigation out of view.
    nonisolated static func mergedHeight(header: CGFloat, pinned: CGFloat,
                                         body: CGFloat, footer: CGFloat,
                                         allowsZeroPinned: Bool) -> CGFloat? {
        guard header > 0, body > 0, footer > 0,
              pinned > 0 || allowsZeroPinned else { return nil }
        return header + pinned + body + footer
    }

    /// Short pages keep their natural height; only over-tall pages are
    /// constrained to the visible screen.
    nonisolated static func clampedHeight(natural: CGFloat,
                                          available: CGFloat) -> CGFloat {
        min(natural, max(1, available))
    }

    deinit {
        for observer in [contentHeightObserver, hideObserver,
                         settingsOpenObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
