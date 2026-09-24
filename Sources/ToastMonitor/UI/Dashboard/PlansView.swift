import SwiftUI
import Charts

/// 计划与余额: one card per connected service — quota, balance and history.
/// Credentials, account options and subscriptions are managed in
/// Settings › Sources; accounts that are not connected fold into one row
/// that opens it.
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @State private var goSnapshots: [Database.OGSnapshot] = []
    @State private var orSnapshots: [Database.ORSnapshot] = []
    /// Last observed state markers; onReceive only reloads history when the
    /// client actually produced a new result (isLoading flips are ignored).
    @State private var goLastSeen: (lastOK: Int64, lastSync: Int64)?
    @State private var orLastSeen: Int64 = 0

    private var claudeConnected: Bool { claudeQuota.enabled }
    private var goConnected: Bool { goClient.configured || goClient.state.lastSync > 0 }
    private var orConnected: Bool { orClient.hasKey }
    private var deepseekConnected: Bool { deepseek.state.kind != nil }
    private var ccConnected: Bool { ccQuota.state.configured || ccQuota.state.lastSync > 0 }

    private var unconnected: [String] {
        [(claudeConnected, "Claude"), (goConnected, "OpenCode Go"), (ccConnected, "Command Code"),
         (orConnected, "OpenRouter"), (deepseekConnected, "DeepSeek")]
            .filter { !$0.0 }.map(\.1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle("Plans & Balance")
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                if claudeConnected { claudeCard }
                if goConnected { goCard }
                if orConnected { orCard }
                if deepseekConnected {
                    serviceCard(title: "DeepSeek", icon: "d.circle.fill", color: ToolKind.dsh.color) {
                        DeepSeekBalanceView()
                    }
                }
                if ccConnected { ccCard }
                if !app.subscriptions.isEmpty { subsCard }
                if !unconnected.isEmpty { unconnectedCard }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .onAppear {
            goLastSeen = (goClient.state.lastOK, goClient.state.lastSync)
            orLastSeen = orClient.state.lastOK
            loadSnapshots()
        }
        .onReceive(goClient.$state) { state in
            if goLastSeen?.lastOK != state.lastOK || goLastSeen?.lastSync != state.lastSync {
                goLastSeen = (state.lastOK, state.lastSync)
                loadOGSnapshots()
            }
        }
        .onReceive(orClient.$state) { state in
            if orLastSeen != state.lastOK {
                orLastSeen = state.lastOK
                loadORSnapshots()
            }
        }
    }

    private func openAccountSettings() {
        SettingsWindowController.shared.show(pane: .sources)
    }

    private var unconnectedCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not connected")
                    .font(TMType.medium(TMType.body))
                Text(unconnected.joined(separator: " · "))
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set Up…", action: openAccountSettings)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: TMDesign.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TMDesign.radius, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }

    private func loadSnapshots() {
        loadOGSnapshots()
        loadORSnapshots()
    }

    /// Reloads only the OpenCode Go history series. The completion compares
    /// against the state observed at load time: if a newer result arrived
    /// while the query was running, this round is dropped and the newer
    /// onReceive round owns the series.
    private func loadOGSnapshots() {
        let seen = (goClient.state.lastOK, goClient.state.lastSync)
        UsageQueryService.shared.loadOGSnapshotsByDay { snaps in
            guard let cur = goLastSeen, cur == seen else { return }
            goSnapshots = snaps
        }
    }

    /// Reloads only the OpenRouter history series (one point per day).
    private func loadORSnapshots() {
        let seen = orClient.state.lastOK
        UsageQueryService.shared.loadORSnapshotsByDay { snaps in
            guard orLastSeen == seen else { return }
            orSnapshots = snaps
        }
    }

    // MARK: - OpenCode Go

    private var goCard: some View {
        let go = goClient.state
        return serviceCard(title: "OpenCode Go", icon: "g.circle.fill", color: ToolKind.opencode.color) {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    isLoading: go.isLoading,
                    configured: goClient.configured,
                    error: go.error,
                    lastSync: go.lastOK,
                    syncedText: go.lastOK > 0 ? "Updated \(Format.dateTime(go.lastOK))" : nil,
                    refresh: goClient.configured ? { goClient.refresh() } : nil
                )
                if let err = go.error, goClient.configured {
                    Text(err)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger.opacity(0.85))
                        .lineLimit(2)
                }

                if goClient.configured {
                    if let pct = go.monthlyPct {
                        quotaBar(
                            title: "Monthly quota",
                            usedPct: pct,
                            resetAt: go.monthlyReset.map { go.lastSync + $0 },
                            limit: OpenCodeGoClient.monthlyLimitUSD,
                            color: ToolKind.opencode.color,
                            reference: subForGo?.price
                        )
                    }
                    windowRow("5h window", pct: go.rollingPct, reset: go.rollingReset)
                    windowRow("Weekly window", pct: go.weeklyPct, reset: go.weeklyReset)

                    if let sub = subForGo, let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                        Divider()
                        HStack(spacing: 8) {
                            Text("Fixed subscription")
                                .font(TMType.regular(TMType.caption))
                                .foregroundStyle(TMDesign.quiet)
                            Spacer()
                            Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "mo" : "yr")")
                                .font(TMType.semibold(TMType.caption))
                                .tmMonospacedDigit()
                            Text("Day \(info.dayOfCycle)/\(info.totalDays)")
                                .font(TMType.regular(TMType.caption))
                                .tmMonospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                            if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                let line = ForecastText.line(for: fc, plan: sub.plan)
                                Text(line.text)
                                    .font(TMType.semibold(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(ForecastText.color(line.status))
                            }
                        }
                    }

                    goHistory
                }
            }
        }
    }

    /// 月额度剩余历史按「每天收盘点 + 同日额度变化事件」绘制。
    /// 数据库会保留额度增加/重置前后的真实点，避免把当天的跳变压成
    /// 一个最终值。周额度和 5h 窗口已经在卡片上方单独展示。
    private var goHistory: some View {
        let daily = Self.dailyMonthlyRemaining(goSnapshots)
        let currentRemaining = goClient.state.monthlyPct.map { max(0, min(100, 100 - $0)) }
        return VStack(alignment: .leading, spacing: 6) {
            if daily.count >= 2 {
                HStack(spacing: 12) {
                    Text("Monthly quota remaining (daily)")
                        .font(TMType.semibold(TMType.caption))
                    Spacer()
                    if let currentRemaining {
                        Text("\(Int(currentRemaining.rounded()))% left")
                            .font(TMType.monoRegular(TMType.micro))
                            .foregroundStyle(TMDesign.quiet)
                    }
                }
                Chart(daily) { point in
                    if let remaining = point.remaining {
                        LineMark(
                            x: .value("Date", Date(timeIntervalSince1970: TimeInterval(point.ts))),
                            y: .value("Remaining %", remaining)
                        )
                        .foregroundStyle(TMDesign.accent)
                        // A quota reset is a real discontinuity. Linear
                        // interpolation keeps the daily samples honest and
                        // avoids inventing a smooth curve between reset and
                        // post-reset values.
                        .interpolationMethod(.linear)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(daily.count / 6, 1))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("OpenCode Go monthly quota remaining history chart")
                .accessibilityValue(Text(goHistoryAccessibilitySummary(daily)))
                .accessibilityHint("VoiceOver browses daily monthly quota remaining; increases indicate a quota reset")
                .frame(height: 110)
            } else {
                Text("Not enough snapshots")
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
        .padding(.top, 4)
    }

    /// Shared dash pattern for secondary quota guides elsewhere in Plans.
    private static let historyDash: [CGFloat] = [4, 3]

    private struct DailyPoint: Identifiable {
        let day: Int64
        let remaining: Double?
        let ts: Int64
        var id: Int64 { ts }
    }

    /// Converts provider-reported used percent to the remaining percent the
    /// chart communicates to the user. The database has already retained one
    /// daily point plus any intra-day quota-change points, so do not collapse
    /// the samples by day again here.
    private static func dailyMonthlyRemaining(_ snaps: [Database.OGSnapshot]) -> [DailyPoint] {
        return snaps.map { snapshot in
            let day = Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(snapshot.ts))).timeIntervalSince1970)
            return DailyPoint(
                day: day,
                remaining: snapshot.monthlyPct.map { max(0, min(100, 100 - $0)) },
                ts: snapshot.ts
            )
        }
        .sorted { $0.ts < $1.ts }
    }
    private func goHistoryAccessibilitySummary(_ daily: [DailyPoint]) -> String {
        let days = Set(daily.map(\.day)).count
        let current = daily.last?.remaining.map { "\(Int($0.rounded()))% remaining" } ?? "no current value"
        return "\(days) days, \(current)"
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
                    lastSync: or.lastOK,
                    syncedText: or.lastOK > 0 ? "Updated \(Format.dateTime(or.lastOK))" : nil,
                    refresh: orClient.hasKey ? { orClient.refresh() } : nil
                )
                if let err = or.error, orClient.hasKey {
                    Text(err)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger.opacity(0.85))
                        .lineLimit(2)
                }

                if orClient.hasKey {
                    HStack(spacing: 24) {
                        liveStat("Balance", or.accountBalance.map(Format.money) ?? "—")
                        liveStat("Today", Format.money(or.usageDaily))
                        liveStat("Month", Format.money(or.usageMonthly))
                        if let limit = or.limit {
                            liveStat("Key limit", Format.money(limit))
                        }
                    }
                    if let remaining = or.limitRemaining, let limit = or.limit {
                        // Bar semantics are "used": a brand-new key at 100%
                        // remaining renders an empty bar, never a full red one.
                        let usedPct = limit > 0 ? (limit - remaining) / limit * 100 : 0
                        quotaBar(
                            title: "Key quota",
                            usedPct: usedPct,
                            resetAt: nil,
                            limit: limit,
                            color: ToolKind.openrouter.color,
                            reference: nil,
                            remainingText: Format.money(remaining)
                        )
                    }
                    Text(or.isManagementKey
                         ? "Management key"
                         : "Standard key")
                        .font(TMType.regular(TMType.micro))
                        .foregroundStyle(TMDesign.faint)

                    orHistory
                }
            }
        }
    }

    private var orHistory: some View {
        let useAccountBalance = orSnapshots.contains { $0.accountBalance != nil }
        let balanceSnapshots = orSnapshots.filter {
            useAccountBalance ? $0.accountBalance != nil : $0.limitRemaining != nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            if balanceSnapshots.count >= 2 {
                Text("Balance history (daily)")
                    .font(TMType.semibold(TMType.caption))
                Chart(balanceSnapshots) { s in
                    if let balance = useAccountBalance ? s.accountBalance : s.limitRemaining {
                        LineMark(
                            x: .value("Time", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                            y: .value("Balance", balance)
                        )
                        .foregroundStyle(TMDesign.accent.opacity(0.85))
                        // Balance changes are measured values. Linear segments
                        // prevent a smoothing spline from inventing an upward
                        // bump between two declining snapshots.
                        .interpolationMethod(.linear)
                    }
                }
                .chartXAxis {
                    // Same day-stride axis as goHistory so both history
                    // charts share tick density and label format.
                    AxisMarks(values: .stride(by: .day, count: max(balanceSnapshots.count / 6, 1))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel("OpenRouter balance history chart")
                .accessibilityValue(Text(orHistoryAccessibilitySummary(balanceSnapshots, useAccountBalance: useAccountBalance)))
                .accessibilityHint("VoiceOver browses daily OpenRouter balance; decreases indicate usage")
                .frame(height: 110)
            } else {
                Text("Not enough snapshots")
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
        .padding(.top, 4)
    }
    private func orHistoryAccessibilitySummary(_ snapshots: [Database.ORSnapshot], useAccountBalance: Bool) -> String {
        let current = snapshots.last.flatMap { useAccountBalance ? $0.accountBalance : $0.limitRemaining }
            .map(Format.money)
            ?? "no current balance"
        return "\(snapshots.count) days, current balance \(current)"
    }

    // MARK: - Claude (undocumented endpoint, opt-in, off by default)

    private var claudeCard: some View {
        let cq = claudeQuota.state
        return serviceCard(title: "Claude", icon: ToolKind.claude.symbol, color: ToolKind.claude.color) {
            VStack(alignment: .leading, spacing: 12) {
                if claudeQuota.enabled {
                    statusHeader(
                        isLoading: cq.lastSync <= 0 && cq.error == nil && cq.configured,
                        configured: cq.configured,
                        error: cq.error,
                        lastSync: cq.lastSync,
                        syncedText: cq.lastSync > 0 ? "Updated \(Format.dateTime(cq.lastSync))" : nil,
                        refresh: { claudeQuota.refresh(force: true) }
                    )
                    if let err = cq.error, cq.configured {
                        Text(err)
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.danger.opacity(0.85))
                            .lineLimit(2)
                    }
                    if let weekly = cq.sevenDay {
                        claudeWindowRow("Weekly window", window: weekly)
                    }
                    if let fiveHour = cq.fiveHour {
                        claudeWindowRow("5h window", window: fiveHour)
                    }
                    if let opus = cq.sevenDayOpus {
                        claudeWindowRow("Weekly Opus window", window: opus)
                    }
                }
            }
        }
    }

    private func claudeWindowRow(_ label: String, window: ClaudeQuotaClient.Window) -> some View {
        let remaining = 100 - window.usedPercent
        return HStack(spacing: 8) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Spacer()
            Text("\(remaining)% left")
                .font(TMType.semibold(TMType.caption))
                .tmMonospacedDigit()
                .foregroundStyle(TMDesign.quiet)
            if let resetAt = window.resetAt {
                let remainingSecs = resetAt - Int64(Date().timeIntervalSince1970)
                if remainingSecs > 0 {
                    Text("resets in \(Format.remaining(remainingSecs))")
                        .font(TMType.monoRegular(TMType.micro))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
    }

    // MARK: - Command Code GOAT (experimental private billing API)

    private var ccCard: some View {
        let cc = ccQuota.state
        return serviceCard(title: "Command Code GOAT", icon: "c.circle.fill", color: TMDesign.commandCode) {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    isLoading: cc.isLoading,
                    configured: cc.configured,
                    error: cc.error,
                    lastSync: cc.lastSync,
                    syncedText: cc.lastSync > 0 ? "Updated \(Format.dateTime(cc.lastSync))" : nil,
                    refresh: cc.configured ? { ccQuota.refresh() } : nil
                )
                if let err = cc.error, cc.configured {
                    Text(err)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger.opacity(0.85))
                        .lineLimit(2)
                }

                if cc.configured {
                    if let total = cc.monthlyCreditsTotal, let pct = cc.monthlyUsedPercent {
                        quotaBar(
                            title: "Monthly credits",
                            usedPct: pct,
                            resetAt: cc.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) },
                            limit: total,
                            color: TMDesign.commandCode,
                            reference: nil
                        )
                    } else if let remaining = cc.monthlyCreditsRemaining {
                        // Unknown plan or no allowance reported: show the raw
                        // balance rather than fabricating a percentage.
                        liveStat("Credits left", Format.money(remaining))
                    }
                }
            }
        }
    }

    // MARK: - 固定订阅（管理在计划页内嵌表单；设置页同组件）

    /// Where each fixed subscription stands in its billing cycle. Adding and
    /// editing happen in Settings › Sources.
    private var subsCard: some View {
        serviceCard(title: "Subscriptions", icon: "calendar", color: TMDesign.accent) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(app.subscriptions) { sub in
                    HStack(spacing: 8) {
                        Image(systemName: SubscriptionSettingsSection.planIcon(sub.plan))
                            .foregroundStyle(SubscriptionSettingsSection.planColor(sub.plan))
                            .frame(width: 18)
                        Text(sub.name)
                            .font(TMType.medium(TMType.body))
                        Spacer()
                        Text("\(Format.money(sub.price))/\(sub.cycle == "yearly" ? "yr" : "mo")")
                            .font(TMType.semibold(TMType.caption))
                            .tmMonospacedDigit()
                        if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                            Text("Day \(info.dayOfCycle)/\(info.totalDays) · renews \(SubscriptionMath.dateStr(info.end))")
                                .font(TMType.regular(TMType.caption))
                                .tmMonospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                            if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                let line = ForecastText.line(for: fc, plan: sub.plan)
                                Text(line.text)
                                    .font(TMType.semibold(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(ForecastText.color(line.status))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 容器与通用行

    private func statusHeader(isLoading: Bool, configured: Bool, error: String?,
                              lastSync: Int64, syncedText: String?,
                              refresh: (() -> Void)?) -> some View {
        let stale = lastSync > 0
            && Date().timeIntervalSince1970 - TimeInterval(lastSync) > 120
        return HStack(spacing: 8) {
            Text("Status")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            if !configured {
                // Not configured is neutral, never an error.
                Text("Not configured")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else if error != nil {
                TMStatusPill(text: "Error", color: TMDesign.danger, symbol: "xmark.circle.fill")
            } else if isLoading && lastSync <= 0 {
                // Loading only before the first result; refreshes with an old
                // value keep showing the last known state.
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading")
            } else if lastSync <= 0 {
                TMStatusPill(text: "Idle", color: TMDesign.quiet, symbol: "circle.dashed")
            } else if stale {
                TMStatusPill(text: "Stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
            } else {
                Label("Synced", systemImage: "checkmark.circle.fill")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            }
            Spacer()
            if let syncedText {
                Text(syncedText)
                    .font(TMType.monoRegular(TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
            if let refresh {
                Button {
                    refresh()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .font(TMType.regular(TMType.caption))
                .disabled(isLoading)
                .accessibilityLabel("Refresh status")
                .accessibilityHint("Re-queries this service's quota")
            }
        }
        // Fixed minimum row height: the plain-text branches ("Not configured",
        // "Synced") are ~10pt shorter than TMStatusPill's padded capsule, so
        // switching states used to make the whole row jump in height.
        .frame(minHeight: 24)
    }

    /// Quota progress bar. `usedPct` is the fraction of the limit already
    /// consumed (0–100); bar width and color follow usage, so a brand-new
    /// key at 100% remaining renders an empty bar instead of a full red one.
    /// `resetAt` (absolute unix seconds) shows the "resets in …" fine-print.
    /// `reference` draws a hairline at a fixed value — used for the
    /// subscription price as a share of the quota limit (e.g. a $10 sub on a
    /// $60 monthly limit marks the 16.7% position) so the paid tier is
    /// visible against actual consumption.
    private func quotaBar(title: String, usedPct: Double, resetAt: Int64?,
                          limit: Double, color: Color, reference: Double?,
                          remainingText: String? = nil) -> some View {
        let p = min(max(usedPct, 0), 100)
        let used = p / 100 * limit
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(TMType.medium(TMType.caption))
                Spacer()
                if let remainingText {
                    Text("Left \(remainingText) / \(Format.money(limit))")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                } else {
                    Text("Used \(Format.money(used)) / \(Format.money(limit))")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                }
                Text("\(Int(p))%")
                    .font(TMType.semibold(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color)
                        // p == 0 renders a truly empty bar; the 3pt floor
                        // only protects tiny-but-nonzero usage from vanishing.
                        .frame(width: p > 0 ? max(3, w * CGFloat(p / 100)) : 0)
                    if let reference {
                        // Subscription-price reference line (see doc comment).
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 1)
                            .offset(x: w * CGFloat(min(reference / limit, 1)) - 0.5)
                    }
                }
            }
            .frame(height: 7)
            if let resetAt, usedPct > 0 {
                let remaining = resetAt - Int64(Date().timeIntervalSince1970)
                if remaining > 0 {
                    Text("resets in \(Format.remaining(remaining))")
                        .font(TMType.monoRegular(TMType.micro))
                        .foregroundStyle(TMDesign.faint)
                }
            }
        }
    }

    private func windowRow(_ label: String, pct: Double?, reset: Int64?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Spacer()
            if let pct {
                Text("\(Int(pct))%")
                    .font(TMType.semibold(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
            } else {
                Text("—")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.faint)
            }
            if let reset, goClient.state.lastSync > 0 {
                let absReset = goClient.state.lastSync + reset
                let remaining = absReset - Int64(Date().timeIntervalSince1970)
                if remaining > 0 {
                    Text("resets in \(Format.remaining(remaining))")
                        .font(TMType.monoRegular(TMType.micro))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
    }

    private func liveStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(TMType.semibold(17))
                .tmMonospacedDigit()
        }
    }

    private func serviceCard<Content: View>(title: String, icon: String, color: Color,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TMType.medium(14))
                    .foregroundStyle(color)
                    .frame(width: 22)
                SectionTitle(title)
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
