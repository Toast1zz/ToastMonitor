import SwiftUI
import Charts

/// Plans: one card per connected account — quota windows, balance and history.
/// Credentials, account options and subscriptions are managed in
/// Settings › Accounts; accounts that are not connected fold into one card
/// that opens it.
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false
    @State private var goSnapshots: [Database.OGSnapshot] = []
    @State private var orSnapshots: [Database.ORSnapshot] = []
    /// Last observed state markers; onReceive only reloads history when the
    /// client actually produced a new result (isLoading flips are ignored).
    @State private var goLastSeen: (lastOK: Int64, lastSync: Int64)?
    @State private var orLastSeen: Int64 = 0

    // Shared with the popover, so an account never reads "Not configured"
    // here while it shows numbers there.
    private var claudeConnected: Bool { AccountConnection.claude }
    private var goConnected: Bool { AccountConnection.openCodeGo }
    private var orConnected: Bool { AccountConnection.openRouter }
    private var deepseekConnected: Bool { AccountConnection.deepSeek }
    private var ccConnected: Bool { AccountConnection.commandCode }

    private var unconnected: [String] {
        [(claudeConnected, "Claude"), (goConnected, "OpenCode Go"), (ccConnected, "Command Code"),
         (orConnected, "OpenRouter"), (deepseekConnected, "DeepSeek")]
            .filter { !$0.0 }.map(\.1)
    }

    /// Connected accounts and subscriptions in two columns; the "not
    /// connected" card runs full width below them.
    private var cards: [AnyView] {
        var out: [AnyView] = []
        if claudeConnected { out.append(AnyView(claudeCard)) }
        if goConnected { out.append(AnyView(goCard)) }
        if orConnected { out.append(AnyView(orCard)) }
        if ccConnected { out.append(AnyView(ccCard)) }
        if deepseekConnected { out.append(AnyView(deepseekCard)) }
        if !app.subscriptions.isEmpty { out.append(AnyView(subsCard)) }
        return out
    }

    var body: some View {
        DashPage {
            let items = cards
            // Two columns, each card at its own content height, stacked from
            // the top. Cards are never stretched to fill the window: an
            // account with one quota bar is a short card, not a tall empty one.
            HStack(alignment: .top, spacing: DashLayout.gap) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(spacing: DashLayout.gap) {
                        ForEach(Array(stride(from: column, to: items.count, by: 2)), id: \.self) { index in
                            items[index].dashFixedHeight()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            if !unconnected.isEmpty { unconnectedCard.dashFixedHeight() }
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
        SettingsWindowController.shared.show(pane: .accounts)
    }

    private var unconnectedCard: some View {
        DashCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not connected")
                        .font(TMType.semibold(15))
                    Text(unconnected.joined(separator: " · "))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Set Up…", action: openAccountSettings)
                    .tmGlassButton(circle: false)
            }
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
        return serviceCard(title: "OpenCode Go", symbol: "g.circle.fill", color: ToolKind.opencode.color,
                           isLoading: go.isLoading, configured: goConnected,
                           error: go.error, lastSync: go.lastOK,
                           refresh: goClient.configured ? { goClient.refresh() } : nil) {
            if goConnected {
                if let pct = go.monthlyPct {
                    let limit = OpenCodeGoClient.monthlyLimitUSD
                    let used = min(max(pct, 0), 100) / 100 * limit
                    meter("Monthly", usedPercent: pct,
                          detail: "\(Format.money(used)) of \(Format.money(limit))"
                              + resetSuffix(absolute: go.monthlyReset.map { go.lastSync + $0 }),
                          color: ToolKind.opencode.color,
                          marker: subForGo.map { $0.price / limit })
                }
                windowMeter("5h", pct: go.rollingPct, reset: go.rollingReset)
                windowMeter("Weekly", pct: go.weeklyPct, reset: go.weeklyReset)

                if let sub = subForGo,
                   let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                    Divider()
                    subscriptionLine(sub, info: info)
                }
                goHistory
            }
        }
    }

    /// The forecast for a subscription that is tied to a quota.
    private func subscriptionLine(_ sub: Database.Subscription,
                                  info: SubscriptionMath.CycleInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Subscription")
                    .font(TMType.medium(TMType.body))
                Spacer()
                Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "mo" : "yr")")
                    .font(TMType.semibold(TMType.body))
                    .tmMonospacedDigit()
            }
            HStack(alignment: .firstTextBaseline) {
                if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                    let line = ForecastText.line(for: fc, plan: sub.plan)
                    Text(line.text)
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(ForecastText.color(line.status))
                }
                Spacer()
                Text("Day \(info.dayOfCycle) of \(info.totalDays)")
                    .font(TMType.regular(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(TMDesign.quiet)
            }
        }
    }

    /// 月额度剩余历史按「每天收盘点 + 同日额度变化事件」绘制。
    /// 数据库会保留额度增加/重置前后的真实点，避免把当天的跳变压成
    /// 一个最终值。周额度和 5h 窗口已经在卡片上方单独展示。
    private var goHistory: some View {
        let daily = Self.dailyMonthlyRemaining(goSnapshots)
        let currentRemaining = goClient.state.monthlyPct.map { max(0, min(100, 100 - $0)) }
        return historyBlock(title: "Monthly remaining, daily",
                            current: currentRemaining.map { "\(Int($0.rounded()))% left" },
                            hasData: daily.count >= 2) {
            Chart(daily) { point in
                if let remaining = point.remaining {
                    LineMark(
                        x: .value("Date", Date(timeIntervalSince1970: TimeInterval(point.ts))),
                        y: .value("Remaining %", remaining)
                    )
                    .foregroundStyle(ToolKind.opencode.color)
                    // A quota reset is a real discontinuity. Linear
                    // interpolation keeps the daily samples honest and
                    // avoids inventing a smooth curve between reset and
                    // post-reset values.
                    .interpolationMethod(.linear)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { historyDateAxis(count: daily.count) }
            .chartYAxis {
                historyValueAxis { Text("\(Int($0))%") }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("OpenCode Go monthly quota remaining history chart")
            .accessibilityValue(Text(goHistoryAccessibilitySummary(daily)))
            .accessibilityHint("VoiceOver browses daily monthly quota remaining; increases indicate a quota reset")
        }
    }

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
        return serviceCard(title: "OpenRouter", symbol: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color,
                           isLoading: or.isLoading, configured: orClient.hasKey,
                           error: or.error, lastSync: or.lastOK,
                           refresh: orClient.hasKey ? { orClient.refresh() } : nil) {
            if orClient.hasKey {
                HStack(alignment: .top, spacing: 28) {
                    liveStat("Balance", or.accountBalance.map(Format.money) ?? "—")
                    liveStat("Today", Format.money(or.usageDaily))
                    liveStat("Month", Format.money(or.usageMonthly))
                    if let limit = or.limit {
                        liveStat("Key limit", Format.money(limit))
                    }
                }
                if let remaining = or.limitRemaining, let limit = or.limit {
                    // Bar semantics are "used": a brand-new key at 100%
                    // remaining renders an empty bar, never a full one.
                    let usedPct = limit > 0 ? (limit - remaining) / limit * 100 : 0
                    meter("Key quota", usedPercent: usedPct,
                          detail: "\(Format.money(remaining)) of \(Format.money(limit)) left",
                          color: ToolKind.openrouter.color)
                }
                orHistory
            }
        }
    }

    private var orHistory: some View {
        let useAccountBalance = orSnapshots.contains { $0.accountBalance != nil }
        let balanceSnapshots = orSnapshots.filter {
            useAccountBalance ? $0.accountBalance != nil : $0.limitRemaining != nil
        }
        return historyBlock(title: "Balance, daily",
                            current: balanceSnapshots.last
                                .flatMap { useAccountBalance ? $0.accountBalance : $0.limitRemaining }
                                .map(Format.money),
                            hasData: balanceSnapshots.count >= 2) {
            Chart(balanceSnapshots) { s in
                if let balance = useAccountBalance ? s.accountBalance : s.limitRemaining {
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                        y: .value("Balance", balance)
                    )
                    .foregroundStyle(ToolKind.openrouter.color)
                    // Balance changes are measured values. Linear segments
                    // prevent a smoothing spline from inventing an upward
                    // bump between two declining snapshots.
                    .interpolationMethod(.linear)
                }
            }
            .chartXAxis { historyDateAxis(count: balanceSnapshots.count) }
            .chartYAxis {
                historyValueAxis { Text(Format.moneyShort($0)) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("OpenRouter balance history chart")
            .accessibilityValue(Text(orHistoryAccessibilitySummary(balanceSnapshots, useAccountBalance: useAccountBalance)))
            .accessibilityHint("VoiceOver browses daily OpenRouter balance; decreases indicate usage")
        }
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
        return serviceCard(title: "Claude", symbol: ToolKind.claude.symbol, color: ToolKind.claude.color,
                           isLoading: cq.lastSync <= 0 && cq.error == nil && cq.configured,
                           configured: claudeConnected, error: cq.error, lastSync: cq.lastSync,
                           refresh: { claudeQuota.refresh(force: true) }) {
            if let fiveHour = cq.fiveHour {
                claudeMeter("5h", window: fiveHour)
            }
            if let weekly = cq.sevenDay {
                claudeMeter("Weekly", window: weekly)
            }
            if let opus = cq.sevenDayOpus {
                claudeMeter("Weekly Opus", window: opus)
            }
        }
    }

    private func claudeMeter(_ label: String, window: ClaudeQuotaClient.Window) -> some View {
        meter(label, usedPercent: Double(window.usedPercent),
              detail: resetSuffix(absolute: window.resetAt).nilIfEmpty,
              color: ToolKind.claude.color)
    }

    // MARK: - Command Code GOAT (experimental private billing API)

    private var ccCard: some View {
        let cc = ccQuota.state
        return serviceCard(title: "Command Code GOAT", symbol: "c.circle.fill", color: TMDesign.commandCode,
                           isLoading: cc.isLoading, configured: ccConnected,
                           error: cc.error, lastSync: cc.lastSync,
                           refresh: ccConnected ? { ccQuota.refresh() } : nil) {
            if ccConnected {
                if let total = cc.monthlyCreditsTotal, let pct = cc.monthlyUsedPercent {
                    meter("Monthly credits", usedPercent: pct,
                          detail: "\(Format.money(pct / 100 * total)) of \(Format.money(total))"
                              + resetSuffix(absolute: cc.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) }),
                          color: TMDesign.commandCode)
                } else if let remaining = cc.monthlyCreditsRemaining {
                    // Unknown plan or no allowance reported: show the raw
                    // balance rather than fabricating a percentage.
                    liveStat("Credits left", Format.money(remaining))
                }
            }
        }
    }

    // MARK: - DeepSeek

    private var deepseekCard: some View {
        let state = deepseek.state
        let wallets = state.expired ? [] : state.balance?.wallets ?? []
        // Same reading as the popover: funded wallets only, symbol amounts.
        let funded = wallets.filter { $0.total.amount != 0 }
        let shown = funded.isEmpty ? Array(wallets.prefix(1)) : funded
        let balance = shown.isEmpty ? deepseek.balanceText
            : shown.map { $0.total.symbolFormatted }.joined(separator: " · ")
        let unavailable = state.balance?.available == false
        let spend = deepseek.spend(for: .today, configuration: UsagePeriodSettings.shared.configuration)
        let updated = state.balanceUpdated.map { Int64($0.timeIntervalSince1970) } ?? 0
        return serviceCard(title: "DeepSeek", symbol: "d.circle.fill", color: ToolKind.dsh.color,
                           isLoading: state.loadingBalance && updated == 0,
                           configured: deepseekConnected,
                           error: state.expired ? "Sign-in expired" : (state.balanceError ?? state.spendError),
                           lastSync: updated,
                           refresh: { deepseek.refresh(force: true) }) {
            HStack(alignment: .top, spacing: 28) {
                liveStat("Balance", balance, tint: unavailable ? TMDesign.danger : .primary)
                    .help(unavailable ? "Unavailable for API calls" : "")
                if state.kind == .platform {
                    liveStat("Today", spend.map { $0.amounts.isEmpty ? "—"
                        : $0.amounts.map(\.symbolFormatted).joined(separator: " · ") } ?? "—")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                deepseek.loadSpendIfNeeded(for: .today, configuration: UsagePeriodSettings.shared.configuration)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: - 固定订阅（管理在设置页 › Accounts）

    /// Where each fixed subscription stands in its billing cycle. Adding and
    /// editing happen in Settings › Accounts.
    private var subsCard: some View {
        DashCard("Subscriptions") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(app.subscriptions) { sub in
                    HStack(alignment: .top, spacing: 12) {
                        DashGlyph(symbol: SubscriptionSettingsSection.planIcon(sub.plan),
                                  color: SubscriptionSettingsSection.planColor(sub.plan), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                                .font(TMType.medium(TMType.body))
                            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                                Text("Day \(info.dayOfCycle) of \(info.totalDays) · renews \(SubscriptionMath.dateStr(info.end))")
                                    .font(TMType.regular(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(TMDesign.quiet)
                                if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                    let line = ForecastText.line(for: fc, plan: sub.plan)
                                    Text(line.text)
                                        .font(TMType.regular(TMType.caption))
                                        .tmMonospacedDigit()
                                        .foregroundStyle(ForecastText.color(line.status))
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        Text("\(Format.money(sub.price))/\(sub.cycle == "yearly" ? "yr" : "mo")")
                            .font(TMType.semibold(TMType.body))
                            .tmMonospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - 容器与通用行

    /// One account: glyph and name, its freshness at the trailing end, then
    /// the account's own content.
    private func serviceCard<Content: View>(
        title: String, symbol: String, color: Color,
        isLoading: Bool, configured: Bool, error: String?, lastSync: Int64,
        refresh: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    DashGlyph(symbol: symbol, color: color)
                    Text(title).font(TMType.semibold(15))
                    Spacer(minLength: 8)
                    freshness(isLoading: isLoading, configured: configured,
                              error: error, lastSync: lastSync)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let refresh {
                        Button(action: refresh) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoading)
                        .help("Refresh \(title)")
                        .accessibilityLabel("Refresh \(title)")
                    }
                }
                // Straight into the card's stack: an account with nothing to
                // show (e.g. an error) adds no gap under its header.
                content()
            }
        }
    }

    /// Trailing status: nothing for a healthy account beyond when it last
    /// updated; a colored pill only for states that need attention.
    @ViewBuilder
    private func freshness(isLoading: Bool, configured: Bool, error: String?, lastSync: Int64) -> some View {
        let stale = lastSync > 0 && Date().timeIntervalSince1970 - TimeInterval(lastSync) > 120
        if !configured {
            Text("Not configured")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
        } else if let error {
            // The reason itself, in red, instead of an "Error" pill plus a
            // second line repeating it.
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.danger)
                .help(error)
        } else if isLoading && lastSync <= 0 {
            Text("Loading")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
        } else if lastSync <= 0 {
            TMStatusPill(text: "Idle", color: TMDesign.quiet, symbol: "circle.dashed")
        } else if stale {
            TMStatusPill(text: "Stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
        } else {
            let age = Int64(Date().timeIntervalSince1970) - lastSync
            Text(age < 60 ? "Just now" : "\(Format.remaining(age)) ago")
                .font(TMType.regular(TMType.caption))
                .tmMonospacedDigit()
                .foregroundStyle(TMDesign.quiet)
                .help("Updated \(Format.dateTime(lastSync))")
        }
    }

    /// " · resets in 4.8d" for an absolute unix-seconds reset; empty once
    /// passed or unknown.
    private func resetSuffix(absolute: Int64?) -> String {
        guard let absolute else { return "" }
        let remaining = absolute - Int64(Date().timeIntervalSince1970)
        return remaining > 0 ? " · resets in \(Format.remaining(remaining))" : ""
    }

    /// A quota meter. The bar always encodes usage; the used/remaining
    /// preference from the popover changes only the number beside it.
    private func meter(_ title: String, usedPercent: Double, detail: String?,
                       color: Color, marker: Double? = nil) -> some View {
        let p = min(max(usedPercent, 0), 100)
        let shown = Int((showsRemaining ? 100 - p : p).rounded())
        return QuotaMeter(title: title,
                          detail: detail.map { $0.hasPrefix(" · ") ? String($0.dropFirst(3)) : $0 },
                          valueText: "\(shown)%",
                          unitText: showsRemaining ? "left" : "used",
                          usedPercent: p, tint: color, marker: marker)
    }

    private func windowMeter(_ label: String, pct: Double?, reset: Int64?) -> some View {
        let absolute = reset.flatMap { goClient.state.lastSync > 0 ? goClient.state.lastSync + $0 : nil }
        return Group {
            if let pct {
                meter(label, usedPercent: pct, detail: resetSuffix(absolute: absolute).nilIfEmpty,
                      color: ToolKind.opencode.color)
            }
        }
    }

    private func liveStat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(TMType.semibold(20))
                .tmMonospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - History charts

    /// A history chart, shown only once there are enough samples to draw a
    /// line; until then the card simply has no chart.
    @ViewBuilder
    private func historyBlock<C: View>(title: String, current: String?, hasData: Bool,
                                       @ViewBuilder chart: () -> C) -> some View {
        if hasData {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                chart().frame(height: 110)
            }
        }
    }

    private func historyDateAxis(count: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: max(count / 6, 1))) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.12))
            AxisValueLabel(format: Date.FormatStyle().month(.abbreviated).day()
                .locale(Locale(identifier: "en_US")))
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
        }
    }

    private func historyValueAxis<L: View>(@ViewBuilder label: @escaping (Double) -> L) -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.12))
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    label(v)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
