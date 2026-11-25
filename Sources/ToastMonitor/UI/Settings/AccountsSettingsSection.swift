
import SwiftUI
@MainActor
final class CodexBillingModeCoordinator {
    static let shared = CodexBillingModeCoordinator()
    private let database: Database
    private let queries: UsageQueryService
    private let queue: DispatchQueue
    private let onCommitted: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var latestSelection: String?

    init(database: Database = .shared, queries: UsageQueryService = .shared,
         queue: DispatchQueue = DispatchQueue(label: "toastmonitor.codex-billing-setting", qos: .userInitiated),
         onCommitted: @escaping @MainActor () -> Void = { AppState.shared.refresh() }) {
        self.database = database
        self.queries = queries
        self.queue = queue
        self.onCommitted = onCommitted
    }

    func reloadFromDatabase() {
        generation &+= 1
        latestSelection = database.setting("codex_billing_mode") ?? "api"
    }

    @discardableResult
    func set(_ value: String, restoreSelection: @escaping @MainActor (String) -> Void,
             completion: @escaping @MainActor () -> Void = {}) -> Bool {
        let previousSelection = latestSelection ?? (database.setting("codex_billing_mode") ?? "api")
        guard value != previousSelection else { return false }
        latestSelection = value
        generation &+= 1
        let requestGeneration = generation
        let database = self.database
        queue.async { [weak self] in
            let saved = database.setSetting("codex_billing_mode", value)
            DispatchQueue.main.async {
                guard let self else { return }
                guard saved else {
                    if self.generation == requestGeneration {
                        let persisted = database.setting("codex_billing_mode") ?? "api"
                        self.latestSelection = persisted
                        restoreSelection(persisted)
                    }
                    completion()
                    return
                }
                self.queries.invalidateBillingModeCaches {
                    self.onCommitted()
                    completion()
                }
            }
        }
        return true
    }
}


/// Which quota/balance accounts show a row in the popover. One store behind
/// both Settings › Appearance and Settings › Accounts, so the two
/// lists always agree.
enum PopoverAccountRows {
    static let accounts: [(key: String, title: String)] = [
        ("claude", "Claude"), ("go", "OpenCode Go"), ("codex", "Codex"),
        ("cc", "Command Code"), ("grok", "Grok"), ("antigravity", "Antigravity"), ("router", "OpenRouter"), ("deepseek", "DeepSeek"),
    ]

    static var keys: [String] { accounts.map(\.key) }

    static func isVisible(_ key: String) -> Bool {
        Database.shared.setting("hide_quota_row_\(key)") != "1"
    }

    /// Persists off the main thread, then tells the resident popover.
    static func setVisible(_ key: String, _ visible: Bool) {
        let value = visible ? nil : "1"
        SettingsWriteQueue.shared.async {
            _ = Database.shared.setSetting("hide_quota_row_\(key)", value)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AccountsSettingsSection.quotaRowsChanged, object: nil)
            }
        }
    }
}

