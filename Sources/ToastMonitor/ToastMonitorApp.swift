import SwiftUI
import AppKit
import Darwin

/// Pure AppKit entry point. No SwiftUI Scene at all: a WindowGroup or
/// Settings scene makes macOS re-open an empty window when the last window
/// closes (user reported the mystery "ToastMonitor" blank window). The
/// Dashboard is an NSWindow owned by WindowManager, the menu-bar surface is a
/// status-item NSPanel owned by PanelController — nothing needs a scene.
@main
enum ToastMonitorMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var statusItem: NSStatusItem?
    @MainActor private var panelController: PanelController?
    @MainActor private var appStateObserver: Any?
    private var debugBackdrop: NSWindow?
    /// Read secrets from stdin so they never appear in argv/`ps` output or
    /// shell history. Callers may pipe one line or an EOF-terminated value.
    private func readSecretFromStdin(_ label: String) -> String? {
        let maxBytes = 64 * 1024
        print(label, terminator: " ")
        fflush(stdout)
        var data = Data()
        while data.count <= maxBytes {
            do {
                guard let chunk = try FileHandle.standardInput.read(
                    upToCount: min(4096, maxBytes + 1 - data.count)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            } catch {
                return nil
            }
        }
        guard data.count <= maxBytes,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
    private func boundedRenderDimension(_ args: [String], index: Int,
                                        defaultValue: Double,
                                        range: ClosedRange<Double>,
                                        label: String) -> Double {
        guard args.indices.contains(index) else { return defaultValue }
        guard let value = Double(args[index]),
              value.isFinite, range.contains(value) else {
            print("\(label) 尺寸无效（范围 \(range.lowerBound)-\(range.upperBound)）")
            exit(1)
        }
        return value
    }


    // MARK: - Crash reporting (minimal)

    /// Installs a minimal crash reporter: an Objective-C uncaught-exception
    /// handler plus C signal handlers for the fatal signals. Each writes a
    /// one-line marker to `<Application Support>/ToastMonitor/crash-<ts>.log`.
    /// Does not interfere with normal operation: the signal path restores the
    /// default disposition and re-raises so the OS still records the crash.
    private func installCrashHandlers() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ToastMonitor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        pruneCrashLogs(in: dir)
        // Precompute "<dir>/crash-" for the signal handler (which must not
        // call Foundation) and force the scratch buffer's lazy init now.
        tmCrashDirPrefixC = Array((dir.path + "/crash-").utf8CString.dropLast())
        _ = tmCrashScratch.count

        // Objective-C exception handler: may use Foundation (normal context).
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack = exception.callStackSymbols.prefix(12).joined(separator: "\n")
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("ToastMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let line = "uncaught exception \(name): \(reason)\n\(stack)\n"
            let path = dir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).log")
            try? line.write(to: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            // Returning lets the runtime terminate the app normally.
        }

        signal(SIGILL, tmCrashSignalHandler)
        signal(SIGABRT, tmCrashSignalHandler)
        signal(SIGSEGV, tmCrashSignalHandler)
        signal(SIGBUS, tmCrashSignalHandler)
        signal(SIGFPE, tmCrashSignalHandler)
    }

    private func pruneCrashLogs(in directory: URL) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
            .isRegularFileKey, .contentModificationDateKey
        ], options: [.skipsHiddenFiles])) ?? []
        let logs = urls.filter { url in
            url.lastPathComponent.hasPrefix("crash-") && url.pathExtension == "log"
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in logs {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        for url in logs.dropFirst(20) {
            try? fm.removeItem(at: url)
        }
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandlers()
        // Headless CLI modes (used for provisioning the keychain over SSH).
        let args = CommandLine.arguments
        if args.contains("--version") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0 (dev)"
            print("ToastMonitor \(version)")
            exit(0)
        }
        if args.contains("--probe-vault") {
            // Diagnostic: run in a GUI session via `open --args` so the
            // keychain behaves exactly as it does for the real app. Reports
            // presence/length only — never key material. Written to the app
            // support dir (0600), not /tmp.
            let raw = KeychainStore.get(account: "or-keys")
            let orKeys = OpenRouterClient.shared.storedKeys()
            let log = """
            vault: \(KeychainStore.get(account: "or-keys") != nil ? "loginKC ok" : "loginKC empty")
            or-keys raw: \(raw == nil ? "nil" : "present") (len \(raw?.count ?? -1))
            storedKeys(): \(orKeys.count) keys
            hasKey: \(OpenRouterClient.shared.hasKey)
            state.error: \(OpenRouterClient.shared.state.error ?? "nil")
            state.usageMonthly: \(OpenRouterClient.shared.state.usageMonthly)
            """
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ToastMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let outURL = dir.appendingPathComponent("probe.log")
            try? log.write(to: outURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
            print(log)
            exit(0)
        }
        if args.contains("--set-or-key") {
            Database.shared.open()
            guard let key = readSecretFromStdin("OpenRouter API key (stdin):"),
                  OpenRouterClient.shared.setKey(key) else {
                print("key store failed (Keychain unavailable or key invalid; no plaintext fallback)")
                exit(1)
            }
            print("key stored")
            exit(0)
        }
        if args.contains("--clear-or-key") {
            Database.shared.open()
            KeychainStore.delete(account: "or-keys", allowPrompt: true)
            KeychainStore.delete(account: "openrouter-key", allowPrompt: true)
            Database.shared.setSetting("or_keys", nil)
            Database.shared.setSetting("openrouter_key", nil)
            Database.shared.setSetting("or_cred_storage", nil)
            print("key cleared (keychain + legacy settings)")
            exit(0)
        }
        if args.contains("--clear-go") {
            Database.shared.open()
            KeychainStore.delete(account: "go-workspace-id", allowPrompt: true)
            KeychainStore.delete(account: "go-auth-cookie", allowPrompt: true)
            Database.shared.setSetting("go_workspace_id", nil)
            Database.shared.setSetting("go_auth_cookie", nil)
            Database.shared.setSetting("go_cred_storage", nil)
            print("go credentials cleared")
            exit(0)
        }
        if args.contains("--provision-or-key") {
            Database.shared.open()
            guard let key = readSecretFromStdin("OpenRouter API key (stdin):") else {
                print("key provision failed: empty input")
                exit(1)
            }
            if OpenRouterClient.shared.provisionKey(key) {
                print("key provisioned")
                exit(0)
            }
            print("key provision failed: Keychain unavailable")
            exit(1)
        }
        if let flag = args.firstIndex(of: "--provision-go") {
            guard flag + 1 < args.count, !args[flag + 1].isEmpty else {
                print("--provision-go 缺少 workspace ID")
                exit(1)
            }
            Database.shared.open()
            let workspaceID = args[flag + 1]
            guard let cookie = readSecretFromStdin("OpenCode Go auth cookie (stdin):") else {
                print("go provision failed: empty cookie")
                exit(1)
            }
            if OpenCodeGoClient.shared.provision(workspaceId: workspaceID, cookie: cookie) {
                print("go provisioned")
                exit(0)
            }
            print("go provision failed: Keychain unavailable or credentials invalid")
            exit(1)
        }
        if let flag = args.firstIndex(of: "--provision-hermes") {
            guard flag + 1 < args.count, !args[flag + 1].isEmpty else {
                print("--provision-hermes 缺少 URL")
                exit(1)
            }
            Database.shared.open()
            if HermesRemoteClient.shared.provision(url: args[flag + 1]) {
                print("hermes provisioned")
                exit(0)
            }
            print("hermes provision failed: URL must be HTTPS or private network")
            exit(1)
        }
        if let flag = args.firstIndex(of: "--export-diagnostics") {
            guard flag + 1 < args.count, !args[flag + 1].isEmpty else {
                print("--export-diagnostics 缺少输出路径")
                exit(1)
            }
            Database.shared.open()
            let summary = Database.shared.diagnosticsSummary()
            let outPath = args[flag + 1]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]),
               (try? data.write(to: URL(fileURLWithPath: outPath))) != nil {
                print("diagnostics written to \(outPath)")
                exit(0)
            }
            print("diagnostics export failed")
            exit(1)
        }
        // Headless UI verification: render the popover root to a PNG.
        // Usage: ToastMonitor --render-popover /tmp/popover.png [height]
        if let flag = args.firstIndex(of: "--render-popover") {
            guard flag + 1 < args.count else { print("--render-popover 缺少输出路径"); exit(1) }
            let outPath = args[flag + 1]
            let height = boundedRenderDimension(args, index: flag + 2,
                                                defaultValue: 620, range: 64...10_000,
                                                label: "--render-popover")
            Database.shared.open()
            AppState.shared.start()
            var renderPeriod: String?
            if let periodFlag = args.firstIndex(of: "--period"), periodFlag + 1 < args.count {
                renderPeriod = args[periodFlag + 1]
            }
            let deadline = Date().addingTimeInterval(10)
            while AppState.shared.snapshotFetchedAt == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if let renderPeriod {
                NotificationCenter.default.post(
                    name: PopoverHomeView.testPeriodNotification,
                    object: renderPeriod
                )
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // Opaque backdrop: off-screen cacheDisplay skips drawing for
            // transparent views (the real panel draws on NSVisualEffectView).
            renderSnapshot(PopoverRootView().background(Color(nsColor: .windowBackgroundColor)),
                           to: outPath, height: height, width: 400)
            exit(0)
        }
        // Headless UI verification: render the dashboard to a PNG without a
        // window or Keychain access (OpenRouter/Go clients are not started).
        // Usage: ToastMonitor --render-dashboard /tmp/dash.png
        if let flag = args.firstIndex(of: "--render-dashboard") {
            guard flag + 1 < args.count else { print("--render-dashboard 缺少输出路径"); exit(1) }
            let outPath = args[flag + 1]
            let height = boundedRenderDimension(args, index: flag + 2,
                                                defaultValue: 720, range: 200...10_000,
                                                label: "--render-dashboard 高度")
            let width = boundedRenderDimension(args, index: flag + 3,
                                               defaultValue: 1120, range: 320...20_000,
                                               label: "--render-dashboard 宽度")
            let tabName = flag + 4 < args.count ? args[flag + 4] : "overview"
            let tab: DashboardView.Tab? = {
                switch tabName {
                case "analysis": return .analysis
                case "plans": return .plans
                case "sources", "settings": return .settings
                default: return .overview
                }
            }()
            Database.shared.open()
            AppState.shared.start()
            let deadline = Date().addingTimeInterval(10)
            while AppState.shared.snapshotFetchedAt == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            renderDashboard(to: outPath, height: height, width: width, tab: tab)
            exit(0)
        }

        let isDashboardVerification = args.contains("--show-dashboard")
        let isPanelVerification = args.contains("--show-panel")
            || args.contains("--verify-status-toggle")
        NSApp.setActivationPolicy(.accessory)
        Database.shared.open() // synchronous — needed before any DB reads

        // UI verification must be hermetic. A directly executed development
        // binary has no stable code-signing requirement, so starting the
        // OpenRouter and OpenCode Go clients here would ask for three login
        // Keychain items while we're only inspecting toolbar/panel geometry.
        if isDashboardVerification || isPanelVerification {
            AppState.shared.start()
            NSApp.finishLaunching()
            if isPanelVerification {
                setupMenuBar()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppState.shared.refresh()
                WindowManager.shared.show()
                if let captureFlag = args.firstIndex(of: "--capture-dashboard"),
                   captureFlag + 1 < args.count {
                    let output = args[captureFlag + 1]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if WindowManager.shared.captureWindow(to: output) {
                            print("captured dashboard \(output)")
                        } else {
                            print("dashboard capture failed")
                        }
                    }
                }
            }
            return
        }

        KeychainStore.migrateLegacyVaultIfNeeded() // one-time: legacy vault file → login keychain
        AppState.shared.start()
        CollectorEngine.shared.start()
        OpenRouterClient.shared.start()
        OpenCodeGoClient.shared.start()
        CodexQuotaClient.shared.start()
        HermesRemoteClient.shared.start()
        setupMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppState.shared.refresh()
        }
    }

    /// Renders the dashboard root into a PNG via off-screen NSHostingView
    /// (used by --render-dashboard; no window server round-trip needed).
    private func renderDashboard(to path: String, height: CGFloat = 720, width: CGFloat = 1120, tab: DashboardView.Tab? = nil) {
        let root = DashboardView(initialTab: tab).environmentObject(AppState.shared)
        renderSnapshot(root, to: path, height: height, width: width)
    }

    private func renderSnapshot<V: View>(_ root: V, to path: String, height: CGFloat, width: CGFloat) {
        let hosting = NSHostingView(rootView: root)
        if path.contains("dark") {
            hosting.appearance = NSAppearance(named: .darkAqua)
        } else if path.contains("light") {
            hosting.appearance = NSAppearance(named: .aqua)
        }
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("render failed: no bitmap rep")
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed: no PNG data")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("rendered \(path)")
        } catch {
            print("render failed: cannot write \(path): \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Native status item + Tusi-style borderless panel. AppKit owns the
    /// material and expanded-interface lifecycle; the panel intentionally has
    /// no NSPopover arrow.
    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // NSStatusBarButton sizes itself from its title, not from
            // subviews — a hosting view can never make it visible. Use
            // attributedTitle (image attachment + text) natively.
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityLabel("ToastMonitor 用量与额度")
            updateStatusLabel(button)
            // Refresh the label whenever AppState publishes changes.
            appStateObserver = AppState.shared.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let button = self.statusItem?.button else { return }
                    self.updateStatusLabel(button)
                }
            }
        }
        panelController = PanelController(
            statusItem: item,
            content: PopoverRootView(),
            // Start near the measured home-page size. A legacy 640 pt seed
            // visibly expanded on first presentation and made the fixed tabs
            // look as though the whole document had shifted upward.
            size: NSSize(width: 400, height: 780)
        )
        // A borderless NSPanel owns its own visibility state. Keep the status
        // button's explicit target/action on every macOS version so a second
        // click is a real toggle. Expanded-interface sessions are intended for
        // interfaces whose lifecycle is delegated back to AppKit; combining
        // both mechanisms made an already-visible panel ignore the next click.

        // 真实运行截图钩子（重设计验收用）：--show-panel 显示 popover，
        // --backdrop white|dark 在背后垫一个大窗口模拟亮/暗桌面背景，
        // --capture <path> 让 app 自己把窗口保存成 PNG（窗口真实显示，
        // 玻璃采样到背后窗口；screencapture 受会话隔离不可靠）。
        let args = CommandLine.arguments
        if args.contains("--verify-status-toggle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let button = self.statusItem?.button,
                      let panel = self.panelController else {
                    print("status toggle verification failed: unavailable")
                    exit(1)
                }
                button.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let opened = panel.isVisible
                    button.performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        let closed = !panel.isVisible
                        print("status toggle verification: opened=\(opened) closed=\(closed)")
                        exit(opened && closed ? 0 : 1)
                    }
                }
            }
        }
        if args.contains("--show-panel") {
            debugBackdrop = nil
            if let bi = args.firstIndex(of: "--backdrop"), bi + 1 < args.count {
                let bg = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 960),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
                bg.backgroundColor = args[bi + 1] == "dark" ? .black : .white
                bg.isOpaque = true
                bg.level = .normal
                bg.orderFront(nil)
                debugBackdrop = bg
            }
            let capturePath = args.firstIndex(of: "--capture").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let panel = self.panelController else { return }
                // A command-line-launched accessory app has no ordinary
                // window to make it active. Activate only this hermetic UI
                // verification path so the floating panel remains attached to
                // the current Space while Computer Use connects.
                NSApp.activate(ignoringOtherApps: true)
                panel.toggle()
                if let capturePath {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if let view = panel.panelContent,
                           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            if let data = rep.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath: capturePath))
                                print("captured \(capturePath)")
                            }
                        }
                    }
                }
            }
        }
    }


    private func updateStatusLabel(_ button: NSStatusBarButton) {
        let app = AppState.shared
        // Status bar shows ONLY today's tokens (user preference); costs live
        // in the popover and tooltip.
        let text = Format.compact(app.todayTokens)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attr = NSMutableAttributedString()
        if let img = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: nil) {
            let attach = NSTextAttachment()
            attach.image = img
            // 与系统时间同级排版：等宽数字 13pt；图标（16pt SF Symbol）
            // 中心对齐文字 cap 高度中心 —— bounds.y 是相对基线的偏移，
            // 下沉 (图标高 - capHeight)/2 让两者视觉共线。
            let size = img.size
            attach.bounds = NSRect(x: 0,
                                   y: -round((size.height - font.capHeight) / 2),
                                   width: size.width,
                                   height: size.height)
            attr.append(NSAttributedString(attachment: attach))
        }
        attr.append(NSAttributedString(string: " \(text)", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]))
        button.attributedTitle = attr
        button.setAccessibilityValue("今日 \(text) tokens")

        let or = OpenRouterClient.shared
        let todayActual = app.costToday.actual + or.state.usageDaily
        let tooltip = """
        ToastMonitor
        今日 \(Format.compact(app.todayTokens)) tokens（输入 + 输出 + 缓存命中）
        今日已确认变量支出 \(Format.money(todayActual))
        今日估算变量支出 \(Format.money(app.costToday.estimated))
        · 订阅摊销 \(Format.money(subAmortized()))
        · OpenRouter 实际 \(Format.money(or.state.usageDaily))
        """
        button.toolTip = tooltip
    }

    private func subAmortized() -> Double {
        var t = 0.0
        let app = AppState.shared
        for sub in app.subscriptions {
            guard sub.startDate <= Int64(Date().timeIntervalSince1970) else { continue }
            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                t += sub.price / Double(info.totalDays)
            }
        }
        return t
    }

    @objc private func togglePanel(_ sender: Any?) {
        // AppKit sends both click-count 1 and click-count 2 for a double click.
        // Act on the first event only so a fast double click cannot immediately
        // undo its own toggle.
        if let event = NSApp.currentEvent,
           event.type == .leftMouseUp,
           event.clickCount >= 2 {
            return
        }
        panelController?.toggle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Crash signal handler (async-signal-safe)

/// "<dir>/crash-" (NUL-terminated). Built once in `installCrashHandlers`
/// (Foundation allowed there); read-only afterwards.
nonisolated(unsafe) private var tmCrashDirPrefixC: [CChar] = []
/// Preallocated scratch buffer. Lazily initialized on first access — forced
/// during `installCrashHandlers`, so the handler itself never allocates
/// (malloc is not async-signal-safe).
nonisolated(unsafe) private var tmCrashScratch = [CChar](repeating: 0, count: 2048)

/// Appends the decimal digits of `v` (>= 0) to `buf` at `i`, returning the
/// index after the last digit. Pure integer math — safe in signal handlers.
private func tmAppendDecimal(_ v: Int64, to buf: UnsafeMutableBufferPointer<CChar>, at i: Int) -> Int {
    var n = 1
    var t = v
    while t >= 10 { n += 1; t /= 10 }
    var pos = i + n - 1
    var x = v
    repeat {
        buf[pos] = CChar(48 + x % 10)
        x /= 10
        pos -= 1
    } while x > 0
    return i + n
}

/// Writes `<dir>/crash-<unix-ts>.log` with a one-line "signal <N>" marker,
/// then restores the default disposition and re-raises so the OS records
/// the crash normally. Only async-signal-safe calls: open/write/close/time/
/// signal/raise plus integer math on the preallocated buffer (string
/// literals are static; iterating their utf8 never allocates).
private func tmCrashSignalHandler(_ sig: Int32) {
    tmCrashScratch.withUnsafeMutableBufferPointer { buf in
        var i = 0
        for c in tmCrashDirPrefixC {
            if i >= buf.count - 24 { break }
            buf[i] = c
            i += 1
        }
        i = tmAppendDecimal(Int64(time(nil)), to: buf, at: i)
        for b in ".log".utf8 {
            guard i < buf.count - 2 else { break }
            buf[i] = CChar(bitPattern: b)
            i += 1
        }
        buf[i] = 0 // NUL-terminate the path
        let fd = open(buf.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            var j = 0
            for b in "signal ".utf8 {
                buf[j] = CChar(bitPattern: b)
                j += 1
            }
            j = tmAppendDecimal(Int64(sig), to: buf, at: j)
            buf[j] = 0x0A // '\n'
            _ = write(fd, buf.baseAddress!, j + 1)
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
