import SwiftUI
import AppKit
import Darwin

/// Pure AppKit entry point. No SwiftUI Scene at all: a WindowGroup or
/// Settings scene makes macOS re-open an empty window when the last window
/// closes (user reported the mystery "ToastMonitor" blank window). The
/// Dashboard is an NSWindow owned by WindowManager, the popover is an
/// NSPanel owned by PanelController — nothing needs a scene.
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
    /// Read secrets from stdin so they never appear in argv/`ps` output or
    /// shell history. Callers may pipe one line or an EOF-terminated value.
    private func readSecretFromStdin(_ label: String) -> String? {
        print(label, terminator: " ")
        fflush(stdout)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
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
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Precompute "<dir>/crash-" for the signal handler (which must not
        // call Foundation) and force the scratch buffer's lazy init now.
        tmCrashDirPrefixC = Array((dir.path + "/crash-").utf8CString)
        _ = tmCrashScratch.count

        // Objective-C exception handler: may use Foundation (normal context).
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack = exception.callStackSymbols.prefix(12).joined(separator: "\n")
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("ToastMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = "uncaught exception \(name): \(reason)\n\(stack)\n"
            let path = dir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).log")
            try? line.write(to: path, atomically: true, encoding: .utf8)
            // Returning lets the runtime terminate the app normally.
        }

        signal(SIGILL, tmCrashSignalHandler)
        signal(SIGABRT, tmCrashSignalHandler)
        signal(SIGSEGV, tmCrashSignalHandler)
        signal(SIGBUS, tmCrashSignalHandler)
        signal(SIGFPE, tmCrashSignalHandler)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandlers()
        // Headless CLI modes (used for provisioning the keychain over SSH).
        let args = CommandLine.arguments
        if args.contains("--version") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0 (dev)"
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
            guard let key = readSecretFromStdin("OpenRouter API key (stdin):"),
                  KeychainStore.set(key, account: "or-keys") else {
                print("key store failed (Keychain unavailable; no plaintext fallback)")
                exit(1)
            }
            print("key stored")
            exit(0)
        }
        if args.contains("--clear-or-key") {
            Database.shared.open()
            KeychainStore.delete(account: "or-keys")
            KeychainStore.delete(account: "openrouter-key")
            Database.shared.setSetting("or_keys", nil)
            Database.shared.setSetting("openrouter_key", nil)
            Database.shared.setSetting("or_cred_storage", nil)
            print("key cleared (keychain + legacy settings)")
            exit(0)
        }
        if args.contains("--clear-go") {
            Database.shared.open()
            KeychainStore.delete(account: "go-workspace-id")
            KeychainStore.delete(account: "go-auth-cookie")
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
        if let flag = args.firstIndex(of: "--provision-go"), flag + 1 < args.count {
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
            print("go provision failed: Keychain unavailable")
            exit(1)
        }
        if let flag = args.firstIndex(of: "--provision-hermes"), flag + 1 < args.count {
            Database.shared.open()
            if HermesRemoteClient.shared.provision(url: args[flag + 1]) {
                print("hermes provisioned")
                exit(0)
            }
            print("hermes provision failed: URL must be HTTPS or private network")
            exit(1)
        }
        if let flag = args.firstIndex(of: "--export-diagnostics"), flag + 1 < args.count {
            Database.shared.open()
            let summary = Database.shared.diagnosticsSummary()
            let outPath = args[flag + 1]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: outPath))
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
            let height = (flag + 2 < args.count) ? (Double(args[flag + 2]) ?? 620) : 620
            guard height.isFinite, height > 0 else { print("--render-popover 高度无效"); exit(1) }
            Database.shared.open()
            ensureDefaultSubscriptions()
            AppState.shared.start()
            let deadline = Date().addingTimeInterval(10)
            while AppState.shared.snapshotFetchedAt == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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
            let height = (flag + 2 < args.count) ? (Double(args[flag + 2]) ?? 720) : 720
            let width = (flag + 3 < args.count) ? (Double(args[flag + 3]) ?? 1120) : 1120
            guard height.isFinite, height > 0, width.isFinite, width > 0 else { print("--render-dashboard 尺寸无效"); exit(1) }
            let tabName = flag + 4 < args.count ? args[flag + 4] : "overview"
            let tab: DashboardView.Tab? = {
                switch tabName {
                case "analysis": return .analysis
                case "plans": return .plans
                case "sources": return .sources
                default: return .overview
                }
            }()
            Database.shared.open()
            ensureDefaultSubscriptions()
            AppState.shared.start()
            let deadline = Date().addingTimeInterval(10)
            while AppState.shared.snapshotFetchedAt == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            renderDashboard(to: outPath, height: height, width: width, tab: tab)
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)
        Database.shared.open() // synchronous — needed before any DB reads
        _ = KeychainStore.migrateLegacyVaultIfNeeded() // one-time: legacy vault file → login keychain
        ensureDefaultSubscriptions()
        AppState.shared.start()
        CollectorEngine.shared.start()
        OpenRouterClient.shared.start()
        OpenCodeGoClient.shared.start()
        CodexQuotaClient.shared.start()
        HermesRemoteClient.shared.start()
        setupMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppState.shared.refresh()
            if args.contains("--show-dashboard") {
                WindowManager.shared.show()
            }
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
        try? data.write(to: URL(fileURLWithPath: path))
        print("rendered \(path)")
    }

    /// Custom status item + floating panel (Tusi-style 20pt corners).
    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // NSStatusBarButton sizes itself from its title, not from
            // subviews — a hosting view can never make it visible. Use
            // attributedTitle (image attachment + text) natively.
            button.target = self
            button.action = #selector(togglePanel(_:))
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
            size: NSSize(width: 400, height: 600)
        )
    }

    /// Codex Plus is a fixed monthly subscription (like OpenCode Go): it is
    /// NOT variable API spend, so it never lands in "实际支出"; it IS counted
    /// in the estimated column and in the hero total. Price is editable in
    /// Settings; deleting the record removes it everywhere.
    private func ensureDefaultSubscriptions() {
        let db = Database.shared
        if !db.subscriptions().contains(where: { $0.plan == "codex" }) {
            db.upsertSubscription(Database.Subscription(
                id: 0, name: "Codex Plus", plan: "codex",
                startDate: Int64(Date().timeIntervalSince1970),
                cycle: "monthly", price: 20, currency: "USD"))
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
        panelController?.toggle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Crash signal handler (async-signal-safe)

/// "<dir>/crash-" (NUL-terminated). Built once in `installCrashHandlers`
/// (Foundation allowed there); read-only afterwards.
private var tmCrashDirPrefixC: [CChar] = []
/// Preallocated scratch buffer. Lazily initialized on first access — forced
/// during `installCrashHandlers`, so the handler itself never allocates
/// (malloc is not async-signal-safe).
private var tmCrashScratch = [CChar](repeating: 0, count: 2048)

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
