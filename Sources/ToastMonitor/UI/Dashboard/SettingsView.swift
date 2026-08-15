import SwiftUI

/// 设置: per-tool data source (local Mac vs remote VPS feed) + feed URL.
struct SettingsView: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle("Settings")
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Data Sources")

                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: tool.symbol)
                                    .font(TMType.regular(12))
                                    .foregroundStyle(tool.color)
                                    .frame(width: 18)
                                Text(tool.displayName)
                                    .font(TMType.regular(12.5))
                                    .frame(width: 100, alignment: .leading)
                                if tool.supportsRemoteSource {
                                    Picker("Source", selection: Binding(
                                        get: { sources[tool] ?? (tool.defaultSource == "remote") },
                                        set: { newValue in
                                        // P0-4: persist immediately (off main thread), show effect.
                                        let gen = (sourceGeneration[tool] ?? 0) + 1
                                        sourceGeneration[tool] = gen
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            let ok = tool.setSource(remote: newValue)
                                            DispatchQueue.main.async {
                                                // Generation guard: a stale write's
                                                // completion must not overwrite the
                                                // feedback of a newer one.
                                                guard sourceGeneration[tool] == gen else { return }
                                                if ok {
                                                    sources[tool] = newValue
                                                    effectiveSources[tool] = newValue
                                                    sourceSaved[tool] = true
                                                    sourceFailed[tool] = nil
                                                } else {
                                                    // Keep the picker aligned with the
                                                    // effective persisted value after a
                                                    // failed write.
                                                    sources[tool] = tool.sourceIsRemote
                                                    effectiveSources[tool] = tool.sourceIsRemote
                                                    sourceFailed[tool] = true
                                                    sourceSaved[tool] = nil
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                    if sourceSaved[tool] != nil { sourceSaved[tool] = nil }
                                                    if sourceFailed[tool] != nil { sourceFailed[tool] = nil }
                                                }
                                            }
                                        }
                                        }
                                    )) {
                                        Text("Local (Mac)").tag(false)
                                        Text("Remote (VPS)").tag(true)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 200)
                                } else {
                                    Text("Local only")
                                        .font(TMType.regular(TMType.caption))
                                        .foregroundStyle(TMDesign.quiet)
                                        .frame(width: 200, alignment: .leading)
                                }
                                Spacer()
                                // Actual effective value, not the draft.
                                // UI-8: 走缓存，body 渲染不查 DB。
                                Text((effectiveSources[tool] ?? (tool.defaultSource == "remote"))
                                     ? "Reads VPS feed" : "Reads local logs")
                                    .font(TMType.regular(TMType.micro))
                                    .foregroundStyle(TMDesign.quiet)
                                if sourceSaved[tool] == true {
                                    Text("Saved ✓")
                                        .font(TMType.regular(TMType.micro))
                                        .foregroundStyle(TMDesign.accent)
                                }
                                if sourceFailed[tool] == true {
                                    Text("Save failed")
                                        .font(TMType.regular(TMType.micro))
                                        .foregroundStyle(TMDesign.danger)
                                }
                            }
                            .padding(.vertical, 2)

                            if tool == .codex {
                                HStack(spacing: 10) {
                                    Text("Billing")
                                        .font(TMType.regular(TMType.caption))
                                        .foregroundStyle(TMDesign.quiet)
                                        .frame(width: 100, alignment: .leading)
                                    Picker("Codex billing", selection: $codexBilling) {
                                        Text("ChatGPT / Codex subscription").tag("subscription")
                                        Text("API usage (per-token)").tag("api")
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 320)
                                    Text(codexBilling == "subscription"
                                         ? "Codex cost covered by the subscription"
                                         : "Codex usage billed as API spend")
                                        .font(TMType.regular(TMType.micro))
                                        .foregroundStyle(TMDesign.quiet)
                                }
                                .padding(.leading, 28)
                                .onChange(of: codexBilling) { _, newValue in
                                    let v = newValue
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        _ = Database.shared.setSetting("codex_billing_mode", v)
                                    }
                                }
                            }
                        }
                    }
                }
                .tmPanelSurface()

                // Operational status stays on this page, but uses one
                // compact list instead of a second nested page or one card
                // per collector.
                SourcesView(embedded: true, localSources: effectiveSources)

                // 远程 Feed
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Remote Feed")
                    HStack {
                        TextField("Feed URL (HTTPS or private range)", text: $feedURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: TMType.caption, design: .monospaced))
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
                        .font(TMType.regular(12))
                        Button {
                            HermesRemoteClient.shared.maybePoll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .font(TMType.regular(12))
                        .help("Pull now")
                    }
                    let st = remote.status
                    HStack {
                        if st.lastSync > 0 {
                            Text(st.lastRows > 0
                                 ? "Synced \(Format.dateTime(st.lastSync)) · \(st.lastRows) new"
                                 : "Synced \(Format.dateTime(st.lastSync)) · up to date")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                        }
                        if let err = st.error {
                            Text(err)
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.danger)
                        }
                        if feedDisabled {
                            Text("Remote feed disabled")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.accent)
                        } else if saved {
                            Text("Saved")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.accent)
                        }
                        if let err = feedError {
                            Text(err)
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.danger)
                        }
                    }
                }
                .tmPanelSurface()

                DataMaintenanceSection()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .onAppear {
            feedURL = remote.feedURL
            for t in tools {
                sources[t] = t.sourceIsRemote
                effectiveSources[t] = t.sourceIsRemote
            }
            codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
        }
        .onChange(of: feedURL) { _, _ in
            saved = false
            feedError = nil
            feedDisabled = false
        }
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

