import AppKit
import SwiftUI
import Combine

/// Tusi-style floating panel: borderless NSPanel whose content is a
/// visual-effect container clipped to a 20pt continuous corner radius
/// (matches neko1chau/Tusi Theme.cornerRadius = 20, the modern macOS
/// menu-bar tool look). The panel hides on resign-key, Esc, or status
/// item toggle.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private weak var statusItem: NSStatusItem?
    private var resignObserver: NSObjectProtocol?
    private var contentHeightObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    /// Posted by the SwiftUI root when its natural content height changes;
    /// userInfo["height"] carries the CGFloat. The panel resizes to fit.
    static let contentHeightNotification = Notification.Name("tmPanelContentHeight")
    /// Posted by the SwiftUI home view when the period changes, so the panel
    /// can reset the scroll view to the top (Codex's scroll-reset design).
    static let resetScrollNotification = Notification.Name("tmPanelResetScroll")
    private var scrollResetObserver: NSObjectProtocol?
    /// Popover 设置页开关状态（userInfo["open"]: Bool）——Esc 先返回再关闭。
    static let settingsVisibilityNotification = Notification.Name("tmPanelSettingsVisibility")
    /// Esc 在设置页时请求返回首页。
    static let settingsBackNotification = Notification.Name("tmPanelSettingsBack")
    private var settingsOpenObserver: NSObjectProtocol?
    private var settingsOpen = false

    /// 20pt continuous corner radius — matches Tusi's Theme.cornerRadius.
    static let cornerRadius: CGFloat = 20

    init<Content: View>(statusItem: NSStatusItem, content: Content, size: NSSize) {
        self.statusItem = statusItem
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false // we close on resign-key ourselves
        panel.delegate = self

        // Container: .popover material + 20pt continuous corners.
        let container = PanelContainerView(cornerRadius: Self.cornerRadius)
        container.translatesAutoresizingMaskIntoConstraints = false
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        // Close when the panel resigns key (click elsewhere / Cmd-Tab away).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }

        // Self-size to the SwiftUI content's natural height. The home view
        // posts two slices ("body" scroll content, "pinned" period selector);
        // merge them 50ms after the last one so both land in one resize.
        contentHeightObserver = NotificationCenter.default.addObserver(
            forName: Self.contentHeightNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let kind = note.userInfo?["kind"] as? String,
                  let h = note.userInfo?["height"] as? CGFloat else { return }
            if kind == "pinned" {
                self.pinnedSliceHeight = h
            } else {
                self.bodySliceHeight = h
            }
            NSObject.cancelPreviousPerformRequests(
                withTarget: self, selector: #selector(applyMergedHeight), object: nil)
            self.perform(#selector(applyMergedHeight), with: nil, afterDelay: 0.05)
        }
        // Period switches reset the scroll position.
        scrollResetObserver = NotificationCenter.default.addObserver(
            forName: Self.resetScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetScrollToTop()
        }

        // Esc closes.
        // Esc 关闭；若设置在 Popover 设置页，先返回首页再按一次关闭
        // （与 Tusi 的 Esc 行为一致）。
        settingsOpenObserver = NotificationCenter.default.addObserver(
            forName: Self.settingsVisibilityNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.settingsOpen = (note.userInfo?["open"] as? Bool) ?? false
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.panel.isVisible {
                if self.settingsOpen {
                    self.settingsOpen = false
                    NotificationCenter.default.post(name: Self.settingsBackNotification, object: nil)
                } else {
                    self.hide()
                }
                return nil
            }
            return event
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Foreground signal: the menu bar surface being expanded means the user
    /// is looking at numbers — collectors and the UI snapshot speed up.
    static let visibilityNotification = TMNotifications.popoverVisibility

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Top anchor (screen coords): the panel's top edge is pinned 6pt below
    /// the menu bar's bottom edge (visible.maxY) — Tusi's approach. It never
    /// follows the status button's Y (unreliable in NSStatusBarWindow) and
    /// can therefore never cover the status bar. Only the bottom moves.
    private func show() {
        guard let button = statusItem?.button, let win = button.window else { return }
        let buttonFrame = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = win.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // visible.maxY IS the menu bar bottom. The panel runs at popUpMenu
        // level (above the menu bar), so keep the top edge just below it.
        // 6pt matches Tusi; 14pt was a safety margin but left a visible gap.
        let topY = visible.maxY - 6
        let maxH = max(120, topY - visible.minY - 8)
        let h = min(max(panel.frame.height, 120), maxH)
        let w = panel.frame.width
        let x = min(max(buttonFrame.midX - w / 2, visible.minX + 8), visible.maxX - w - 8)
        logPanel("show: visible=\(visible) screenFrame=\(screen.frame) topY=\(topY) h=\(h) x=\(x) buttonFrame=\(buttonFrame)")
        panel.setFrame(NSRect(x: x, y: topY - h, width: w, height: h), display: true)
        logPanel("show setFrame: finalFrame=\(panel.frame)")
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
        // First-layout height reports can arrive before SwiftUI settles;
        // re-apply the merged height once the panel is on screen so the
        // initial size matches the content instead of the viewport.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyMergedHeight), object: nil)
        perform(#selector(applyMergedHeight), with: nil, afterDelay: 0.4)
    }

    /// Grow/shrink the panel to fit the reported content height. The top
    /// stays pinned below the menu bar; only the bottom edge moves.
    private func applyHeight(_ h: CGFloat) {
        guard panel.isVisible else { return } // Tusi: only while visible
        guard let screen = (statusItem?.button?.window?.screen) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let topY = visible.maxY - 6
        let maxH = max(120, topY - visible.minY - 8)
        let target = min(max(h, 120), maxH)
        logPanel("applyHeight: reported=\(h) topY=\(topY) maxH=\(maxH) target=\(target) currentFrame=\(panel.frame)")
        guard abs(target - panel.frame.height) > 2 else { return }
        var frame = panel.frame
        frame.size.height = target
        frame.origin.y = topY - target // top pinned; bottom moves
        // Animate the height change instead of hard-cutting it (fatbobman:
        // "make height an explicit animated state"). With linear interpolation
        // the top edge stays exactly at topY throughout: origin.y(t)+height(t)
        // = (topY - h_old + t(h_old-h_new)) + (h_old + t(h_new-h_old)) = topY.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
        logPanel("applyHeight setFrame: finalFrame=\(panel.frame)")
    }

    /// Append a line to /tmp/tm-panel.log (diagnostics while the panel
    /// positioning bug is being chased). Debug-only: shipped builds must
    /// never append to /tmp.
    private func logPanel(_ msg: String) {
        guard DebugLog.enabled else { return }
        let path = "/tmp/tm-panel.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        fh.seekToEndOfFile()
        fh.write("[\(Date())] \(msg)\n".data(using: .utf8) ?? Data())
        try? fh.close()
    }

    /// Reset the SwiftUI scroll view inside the hosting view to the top
    /// (period switches must never leave the content scrolled off).
    private func resetScrollToTop() {
        guard let hosting = panel.contentView?.subviews.first else { return }
        func findScroll(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews {
                if let found = findScroll(sub) { return found }
            }
            return nil
        }
        if let sv = findScroll(hosting) {
            let clip = sv.contentView
            let old = clip.bounds.origin
            clip.scroll(to: .zero)
            sv.reflectScrolledClipView(clip)
            logPanel("resetScroll: old=\(old) new=\(clip.bounds.origin) docH=\(sv.documentView?.frame.height ?? 0) clipH=\(clip.bounds.height)")
        }
    }

    /// Height of the scrollable body as measured by the SwiftUI home view.
    private var bodySliceHeight: CGFloat = 0
    /// Height of the pinned period selector as measured by the SwiftUI view.
    private var pinnedSliceHeight: CGFloat = 0

    /// Fixed chrome: header + dividers + footer ≈ 108pt.
    @objc private func applyMergedHeight() {
        let total = bodySliceHeight + pinnedSliceHeight + 108
        applyHeight(total)
    }

    private func hide() {
        panel.orderOut(nil)
        NotificationCenter.default.post(name: Self.visibilityNotification, object: false)
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let contentHeightObserver {
            NotificationCenter.default.removeObserver(contentHeightObserver)
        }
        if let scrollResetObserver {
            NotificationCenter.default.removeObserver(scrollResetObserver)
        }
        if let settingsOpenObserver {
            NotificationCenter.default.removeObserver(settingsOpenObserver)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}

/// Visual-effect container clipped to a continuous corner radius.
final class PanelContainerView: NSView {
    private let effect = NSVisualEffectView()
    private var cancellable: AnyCancellable?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        // 玻璃强度由 Popover 设置页的滑块控制（effect 层 alpha）。
        effect.alphaValue = GlassSettings.alpha(for: GlassSettings.shared.intensity)
        cancellable = GlassSettings.shared.$intensity.sink { [weak self] v in
            self?.effect.alphaValue = GlassSettings.alpha(for: v)
        }
        addSubview(effect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
