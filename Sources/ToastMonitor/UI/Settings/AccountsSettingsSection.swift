import SwiftUI

/// Settings › Sources › Accounts: every quota/balance account in one list.
/// A collapsed row names the account and its connection state; expanding it
/// shows that account's credentials and options, including whether its row
/// appears in the popover.
struct AccountsSettingsSection: View {
    /// Posted when an account row is shown or hidden, so the resident
    /// popover picks it up without waiting for its next appearance.
    static let quotaRowsChanged = Notification.Name("tmQuotaRowsChanged")

    private enum CredentialTarget: Equatable {
        case openCodeGo, openRouter, commandCode
    }

    @ObservedObject private var app = AppState.shared
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @AppStorage(CodexPlanName.customNameKey) private var codexName = ""

    @State private var expanded: Set<String> = []
    @State private var rowVisible: [String: Bool] = [:]
    @State private var codexBilling = "api"

    @State private var showGoForm = false
    @State private var showORForm = false
    @State private var showCCForm = false
    @State private var goWS = ""
    @State private var goCookie = ""
    @State private var orKey = ""
    @State private var orAppend = false
    @State private var ccCookie = ""
    @State private var pendingClear: CredentialTarget?
    /// Last save/clear outcome per account, shown inside that account only.
    @State private var message: [String: (text: String, failed: Bool)] = [:]

    private static let popoverKeys = ["claude", "go", "codex", "cc", "router", "deepseek"]

