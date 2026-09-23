import SwiftUI

/// Settings › Sources: per-tool data source (local Mac vs remote VPS feed),
/// the remote feed URL, and collector status.
struct SourcesSettingsPane: View {
    /// UI-3: 订阅后 poll 完成时 feed 状态行随 @Published 刷新。
    @ObservedObject private var remote = HermesRemoteClient.shared
    @State private var feedURL = ""
    @State private var sources: [ToolKind: Bool] = [:] // tool -> isRemote (draft)
    /// UI-8: 生效值缓存（onAppear 加载、toggle 后更新）。body 每格渲染
    /// 直接读 tool.sourceIsRemote 会同步查 DB（每帧每工具一次）。
    @State private var effectiveSources: [ToolKind: Bool] = [:]
    @State private var saved = false
    @State private var feedError: String?
    @State private var feedDisabled = false
    /// Per-tool feedback slots: each tool owns its own "Saved ✓"/"Save
    /// failed" message, so one tool's save never clears another's feedback.
    @State private var sourceSaved: [ToolKind: Bool] = [:]
    @State private var sourceFailed: [ToolKind: Bool] = [:]
    /// Per-tool write generation: only the latest write for a tool may touch
    /// the saved/failed feedback, so rapid toggles cannot interleave.
    @State private var sourceGeneration: [ToolKind: Int] = [:]

    private let tools = ToolKind.allCases.filter { $0 != .openrouter }
    /// Codex billing draft: "subscription" (ChatGPT/Codex plan covers the
    /// usage) or "api" (per-token API spend). Persisted via Database setting.
    @State private var codexBilling: String = "api"

    var body: some View {
        dataSourcesSection
            .onAppear {
                feedURL = remote.feedURL
                for t in tools {
                    sources[t] = t.sourceIsRemote
                    effectiveSources[t] = t.sourceIsRemote
                }
                codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
            }

        remoteFeedSection
            .onChange(of: feedURL) { _ in
                saved = false
                feedError = nil
                feedDisabled = false
            }

        // Operational status: one compact list rather than a card per
        // collector.
        Section("Collector Status") {
            SourcesView(embedded: true, localSources: effectiveSources)
        }
    }

