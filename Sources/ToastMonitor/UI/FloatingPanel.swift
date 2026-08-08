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
        // 控制中心模式：popover 永远深色玻璃 + 白字（无论系统外观）。
        // 浅色系统下黑字叠透明玻璃对比度不可控；深色外观让所有
        // primary/secondary 文字自动白系，配合容器内的恒定暗基底。
        panel.appearance = NSAppearance(named: .darkAqua)

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
    /// 恒定暗基底（控制中心同款）：玻璃透明度再低，内容之下始终有一层
    /// 0.25 黑 tint 兜底，保证白字可读。磨砂端 = 深玻璃 + 暗底；
    /// 通透端 = 近透明玻璃 + 轻暗底。
    private let tint = NSView()
    /// 顶部光源（Tusi topLight 移植）：Liquid Glass 边缘高光的 AppKit 近似
    /// ——1px 白色 hairline 描边 + 顶部白色微光渐变，盖住 behindWindow 玻璃
    /// 在圆角裁剪边缘的固有暗边（截图里的黑框）。
    private let topLight = CAGradientLayer()
    /// 高光细线：CAShapeLayer 路径描边（CALayer.border 对连续圆角的抗锯齿
    /// 差，圆角处毛刺严重；shape layer 的描边平滑且精确跟随圆角路径）。
    private let rimLine = CAShapeLayer()
    /// 边缘折射光晕：宽线低 alpha（玻璃边缘受光折射的柔光，浅色背景下
    /// 是「玻璃边」而不是黑边的关键——亮度要高到能压过深色玻璃）。
    private let rimGlow = CAShapeLayer()
    /// 厚度暗线：紧贴光晕内侧的薄暗线——玻璃截面的厚度阴影（2.5D 厚度感）。
    private let rimShadow = CAShapeLayer()
    /// 底部暗影：光从上方来，玻璃底部是暗面（厚度/立体感的下半）。
    private let bottomShadow = CAGradientLayer()
    private var cancellable: AnyCancellable?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        // 材质与整个容器强制深色外观：玻璃采样呈深色系，不跟随系统浅色。
        appearance = NSAppearance(named: .darkAqua)

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.appearance = NSAppearance(named: .darkAqua)
        // effect 自身圆角：behindWindow 材质在容器 masksToBounds 的裁剪
        // 边界处会退化出一条固有暗环（亮背景下的「黑边」）；让 effect 自己
        // 按容器半径圆角，裁剪线与边缘重合，消除暗环。
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        // 玻璃强度由 Popover 设置页的滑块控制（effect 层 alpha）。
        effect.alphaValue = GlassSettings.alpha(for: GlassSettings.shared.intensity)
        cancellable = GlassSettings.shared.$intensity.sink { [weak self] v in
            self?.effect.alphaValue = GlassSettings.alpha(for: v)
        }
        addSubview(effect)

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        tint.autoresizingMask = [.width, .height]
        // tint 内缩 + 自身圆角：黑色基底不铺到边缘，留出 ~2pt 高光带。
        // 之前 tint 直铺到圆角边，边缘一圈就是黑——浅色背景下的「黑边」。
        tint.layer?.cornerRadius = max(cornerRadius - 2, 0)
        tint.layer?.masksToBounds = true
        addSubview(tint)

        // 玻璃厚度层次（2.5D）：
        // 1) 外缘细亮线（受光边缘）——CAShapeLayer 描边平滑抗锯齿。
        rimLine.fillColor = nil
        rimLine.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        rimLine.lineWidth = 0.5
        layer?.addSublayer(rimLine)

        // 2) 边缘折射光晕：宽线低 alpha，亮度足够压过深色玻璃——
        //    浅色背景下它就是「玻璃边缘」，不是黑边。
        rimGlow.fillColor = nil
        rimGlow.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        rimGlow.lineWidth = 5
        layer?.addSublayer(rimGlow)

        // 3) 厚度暗线：光晕内侧的薄暗影（玻璃截面暗部）——厚度感。
        rimShadow.fillColor = nil
        rimShadow.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
        rimShadow.lineWidth = 2
        layer?.addSublayer(rimShadow)

        // 顶部光源：上 40% 高度白色微光（控制中心玻璃的顶部反射感）。
        topLight.startPoint = CGPoint(x: 0.5, y: 1)
        topLight.endPoint = CGPoint(x: 0.5, y: 0.6)
        topLight.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        layer?.addSublayer(topLight)

        // 底部暗影：底部 25% 黑色渐变（玻璃暗面，厚度感的下半）。
        bottomShadow.startPoint = CGPoint(x: 0.5, y: 0)
        bottomShadow.endPoint = CGPoint(x: 0.5, y: 0.25)
        bottomShadow.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor,
        ]
        layer?.addSublayer(bottomShadow)
    }

    override func layout() {
        super.layout()
        // 渐变是裸 layer：resize 时禁用隐式动画，避免滞后一帧。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topLight.frame = bounds
        bottomShadow.frame = bounds
        let r = Self.radiusHint(bounds, layerCorner: layer?.cornerRadius ?? 20)
        let linePath = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: r, cornerHeight: r, transform: nil
        )
        let glowPath = CGPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: max(r - 1.5, 0), cornerHeight: max(r - 1.5, 0), transform: nil
        )
        let shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: 3.5, dy: 3.5),
            cornerWidth: max(r - 3.5, 0), cornerHeight: max(r - 3.5, 0), transform: nil
        )
        rimLine.frame = bounds
        rimLine.path = linePath
        rimGlow.frame = bounds
        rimGlow.path = glowPath
        rimShadow.frame = bounds
        rimShadow.path = shadowPath
        CATransaction.commit()
    }

    /// 圆角半径不能超过内缩后的短边一半，否则 CGPath 断言崩溃。
    private static func radiusHint(_ bounds: CGRect, layerCorner: CGFloat) -> CGFloat {
        min(layerCorner, min(bounds.width, bounds.height) / 2 - 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