/// 订阅管理: list + add/edit form (固定成本侧信息).
struct SubscriptionSettingsSection: View {
    @ObservedObject private var app = AppState.shared
    @State private var showForm = false
    @State private var editing: Database.Subscription?
    /// The row id captured at edit time; saving uses this instead of
    /// re-deriving it from `editing` so an edit can never fall back to id 0.
    @State private var editID: Int64 = 0
    @State private var name = ""
    @State private var plan = ""
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()
    @State private var cycle = "monthly"
    @State private var price = ""
    @State private var priceError = false
    @State private var dateError = false
    @State private var databaseError: String?
    @State private var pendingDelete: Database.Subscription?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Subscriptions")
                Spacer()
                Button {
                    editing = nil
                    editID = 0
                    name = ""
                    plan = ""
                    startDate = Date()
                    hasEndDate = false
                    endDate = Date()
                    cycle = "monthly"
                    price = ""
                    showForm = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(TMType.regular(12))
                .disabled(showForm)
                Button {
                    editing = nil
                    editID = 0
                    name = "OpenCode Go"
                    plan = "go"
                    startDate = Date()
                    hasEndDate = false
                    endDate = Date()
                    cycle = "monthly"
                    price = "10"
                    showForm = true
                } label: {
                    Text("Go template")
                }
                .font(TMType.regular(12))
                .disabled(showForm)
                .help("Fill OpenCode Go $10/mo template")
            }