    private var dataSourcesSection: some View {
        Section("Data Sources") {
            ForEach(tools) { tool in
                if tool.supportsRemoteSource {
                    Picker(selection: sourceBinding(for: tool)) {
                        Text("Local").tag(false)
                        Text("Remote").tag(true)
                    } label: {
                        sourceLabel(tool)
                    }
                    .accessibilityLabel("\(tool.displayName) source")
                } else {
                    LabeledContent {
                        Text("Local only")
                    } label: {
                        sourceLabel(tool)
                    }
                }
                if tool == .codex {
                    Picker(selection: $codexBilling) {
                        Text("Subscription").tag("subscription")
                        Text("API").tag("api")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: ToolKind.codex.symbol)
                                .foregroundStyle(ToolKind.codex.color)
                                .frame(width: 18)
                            Text("Codex Billing")
                        }
                    }
                    .accessibilityLabel("Codex billing")
                    .help(codexBilling == "subscription"
                          ? "Treat Codex costs as covered by a ChatGPT/Codex subscription"
                          : "Count Codex costs as per-token API spend")
                }
            }
        }
        .onChange(of: codexBilling) { newValue in
            let value = newValue
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Database.shared.setSetting("codex_billing_mode", value)
            }
        }
    }

    /// Tool icon and name, followed by the per-tool save feedback.
    private func sourceLabel(_ tool: ToolKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tool.symbol)
                .foregroundStyle(tool.color)
                .frame(width: 18)
            Text(tool.displayName)
            if sourceSaved[tool] == true {
                Image(systemName: "checkmark")
                    .foregroundStyle(TMDesign.accent)
                    .accessibilityLabel("Saved")
            } else if sourceFailed[tool] == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(TMDesign.danger)
                    .accessibilityLabel("Save failed")
            }
        }
    }

    private var remoteFeedSection: some View {
        Section {
            HStack {
                TextField("Feed URL", text: $feedURL, prompt: Text("HTTPS or private range"))
                Button("Save") {
                    let raw = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved = false
                    // Validate locally first so the failure reason can
                    // be specific instead of a single generic message.
                    if let problem = Self.feedURLProblem(raw) {
                        feedError = problem
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = HermesRemoteClient.shared.provision(url: raw.isEmpty ? nil : raw)
                        DispatchQueue.main.async {
                            saved = ok
                            feedError = ok ? nil : "Save failed (database unavailable)"
                            feedDisabled = ok && raw.isEmpty
                        }
                    }
                }
                Button {
                    HermesRemoteClient.shared.maybePoll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Pull now")
                .accessibilityLabel("Pull now")
            }
        } header: {
            Text("Remote Feed")
        } footer: {
            remoteFeedStatus
        }
    }

    @ViewBuilder
    private var remoteFeedStatus: some View {
        let st = remote.status
        if st.lastSync > 0 || st.error != nil || feedDisabled || saved || feedError != nil {
            HStack {
                if st.lastSync > 0 {
                    Text(st.lastRows > 0
                         ? "Synced \(Format.dateTime(st.lastSync)) · \(st.lastRows) new"
                         : "Synced \(Format.dateTime(st.lastSync)) · up to date")
                }
                if let err = st.error {
                    Text(err).foregroundStyle(TMDesign.danger)
                }
                if feedDisabled {
                    Text("Remote feed disabled").foregroundStyle(TMDesign.accent)
                } else if saved {
                    Text("Saved").foregroundStyle(TMDesign.accent)
                }
                if let err = feedError {
                    Text(err).foregroundStyle(TMDesign.danger)
                }
            }
        }
    }

    private func sourceBinding(for tool: ToolKind) -> Binding<Bool> {
        Binding(
            get: { sources[tool] ?? (tool.defaultSource == "remote") },
            set: { newValue in
                let generation = (sourceGeneration[tool] ?? 0) + 1
                sourceGeneration[tool] = generation
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = tool.setSource(remote: newValue)
                    DispatchQueue.main.async {
                        guard sourceGeneration[tool] == generation else { return }
                        if ok {
                            sources[tool] = newValue
                            effectiveSources[tool] = newValue
                            sourceSaved[tool] = true
                            sourceFailed[tool] = nil
                        } else {
                            let persisted = tool.sourceIsRemote
                            sources[tool] = persisted
                            effectiveSources[tool] = persisted
                            sourceFailed[tool] = true
                            sourceSaved[tool] = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            sourceSaved[tool] = nil
                            sourceFailed[tool] = nil
                        }
                    }
                }
            }
        )
    }

    /// Local validation mirroring HermesRemoteClient.provision, so the Save
    /// button can report the specific reason instead of a generic failure.
    private static func feedURLProblem(_ raw: String) -> String? {
        if raw.isEmpty { return nil }
        if raw.count > HermesRemoteClient.maxFeedURLLength {
            return "URL too long (max \(HermesRemoteClient.maxFeedURLLength) chars)"
        }
        if raw.rangeOfCharacter(from: .controlCharacters) != nil {
            return "URL contains control characters"
        }
        guard let url = URL(string: raw) else {
            return "Not a valid URL"
        }
        guard HermesRemoteClient.isAllowedFeedURL(url) else {
            return "URL rejected — HTTPS or private range only"
        }
        return nil
    }
}

/// Settings › Data: export, local rebuild, and the automatic backups.
struct DataSettingsPane: View {
    @ObservedObject private var app = AppState.shared
    @State private var preview: Database.LocalRebuildPreview?
    @State private var receipt: DataRepairReceipt?
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirmsRepair = false
    @State private var confirmsRestore = false
    /// Every managed snapshot (weekly automatic + pre-rebuild + pre-clear +
    /// manual export leftovers do NOT show here — export goes to a
    /// user-chosen path outside the managed directory). Newest first, same
    /// ordering DataMaintenance.pruneBackups uses to decide what survives.
    @State private var backups: [URL] = []
    @State private var pendingRestoreBackup: URL?

    var body: some View {
        Section {
            LabeledContent("Export database") {
                Button("Export…") { exportDatabase() }
                    .disabled(isWorking)
            }
        } header: {
            Text("Backup")
        }
        .onAppear { loadBackups() }

        Section {
            LabeledContent("Rebuild local usage data") {
                Button("Preview") { loadPreview() }
                    .disabled(isWorking)
            }
            if let preview {
                LabeledContent("Found") {
                    Text("\(preview.turns) records · \(preview.sessions) sessions · \(Format.count(preview.tokens)) tokens")
                        .tmMonospacedDigit()
                }
                HStack {
                    Spacer()
                    if receipt != nil {
                        Button("Restore Pre-Rebuild Backup…") { confirmsRestore = true }
                            .disabled(isWorking)
                    }
                    Button("Back Up and Rebuild…", role: .destructive) { confirmsRepair = true }
                        .disabled(isWorking || preview.turns == 0)
                }
            }
            if isWorking || message != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    if let message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Rebuild")
        }
        .confirmationDialog("Rebuild local usage data?", isPresented: $confirmsRepair) {
            Button("Back Up and Rebuild", role: .destructive) { repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only sources set to Local are processed; a backup is created first, then raw logs are re-scanned.")
        }
        .confirmationDialog("Restore pre-rebuild backup?", isPresented: $confirmsRestore) {
            Button("Restore Backup", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
        }

        backupsSection
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { pendingRestoreBackup != nil },
                set: { if !$0 { pendingRestoreBackup = nil } })) {
                    Button("Restore Backup", role: .destructive) { restoreManaged() }
                    Button("Cancel", role: .cancel) { pendingRestoreBackup = nil }
                } message: {
                    Text("This replaces all current usage data, subscriptions and settings with the snapshot's contents.")
                }
    }

