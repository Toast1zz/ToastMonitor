import SwiftUI

/// 设置: per-tool data source (local Mac vs remote VPS feed) + feed URL.
struct SettingsView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var feedURL = ""
    @State private var sources: [ToolKind: Bool] = [:] // tool -> isRemote (draft)
    @State private var saved = false
    @State private var feedError = false
    @State private var sourceSaved: ToolKind?
    @State private var sourceFailed: ToolKind?

    private let tools = ToolKind.allCases.filter { $0 != .openrouter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TMPageHeader("配置")
                VStack(alignment: .leading, spacing: 12) {
                    Text("数据来源")
                        .font(.system(size: 13, weight: .semibold))

                    ForEach(tools) { tool in
                        HStack(spacing: 10) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(tool.color)
                                .frame(width: 18)
                            Text(tool.displayName)
                                .font(.system(size: 12.5))
                                .frame(width: 100, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { sources[tool] ?? (tool.defaultSource == "remote") },
                                set: { newValue in
                                    // P0-4: persist immediately (off main thread), show effect.
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let ok = tool.setSource(remote: newValue)
                                        DispatchQueue.main.async {
                                            if ok {
                                                sources[tool] = newValue
                                                sourceSaved = tool
                                                sourceFailed = nil
                                            } else {
                                                // Keep the picker aligned with the
                                                // effective persisted value after a
                                                // failed write.
                                                sources[tool] = tool.sourceIsRemote
                                                sourceFailed = tool
                                                sourceSaved = nil
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                if sourceSaved == tool { sourceSaved = nil }
                                                if sourceFailed == tool { sourceFailed = nil }
                                            }
                                        }
                                    }
                                }
                            )) {
                                Text("本机 (Mac)").tag(false)
                                Text("远程 (VPS)").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                            Spacer()
                            // Actual effective value, not the draft.
                            Text(tool.sourceIsRemote ? "读取 VPS feed" : "读取本机日志")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            if sourceSaved == tool {
                                Text("已保存 ✓")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(TMDesign.accent)
                            }
                            if sourceFailed == tool {
                                Text("保存失败")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(TMDesign.danger)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .tmPanelSurface()

                // 来源健康（详情在「来源状态」页，这里只留一行摘要）
                VStack(alignment: .leading, spacing: 10) {
                    Text("数据来源健康")
                        .font(.system(size: 13, weight: .semibold))
                    if health.sources.isEmpty {
                        Text("暂无扫描记录")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        let broken = health.sources.filter { $0.error != nil }.count
                        let stale = health.sources.filter { $0.error == nil && $0.isStale }.count
                        HStack(spacing: 8) {
                            if broken > 0 {
                                TMStatusPill(text: "\(broken) 个来源异常", color: TMDesign.danger, symbol: "exclamationmark.triangle.fill")
                            }
                            if stale > 0 {
                                TMStatusPill(text: "\(stale) 个来源过期", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                            }
                            if broken == 0 && stale == 0 {
                                TMStatusPill(text: "已同步", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                            }
                        }
                    }
                }
                .tmPanelSurface()

                // 远程 Feed
                VStack(alignment: .leading, spacing: 10) {
                    Text("远程 Feed")
                        .font(.system(size: 13, weight: .semibold))
                    HStack {
                        TextField("HTTPS 或私有网段 Feed URL", text: $feedURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Button("保存") {
                            let raw = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            saved = false
                            DispatchQueue.global(qos: .userInitiated).async {
                                let ok = HermesRemoteClient.shared.provision(url: raw.isEmpty ? nil : raw)
                                DispatchQueue.main.async {
                                    saved = ok
                                    feedError = !ok
                                }
                            }
                        }
                        .font(.system(size: 12))
                        Button {
                            HermesRemoteClient.shared.maybePoll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .font(.system(size: 12))
                        .help("立即拉取")
                    }
                    let st = HermesRemoteClient.shared.status
                    HStack {
                        if st.lastSync > 0 {
                            Text(st.lastRows > 0
                                 ? "上次同步 \(Format.dateTime(st.lastSync)) · \(st.lastRows) 条新增"
                                 : "上次同步 \(Format.dateTime(st.lastSync)) · 已是最新")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        if let err = st.error {
                            Text(err)
                                .font(.system(size: 10.5))
                                .foregroundStyle(TMDesign.danger)
                        }
                        if saved {
                            Text("已保存")
                                .font(.system(size: 10.5))
                                .foregroundStyle(TMDesign.accent)
                        }
                        if feedError {
                            Text("URL 不安全或保存失败（仅 HTTPS/私有网段）")
                                .font(.system(size: 10.5))
                                .foregroundStyle(TMDesign.danger)
                        }
                    }
                }
                .tmPanelSurface()

                // 额度凭据统一在「计划与余额」页管理。
                VStack(alignment: .leading, spacing: 10) {
                    Text("配额凭据")
                        .font(.system(size: 13, weight: .semibold))
                    Button("前往计划与余额") {
                        NotificationCenter.default.post(name: DashboardView.selectTab, object: DashboardView.Tab.plans)
                    }
                    .font(.system(size: 11))
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
                Text("订阅（固定成本）")
                    .font(.system(size: 13, weight: .semibold))
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
                    Label("添加", systemImage: "plus")
                }
                .font(.system(size: 12))
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
                    Text("Go 模板")
                }
                .font(.system(size: 12))
                .disabled(showForm)
                .help("填入 OpenCode Go $10/月 模板")
            }

            if app.subscriptions.isEmpty {
                Text("暂无订阅")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.subscriptions) { sub in
                    HStack {
                        Image(systemName: planIcon(sub.plan))
                            .foregroundStyle(planColor(sub.plan))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                                .font(.system(size: 12, weight: .medium))
                            Text("\(Format.dateTime(sub.startDate)) 起 · \(sub.cycle == "yearly" ? "年度" : "月度") · \(Format.money(sub.price))/期"
                                 + (sub.endDate > 0 ? " · 至 \(SubscriptionMath.dateStr(Date(timeIntervalSince1970: TimeInterval(sub.endDate))))" : ""))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                                HStack(spacing: 6) {
                                    Text("第 \(info.dayOfCycle)/\(info.totalDays) 天 · 续期 \(SubscriptionMath.dateStr(info.end)) · 日均 \(Format.money(sub.price / Double(info.totalDays)))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                        let line = ForecastText.compact(for: fc, plan: sub.plan)
                                        Text(line.text)
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                            .foregroundStyle(ForecastText.color(line.status))
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button("编辑") {
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
                        .font(.system(size: 11))
                        Button {
                            pendingDelete = sub
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.danger)
                        .help("删除订阅")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                }
            }

            if showForm {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing == nil ? "添加订阅" : "编辑订阅 · \(editing?.name ?? "")")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 10) {
                        TextField("名称（如 Codex / Claude Pro）", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                        Picker("", selection: $plan) {
                            Text("不关联").tag("")
                            Text("OpenCode Go").tag("go")
                            Text("OpenRouter").tag("openrouter")
                            Text("Claude Pro").tag("claude")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    HStack(spacing: 10) {
                        DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                            .font(.system(size: 11.5))
                        Toggle("结束时间", isOn: $hasEndDate)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                        if hasEndDate {
                            DatePicker("", selection: $endDate, displayedComponents: .date)
                                .font(.system(size: 11.5))
                        }
                        Picker("周期", selection: $cycle) {
                            Text("月度").tag("monthly")
                            Text("年度").tag("yearly")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        HStack(spacing: 4) {
                            TextField("费用", text: $price)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(width: 80)
                            Text("$ / 期").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("保存") {
                            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            // 价格必须为非负有效数字（§8: 负值/无效字符串不得静默转 0）。
                            guard let p = Double(price.trimmingCharacters(in: .whitespaces)), p >= 0 else {
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
                                        app.refresh()
                                        showForm = false
                                        databaseError = nil
                                    } else {
                                        databaseError = "订阅保存失败，请检查磁盘空间或数据库权限"
                                    }
                                }
                            }
                        }
                        .font(.system(size: 12))
                        if priceError {
                            Text("费用无效（需 ≥ 0 的数字）")
                                .font(.system(size: 10))
                                .foregroundStyle(TMDesign.danger)
                        }
                        if dateError {
                            Text("结束日期不能早于开始日期")
                                .font(.system(size: 10))
                                .foregroundStyle(TMDesign.danger)
                        }
                        if let databaseError {
                            Text(databaseError)
                                .font(.system(size: 10))
                                .foregroundStyle(TMDesign.danger)
                        }
                        Button("取消") { showForm = false }
                            .font(.system(size: 12))
                        Spacer()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)))
        .onChange(of: showForm) { _, _ in
            // Draft validation must not survive closing and later reopening
            // the form; especially dateError used to appear on a fresh edit.
            priceError = false
            dateError = false
            databaseError = nil
        }
        .alert("删除订阅？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let sub = pendingDelete {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = Database.shared.deleteSubscription(id: sub.id)
                            DispatchQueue.main.async {
                                if ok {
                                    app.refresh()
                                    databaseError = nil
                                } else {
                                    databaseError = "订阅删除失败，请检查磁盘空间或数据库权限"
                                }
                            }
                        }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete.map { "将删除「\($0.name)」及其周期/预测记录。" } ?? "")
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
                Text("数据维护")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("预览本机数据重建") { loadPreview() }
                    .font(.system(size: 11))
                    .disabled(isWorking)
            }
            if let preview {
                Text("\(preview.turns) 条记录 · \(preview.sessions) 个会话 · \(Format.count(preview.tokens)) tokens")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("备份并重建", role: .destructive) { confirmsRepair = true }
                        .disabled(isWorking || preview.turns == 0)
                    if receipt != nil {
                        Button("恢复修复前备份") { confirmsRestore = true }
                            .disabled(isWorking)
                    }
                }
                .font(.system(size: 11))
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .tmPanelSurface()
        .confirmationDialog("重建本机用量数据？", isPresented: $confirmsRepair) {
            Button("备份并重建", role: .destructive) { repair() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅处理当前设为“本机”的来源；先创建备份，再重新扫描原始日志。")
        }
        .confirmationDialog("恢复修复前备份？", isPresented: $confirmsRestore) {
            Button("恢复备份", role: .destructive) { restore() }
            Button("取消", role: .cancel) {}
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
                    message = "备份：\(value.backupPath)"
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
                message = ok ? "已恢复：\(receipt.backupPath)" : "恢复失败；备份仍保留"
                isWorking = false
                if ok {
                    app.refresh()
                    loadPreview()
                }
            }
        }
    }
}