    var body: some View {
        Section("Accounts") {
            account("claude", "Claude", symbol: ToolKind.claude.symbol, color: ToolKind.claude.color,
                    status: claudeStatus) {
                Toggle("Read quota from Claude Code", isOn: Binding(
                    get: { claudeQuota.enabled },
                    set: { claudeQuota.setEnabled($0) }
                ))
                Text("Uses an undocumented Anthropic endpoint with your Claude Code login. "
                     + "Anthropic's Consumer Terms restrict these OAuth tokens to Claude Code and claude.ai.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            account("go", "OpenCode Go", symbol: "g.circle.fill", color: ToolKind.opencode.color,
                    status: goClient.configured ? "Connected" : "Not connected") {
                credentials(configured: goClient.configured, label: "Workspace",
                            change: { showGoForm = true }, clear: { pendingClear = .openCodeGo })
            }
            account("codex", "Codex", symbol: ToolKind.codex.symbol, color: ToolKind.codex.color,
                    status: codexQuota.state.lastSync > 0 ? "Connected" : "Not connected") {
                LabeledContent("Billing") {
                    Picker("Billing", selection: $codexBilling) {
                        Text("Subscription").tag("subscription")
                        Text("API").tag("api")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
                TextField("Name", text: $codexName, prompt: Text(codexAutoName))
            }
            account("cc", "Command Code", symbol: "c.circle.fill", color: TMDesign.commandCode,
                    status: ccQuota.state.configured ? (ccQuota.state.planName ?? "Connected") : "Not connected") {
                credentials(configured: ccQuota.state.configured, label: "Session",
                            change: { showCCForm = true }, clear: { pendingClear = .commandCode })
            }
            account("router", "OpenRouter", symbol: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color,
                    status: orClient.hasKey ? keyCountText : "Not connected") {
                credentials(configured: orClient.hasKey, label: "API keys",
                            change: { showORForm = true }, clear: { pendingClear = .openRouter })
            }
            account("deepseek", "DeepSeek", symbol: "d.circle.fill", color: ToolKind.dsh.color,
                    status: deepseek.state.kind == nil ? "Not connected"
                        : (deepseek.state.kind == .platform ? "Platform account" : "API key")) {
                DeepSeekAccountSettings()
            }
        }
        .onAppear {
            for key in Self.popoverKeys {
                rowVisible[key] = Database.shared.setting("hide_quota_row_\(key)") != "1"
            }
            codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
        }
        .onChange(of: codexBilling) { value in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Database.shared.setSetting("codex_billing_mode", value)
            }
        }
        .onChange(of: showGoForm) { if !$0 { goWS = ""; goCookie = "" } }
        .onChange(of: showORForm) { if !$0 { orKey = ""; orAppend = false } }
        .onChange(of: showCCForm) { if !$0 { ccCookie = "" } }
        .sheet(isPresented: $showGoForm) { goSheet }
        .sheet(isPresented: $showORForm) { openRouterSheet }
        .sheet(isPresented: $showCCForm) { commandCodeSheet }
        .confirmationDialog("Clear saved credentials?", isPresented: Binding(
            get: { pendingClear != nil },
            set: { if !$0 { pendingClear = nil } })) {
                Button("Cancel", role: .cancel) { pendingClear = nil }
                Button("Clear Credentials", role: .destructive) { clearPending() }
            } message: {
                Text(clearMessage)
            }
    }

    // MARK: - Rows

    private func account<Content: View>(_ key: String, _ title: String, symbol: String, color: Color,
                                        status: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open { expanded.insert(key) } else { expanded.remove(key) }
            })) {
            content
            if let note = message[key] {
                Text(note.text)
                    .foregroundStyle(note.failed ? TMDesign.danger : .secondary)
            }
            Toggle("Show in popover", isOn: visibility(key))
        } label: {
            LabeledContent {
                Text(status)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .frame(width: 18)
                    Text(title)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(status)
    }

    private func credentials(configured: Bool, label: String,
                             change: @escaping () -> Void,
                             clear: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                if configured {
                    Button("Clear", role: .destructive, action: clear)
                }
                Button(configured ? "Change…" : "Set Up…", action: change)
            }
        }
    }

    private func visibility(_ key: String) -> Binding<Bool> {
        Binding(
            get: { rowVisible[key] ?? true },
            set: { visible in
                rowVisible[key] = visible
                let value = visible ? nil : "1"
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Database.shared.setSetting("hide_quota_row_\(key)", value)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.quotaRowsChanged, object: nil)
                    }
                }
            }
        )
    }

    private var claudeStatus: String {
        guard claudeQuota.enabled else { return "Off" }
        if claudeQuota.state.error != nil { return "Error" }
        return claudeQuota.state.configured || claudeQuota.state.lastSync > 0 ? "Connected" : "Not signed in"
    }

    private var keyCountText: String {
        let n = orClient.state.keyCount
        return n == 1 ? "1 key" : "\(n) keys"
    }

    /// What the Codex row is called when no custom name is set.
    private var codexAutoName: String {
        CodexPlanName.resolve(custom: nil, apiPlan: codexQuota.state.planType,
                              subscription: app.subscriptions.first { $0.plan == "openai" || $0.plan == "codex" })
    }

    // MARK: - Credential sheets

    private var goSheet: some View {
        credentialSheet(title: "OpenCode Go Credentials",
                        note: "Stored in your macOS Keychain and used only to query quota.",
                        key: "go", saveTitle: "Save & Query",
                        canSave: !goWS.trimmed.isEmpty && !goCookie.trimmed.isEmpty,
                        cancel: { showGoForm = false }, save: saveGo) {
            TextField("Workspace ID", text: $goWS, prompt: Text("wrk_..."))
                .font(.system(size: TMType.body, design: .monospaced))
            SecureField("Authentication cookie", text: $goCookie, prompt: Text("Fe26.2**..."))
                .font(.system(size: TMType.body, design: .monospaced))
        }
    }

    private var openRouterSheet: some View {
        credentialSheet(title: "OpenRouter API Key",
                        note: "Stored in your macOS Keychain and never displayed after saving.",
                        key: "router", saveTitle: "Save",
                        canSave: !orKey.trimmed.isEmpty,
                        cancel: { showORForm = false }, save: saveOpenRouter) {
            SecureField("API key", text: $orKey, prompt: Text("sk-or-..."))
                .font(.system(size: TMType.body, design: .monospaced))
            if orClient.hasKey {
                Toggle("Keep existing keys", isOn: $orAppend)
            }
        }
    }

    private var commandCodeSheet: some View {
        credentialSheet(title: "Command Code Session",
                        note: "Paste the Cookie header from a signed-in commandcode.ai browser session, "
                            + "or just the session token. Stored in your macOS Keychain.",
                        key: "cc", saveTitle: "Save",
                        canSave: !ccCookie.trimmed.isEmpty,
                        cancel: { showCCForm = false }, save: saveCommandCode) {
            SecureField("Cookie header or session token", text: $ccCookie,
                        prompt: Text("__Secure-commandcode_prod_.session_token=…"))
                .font(.system(size: TMType.body, design: .monospaced))
        }
    }

    private func credentialSheet<Fields: View>(title: String, note: String, key: String,
                                               saveTitle: String, canSave: Bool,
                                               cancel: @escaping () -> Void,
                                               save: @escaping () -> Void,
                                               @ViewBuilder fields: () -> Fields) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(note)
                .foregroundStyle(.secondary)
            Form { fields() }
                .formStyle(.grouped)
            if let note = message[key], note.failed {
                Text(note.text)
                    .foregroundStyle(TMDesign.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func saveGo() {
        if goClient.provision(workspaceId: goWS.trimmed, cookie: goCookie.trimmed) {
            goClient.refresh()
            showGoForm = false
            message["go"] = ("Credentials saved", false)
        } else {
            message["go"] = (goClient.state.error ?? "Save failed (Keychain unavailable)", true)
        }
    }

    private func saveOpenRouter() {
        let key = orKey.trimmed
        if orAppend ? orClient.addKey(key) : orClient.setKey(key) {
            showORForm = false
            message["router"] = ("Key saved", false)
        } else {
            message["router"] = (orClient.state.error ?? "Save failed (Keychain unavailable)", true)
        }
    }

    private func saveCommandCode() {
        if ccQuota.provision(cookie: ccCookie.trimmed) {
            ccQuota.refresh()
            showCCForm = false
            message["cc"] = ("Session saved", false)
        } else {
            message["cc"] = (ccQuota.state.error ?? "Save failed (Keychain unavailable)", true)
        }
    }

    private var clearMessage: String {
        switch pendingClear {
        case .openCodeGo:
            return "ToastMonitor will stop showing OpenCode Go quota until credentials are set up again."
        case .commandCode:
            return "ToastMonitor will remove the saved Command Code session from Keychain and stop showing its quota."
        case .openRouter, nil:
            return "ToastMonitor will remove the saved OpenRouter keys from Keychain and stop showing the balance."
        }
    }

    private func clearPending() {
        switch pendingClear {
        case .openCodeGo:
            goClient.clear()
            message["go"] = ("Credentials cleared", false)
        case .openRouter:
            _ = orClient.setKey(nil)
            message["router"] = ("Keys cleared", false)
        case .commandCode:
            ccQuota.clear()
            message["cc"] = ("Session cleared", false)
        case .none:
            break
        }
        pendingClear = nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
