import SwiftUI
import Charts

/// 计划与余额: one card per service — quota, balance, credentials and history
/// in the same place. Fixed subscriptions are a read-only summary here;
/// add/edit lives in 设置.
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @State private var goSnapshots: [Database.OGSnapshot] = []
    @State private var orSnapshots: [Database.ORSnapshot] = []
    @State private var showGoForm = false
    @State private var showORForm = false
    @State private var goWS = ""
    @State private var goCookie = ""
    @State private var orKey = ""
    @State private var orAppend = false
    /// Each credential form shows only its own message/color — saving Go
    /// must never flash a message inside the OpenRouter form (and vice versa).
    @State private var goFormMessage: String?
    @State private var goFormFailed = false
    @State private var orFormMessage: String?
    @State private var orFormFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TMPageHeader("计划与余额")
                goCard
                orCard
                subsCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .onAppear { loadSnapshots() }
        .onReceive(goClient.$state) { _ in loadOGSnapshots() }
        .onReceive(orClient.$state) { _ in loadORSnapshots() }
    }

    private func loadSnapshots() {
        loadOGSnapshots()
        loadORSnapshots()
    }

    /// Reloads only the OpenCode Go history series.
    private func loadOGSnapshots() {
        UsageQueryService.shared.loadOGSnapshots(limit: 120) { goSnapshots = $0 }
    }

    /// Reloads only the OpenRouter history series.
    private func loadORSnapshots() {
        UsageQueryService.shared.loadORSnapshots(limit: 120) { orSnapshots = $0 }
    }

    // MARK: - OpenCode Go

    private var goCard: some View {
        let go = goClient.state
        return serviceCard(title: "OpenCode Go", icon: "g.circle.fill", color: TMDesign.accent) {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    isLoading: go.isLoading,
                    configured: goClient.configured,
                    error: go.error,
                    syncedText: go.lastOK > 0 ? "更新于 \(Format.dateTime(go.lastOK))" : nil,
                    refresh: goClient.configured ? { goClient.refresh() } : nil
                )
                if let err = go.error {
                    Text(err)
                        .font(.system(size: TMType.caption))
                        .foregroundStyle(TMDesign.danger.opacity(0.85))
                        .lineLimit(2)
                }

                // Credentials live here — provisioning and quota are one task.
                credentialsRow(
                    configured: goClient.configured,
                    summary: goClient.configured ? "已配置 workspace" : "未配置 — 配额无法读取",
                    actionTitle: goClient.configured ? "更换凭据" : "配置",
                    showForm: $showGoForm,
                    clearAction: {
                        goClient.clear()
                        goWS = ""
                        goCookie = ""
                        goFormMessage = "OpenCode Go 凭据已清除"
                        goFormFailed = false
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("workspaceId (wrk_...)", text: $goWS)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: TMType.caption, design: .monospaced))
                            SecureField("auth cookie (Fe26.2**...)", text: $goCookie)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: TMType.caption, design: .monospaced))
                            Button("保存并查询") {
                                let ws = goWS.trimmingCharacters(in: .whitespacesAndNewlines)
                                let ck = goCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !ws.isEmpty, !ck.isEmpty else { return }
                                if goClient.provision(workspaceId: ws, cookie: ck) {
                                    goClient.refresh()
                                    showGoForm = false
                                    goWS = ""
                                    goCookie = ""
                                    goFormMessage = "OpenCode Go 凭据已保存"
                                    goFormFailed = false
                                } else {
                                    goFormMessage = goClient.state.error ?? "保存失败（钥匙串不可用）"
                                    goFormFailed = true
                                }
                            }
                            .font(.system(size: TMType.caption))
                        }
                        if let goFormMessage, showGoForm {
                            Text(goFormMessage)
                                .font(.system(size: TMType.caption))
                                .foregroundStyle(goFormFailed ? TMDesign.danger : TMDesign.accent)
                        }
                    }
                }

                if goClient.configured {
                    if let pct = go.monthlyPct {
                        quotaBar(
                            title: "月度额度",
                            pct: pct,
                            reset: go.monthlyReset,
                            limit: OpenCodeGoClient.monthlyLimitUSD,
                            color: TMDesign.accent,
                            reference: subForGo?.price
                        )
                    }
                    windowRow("5 小时窗口", pct: go.rollingPct, reset: go.rollingReset)
                    windowRow("本周窗口", pct: go.weeklyPct, reset: go.weeklyReset)

                    if let sub = subForGo, let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                        Divider()
                        HStack(spacing: 8) {
                            Text("固定订阅")
                                .font(.system(size: TMType.caption))
                                .foregroundStyle(TMDesign.quiet)
                            Spacer()
                            Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "月" : "年")")
                                .font(.system(size: TMType.caption, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                            Text("第 \(info.dayOfCycle)/\(info.totalDays) 天")
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                            if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                let line = ForecastText.compact(for: fc, plan: sub.plan)
                                Text(line.text)
                                    .font(.system(size: TMType.caption, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(ForecastText.color(line.status))
                            }
                        }
                    }

                    goHistory
                }
            }
        }
    }

    private var goHistory: some View {
        let data = goSnapshots.filter { $0.monthlyPct != nil }
        return VStack(alignment: .leading, spacing: 6) {
            if data.count >= 2 {
                Text("月度用量历史")
                    .font(.system(size: TMType.caption, weight: .semibold))
                Chart(data.reversed()) { s in
                    if let pct = s.monthlyPct {
                        LineMark(
                            x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                            y: .value("用量 %", pct)
                        )
                        .foregroundStyle(TMDesign.accent.opacity(0.85))
                        .interpolationMethod(.catmullRom)
                    }
                    if let pct = s.weeklyPct {
                        LineMark(
                            x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                            y: .value("用量 %", pct)
                        )
                        .foregroundStyle(TMDesign.accentShade(0.6).opacity(0.8))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(v))%") }
                        }
                    }
                }
                .frame(height: 110)
            } else {
                Text("快照不足")
                    .font(.system(size: TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
        .padding(.top, 4)
    }

    private var subForGo: Database.Subscription? {
        app.subscriptions.first { $0.plan == "go" }
    }

    // MARK: - OpenRouter

    private var orCard: some View {
        let or = orClient.state
        return serviceCard(title: "OpenRouter", icon: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color) {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    isLoading: or.isLoading,
                    configured: orClient.hasKey,
                    error: or.error,
                    syncedText: or.lastOK > 0 ? "更新于 \(Format.dateTime(or.lastOK))" : nil,
                    refresh: orClient.hasKey ? { orClient.refresh() } : nil
                )
                if let err = or.error {
                    Text(err)
                        .font(.system(size: TMType.caption))
                        .foregroundStyle(TMDesign.danger.opacity(0.85))
                        .lineLimit(2)
                }

                credentialsRow(
                    configured: orClient.hasKey,
                    summary: orClient.hasKey ? "已配置 \(or.keyCount) 个 key（钥匙串）" : "未配置 — 额度无法读取",
                    actionTitle: orClient.hasKey ? "更换 / 追加" : "配置",
                    showForm: $showORForm,
                    clearAction: {
                        _ = orClient.setKey(nil)
                        orKey = ""
                        orAppend = false
                        orFormMessage = "OpenRouter key 已清除"
                        orFormFailed = false
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SecureField("sk-or-...", text: $orKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: TMType.caption, design: .monospaced))
                            Button("保存") {
                                let k = orKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                let ok = orAppend ? orClient.addKey(k) : orClient.setKey(k)
                                if ok {
                                    showORForm = false
                                    orKey = ""
                                    orAppend = false
                                    orFormMessage = "OpenRouter key 已保存并开始查询"
                                    orFormFailed = false
                                } else {
                                    orFormMessage = orClient.state.error ?? "保存失败（钥匙串不可用）"
                                    orFormFailed = true
                                }
                            }
                            .font(.system(size: TMType.caption))
                            .disabled(orKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if orClient.hasKey {
                                Toggle("追加到现有 key", isOn: $orAppend)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: TMType.caption))
                                    .controlSize(.small)
                            }
                        }
                        if let orFormMessage, showORForm {
                            Text(orFormMessage)
                                .font(.system(size: TMType.caption))
                                .foregroundStyle(orFormFailed ? TMDesign.danger : TMDesign.accent)
                        }
                    }
                }

                if orClient.hasKey {
                    HStack(spacing: 24) {
                        liveStat("现金余额", Format.money(or.accountBalance ?? 0))
                        liveStat("今日实际", Format.money(or.usageDaily))
                        liveStat("本月实际", Format.money(or.usageMonthly))
                        if let limit = or.limit {
                            liveStat("key 限额", Format.money(limit))
                        }
                    }
                    if let remaining = or.limitRemaining, let limit = or.limit {
                        quotaBar(
                            title: "key 额度剩余",
                            pct: limit > 0 ? remaining / limit * 100 : 0,
                            reset: nil,
                            limit: limit,
                            color: TMDesign.accent,
                            reference: nil,
                            remainingText: Format.money(remaining)
                        )
                    }
                    Text(or.isManagementKey
                         ? "管理 key"
                         : "普通 key")
                        .font(.system(size: TMType.micro))
                        .foregroundStyle(TMDesign.faint)

                    orHistory
                }
            }
        }
    }

    private var orHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            if orSnapshots.count >= 2 {
                Text("用量快照历史")
                    .font(.system(size: TMType.caption, weight: .semibold))
                Chart(orSnapshots.reversed()) { s in
                    LineMark(
                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                        y: .value("用量", s.usage)
                    )
                    .foregroundStyle(ToolKind.openrouter.color.opacity(0.8))
                    .interpolationMethod(.catmullRom)
                    if let limit = s.limit {
                        RuleMark(y: .value("额度", limit))
                            .foregroundStyle(.gray.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Format.moneyShort(v)) }
                        }
                    }
                }
                .frame(height: 110)
            } else {
                Text("快照不足")
                    .font(.system(size: TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 固定订阅（管理在计划页内嵌表单；设置页同组件）

    private var subsCard: some View {
        serviceCard(title: "固定订阅", icon: "calendar", color: .gray) {
            SubscriptionSettingsSection()
        }
    }

    // MARK: - 容器与通用行

    private func statusHeader(isLoading: Bool, configured: Bool, error: String?,
                              syncedText: String?, refresh: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Text("状态")
                .font(.system(size: TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if !configured {
                Text("未配置")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else if error != nil {
                TMStatusPill(text: "同步失败", color: TMDesign.danger, symbol: "xmark.circle.fill")
            } else {
                Label("已同步", systemImage: "checkmark.circle.fill")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            }
            Spacer()
            if let syncedText {
                Text(syncedText)
                    .font(.system(size: TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
            if let refresh {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: TMType.caption))
            }
        }
    }

    private func credentialsRow(configured: Bool, summary: String, actionTitle: String,
                                showForm: Binding<Bool>, clearAction: (() -> Void)? = nil,
                                @ViewBuilder form: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: configured ? "key.fill" : "key.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(configured ? TMDesign.accent : TMDesign.quiet)
                Text(summary)
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(configured ? TMDesign.quiet : .secondary)
                Spacer()
                if configured {
                    Button(actionTitle) {
                        showForm.wrappedValue.toggle()
                    }
                    .font(.system(size: TMType.caption))
                } else {
                    Button(actionTitle) {
                        showForm.wrappedValue.toggle()
                    }
                    .font(.system(size: TMType.caption))
                    .buttonStyle(.borderedProminent)
                    .tint(TMDesign.accent)
                }
                if configured, let clearAction {
                    Button("清除") {
                        showForm.wrappedValue = false
                        clearAction()
                    }
                    .font(.system(size: TMType.caption))
                }
            }
            if showForm.wrappedValue {
                form()
            }
        }
    }

    private func quotaBar(title: String, pct: Double, reset: Int64?,
                          limit: Double, color: Color, reference: Double?,
                          remainingText: String? = nil) -> some View {
        let p = min(max(pct, 0), 100)
        let used = p / 100 * limit
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: TMType.caption, weight: .medium))
                Spacer()
                if let remainingText {
                    Text("剩余 \(remainingText) / \(Format.money(limit))")
                        .font(.system(size: TMType.caption, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Text("已用 \(Format.money(used)) / \(Format.money(limit))")
                        .font(.system(size: TMType.caption, design: .monospaced))
                        .monospacedDigit()
                }
                Text("\(Int(p))%")
                    .font(.system(size: TMType.caption, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(p > 95 ? TMDesign.danger : (p > 80 ? TMDesign.accent : TMDesign.quiet))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(p > 95 ? TMDesign.danger : (p > 80 ? TMDesign.accent : color))
                        .frame(width: max(3, w * CGFloat(p / 100)))
                    if let reference {
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 1)
                            .offset(x: w * CGFloat(min(reference / limit, 1)) - 0.5)
                    }
                }
            }
            .frame(height: 7)
            if let reset, pct > 0 {
                Text("重置于 \(Format.countdown(reset))")
                    .font(.system(size: TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
    }

    private func windowRow(_ label: String, pct: Double?, reset: Int64?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Spacer()
            if let pct {
                Text("\(Int(pct))%")
                    .font(.system(size: TMType.caption, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pct > 95 ? TMDesign.danger : (pct > 80 ? TMDesign.accent : .primary))
            } else {
                Text("—")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.faint)
            }
            if let reset, goClient.state.lastSync > 0 {
                let absReset = goClient.state.lastSync + reset
                Text("重置 \(Format.remaining(absReset - Int64(Date().timeIntervalSince1970)))")
                    .font(.system(size: TMType.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
            }
        }
    }

    private func liveStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func serviceCard<Content: View>(title: String, icon: String, color: Color,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: TMDesign.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TMDesign.radius, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }
}
