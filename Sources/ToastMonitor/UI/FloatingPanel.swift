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
    /// 内容容器：非激活面板显示时手动刷新 cursor rects（见 show()）。
    private weak var containerView: NSView?
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
    /// Requests hiding the menu-bar panel without closing whichever window
    /// becomes key while the dashboard is opening.
    static let hideNotification = Notification.Name("tmPanelHide")
    private var hideObserver: NSObjectProtocol?
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
        // Let WindowServer derive the shadow from the window's alpha mask.
        // A CALayer shadow inside the rectangular content bounds gives every
        // corner a non-zero alpha; window screenshots then reveal a pale
        // square behind the rounded glass.
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false // we close on resign-key ourselves
        panel.delegate = self

        // 单层原生玻璃外壳（重设计规格）：macOS 26+ 用 NSGlassEffectView，
        // 旧系统降级单层 NSVisualEffectView。跟随系统外观——语义前景色
        // 在亮/暗桌面背景上自动保持可读。
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = PanelContainerView(cornerRadius: Self.cornerRadius, content: host)
        // The clipped container is the window's root content view. There is
        // no rectangular wrapper behind it, so pixels outside the continuous
        // corner are genuinely transparent in the window surface.
        container.frame = NSRect(origin: .zero, size: size)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        self.containerView = container

        // Close when the panel resigns key (click elsewhere / Cmd-Tab away).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }

        // Self-size to the SwiftUI content's natural height. The home view
        // posts two slices ("body" scroll content, "pinned" period selector);
        // merge them 50ms after the last one so both land in one resize.
        contentHeightObserver = NotificationCenter.default.addObserver(
            forName: Self.contentHeightNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let kind = note.userInfo?["kind"] as? String,
                  let h = note.userInfo?["height"] as? CGFloat else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if kind == "pinned" {
                    self.pinnedSliceHeight = h
                } else {
                    self.bodySliceHeight = h
                }
                NSObject.cancelPreviousPerformRequests(
                    withTarget: self, selector: #selector(applyMergedHeight), object: nil)
                self.perform(#selector(applyMergedHeight), with: nil, afterDelay: 0.05)
            }
        }
        // Period switches reset the scroll position.
        scrollResetObserver = NotificationCenter.default.addObserver(
            forName: Self.resetScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetScrollToTop() }
        }

        // Esc closes.
        // Esc 关闭；若设置在 Popover 设置页，先返回首页再按一次关闭
        // （与 Tusi 的 Esc 行为一致）。
        settingsOpenObserver = NotificationCenter.default.addObserver(
            forName: Self.settingsVisibilityNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let open = (note.userInfo?["open"] as? Bool) ?? false
            Task { @MainActor [weak self] in self?.settingsOpen = open }
        }
        hideObserver = NotificationCenter.default.addObserver(
            forName: Self.hideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
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

    /// 内容容器（--capture 截图钩子用）。
    var panelContent: NSView? { panel.contentView }

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
        panel.invalidateShadow()
        panel.makeKeyAndOrderFront(nil)
        // 非激活窗口不会自动重建 cursor rects，鼠标从终端移入时残留
        // I-beam；强制刷新让容器默认箭头光标生效。
        if let containerView {
            panel.invalidateCursorRects(for: containerView)
        }
        NotificationCenter.default.post(name: Self.visibilityNotification, object: true)
        // 若已有内容高度测量值（非冷启动），立即应用——否则面板先用旧的
        // 600pt 高度显示，底部 Activity/Trend 被裁剪，等 0.4s 后才"展开"。
        // 冷启动时 slice 还是 0，等 SwiftUI 首布局的 onAppear 测量通知
        // （50ms 合并延迟）即可，不再依赖这里的 0.4s 兜底。
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyMergedHeight), object: nil)
        if bodySliceHeight > 0 || pinnedSliceHeight > 0 {
            applyMergedHeight()
        }
        // First-layout height reports can arrive before SwiftUI settles;
        // re-apply once more after the panel is on screen so the initial
        // size matches the content instead of the viewport.
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
        // 8pt 阈值：初始高度已预留完整内容（850），微小的测量差异不触发
        // 高度动画，避免打开瞬间的弹簧感；设置页等大幅差异仍会自适应。
        guard abs(target - panel.frame.height) > 8 else { return }
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
        panel.invalidateShadow()
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
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
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
    /// macOS 26+ 原生 Liquid Glass 外壳（NSGlassEffectView；基类存储绕开
    /// 存储属性 availability 限制，使用处 cast）。
    private var glass: NSView?
    /// 降级路径（macOS 14–25）：单层 NSVisualEffectView。
    private var effect: NSVisualEffectView?
    private var cancellable: AnyCancellable?

    /// 单一连续圆角外壳。内容嵌入唯一的主玻璃层；禁止 glass-on-glass——
    /// 内容层只能使用极轻的 system fill 表达分组（见内容视图）。
    init(cornerRadius: CGFloat, content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        // This root layer is also the window's alpha mask: outside the
        // continuous rounded rect the backing surface remains transparent.
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = cornerRadius
            g.translatesAutoresizingMaskIntoConstraints = false
            // 内容独立叠加在玻璃之上（与降级路径同构）。玻璃需要 contentView
            // 才渲染，放一个空视图占位；内容不嵌入玻璃，alphaValue 才能只
            // 作用于玻璃背景——通透度滑块调的是真正的透明度。
            g.contentView = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(g)
            addSubview(content)
            NSLayoutConstraint.activate([
                g.leadingAnchor.constraint(equalTo: leadingAnchor),
                g.trailingAnchor.constraint(equalTo: trailingAnchor),
                g.topAnchor.constraint(equalTo: topAnchor),
                g.bottomAnchor.constraint(equalTo: bottomAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            // 通透度滑块：低端 = 玻璃 alpha 趋近 0（几乎全透明）+ 无黑 tint；
            // 高端 = 满 alpha + 0.3 黑 tint（磨砂）。
            g.tintColor = NSColor.black.withAlphaComponent(GlassSettings.tint(for: GlassSettings.shared.intensity))
            g.alphaValue = GlassSettings.alpha(for: GlassSettings.shared.intensity)
            cancellable = GlassSettings.shared.$intensity.sink { [weak self] v in
                guard let g = self?.glass as? NSGlassEffectView else { return }
                g.tintColor = NSColor.black.withAlphaComponent(GlassSettings.tint(for: v))
                g.alphaValue = GlassSettings.alpha(for: v)
            }
            glass = g
        } else {
            let e = NSVisualEffectView()
            e.material = .popover
            e.blendingMode = .behindWindow
            e.state = .active
            e.wantsLayer = true
            e.layer?.cornerRadius = cornerRadius
            e.layer?.masksToBounds = true
            // 降级只允许一条 0.5pt hairline（规格：不多画）。
            e.layer?.borderWidth = 0.5
            e.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            e.autoresizingMask = [.width, .height]
            addSubview(e)
            content.autoresizingMask = [.width, .height]
            addSubview(content)
            e.alphaValue = GlassSettings.alpha(for: GlassSettings.shared.intensity)
            cancellable = GlassSettings.shared.$intensity.sink { [weak self] v in
                self?.effect?.alphaValue = GlassSettings.alpha(for: v)
            }
            effect = e
        }
    }

    /// 非激活面板不参与常规光标更新：鼠标从终端（I-beam）移入面板时
    /// 会残留文本光标。整面板默认箭头光标；内容中的文本输入区（如有）
    /// 会以更具体的 cursor rect 覆盖。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
