import AppKit
import SwiftUI

/// Borderless status-item panel. Unlike `NSPopover`, this has no arrow, while
/// still using AppKit's popover material, shadow and current rendering.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The physical panel surface follows AppKit's popover material model: one
/// system visual-effect view clipped at the window boundary. The system owns
/// the light/dark surface treatment instead of a hand-tuned color wash.
private final class PanelSurfaceView: NSView {
    private let cornerRadius: CGFloat
    private let effect = NSVisualEffectView()

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        clipsToBounds = true
        // Keep the boundary at AppKit's hairline scale; the system shadow
        // provides separation, so a full-pixel outline is unnecessarily heavy.
        layer?.borderWidth = 0.5

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        applyAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    override func layout() {
        super.layout()
        // Keep every drawing surface on the same continuous shape. In
        // particular, NSVisualEffectView can otherwise composite its
        // behind-window material to its rectangular bounds before the parent
        // layer's corner radius is applied.
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Apple's semantic separator adapts to light/dark appearance and
            // gives a white-on-white popover a quiet boundary without a
            // custom shadow or hand-picked gray.
            layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.42).cgColor
        }
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
    private var resignObserver: NSObjectProtocol?
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

    /// Settings key controlling whether the panel auto-closes when it loses
    /// focus (e.g. clicking another window or app). Default (unset) is
    /// "0" — stay open until the status button, Esc or the in-panel close
    /// affordance dismisses it.
    static let dismissOnResignKey = "popover_dismiss_on_resign"

    /// `true` restores the classic transient behavior: resigning key closes
    /// the panel. Read per event so toggling the setting applies immediately.
    static var dismissOnResign: Bool {
        Database.shared.setting(dismissOnResignKey) == "1"
    }

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
        // Match Tusi's native floating-panel structure: the panel itself owns
        // the elevation and the rounded root content view owns the alpha mask.
        // With no rectangular wrapper behind it, AppKit's shadow follows the
        // actual rounded surface instead of producing the former corner block.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.isExcludedFromWindowsMenu = true

        let surface = PanelSurfaceView(cornerRadius: Self.cornerRadius)
        surface.frame = panel.contentRect(forFrameRect: panel.frame)
        surface.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: content)
        hosting.frame = surface.bounds
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        // The rounded surface must be the window's root content view. An
        // outer rectangular shadow host participates in WindowServer's
        // compositing and brings square corners back at the window edge.
        panel.contentView = surface

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

        // Opt-in focus-loss dismissal (settings: "Close when clicking
        // elsewhere"). When disabled, clicking other windows or apps leaves
        // the panel open; only the status button's toggle, the in-panel close
        // affordance, or Esc dismiss it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible,
                      Self.dismissOnResign else { return }
                // Let the status button's action own the toggle; closing here
                // first would turn the same click into an immediate reopen.
                if let buttonWindow = self.statusItem?.button?.window,
                   buttonWindow.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.dismiss()
            }
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
            self.dismiss()
            return nil
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
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.animator().alphaValue = 1
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
                         settingsOpenObserver, resignObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
