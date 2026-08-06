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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless CLI modes (used for provisioning the keychain over SSH).
        let args = CommandLine.arguments
        if args.contains("--probe-vault") {
            // Diagnostic: run in a GUI session via `open --args` so the
            // keychain behaves exactly as it does for the real app.
            let raw = KeychainStore.get(account: "or-keys")
            let orKeys = OpenRouterClient.shared.storedKeys()
            let log = """
            vault: \(KeychainStore.get(account: "or-keys") != nil ? "loginKC ok" : "loginKC empty")
            or-keys raw: \(raw?.prefix(20) ?? "nil") (len \(raw?.count ?? -1))
            storedKeys(): \(orKeys.count) keys, first prefix \(orKeys.first?.prefix(8) ?? "-")
            hasKey: \(OpenRouterClient.shared.hasKey)
            state.error: \(OpenRouterClient.shared.state.error ?? "nil")
            state.usageMonthly: \(OpenRouterClient.shared.state.usageMonthly)
            """
            try? log.write(toFile: "/tmp/tm-probe.log", atomically: true, encoding: .utf8)
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

        let attr = NSMutableAttributedString()
        if let img = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: nil) {
            let attach = NSTextAttachment()
            attach.image = img
            attr.append(NSAttributedString(attachment: attach))
        }
        attr.append(NSAttributedString(string: " \(text)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
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
            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
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