    private func exportDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ToastMonitor-backup-\(Int64(Date().timeIntervalSince1970)).db"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Database.shared.backup(to: url.path)
            DispatchQueue.main.async {
                message = ok ? "Database exported: \(url.path)" : "Database export failed"
                isWorking = false
            }
        }
    }

    /// A backup is created automatically once a week (idle weeks included)
    /// plus before any repair/clear operation; the newest 7 are kept. Listed
    /// here so "the app has been quietly backing this up" is visible and
    /// any of them — not just the current session's pre-repair one — can be
    /// restored with one click, per the "只差编排" gap noted when this was
    /// scoped: the backup/restore/integrity-check machinery already existed
    /// end to end, it just had no way for a user to see or reach it.
    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backups, id: \.self) { url in
                    LabeledContent {
                        Button("Restore…") { pendingRestoreBackup = url }
                            .disabled(isWorking)
                    } label: {
                        Text(Self.label(for: url).capitalized)
                        Text(Self.dateAndSize(for: url))
                            .tmMonospacedDigit()
                    }
                }
            }
        } header: {
            Text("Automatic Backups")
        }
    }

    /// The trailing "-yyyyMMdd-HHmmss.db" suffix is redundant with the date
    /// line right below it — only the label (weekly / pre-rebuild / pre-clear
    /// / manual) is worth a row of its own. Sliced by fixed length rather
    /// than searching for the next "-", since a label can itself contain a
    /// hyphen (createBackup's sanitizer allows "-" through unchanged, e.g.
    /// "pre-rebuild") — the timestamp suffix's length is deterministic
    /// ("-yyyyMMdd-HHmmss" is always exactly 16 characters) while the
    /// label's is not.
    private static func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "toastmonitor-"
        guard name.hasPrefix(prefix) else { return name }
        let withoutPrefix = name.dropFirst(prefix.count)
        guard withoutPrefix.count > 16 else { return String(withoutPrefix) }
        return String(withoutPrefix.dropLast(16))
    }

    private static func dateAndSize(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate
            .map { Format.dateTime(Int64($0.timeIntervalSince1970)) } ?? "—"
        let size = values?.fileSize.map { Format.bytes(Int64($0)) } ?? "—"
        return "\(date) · \(size)"
    }

    private func loadBackups() {
        DispatchQueue.global(qos: .utility).async {
            let urls = DataMaintenance.availableBackups()
            DispatchQueue.main.async { backups = urls }
        }
    }

    private func restoreManaged() {
        guard let target = pendingRestoreBackup else { return }
        pendingRestoreBackup = nil
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DataMaintenance.restore(backupPath: target.path)
            DispatchQueue.main.async {
                message = ok ? "Restored: \(target.lastPathComponent)" : "Restore failed; original data retained"
                isWorking = false
                if ok {
                    app.refresh()
                    refreshPreviewQuietly()
                }
            }
        }
    }

    private func loadPreview() {
        isWorking = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let value = DataMaintenance.preview()
            DispatchQueue.main.async {
                preview = value
                isWorking = false
            }
        }
    }

    private func repair() {
        isWorking = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try DataMaintenance.repair()
                DispatchQueue.main.async {
                    receipt = value
                    message = "Backup: \(value.backupPath)"
                    // Reset here rather than relying on loadPreview()'s side
                    // effect: loadPreview() sets isWorking = true then wipes
                    // `message` to nil before its own async read completes,
                    // which cleared this success message before it could be
                    // seen and left the spinner stuck if the scan callback
                    // below never fired.
                    isWorking = false
                    loadBackups()
                    CollectorEngine.shared.scheduleScan(force: true) { _ in
                        app.refresh()
                        refreshPreviewQuietly()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    message = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }

    /// Reloads the preview counts without touching `message` or `isWorking`
    /// — used after repair/restore so the outcome message just set by the
    /// caller stays visible instead of being cleared by loadPreview()'s reset.
    private func refreshPreviewQuietly() {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = DataMaintenance.preview()
            DispatchQueue.main.async { preview = value }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DataMaintenance.restore(backupPath: receipt.backupPath)
            DispatchQueue.main.async {
                message = ok ? "Restored: \(receipt.backupPath)" : "Restore failed; backup retained"
                isWorking = false
                if ok {
                    app.refresh()
                    refreshPreviewQuietly()
                }
            }
        }
    }
}