/// Settings › Accounts: every quota/balance account in one list.
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
    @ObservedObject private var grokQuota = GrokQuotaClient.shared
    @ObservedObject private var antigravity = AntigravityQuotaClient.shared
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
    @State private var busyKeys: Set<String> = []

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
                    status: goStatus) {
                credentials(configured: goClient.configured,
                            canClear: AccountConnection.openCodeGo,
                            label: "Workspace",
                            change: { showGoForm = true }, clear: { pendingClear = .openCodeGo })
            }
            account("codex", "Codex", symbol: ToolKind.codex.symbol, color: ToolKind.codex.color,
                    status: codexStatus) {
                Toggle("Read Codex quota", isOn: Binding(
                    get: { codexQuota.enabled },
                    set: { codexQuota.setEnabled($0) }
                ))
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
                    status: ccStatus) {
                credentials(configured: ccQuota.state.configured,
                            canClear: AccountConnection.commandCode,
                            label: "Session",
                            change: { showCCForm = true }, clear: { pendingClear = .commandCode })
            }
            account("grok", "Grok", symbol: "x.circle.fill", color: TMDesign.grok,
                    status: grokStatus) {
                Toggle("Read Grok quota", isOn: Binding(
                    get: { grokQuota.enabled },
                    set: { grokQuota.setEnabled($0) }
                ))
                LabeledContent("Login") {
                    if grokQuota.state.configured {
                        Text("Grok CLI")
                    } else {
                        Text("Run `grok login` in Terminal")
                    }
                }
            }
            account("antigravity", "Antigravity", symbol: "a.circle.fill", color: TMDesign.antigravity,
                    status: antigravityStatus) {
                Toggle("Read Antigravity quota", isOn: Binding(
                    get: { antigravity.enabled },
                    set: { antigravity.setEnabled($0) }
                ))
                if !antigravity.state.configured {
                    LabeledContent("Login") {
                        Text("Open Antigravity or Gemini and sign in")
                    }
                }
            }
            account("router", "OpenRouter", symbol: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color,
                    status: routerStatus) {
                credentials(configured: orClient.hasKey,
                            canClear: AccountConnection.openRouter || orClient.state.error != nil,
                            label: "API keys",
                            change: { showORForm = true }, clear: { pendingClear = .openRouter })
            }
            account("deepseek", "DeepSeek", symbol: "d.circle.fill", color: ToolKind.dsh.color,
                    status: deepseekStatus) {
                DeepSeekAccountSettings()
            }
        }
        .onAppear {
            for key in PopoverAccountRows.keys {
                rowVisible[key] = PopoverAccountRows.isVisible(key)
            }
            codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
            if let key = SettingsWindowController.shared.consumePendingExpandAccount() {
                expanded.insert(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.expandAccount)) { note in
            if let key = note.object as? String {
                expanded.insert(key)
                _ = SettingsWindowController.shared.consumePendingExpandAccount()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.databaseReplaced)) { _ in
            CodexBillingModeCoordinator.shared.reloadFromDatabase()
            for key in PopoverAccountRows.keys {
                rowVisible[key] = PopoverAccountRows.isVisible(key)
            }
            codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
        }
        .onChange(of: codexBilling) { value in
            CodexBillingModeCoordinator.shared.set(value, restoreSelection: { codexBilling = $0 })
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
                    .font(.callout)
                    .foregroundStyle(note.failed ? TMDesign.danger : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            Toggle("Show in popover", isOn: visibility(key))
        } label: {
            LabeledContent {
                Text(status)
                    .foregroundStyle(status == "Error" || status == "Sign-in expired" ? TMDesign.danger : .secondary)
            } label: {
                HStack(spacing: 8) {
                    // Decorative: the system would read its symbol name, such
                    // as "off" for Grok's mark.
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(title)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(status)
    }

    private func credentials(configured: Bool,
                             canClear: Bool = false,
                             label: String,
                             change: @escaping () -> Void,
                             clear: @escaping () -> Void) -> some View {
        let active = configured || canClear
        return LabeledContent(label) {
            HStack {
                if active {
                    Button("Clear", role: .destructive, action: clear)
                }
                Button(active ? "Change…" : "Set Up…", action: change)
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 2)
    }

    private func visibility(_ key: String) -> Binding<Bool> {
        Binding(
            get: { rowVisible[key] ?? true },
            set: { visible in
                rowVisible[key] = visible
                PopoverAccountRows.setVisible(key, visible)
            }
        )
    }

    private var claudeStatus: String {
        guard claudeQuota.enabled else { return "Not connected" }
        if claudeQuota.state.error != nil { return "Error" }
        return claudeQuota.state.configured || claudeQuota.state.lastSync > 0 ? "Connected" : "Not signed in"
    }

    private var goStatus: String {
        if goClient.state.error != nil, AccountConnection.openCodeGo { return "Error" }
        guard goClient.configured else { return "Not connected" }
        return "Connected"
    }

    private var codexStatus: String {
        guard codexQuota.enabled else { return "Not connected" }
        if codexQuota.state.error != nil { return "Error" }
        return codexQuota.state.lastSync > 0 ? "Connected" : "Not connected"
    }

    private var ccStatus: String {
        if let err = ccQuota.state.error, err != "Not configured" { return "Error" }
        guard ccQuota.state.configured else { return "Not connected" }
        return ccQuota.state.planName ?? "Connected"
    }

    private var routerStatus: String {
        guard orClient.hasKey else { return "Not connected" }
        if orClient.state.authInvalid || orClient.state.error != nil { return "Error" }
        return keyCountText
    }

    private var deepseekStatus: String {
        guard let kind = deepseek.state.kind else { return "Not connected" }
        if deepseek.state.expired { return "Sign-in expired" }
        if deepseek.state.balanceError != nil { return "Error" }
        return kind == .platform ? "Platform account" : "API key"
    }

    private var grokStatus: String {
        guard grokQuota.enabled else { return "Not connected" }
        let state = grokQuota.state
        if state.error != nil && state.configured { return "Error" }
        guard state.configured else { return "Not signed in" }
        return GrokQuotaClient.plan(subscriptions: app.subscriptions, apiPlan: state.planName) ?? "Connected"
    }

    private var antigravityStatus: String {
        guard antigravity.enabled else { return "Not connected" }
        let state = antigravity.state
        guard state.configured || state.lastSync > 0 else { return "Not connected" }
        return AntigravityQuotaClient.plan(subscriptions: app.subscriptions, apiPlan: state.planName) ?? "Connected"
    }

    private var keyCountText: String {
        let n = orClient.state.keyCount
        return n == 1 ? "1 key" : "\(n) keys"
    }

    /// What the Codex row is called when no custom name is set.
    private var codexAutoName: String {
        CodexPlanName.resolve(custom: nil, apiPlan: codexQuota.state.planType,
                              subscription: SubscriptionMath.activeCodexSubscription(in: app.subscriptions))
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
        let ws = goWS.trimmed
        let cookie = goCookie.trimmed
        guard !busyKeys.contains("go") else { return }
        busyKeys.insert("go")
        Task { @MainActor in
            defer { busyKeys.remove("go") }
            if await goClient.provisionAsync(workspaceId: ws, cookie: cookie) {
                goClient.refresh(force: true)
                showGoForm = false
                message["go"] = ("Credentials saved", false)
            } else {
                message["go"] = (goClient.state.error ?? "Save failed (Keychain unavailable)", true)
            }
        }
    }

    private func saveOpenRouter() {
        let key = orKey.trimmed
        let append = orAppend
        guard !busyKeys.contains("router") else { return }
        busyKeys.insert("router")
        Task { @MainActor in
            defer { busyKeys.remove("router") }
            let ok = append ? await orClient.addKeyAsync(key) : await orClient.setKeyAsync(key)
            if ok {
                showORForm = false
                message["router"] = ("Key saved", false)
            } else {
                message["router"] = (orClient.state.error ?? "Save failed (Keychain unavailable)", true)
            }
        }
    }

    private func saveCommandCode() {
        let cookie = ccCookie.trimmed
        guard !busyKeys.contains("cc") else { return }
        busyKeys.insert("cc")
        Task { @MainActor in
            defer { busyKeys.remove("cc") }
            if await ccQuota.provisionAsync(cookie: cookie) {
                ccQuota.refresh(force: true)
                showCCForm = false
                message["cc"] = ("Session saved", false)
            } else {
                message["cc"] = (ccQuota.state.error ?? "Save failed (Keychain unavailable)", true)
            }
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
        let target = pendingClear
        pendingClear = nil
        guard let target else { return }
        Task { @MainActor in
            switch target {
            case .openCodeGo:
                guard !busyKeys.contains("go") else { return }
                busyKeys.insert("go")
                defer { busyKeys.remove("go") }
                if await goClient.clearAsync() {
                    message["go"] = ("Credentials cleared", false)
                } else {
                    message["go"] = (goClient.state.error ?? "Keychain delete failed", true)
                }
            case .openRouter:
                guard !busyKeys.contains("router") else { return }
                busyKeys.insert("router")
                defer { busyKeys.remove("router") }
                if await orClient.setKeyAsync(nil) {
                    message["router"] = ("Keys cleared", false)
                } else {
                    message["router"] = (orClient.state.error ?? "Keychain delete failed", true)
                }
            case .commandCode:
                guard !busyKeys.contains("cc") else { return }
                busyKeys.insert("cc")
                defer { busyKeys.remove("cc") }
                if await ccQuota.clearAsync() {
                    message["cc"] = ("Session cleared", false)
                } else {
                    message["cc"] = (ccQuota.state.error ?? "Keychain delete failed", true)
                }
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
