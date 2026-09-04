import SwiftUI
import Charts

/// 计划与余额: one card per service — quota, balance, credentials and history
/// in the same place. Fixed subscriptions are a read-only summary here;
/// add/edit lives in 设置.
struct PlansView: View {
    private enum CredentialTarget: Equatable {
        case openCodeGo
        case openRouter
        case commandCode
    }

    @EnvironmentObject var app: AppState
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @State private var goSnapshots: [Database.OGSnapshot] = []
    @State private var orSnapshots: [Database.ORSnapshot] = []
    @State private var showGoForm = false
    @State private var showORForm = false
    @State private var showCCForm = false
    @State private var goWS = ""
    @State private var goCookie = ""
    @State private var orKey = ""
    @State private var orAppend = false
    @State private var ccCookie = ""
    @State private var pendingCredentialClear: CredentialTarget?
    /// Each credential form shows only its own message/color — saving Go
    /// must never flash a message inside the OpenRouter form (and vice versa).
    @State private var goFormMessage: String?
    @State private var goFormFailed = false
    @State private var orFormMessage: String?
    @State private var orFormFailed = false
    @State private var ccFormMessage: String?
    @State private var ccFormFailed = false
    /// Last observed state markers; onReceive only reloads history when the
    /// client actually produced a new result (isLoading flips are ignored).
    @State private var goLastSeen: (lastOK: Int64, lastSync: Int64)?
    @State private var orLastSeen: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle("Plans & Balance")
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                claudeCard
                goCard
                orCard
                ccCard
                subsCard
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
        .onChange(of: showGoForm) { open in
            if open {
                goFormMessage = nil
            } else {
                goWS = ""
                goCookie = ""
            }
        }
        .onChange(of: showORForm) { open in
            if open {
                orFormMessage = nil
            } else {
                orKey = ""
                orAppend = false
            }
        }
        .onChange(of: showCCForm) { open in
            if open {
                ccFormMessage = nil
            } else {
                ccCookie = ""
            }
        }
        .sheet(isPresented: $showGoForm) {
            goCredentialSheet
        }
        .sheet(isPresented: $showORForm) {
            openRouterCredentialSheet
        }
        .sheet(isPresented: $showCCForm) {
            ccCredentialSheet
        }
        .confirmationDialog("Clear saved credentials?", isPresented: Binding(
            get: { pendingCredentialClear != nil },
            set: { if !$0 { pendingCredentialClear = nil } })) {
                Button("Cancel", role: .cancel) { pendingCredentialClear = nil }
                Button("Clear Credentials", role: .destructive) { clearPendingCredentials() }
            } message: {
                Text(pendingCredentialClearMessage)
            }
    }

    private var pendingCredentialClearMessage: String {
        switch pendingCredentialClear {
        case .openCodeGo:
            return "ToastMonitor will stop showing OpenCode Go quota data until credentials are configured again."
        case .commandCode:
            return "ToastMonitor will remove the saved Command Code GOAT session from Keychain and stop showing its quota."
        case .openRouter, nil:
            return "ToastMonitor will remove the saved OpenRouter key from Keychain and stop showing its balance."
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
        return serviceCard(title: "OpenCode Go", icon: "g.circle.fill", color: TMDesign.accent) {
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

                // Credentials live here — provisioning and quota are one task.
                credentialsRow(
                    configured: goClient.configured,
                    summary: goClient.configured ? "Configured workspace" : "Not configured — quota unavailable",
                    actionTitle: goClient.configured ? "Change credentials" : "Configure",
                    action: { showGoForm = true },
                    clearAction: {
                        pendingCredentialClear = .openCodeGo
                    }
                )
                // Form feedback stays visible after the form closes, so a
                // successful save/clear is never silently swallowed.
                if let goFormMessage {
                    Text(goFormMessage)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(goFormFailed ? TMDesign.danger : TMDesign.accent)
                }

                if goClient.configured {
                    if let pct = go.monthlyPct {
                        quotaBar(
                            title: "Monthly quota",
                            usedPct: pct,
                            resetAt: go.monthlyReset.map { go.lastSync + $0 },
                            limit: OpenCodeGoClient.monthlyLimitUSD,
                            color: TMDesign.accent,
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
        return serviceCard(title: "OpenRouter", icon: ToolKind.openrouter.symbol, color: TMDesign.accent) {
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

                credentialsRow(
                    configured: orClient.hasKey,
                    summary: orClient.hasKey ? "\(or.keyCount) key\(or.keyCount == 1 ? "" : "s") (Keychain)" : "Not configured — quota unavailable",
                    actionTitle: orClient.hasKey ? "Change / Add" : "Configure",
                    action: { showORForm = true },
                    clearAction: {
                        pendingCredentialClear = .openRouter
                    }
                )
                if let orFormMessage {
                    Text(orFormMessage)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(orFormFailed ? TMDesign.danger : TMDesign.accent)
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
                            color: TMDesign.accent,
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
                Text("Reads Claude Code's rate-limit percentages from an undocumented "
                     + "Anthropic endpoint, using your existing Claude Code login. This is "
                     + "not an officially supported integration — Anthropic's Consumer Terms "
                     + "restrict OAuth tokens from Free/Pro/Max plans to Claude Code and "
                     + "claude.ai. Off by default; enable at your own risk.")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable Claude quota monitoring", isOn: Binding(
                    get: { claudeQuota.enabled },
                    set: { claudeQuota.setEnabled($0) }
                ))

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
                .foregroundStyle(remaining < 5 ? TMDesign.danger : (remaining < 20 ? TMDesign.accent : TMDesign.quiet))
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
        return serviceCard(title: "Command Code GOAT", icon: "c.circle.fill", color: TMDesign.accent) {
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

                credentialsRow(
                    configured: cc.configured,
                    summary: cc.configured ? (cc.planName ?? "Session configured") : "Not configured — quota unavailable",
                    actionTitle: cc.configured ? "Update Session…" : "Configure",
                    action: { showCCForm = true },
                    clearAction: {
                        pendingCredentialClear = .commandCode
                    }
                )
                if let ccFormMessage {
                    Text(ccFormMessage)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(ccFormFailed ? TMDesign.danger : TMDesign.accent)
                }

                if cc.configured {
                    if let total = cc.monthlyCreditsTotal, let pct = cc.monthlyUsedPercent {
                        quotaBar(
                            title: "Monthly credits",
                            usedPct: pct,
                            resetAt: cc.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) },
                            limit: total,
                            color: TMDesign.accent,
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

    private var ccCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Command Code GOAT Session")
                .font(.title2.weight(.semibold))
            Text("Paste the Cookie header from your logged-in commandcode.ai browser "
                 + "session (or just the session token). Stored only in the macOS "
                 + "Keychain; experimental private API.")
                .font(TMType.regular(TMType.body))
                .foregroundStyle(.secondary)
            Form {
                SecureField("Cookie header or session token", text: $ccCookie,
                            prompt: Text("__Secure-commandcode_prod_.session_token=…"))
                    .font(.system(size: TMType.body, design: .monospaced))
            }
            .formStyle(.grouped)
            if let ccFormMessage, ccFormFailed {
                Text(ccFormMessage)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCCForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveCommandCodeCredentials() }
                    .buttonStyle(.borderedProminent)
                    .tint(TMDesign.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ccCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func saveCommandCodeCredentials() {
        let raw = ccCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if ccQuota.provision(cookie: raw) {
            ccQuota.refresh()
            showCCForm = false
            ccFormMessage = "Command Code GOAT session saved"
            ccFormFailed = false
        } else {
            ccFormMessage = ccQuota.state.error ?? "Save failed (Keychain unavailable)"
            ccFormFailed = true
        }
    }

    // MARK: - 固定订阅（管理在计划页内嵌表单；设置页同组件）

    private var subsCard: some View {
        SubscriptionSettingsSection()
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

    private func credentialsRow(configured: Bool, summary: String, actionTitle: String,
                                action: @escaping () -> Void,
                                clearAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
                Image(systemName: configured ? "key.fill" : "key.slash")
                    .font(TMType.regular(11))
                    .foregroundStyle(configured ? TMDesign.accent : TMDesign.quiet)
                Text(summary)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(configured ? TMDesign.quiet : .secondary)
                Spacer()
                if configured {
                    Button(actionTitle, action: action)
                        .font(TMType.regular(TMType.caption))
                        .buttonStyle(.bordered)
                } else {
                    Button(actionTitle, action: action)
                        .font(TMType.regular(TMType.caption))
                        .buttonStyle(.borderedProminent)
                        .tint(TMDesign.accent)
                }
                if configured, let clearAction {
                    Button("Clear", action: clearAction)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger)
                }
            }
    }

    private var goCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenCode Go Credentials")
                .font(.title2.weight(.semibold))
            Text("These values are stored in your macOS Keychain and used only to query quota information.")
                .font(TMType.regular(TMType.body))
                .foregroundStyle(.secondary)
            Form {
                TextField("Workspace ID", text: $goWS, prompt: Text("wrk_..."))
                    .font(.system(size: TMType.body, design: .monospaced))
                SecureField("Authentication cookie", text: $goCookie, prompt: Text("Fe26.2**..."))
                    .font(.system(size: TMType.body, design: .monospaced))
            }
            .formStyle(.grouped)
            if let goFormMessage, goFormFailed {
                Text(goFormMessage)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { showGoForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save & Query") { saveGoCredentials() }
                    .buttonStyle(.borderedProminent)
                    .tint(TMDesign.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(goWS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || goCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var openRouterCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenRouter Credentials")
                .font(.title2.weight(.semibold))
            Text("The API key is stored in your macOS Keychain and is never displayed after saving.")
                .font(TMType.regular(TMType.body))
                .foregroundStyle(.secondary)
            Form {
                SecureField("API key", text: $orKey, prompt: Text("sk-or-..."))
                    .font(.system(size: TMType.body, design: .monospaced))
                if orClient.hasKey {
                    Toggle("Add this key without replacing existing keys", isOn: $orAppend)
                }
            }
            .formStyle(.grouped)
            if let orFormMessage, orFormFailed {
                Text(orFormMessage)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { showORForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveOpenRouterCredentials() }
                    .buttonStyle(.borderedProminent)
                    .tint(TMDesign.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(orKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func saveGoCredentials() {
        let ws = goWS.trimmingCharacters(in: .whitespacesAndNewlines)
        let ck = goCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws.isEmpty, !ck.isEmpty else { return }
        if goClient.provision(workspaceId: ws, cookie: ck) {
            goClient.refresh()
            showGoForm = false
            goFormMessage = "OpenCode Go credentials saved"
            goFormFailed = false
        } else {
            goFormMessage = goClient.state.error ?? "Save failed (Keychain unavailable)"
            goFormFailed = true
        }
    }

    private func saveOpenRouterCredentials() {
        let key = orKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = orAppend ? orClient.addKey(key) : orClient.setKey(key)
        if ok {
            showORForm = false
            orFormMessage = "OpenRouter key saved"
            orFormFailed = false
        } else {
            orFormMessage = orClient.state.error ?? "Save failed (Keychain unavailable)"
            orFormFailed = true
        }
    }

    private func clearPendingCredentials() {
        switch pendingCredentialClear {
        case .openCodeGo:
            goClient.clear()
            goWS = ""
            goCookie = ""
            goFormMessage = "OpenCode Go credentials cleared"
            goFormFailed = false
        case .openRouter:
            _ = orClient.setKey(nil)
            orKey = ""
            orAppend = false
            orFormMessage = "OpenRouter key cleared"
            orFormFailed = false
        case .commandCode:
            ccQuota.clear()
            ccCookie = ""
            ccFormMessage = "Command Code GOAT session cleared"
            ccFormFailed = false
        case .none:
            break
        }
        pendingCredentialClear = nil
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
                    .foregroundStyle(p > 95 ? TMDesign.danger : (p > 80 ? TMDesign.accent : TMDesign.quiet))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(p > 95 ? TMDesign.danger : (p > 80 ? TMDesign.accent : color))
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
                    .foregroundStyle(pct > 95 ? TMDesign.danger : (pct > 80 ? TMDesign.accent : TMDesign.quiet))
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
