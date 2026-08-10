import SwiftUI

/// 设置: per-tool data source (local Mac vs remote VPS feed) + feed URL.
struct SettingsView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var feedURL = ""
    @State private var sources: [ToolKind: Bool] = [:] // tool -> isRemote (draft)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle("Settings")
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Data Sources")

                    ForEach(tools) { tool in
                        HStack(spacing: 10) {
                            Image(systemName: tool.symbol)
                                .font(TMType.regular(12))
                                .foregroundStyle(tool.color)
                                .frame(width: 18)
                            Text(tool.displayName)
                                .font(TMType.regular(12.5))
                                .frame(width: 100, alignment: .leading)
                            Picker("", selection: Binding(
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
                                                sourceSaved[tool] = true
                                                sourceFailed[tool] = nil
                                            } else {
                                                // Keep the picker aligned with the
                                                // effective persisted value after a
                                                // failed write.
                                                sources[tool] = tool.sourceIsRemote
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
                            .frame(width: 200)
                            Spacer()
                            // Actual effective value, not the draft.
                            Text(tool.sourceIsRemote ? "Reads VPS feed" : "Reads local logs")
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
                    }
                }
                .tmPanelSurface()

                // 来源健康（详情在「来源状态」页，这里只留一行摘要）
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Source Health")
                    if health.sources.isEmpty {
                        Text("No scans yet")
                            .font(TMType.regular(TMType.micro))
                            .foregroundStyle(TMDesign.quiet)
                    } else {
                        let broken = health.sources.filter { $0.error != nil }.count
                        let stale = health.sources.filter { $0.error == nil && $0.isStale }.count
                        HStack(spacing: 8) {
                            if broken > 0 {
                                TMStatusPill(text: "\(broken) source\(broken == 1 ? "" : "s") error", color: TMDesign.danger, symbol: "exclamationmark.triangle.fill")
                            }
                            if stale > 0 {
                                TMStatusPill(text: "\(stale) source\(stale == 1 ? "" : "s") stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                            }
                            if broken == 0 && stale == 0 {
                                TMStatusPill(text: "Synced", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                            }
                        }
                    }
                }
                .tmPanelSurface()

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
                    let st = HermesRemoteClient.shared.status
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

                // 额度凭据统一在「计划与余额」页管理。
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Quota Credentials")
                    Button("Go to Plans & Balance") {
                        NotificationCenter.default.post(name: DashboardView.selectTab, object: DashboardView.Tab.plans)
                    }
                    .font(TMType.regular(11))
                }
                .tmPanelSurface()

                SubscriptionSettingsSection()
                DataMaintenanceSection()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .onAppear {
            feedURL = HermesRemoteClient.shared.feedURL
            for t in tools {
                sources[t] = t.sourceIsRemote
            }
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

            if showForm {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing == nil ? "Add subscription" : "Edit subscription · \(editing?.name ?? "")")
                        .font(TMType.semibold(12))
                    HStack(spacing: 10) {
                        TextField("Name (e.g. Codex / Claude Pro)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(TMType.regular(11.5))
                        Picker("", selection: $plan) {
                            Text("None").tag("")
                            Text("OpenCode Go").tag("go")
                            Text("OpenRouter").tag("openrouter")
                            Text("Claude Pro").tag("claude")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    HStack(spacing: 10) {
                        DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                            .font(TMType.regular(11.5))
                        Toggle("End date", isOn: $hasEndDate)
                            .toggleStyle(.checkbox)
                            .font(TMType.regular(11.5))
                        if hasEndDate {
                            DatePicker("", selection: $endDate, displayedComponents: .date)
                                .font(TMType.regular(11.5))
                        }
                        Picker("Cycle", selection: $cycle) {
                            Text("Monthly").tag("monthly")
                            Text("Yearly").tag("yearly")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        HStack(spacing: 4) {
                            TextField("Price", text: $price)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .frame(width: 80)
                            Text("$ / period").font(TMType.regular(TMType.micro)).foregroundStyle(TMDesign.quiet)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Save") {
                            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            // 价格必须为非负有效数字（§8: 负值/无效字符串不得静默转 0）。
                            guard let p = Double(price.trimmingCharacters(in: .whitespaces)), p.isFinite, p >= 0 else {
                                priceError = true
                                return
                            }
                            priceError = false
                            // 结束日期不得早于开始日期，否则会静默存出一条无效订阅。
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
                                        // Database 会发 subscriptionsDidChange，AppState 自动刷新，
                                        // 无需显式 refresh（避免双刷新）。
                                        showForm = false
                                        databaseError = nil
                                    } else {
                                        databaseError = "Failed to save subscription (disk space or database permissions)"
                                    }
                                }
                            }
                        }
                        .font(TMType.regular(12))
                        if priceError {
                            Text("Invalid price (number ≥ 0)")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.danger)
                        }
                        if dateError {
                            Text("End date must not be before start date")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.danger)
                        }
                        Button("Cancel") { showForm = false }
                            .font(TMType.regular(12))
                        Spacer()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
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
        p == "go" ? "g.circle.fill" : (p == "openrouter" ? ToolKind.openrouter.symbol : (p == "claude" ? ToolKind.claude.symbol : "calendar"))
    }

    private func planColor(_ p: String) -> Color {
        p == "go" ? TMDesign.accent : (p == "openrouter" ? ToolKind.openrouter.color : (p == "claude" ? ToolKind.claude.color : .gray))
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
