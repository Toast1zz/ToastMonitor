import SwiftUI

/// 设置: per-tool data source (local Mac vs remote VPS feed) + feed URL.
struct SettingsView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @State private var feedURL = ""
    @State private var sources: [ToolKind: Bool] = [:] // tool -> isRemote (draft)
    @State private var saved = false
    @State private var feedError = false
    @State private var sourceSaved: ToolKind?
    @State private var sourceFailed: ToolKind?
    @State private var orKeyInput = ""
    @State private var goWorkspaceID = ""
    @State private var goCookie = ""
    @State private var credentialMessage: String?
    @State private var credentialFailed = false

    private let tools = ToolKind.allCases.filter { $0 != .openrouter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TMPageHeader(
                    title: "配置",
                    subtitle: "来源、远程 Feed、凭据与固定订阅",
                    eyebrow: "工作台"
                )
                VStack(alignment: .leading, spacing: 12) {
                    Text("数据来源")
                        .font(.system(size: 13, weight: .semibold))
                    Text("每个工具可以独立选择从「本机」还是「远程 VPS」读取用量日志。选择立即保存并生效，远程数据由 VPS 上的导出任务（tm-export.py）生成。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

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
                                    // P0-4: persist immediately, show effect.
                                    if tool.setSource(remote: newValue) {
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
                                    .foregroundStyle(.green)
                            }
                            if sourceFailed == tool {
                                Text("保存失败")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .tmPanelSurface()

                // 来源健康（每采集器一张状态卡）
                VStack(alignment: .leading, spacing: 10) {
                    Text("数据来源健康")
                        .font(.system(size: 13, weight: .semibold))
                    if health.sources.isEmpty {
                        Text("暂无扫描记录 —— 首次扫描后显示每个来源的耗时、条数与状态。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(health.sources) { h in
                            HStack(spacing: 10) {
                                Image(systemName: ToolKind(rawValue: h.tool)?.symbol ?? "dot.radiowaves.left.and.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ToolKind(rawValue: h.tool)?.color ?? .gray)
                                    .frame(width: 18)
                                Text(ToolKind(rawValue: h.tool)?.displayName ?? h.tool)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 100, alignment: .leading)
                                Text(h.mode == "remote" ? "远程" : "本机")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34)
                                Spacer()
                                if let err = h.error {
                                    Text(err)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.red)
                                } else {
                                    Text("\(Format.dateTime(h.lastScan)) · \(h.lastRows) 条 · \(String(format: "%.0fms", h.durationMs))")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
                .tmPanelSurface()

                // 远程 Feed
                VStack(alignment: .leading, spacing: 10) {
                    Text("远程 Feed")
                        .font(.system(size: 13, weight: .semibold))
                    HStack {
                        TextField("http://100.116.140.74/tm/usage.json", text: $feedURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Button("保存") {
                            let raw = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            saved = false
                            let ok = HermesRemoteClient.shared.provision(url: raw.isEmpty ? nil : raw)
                            saved = ok
                            feedError = !ok
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
                                .foregroundStyle(.red)
                        }
                        if saved {
                            Text("已保存")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.green)
                        }
                        if feedError {
                            Text("URL 不安全或保存失败（仅 HTTPS/私有网段）")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .tmPanelSurface()

                quotaCredentials

                VStack(alignment: .leading, spacing: 6) {
                    Text("关于配额面板")
                        .font(.system(size: 13, weight: .semibold))
                    Text("OpenCode Go 套餐与 OpenRouter 的配额均内建（不依赖 opencode-quota 插件）：\n· 计划与余额：粘贴 workspaceId + 会话 cookie，或命令行 --provision-go 注入\n· OpenRouter API key：在完整面板的设置/配额入口配置，或命令行 --provision-or-key 注入\n· secret 只存 macOS 钥匙串；命令行 secret 通过 stdin，不进入进程参数")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .tmPanelSurface()

                SubscriptionSettingsSection()
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

    private var quotaCredentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配额凭据")
                .font(.system(size: 13, weight: .semibold))
            Text("凭据只保存到 macOS 钥匙串；保存失败时不会回退到 SQLite 明文。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OpenRouter")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(orClient.hasKey ? "已配置 \(orClient.state.keyCount) 个 key" : "未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(orClient.hasKey ? .green : .secondary)
                    if orClient.hasKey {
                        Button("清除") {
                            _ = orClient.setKey(nil)
                            orKeyInput = ""
                            credentialMessage = "OpenRouter key 已清除"
                            credentialFailed = false
                        }
                        .font(.system(size: 11))
                    }
                }
                HStack(spacing: 8) {
                    SecureField("sk-or-...", text: $orKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    Button("保存") {
                        let key = orKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if orClient.setKey(key) {
                            orKeyInput = ""
                            credentialMessage = "OpenRouter key 已保存并开始查询"
                            credentialFailed = false
                        } else {
                            credentialMessage = orClient.state.error ?? "OpenRouter key 保存失败"
                            credentialFailed = true
                        }
                    }
                    .font(.system(size: 11))
                    .disabled(orKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OpenCode Go")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(goClient.configured ? "已配置" : "未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(goClient.configured ? .green : .secondary)
                    if goClient.configured {
                        Button("清除") {
                            goClient.clear()
                            goWorkspaceID = ""
                            goCookie = ""
                            credentialMessage = "OpenCode Go 凭据已清除"
                            credentialFailed = false
                        }
                        .font(.system(size: 11))
                    }
                }
                HStack(spacing: 8) {
                    TextField("workspaceId", text: $goWorkspaceID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    SecureField("auth cookie", text: $goCookie)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    Button("保存") {
                        let ws = goWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cookie = goCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        if goClient.provision(workspaceId: ws, cookie: cookie) {
                            goClient.refresh()
                            goWorkspaceID = ""
                            goCookie = ""
                            credentialMessage = "OpenCode Go 凭据已保存并开始查询"
                            credentialFailed = false
                        } else {
                            credentialMessage = goClient.state.error ?? "OpenCode Go 凭据保存失败"
                            credentialFailed = true
                        }
                    }
                    .font(.system(size: 11))
                    .disabled(goWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || goCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let credentialMessage {
                Text(credentialMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(credentialFailed ? .red : .green)
            }
        }
        .tmPanelSurface()
    }
}

/// 订阅管理: list + add/edit form (固定成本侧信息).
struct SubscriptionSettingsSection: View {
    @ObservedObject private var app = AppState.shared
    @State private var showForm = false
    @State private var editing: Database.Subscription?
    @State private var name = ""
    @State private var plan = ""
    @State private var startDate = Date()
    @State private var cycle = "monthly"
    @State private var price = ""
    @State private var priceError = false
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
                    name = ""
                    plan = ""
                    startDate = Date()
                    cycle = "monthly"
                    price = ""
                    showForm = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .font(.system(size: 12))
                Button {
                    editing = nil
                    name = "OpenCode Go"
                    plan = "go"
                    startDate = Date()
                    cycle = "monthly"
                    price = "10"
                    showForm = true
                } label: {
                    Text("Go 模板")
                }
                .font(.system(size: 12))
                .help("填入 OpenCode Go $10/月 模板")
            }

            if app.subscriptions.isEmpty {
                Text("暂无订阅记录。记录后「计划与余额」会显示周期进度、续期日期和用量预测。")
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
                            Text("\(Format.dateTime(sub.startDate)) 起 · \(sub.cycle == "yearly" ? "年度" : "月度") · \(Format.money(sub.price))/期")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
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
                            name = sub.name
                            plan = sub.plan
                            startDate = Date(timeIntervalSince1970: TimeInterval(sub.startDate))
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
                        .foregroundStyle(.red)
                        .help("删除订阅")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                }
            }

            if showForm {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing == nil ? "添加订阅" : "编辑订阅")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 10) {
                        TextField("名称（如 Codex / Claude Pro）", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                        Picker("", selection: $plan) {
                            Text("不关联").tag("")
                            Text("OpenCode Go").tag("go")
                            Text("OpenRouter").tag("openrouter")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    HStack(spacing: 10) {
                        DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                            .font(.system(size: 11.5))
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
                            let sub = Database.Subscription(
                                id: editing?.id ?? 0,
                                name: name.trimmingCharacters(in: .whitespaces),
                                plan: plan,
                                startDate: Int64(startDate.timeIntervalSince1970),
                                cycle: cycle,
                                price: p,
                                currency: "USD")
                            if Database.shared.upsertSubscription(sub) {
                                app.refresh()
                                showForm = false
                                databaseError = nil
                            } else {
                                databaseError = "订阅保存失败，请检查磁盘空间或数据库权限"
                            }
                        }
                        .font(.system(size: 12))
                        if priceError {
                            Text("费用无效（需 ≥ 0 的数字）")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        if let databaseError {
                            Text(databaseError)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        Button("取消") { showForm = false }
                            .font(.system(size: 12))
                        Spacer()
                        Text("关联 OpenCode Go / OpenRouter 后自动计算已用价值")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)))
        .alert("删除订阅？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let sub = pendingDelete {
                        if Database.shared.deleteSubscription(id: sub.id) {
                            app.refresh()
                            databaseError = nil
                        } else {
                            databaseError = "订阅删除失败，请检查磁盘空间或数据库权限"
                        }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete.map { "将删除「\($0.name)」及其周期/预测记录。" } ?? "")
            }
    }

    private func planIcon(_ p: String) -> String {
        p == "go" ? "g.circle.fill" : (p == "openrouter" ? ToolKind.openrouter.symbol : "calendar")
    }

    private func planColor(_ p: String) -> Color {
        p == "go" ? .orange : (p == "openrouter" ? ToolKind.openrouter.color : .gray)
    }
}
