import Combine
import SwiftUI

/// Plans: quotas on the left, prepaid balances and fixed subscriptions on the right.
/// Matches Overview's zero-outer-scroll layout: the page fits the window, and the
/// Quotas list scrolls internally only when many accounts are connected.
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dashboardActiveTab) private var activeTab
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var grokQuota = GrokQuotaClient.shared
    @ObservedObject private var antigravity = AntigravityQuotaClient.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false
    @AppStorage(CodexPlanName.customNameKey) private var codexCustomName = ""
    @State private var now = Date()

    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum QuotaMode: String, CaseIterable, Identifiable {
        case used = "Used"
        case remaining = "Remaining"
        var id: String { rawValue }
    }

    private enum QuotaID: String, Identifiable {
        case claude, codex, antigravity, grok, commandCode, openCodeGo
        var id: String { rawValue }
    }

    private var claudeConnected: Bool { AccountConnection.claude }
    private var codexConnected: Bool { AccountConnection.codex(subscriptions: app.subscriptions) }
    private var goConnected: Bool { AccountConnection.openCodeGo }
    private var orConnected: Bool { AccountConnection.openRouter }
    private var deepseekConnected: Bool { AccountConnection.deepSeek }
    private var ccConnected: Bool { AccountConnection.commandCode }
    private var grokConnected: Bool { AccountConnection.grok }
    private var antigravityConnected: Bool { AccountConnection.antigravity }

    private var isTabActive: Bool {
        activeTab == nil || activeTab == .plans
    }

    private var quotaModeBinding: Binding<QuotaMode> {
        Binding(
            get: { showsRemaining ? .remaining : .used },
            set: { showsRemaining = ($0 == .remaining) }
        )
    }

    private var connectedQuotaIDs: [QuotaID] {
        var ids: [QuotaID] = []
        if claudeConnected { ids.append(.claude) }
        if codexConnected { ids.append(.codex) }
        if antigravityConnected { ids.append(.antigravity) }
        if grokConnected { ids.append(.grok) }
        if ccConnected { ids.append(.commandCode) }
        if goConnected { ids.append(.openCodeGo) }
        return ids
    }

    private var unconnected: [String] {
        [(claudeConnected, "Claude"),
         (codexConnected, "Codex"),
         (goConnected, "OpenCode Go"),
         (ccConnected, "Command Code"),
         (grokConnected, "Grok"),
         (antigravityConnected, "Antigravity"),
         (orConnected, "OpenRouter"),
         (deepseekConnected, "DeepSeek")]
            .filter { !$0.0 }.map(\.1)
    }

    private var activeSubscriptions: [Database.Subscription] {
        app.subscriptions.filter {
            SubscriptionMath.cycleInfo(start: $0.startDate, end: $0.endDate, cycle: $0.cycle, now: now) != nil
        }
    }

    private var hasRightColumn: Bool {
        orConnected || deepseekConnected || !activeSubscriptions.isEmpty || !unconnected.isEmpty
    }

    private var attentionCount: Int {
        var count = 0
        if claudeConnected, claudeQuota.state.error != nil { count += 1 }
        if codexConnected, codexQuota.state.error != nil { count += 1 }
        if goConnected, goClient.state.error != nil { count += 1 }
        if ccConnected, ccQuota.state.error != nil { count += 1 }
        if grokConnected, grokQuota.state.error != nil { count += 1 }
        if antigravityConnected,
           antigravity.state.error != nil,
           !(antigravity.state.lastSync > 0 && antigravity.state.error == AntigravityQuotaClient.notRunning) {
            count += 1
        }
        if orConnected, orClient.state.authInvalid || orClient.state.error != nil { count += 1 }
        if deepseekConnected, deepseek.state.expired || deepseek.state.balanceError != nil || deepseek.state.spendError != nil {
            count += 1
        }
        return count
    }

    var body: some View {
        DashPage {
            topBar
            GeometryReader { geo in
                let hasQuotas = !connectedQuotaIDs.isEmpty
                let hasRight = hasRightColumn
                HStack(alignment: .top, spacing: DashLayout.gap) {
                    if hasQuotas {
                        quotasCard
                            .frame(width: hasRight ? max(0, floor((geo.size.width - DashLayout.gap) * 0.57)) : max(0, geo.size.width))
                            .frame(maxHeight: .infinity)
                    }
                    if hasRight {
                        rightColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(minuteTicker) { tick in
            guard isTabActive else { return }
            now = tick
        }
        .onChange(of: activeTab) { _ in
            if isTabActive {
                now = Date()
                deepseek.loadSpendIfNeeded(for: .today, configuration: UsagePeriodSettings.shared.configuration)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.dashboardVisibility)) { note in
            guard (note.object as? Bool) == true, isTabActive else { return }
            deepseek.loadSpendIfNeeded(for: .today, configuration: UsagePeriodSettings.shared.configuration)
        }
        .task {
            while !Task.isCancelled {
                if isTabActive {
                    deepseek.loadSpendIfNeeded(for: .today, configuration: UsagePeriodSettings.shared.configuration)
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            DashSegmented(selection: quotaModeBinding,
                          options: QuotaMode.allCases,
                          title: { $0.rawValue },
                          accessibilityName: "Quota display mode")
            Spacer(minLength: 8)
            if attentionCount > 0 {
                Button {
                    openAccountSettings()
                } label: {
                    TMStatusPill(
                        text: "\(attentionCount) account\(attentionCount == 1 ? "" : "s") need attention",
                        color: TMDesign.danger,
                        symbol: "exclamationmark.triangle.fill"
                    )
                }
                .buttonStyle(.plain)
                .help("Open Accounts settings")
            } else {
                Button("Account Settings…") {
                    openAccountSettings()
                }
                .tmGlassButton(circle: false, extraLarge: true)
            }
        }
    }

    private func openAccountSettings(expandAccount: String? = nil) {
        SettingsWindowController.shared.show(pane: .accounts, expandAccount: expandAccount)
    }

    // MARK: - Left Column: Quotas

    private var quotasCard: some View {
        DashCard("Quotas", inset: DashLayout.cardPadding) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(connectedQuotaIDs.enumerated()), id: \.element) { index, id in
                        if index > 0 {
                            Divider()
                                .opacity(0.45)
                                .padding(.vertical, 12)
                        }
                        quotaRow(for: id)
                    }
                }
                .padding(.trailing, 2)
                .overlayScrollers()
            }
        }
    }

    @ViewBuilder
    private func quotaRow(for id: QuotaID) -> some View {
        switch id {
        case .claude: claudeRow
        case .codex: codexRow
        case .antigravity: antigravityRow
        case .grok: grokRow
        case .commandCode: ccRow
        case .openCodeGo: goRow
        }
    }

    private var claudeRow: some View {
        let cq = claudeQuota.state
        let planLabel: String? = {
            let p = cq.planType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !p.isEmpty else { return nil }
            return p.prefix(1).uppercased() + p.dropFirst()
        }()
        let windows = [
            cq.fiveHour.map { makeWindow(label: "5h", usedPercent: Double($0.usedPercent), resetAt: $0.resetAt, duration: 5 * 3600) },
            cq.sevenDay.map { makeWindow(label: "Weekly", usedPercent: Double($0.usedPercent), resetAt: $0.resetAt, duration: 7 * 86400) },
            cq.sevenDayOpus.map { makeWindow(label: "Opus", usedPercent: Double($0.usedPercent), resetAt: $0.resetAt, duration: 7 * 86400) },
        ].compactMap { $0 }

        return PlanQuotaRow(
            title: "Claude",
            planName: planLabel,
            symbol: ToolKind.claude.symbol,
            color: ToolKind.claude.color,
            accountKey: "claude",
            isLoading: cq.lastSync <= 0 && cq.error == nil && cq.configured,
            error: cq.error,
            lastSync: cq.lastSync,
            now: now,
            windows: windows,
            footnote: nil,
            refresh: { claudeQuota.refresh(force: true) },
            openSettings: { openAccountSettings(expandAccount: "claude") }
        )
    }

    private var codexRow: some View {
        let cx = codexQuota.state
        let sub = SubscriptionMath.activeCodexSubscription(in: app.subscriptions, now: now)
        let customTitle = codexCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = customTitle.isEmpty ? "Codex" : customTitle
        let planLabel = CodexPlanName.tier(apiPlan: cx.planType) ?? sub.flatMap(CodexPlanName.tier(subscription:))
        let windowLabel: String = {
            guard let s = cx.windowSeconds else { return "Limit" }
            if s >= 7 * 86400 { return "Weekly" }
            if s >= 86400 { return "\(s / 86400)d" }
            if s >= 3600 { return "\(s / 3600)h" }
            return "Limit"
        }()
        let windows = [
            cx.primaryPct.map {
                makeWindow(label: windowLabel,
                           usedPercent: Double($0),
                           resetAt: cx.resetAt,
                           duration: cx.windowSeconds.map(Int64.init))
            },
        ].compactMap { $0 }
        let footnote: String? = windows.isEmpty && sub != nil
            ? "Subscribed · \(Format.money(sub!.price))/\(Self.cycleSuffix(sub!.cycle))"
            : nil

        return PlanQuotaRow(
            title: title,
            planName: planLabel,
            symbol: ToolKind.codex.symbol,
            color: ToolKind.codex.color,
            accountKey: "codex",
            isLoading: codexQuota.enabled && cx.lastSync <= 0 && cx.error == nil,
            error: cx.error,
            lastSync: cx.lastSync,
            now: now,
            windows: windows,
            footnote: footnote,
            refresh: codexQuota.enabled ? { codexQuota.refresh(force: true) } : nil,
            openSettings: { openAccountSettings(expandAccount: "codex") }
        )
    }

    private var ccRow: some View {
        let cc = ccQuota.state
        let planLabel = cc.planName.map(CommandCodePlanCatalog.shortName(forPlanID:))
        let resetAt = cc.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) }
        var windows: [QuotaWindow] = []
        var footnote: String?
        if let total = cc.monthlyCreditsTotal, let pct = cc.monthlyUsedPercent {
            windows.append(makeWindow(label: "Monthly", usedPercent: pct, resetAt: resetAt, duration: 30 * 86400))
            let usedUSD = min(max(pct, 0), 100) / 100 * total
            footnote = "Credits used: \(Format.money(usedUSD)) of \(Format.money(total))"
        } else if let remaining = cc.monthlyCreditsRemaining {
            footnote = "Credits left: \(Format.money(remaining))"
        }

        return PlanQuotaRow(
            title: "Command Code",
            planName: planLabel,
            symbol: "c.circle.fill",
            color: TMDesign.commandCode,
            accountKey: "cc",
            isLoading: cc.isLoading && cc.lastSync <= 0,
            error: cc.error,
            lastSync: cc.lastSync,
            now: now,
            windows: windows,
            footnote: footnote,
            refresh: { ccQuota.refresh(force: true) },
            openSettings: { openAccountSettings(expandAccount: "cc") }
        )
    }

    private var grokRow: some View {
        let g = grokQuota.state
        let planLabel = GrokQuotaClient.plan(subscriptions: app.subscriptions, apiPlan: g.planName, now: now)
        let windows = [
            g.usedPercent.map { makeWindow(label: "Weekly", usedPercent: $0, resetAt: g.resetAt, duration: 7 * 86400) },
        ].compactMap { $0 }
        var parts: [String] = []
        if let top = g.products.first {
            parts.append("\(top.displayName): \(Int(top.usedPercent.rounded()))% of pool")
        }
        if let balance = g.prepaidBalanceUSD, balance > 0 {
            parts.append("Extra credits: \(Format.money(balance))")
        }

        return PlanQuotaRow(
            title: "Grok",
            planName: planLabel,
            symbol: "x.circle.fill",
            color: TMDesign.grok,
            accountKey: "grok",
            isLoading: g.isLoading && g.lastSync <= 0,
            error: g.error,
            lastSync: g.lastSync,
            now: now,
            windows: windows,
            footnote: parts.isEmpty ? nil : parts.joined(separator: " · "),
            refresh: { grokQuota.refresh(force: true) },
            openSettings: { openAccountSettings(expandAccount: "grok") }
        )
    }

    private var antigravityRow: some View {
        let a = antigravity.state
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let planLabel = AntigravityQuotaClient.plan(subscriptions: app.subscriptions, apiPlan: a.planName, now: now)
        let windows = a.displayLimits.prefix(3).map { label, model in
            makeWindow(
                label: label,
                usedPercent: 100 - model.remaining,
                resetAt: model.resetAt,
                duration: model.windowSeconds
                    ?? AntigravityQuotaClient.windowSeconds(resetAt: model.resetAt, now: nowSeconds)
            )
        }
        let effectiveError = (a.lastSync > 0 && a.error == AntigravityQuotaClient.notRunning) ? nil : a.error

        return PlanQuotaRow(
            title: "Antigravity",
            planName: planLabel,
            symbol: "a.circle.fill",
            color: TMDesign.antigravity,
            accountKey: "antigravity",
            isLoading: a.isLoading && a.lastSync <= 0,
            error: effectiveError,
            lastSync: a.lastSync,
            now: now,
            windows: windows,
            footnote: nil,
            refresh: { antigravity.refresh(force: true) },
            openSettings: { openAccountSettings(expandAccount: "antigravity") }
        )
    }

    private var goRow: some View {
        let go = goClient.state
        let limit = OpenCodeGoClient.monthlyLimitUSD
        let absolute: (Int64?) -> Int64? = { reset in
            reset.flatMap { go.lastSync > 0 ? go.lastSync + $0 : nil }
        }
        let windows = [
            go.monthlyPct.map { makeWindow(label: "Monthly", usedPercent: $0, resetAt: absolute(go.monthlyReset), duration: 30 * 86400) },
            go.weeklyPct.map { makeWindow(label: "Weekly", usedPercent: $0, resetAt: absolute(go.weeklyReset), duration: 7 * 86400) },
            go.rollingPct.map { makeWindow(label: "5h", usedPercent: $0, resetAt: absolute(go.rollingReset), duration: 5 * 3600) },
        ].compactMap { $0 }
        let footnote = go.monthlyPct.map { pct in
            "\(Format.money(min(max(pct, 0), 100) / 100 * limit)) of \(Format.money(limit)) monthly limit"
        }

        return PlanQuotaRow(
            title: "OpenCode Go",
            planName: nil,
            symbol: "g.circle.fill",
            color: ToolKind.opencode.color,
            accountKey: "go",
            isLoading: go.isLoading && go.lastOK <= 0,
            error: go.error,
            lastSync: go.lastOK,
            now: now,
            windows: windows,
            footnote: footnote,
            refresh: goClient.configured ? { goClient.refresh(force: true) } : nil,
            openSettings: { openAccountSettings(expandAccount: "go") }
        )
    }

    private func makeWindow(label: String, usedPercent: Double, resetAt: Int64?, duration: Int64?) -> QuotaWindow {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let clamped = min(max(usedPercent, 0), 100)
        let resetIn = resetAt.flatMap { $0 > nowSeconds ? Format.remaining($0 - nowSeconds) : nil }
        let elapsed: Double? = {
            guard let resetAt, let duration, duration > 0, resetAt > nowSeconds else { return nil }
            return min(max(1 - Double(resetAt - nowSeconds) / Double(duration), 0), 1)
        }()
        return QuotaWindow(label: label, usedPercent: clamped, resetIn: resetIn, elapsed: elapsed)
    }

    // MARK: - Right Column: Balances, Subscriptions, Not connected

    private var rightColumn: some View {
        let subs = activeSubscriptions
        return VStack(alignment: .leading, spacing: DashLayout.gap) {
            if orConnected || deepseekConnected {
                balancesCard
                    .dashFixedHeight()
            }
            if !subs.isEmpty {
                subscriptionsCard(subs)
                    .dashFixedHeight()
            }
            if !unconnected.isEmpty {
                unconnectedCard
                    .dashFixedHeight()
            }
            Spacer(minLength: 0)
        }
    }

    private var balancesCard: some View {
        DashCard("Balances", inset: DashLayout.cardPadding) {
            VStack(alignment: .leading, spacing: 12) {
                if orConnected {
                    openRouterRow
                }
                if orConnected && deepseekConnected {
                    Divider().opacity(0.45)
                }
                if deepseekConnected {
                    deepseekRow
                }
            }
        }
    }

    private var openRouterRow: some View {
        let or = orClient.state
        let periods = UsagePeriodConfiguration(mode: .calendar)
        let todayStart = periods.range(for: .today, now: now).start
        let monthStart = periods.range(for: .month, now: now).start
        let hasCredits = or.creditsUsage != nil
        let todaySpend = hasCredits ? app.openRouterSpend(since: todayStart, current: or.creditsUsage) : 0
        let monthSpend = hasCredits ? app.openRouterSpend(since: monthStart, current: or.creditsUsage) : 0
        let err = or.authInvalid ? "API key rejected (401/403)" : or.error

        return PlanBalanceRow(
            title: "OpenRouter",
            symbol: ToolKind.openrouter.symbol,
            color: ToolKind.openrouter.color,
            accountKey: "router",
            isLoading: or.isLoading && or.lastOK <= 0,
            error: err,
            lastSync: or.lastOK,
            now: now,
            balanceText: or.lastOK > 0 ? (or.accountBalance.map(Format.money) ?? "—") : nil,
            balanceTint: .primary,
            secondaryStats: or.lastOK > 0 ? [
                ("Today", hasCredits ? Format.money(todaySpend) : "—"),
                ("Month", hasCredits ? Format.money(monthSpend) : "—"),
            ] : [],
            keyQuota: (or.lastOK > 0 && or.limitRemaining != nil && (or.limit ?? 0) > 0)
                ? (remaining: or.limitRemaining!, limit: or.limit!) : nil,
            showsRemaining: showsRemaining,
            refresh: { orClient.refresh(force: true) },
            openSettings: { openAccountSettings(expandAccount: "router") }
        )
    }

    private var deepseekRow: some View {
        let state = deepseek.state
        let wallets = state.expired ? [] : (state.balance?.wallets ?? [])
        let funded = wallets.filter { $0.total.amount != 0 }
        let shown = funded.isEmpty ? Array(wallets.prefix(1)) : funded
        let unavailable = state.balance?.available == false
        let spend = deepseek.spend(for: .today, configuration: UsagePeriodSettings.shared.configuration, now: now)
        let updated = state.balanceUpdated.map { Int64($0.timeIntervalSince1970) } ?? 0
        let err = state.expired ? "Sign-in expired" : (state.balanceError ?? state.spendError)

        let balanceText: String? = shown.isEmpty ? nil : shown.map { $0.total.symbolFormatted }.joined(separator: " · ")
        var secondary: [(String, String)] = []
        if state.kind == .platform {
            let todayStr = spend.map {
                $0.amounts.isEmpty ? "—" : $0.amounts.map(\.symbolFormatted).joined(separator: " · ")
            } ?? "—"
            secondary.append(("Today", todayStr))
        }

        return PlanBalanceRow(
            title: "DeepSeek",
            symbol: "d.circle.fill",
            color: ToolKind.dsh.color,
            accountKey: "deepseek",
            isLoading: state.loadingBalance && updated == 0,
            error: err,
            lastSync: updated,
            now: now,
            balanceText: balanceText,
            balanceTint: unavailable ? TMDesign.danger : .primary,
            secondaryStats: secondary,
            keyQuota: nil,
            showsRemaining: showsRemaining,
            warningNote: unavailable ? "Unavailable for API calls" : nil,
            refresh: { deepseek.refresh(force: true, bypassBackoff: true) },
            openSettings: { openAccountSettings(expandAccount: "deepseek") }
        )
    }

    private func subscriptionsCard(_ subs: [Database.Subscription]) -> some View {
        let monthlyTotal = subs.reduce(0.0) { total, sub in
            switch sub.cycle {
            case "yearly": return total + sub.price / 12
            case "weekly": return total + sub.price * 52 / 12
            default: return total + sub.price
            }
        }
        return DashCard("Subscriptions", inset: DashLayout.cardPadding, trailing: {
            HStack(spacing: 8) {
                if monthlyTotal > 0 {
                    Text("\(Format.money(monthlyTotal))/mo")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
                Button("Manage") { openAccountSettings() }
                    .buttonStyle(.borderless)
                    .font(TMType.medium(TMType.caption))
                    .foregroundStyle(TMDesign.accent)
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(subs.enumerated()), id: \.element.id) { index, sub in
                    if index > 0 { Divider().opacity(0.45) }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: SubscriptionSettingsSection.planIcon(sub.plan))
                            .font(.system(size: 12))
                            .foregroundStyle(SubscriptionSettingsSection.planColor(sub.plan))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(sub.name)
                            .font(TMType.medium(TMType.body))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle, now: now) {
                            ViewThatFits(in: .horizontal) {
                                Text("renews \(Self.shortDate(info.end))")
                                Text(Self.shortDate(info.end))
                                Color.clear.frame(width: 0, height: 0)
                            }
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.quiet)
                            .lineLimit(1)
                        }
                        Text("\(Format.money(sub.price))/\(Self.cycleSuffix(sub.cycle))")
                            .font(TMType.semibold(TMType.body))
                            .tmMonospacedDigit()
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var unconnectedCard: some View {
        DashCard(inset: 14) {
            HStack(alignment: .center, spacing: 10) {
                DashGlyph(symbol: "plus", color: TMDesign.quiet, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Not connected")
                        .font(TMType.medium(TMType.caption))
                    Text(unconnected.joined(separator: " · "))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Set Up…") { openAccountSettings() }
                    .tmGlassButton(circle: false)
                    .controlSize(.small)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()

    private static func shortDate(_ date: Date) -> String { dateFormatter.string(from: date) }

    private static func cycleSuffix(_ cycle: String) -> String {
        switch cycle {
        case "yearly": return "yr"
        case "weekly": return "wk"
        default: return "mo"
        }
    }
}

// MARK: - Quota Row

private struct PlanQuotaRow: View {
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false
    @State private var hovering = false

    let title: String
    let planName: String?
    let symbol: String
    let color: Color
    let accountKey: String
    let isLoading: Bool
    let error: String?
    let lastSync: Int64
    let now: Date
    let windows: [QuotaWindow]
    let footnote: String?
    let refresh: (() -> Void)?
    let openSettings: () -> Void

    private var failedEmpty: Bool { error != nil && lastSync <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failedEmpty, let error {
                compactErrorRow(error)
            } else {
                header
                if let error {
                    let problem = RowProblem.from(service: title, error: error, accountKey: accountKey)
                    Text(conciseErrorTitle(problem.title))
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger)
                        .lineLimit(1)
                        .help(problem.detail)
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            windowRow(window)
                        }
                        if let footnote {
                            Text(footnote)
                                .font(TMType.regular(TMType.caption))
                                .tmMonospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func compactErrorRow(_ error: String) -> some View {
        let problem = RowProblem.from(service: title, error: error, accountKey: accountKey)
        return HStack(alignment: .center, spacing: 10) {
            DashGlyph(symbol: symbol, color: color, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TMType.semibold(14))
                    .lineLimit(1)
                Label(conciseErrorTitle(problem.title), systemImage: "exclamationmark.triangle.fill")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
                    .lineLimit(1)
                    .help(problem.detail)
            }
            Spacer(minLength: 8)
            Button("Open Settings…", action: openSettings)
                .tmGlassButton(circle: false)
                .controlSize(.small)
            if let refresh {
                Button(action: refresh) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Retry \(title)")
                .accessibilityLabel("Retry \(title)")
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DashGlyph(symbol: symbol, color: color, size: 22)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            Text(title)
                .font(TMType.semibold(14))
                .lineLimit(1)
            if let planName, !planName.isEmpty {
                Text("·  \(planName)")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if hovering, let refresh {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Refresh \(title)")
                .accessibilityLabel("Refresh \(title)")
            } else {
                freshnessView
            }
        }
    }

    @ViewBuilder
    private var freshnessView: some View {
        let age = Int64(now.timeIntervalSince1970) - lastSync
        if lastSync <= 0 {
            Text("Idle")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
        } else if age > 120 {
            Text("\(Format.remaining(age)) ago")
                .font(TMType.regular(TMType.caption))
                .tmMonospacedDigit()
                .foregroundStyle(TMDesign.accent)
        } else {
            Text(age < 60 ? "Just now" : "\(Format.remaining(age)) ago")
                .font(TMType.regular(TMType.caption))
                .tmMonospacedDigit()
                .foregroundStyle(TMDesign.quiet)
        }
    }

    private func conciseErrorTitle(_ raw: String) -> String {
        let prefix = "\(title) "
        guard raw.hasPrefix(prefix) else { return raw }
        let stripped = String(raw.dropFirst(prefix.count))
        guard let first = stripped.first else { return raw }
        return first.uppercased() + stripped.dropFirst()
    }

    private func windowRow(_ window: QuotaWindow) -> some View {
        let shown = QuotaWindow.shownPercent(used: window.usedPercent, showsRemaining: showsRemaining)
        let tint = DashUsageBar.semanticTint(usedPercent: window.usedPercent, base: color)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.label)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(width: 62, alignment: .leading)
                    .lineLimit(1)
                if let resetIn = window.resetIn {
                    Text("resets in \(resetIn)")
                        .font(TMType.regular(TMType.caption))
                        .tmMonospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(Int(shown.rounded()))% \(showsRemaining ? "left" : "used")")
                    .font(TMType.semibold(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            DashUsageBar(
                fillPercent: shown,
                tint: tint,
                height: 5,
                elapsed: window.barElapsed(showsRemaining: showsRemaining)
            )
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Balance Row

private struct PlanBalanceRow: View {
    @State private var hovering = false

    let title: String
    let symbol: String
    let color: Color
    let accountKey: String
    let isLoading: Bool
    let error: String?
    let lastSync: Int64
    let now: Date
    let balanceText: String?
    let balanceTint: Color
    let secondaryStats: [(label: String, value: String)]
    let keyQuota: (remaining: Double, limit: Double)?
    let showsRemaining: Bool
    var warningNote: String? = nil
    let refresh: () -> Void
    let openSettings: () -> Void

    private var failedEmpty: Bool { error != nil && lastSync <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashGlyph(symbol: symbol, color: color, size: 22)
                Text(title)
                    .font(TMType.semibold(14))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    if lastSync > 0 {
                        let age = max(0, Int64(now.timeIntervalSince1970) - lastSync)
                        Text(age < 60 ? "Just now" : "\(Format.remaining(age)) ago")
                            .font(TMType.regular(TMType.caption))
                            .tmMonospacedDigit()
                            .foregroundStyle(age > 120 ? TMDesign.accent : TMDesign.quiet)
                    }
                    if hovering || error != nil {
                        Button(action: refresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh \(title)")
                        .accessibilityLabel("Refresh \(title)")
                    }
                }
            }

            if (failedEmpty || (error != nil && balanceText == nil)), let error {
                let problem = RowProblem.from(service: title, error: error, accountKey: accountKey)
                HStack(spacing: 8) {
                    Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger)
                        .lineLimit(1)
                        .help(problem.detail)
                    Spacer(minLength: 6)
                    Button("Open Settings…", action: openSettings)
                        .tmGlassButton(circle: false)
                        .controlSize(.small)
                }
            } else if let balanceText {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(balanceText)
                        .font(TMType.semibold(22))
                        .tmMonospacedDigit()
                        .foregroundStyle(balanceTint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 14) {
                        ForEach(Array(secondaryStats.enumerated()), id: \.offset) { _, stat in
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(stat.label)
                                    .font(TMType.regular(TMType.micro))
                                    .foregroundStyle(TMDesign.quiet)
                                Text(stat.value)
                                    .font(TMType.medium(TMType.caption))
                                    .tmMonospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if let keyQuota {
                    let usedPct = (keyQuota.limit - keyQuota.remaining) / keyQuota.limit * 100
                    let shown = QuotaWindow.shownPercent(used: usedPct, showsRemaining: showsRemaining)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Key limit")
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                            Spacer()
                            Text("\(Int(shown.rounded()))% \(showsRemaining ? "left" : "used")")
                                .font(TMType.medium(TMType.micro))
                                .tmMonospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                        }
                        DashUsageBar(
                            fillPercent: shown,
                            tint: DashUsageBar.semanticTint(usedPercent: usedPct, base: color),
                            height: 4
                        )
                    }
                }
                if let warningNote {
                    Text(warningNote)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger)
                }
                if let error {
                    let problem = RowProblem.from(service: title, error: error, accountKey: accountKey)
                    Text(problem.title)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.danger)
                        .lineLimit(1)
                        .help(problem.detail)
                }
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("—")
                    .font(TMType.semibold(22))
                    .foregroundStyle(TMDesign.quiet)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