            if app.subscriptions.isEmpty {
                Text("No subscriptions")
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(app.subscriptions) { sub in
                    HStack {
                        Image(systemName: planIcon(sub.plan))
                            .foregroundStyle(planColor(sub.plan))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                                .font(TMType.medium(12))
                            Text("From \(Format.day(sub.startDate)) · \(sub.cycle == "yearly" ? "Yearly" : "Monthly") · \(Format.money(sub.price))/period"
                                 + (sub.endDate > 0 ? " · to \(SubscriptionMath.dateStr(Date(timeIntervalSince1970: TimeInterval(sub.endDate))))" : ""))
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                                HStack(spacing: 6) {
                                    Text("Day \(info.dayOfCycle)/\(info.totalDays) · renews \(SubscriptionMath.dateStr(info.end)) · avg \(Format.money(sub.price / Double(info.totalDays)))/day")
                                        .font(TMType.regular(TMType.micro))
                                        .tmMonospacedDigit()
                                        .foregroundStyle(TMDesign.quiet)
                                    if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                        let line = ForecastText.line(for: fc, plan: sub.plan)
                                        Text(line.text)
                                            .font(TMType.semibold(TMType.micro))
                                            .tmMonospacedDigit()
                                            .foregroundStyle(ForecastText.color(line.status))
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button("Edit") {
                            editing = sub
                            editID = sub.id
                            name = sub.name
                            plan = sub.plan
                            startDate = Date(timeIntervalSince1970: TimeInterval(sub.startDate))
                            hasEndDate = sub.endDate > 0
                            endDate = sub.endDate > 0 ? Date(timeIntervalSince1970: TimeInterval(sub.endDate)) : Date()
                            cycle = sub.cycle
                            price = "\(sub.price)"
                            showForm = true
                        }
                        .font(TMType.regular(11))
                        Button {
                            pendingDelete = sub
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .font(TMType.regular(11))
                        .foregroundStyle(TMDesign.danger)
                        .help("Delete subscription")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                }
            }

            // Persistence feedback lives outside the form so a delete failure
            // (form closed) is still visible, not silently dropped.
            if let databaseError {
                Text(databaseError)
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.danger)
            }

        }
        .tmPanelSurface()
        .onChange(of: showForm) { _, open in
            // Draft validation must not survive closing and later reopening
            // the form; especially dateError used to appear on a fresh edit.
            priceError = false
            dateError = false
            // A stale persistence error (e.g. failed delete) is cleared when
            // the form reopens so it cannot outlive the operation it reports.
            if open {
                databaseError = nil
            }
        }
        .alert("Delete subscription?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let sub = pendingDelete {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = Database.shared.deleteSubscription(id: sub.id)
                            DispatchQueue.main.async {
                                if ok {
                                    // subscriptionsDidChange 通知驱动 AppState 刷新。
                                    databaseError = nil
                                } else {
                                    databaseError = "Failed to delete subscription (disk space or database permissions)"
                                }
                            }
                        }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete.map { "This deletes \"\($0.name)\" and its cycle/forecast records." } ?? "")
            }
        .sheet(isPresented: $showForm) {
            subscriptionForm
        }
    }

    private var subscriptionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editing == nil ? "Add Subscription" : "Edit Subscription")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("Codex / Claude Pro"))
                Picker("Plan", selection: $plan) {
                    Text("None").tag("")
                    Text("OpenCode Go").tag("go")
                    Text("OpenRouter").tag("openrouter")
                    Text("Claude Pro").tag("claude")
                    Text("ChatGPT / Codex").tag("openai")
                }
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                Toggle("Has end date", isOn: $hasEndDate)
                if hasEndDate {
                    DatePicker("End date", selection: $endDate, displayedComponents: .date)
                }
                Picker("Billing cycle", selection: $cycle) {
                    Text("Monthly").tag("monthly")
                    Text("Yearly").tag("yearly")
                }
                .pickerStyle(.segmented)
                TextField("Price per period (USD)", text: $price)
            }
            .formStyle(.grouped)

            if priceError {
                Text("Enter a valid price (a number greater than or equal to zero).")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }
            if dateError {
                Text("The end date cannot be before the start date.")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { showForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveSubscription() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func saveSubscription() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let p = Double(price.trimmingCharacters(in: .whitespaces)), p.isFinite, p >= 0 else {
            priceError = true
            return
        }
        priceError = false
        let startDay = Calendar.current.startOfDay(for: startDate)
        let endDay = Calendar.current.startOfDay(for: endDate)
        guard !hasEndDate || endDay >= startDay else {
            dateError = true
            return
        }
        dateError = false
        let sub = Database.Subscription(
            id: editID > 0 ? editID : (editing?.id ?? 0),
            name: name.trimmingCharacters(in: .whitespaces),
            plan: plan,
            startDate: Int64(startDate.timeIntervalSince1970),
            endDate: hasEndDate ? Int64(endDate.timeIntervalSince1970) : 0,
            cycle: cycle,
            price: p,
            currency: "USD")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.persist(sub)
            DispatchQueue.main.async {
                if ok {
                    showForm = false
                    databaseError = nil
                } else {
                    databaseError = "Failed to save subscription (disk space or database permissions)"
                }
            }
        }
    }

    /// Defensive persistence: if the edit context lost its id, match by
    /// (name, startDate) so saving an edit never inserts a duplicate row.
    private static func persist(_ sub: Database.Subscription) -> Bool {
        var s = sub
        if s.id <= 0 {
            let existing = Database.shared.subscriptions().first { row in
                row.name == s.name && row.startDate == s.startDate
            }
            if let existing {
                s = Database.Subscription(id: existing.id, name: s.name, plan: s.plan,
                                          startDate: s.startDate, endDate: s.endDate,
                                          cycle: s.cycle, price: s.price, currency: s.currency)
            }
            NSLog("[ToastMonitor] subscription save without id; matched existing id=%lld or inserting", s.id)
        }
        return Database.shared.upsertSubscription(s)
    }

    private func planIcon(_ p: String) -> String {
        switch p {
        case "go": return "g.circle.fill"
        case "openrouter": return ToolKind.openrouter.symbol
        case "claude": return ToolKind.claude.symbol
        case "openai", "chatgpt", "codex": return ToolKind.codex.symbol
        default: return "calendar"
        }
    }

    private func planColor(_ p: String) -> Color {
        switch p {
        case "go": return TMDesign.accent
        case "openrouter": return ToolKind.openrouter.color
        case "claude": return ToolKind.claude.color
        case "openai", "chatgpt", "codex": return ToolKind.codex.color
        default: return .gray
        }
    }
}

private struct DataMaintenanceSection: View {
    @ObservedObject private var app = AppState.shared
    @State private var preview: Database.LocalRebuildPreview?
    @State private var receipt: DataRepairReceipt?
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirmsRepair = false
    @State private var confirmsRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Data Maintenance")
                Spacer()
                Button("Preview local rebuild") { loadPreview() }
                    .font(TMType.regular(11))
                    .disabled(isWorking)
            }
            if let preview {
                Text("\(preview.turns) records · \(preview.sessions) sessions · \(Format.count(preview.tokens)) tokens")
                    .font(TMType.regular(TMType.micro))
                    .tmMonospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
                HStack {
                    Button("Back up & rebuild", role: .destructive) { confirmsRepair = true }
                        .disabled(isWorking || preview.turns == 0)
                    if receipt != nil {
                        Button("Restore pre-repair backup") { confirmsRestore = true }
                            .disabled(isWorking)
                    }
                }
                .font(TMType.regular(11))
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message)
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .textSelection(.enabled)
            }
        }
        .tmPanelSurface()
        .confirmationDialog("Rebuild local usage data?", isPresented: $confirmsRepair) {
            Button("Back up & rebuild", role: .destructive) { repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only sources set to Local are processed; a backup is created first, then raw logs are re-scanned.")
        }
        .confirmationDialog("Restore pre-repair backup?", isPresented: $confirmsRestore) {
            Button("Restore backup", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
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
                    CollectorEngine.shared.scheduleScan(force: true) { _ in
                        app.refresh()
                        loadPreview()
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
                    loadPreview()
                }
            }
        }
    }
}
