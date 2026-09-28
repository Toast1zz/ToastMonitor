import SwiftUI

/// Plans: one card per connected account. Every card is the same size and
/// follows one template — a header, then a row of figure columns centered
/// below it — so a grid of accounts reads as a set, whichever account
/// has more to say. Credentials, account options and subscriptions are
/// managed in Settings › Accounts.
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var deepseek = DeepSeekBillingClient.shared
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false

    /// Tall enough for the largest figure column (label, figure, bar and two
    /// caption lines) under a header.
    static let cardHeight: CGFloat = 178

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

    private var cards: [AnyView] {
        var out: [AnyView] = []
        if claudeConnected { out.append(AnyView(claudeCard)) }
        if ccConnected { out.append(AnyView(ccCard)) }
        if goConnected { out.append(AnyView(goCard)) }
        if orConnected { out.append(AnyView(orCard)) }
        if deepseekConnected { out.append(AnyView(deepseekCard)) }
        if !app.subscriptions.isEmpty { out.append(AnyView(subsCard)) }
        if !unconnected.isEmpty { out.append(AnyView(unconnectedCard)) }
        return out
    }

    var body: some View {
        DashPage {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DashLayout.gap),
                                GridItem(.flexible(), spacing: DashLayout.gap)],
                      alignment: .leading, spacing: DashLayout.gap) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    card.frame(height: Self.cardHeight)
                }
            }
        }
        .task {
            // Today's DeepSeek account spend for its card, fetched beside the
            // popover's own period.
            while !Task.isCancelled {
                deepseek.loadSpendIfNeeded(for: .today, configuration: UsagePeriodSettings.shared.configuration)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func openAccountSettings() {
        SettingsWindowController.shared.show(pane: .accounts)
    }

    // MARK: - Accounts

    private var claudeCard: some View {
        let cq = claudeQuota.state
        let windows = [("5h", cq.fiveHour), ("Weekly", cq.sevenDay), ("Weekly Opus", cq.sevenDayOpus)]
            .compactMap { label, window in window.map { (label: label, window: $0) } }
        return accountCard(title: "Claude", symbol: ToolKind.claude.symbol, color: ToolKind.claude.color,
                           isLoading: cq.lastSync <= 0 && cq.error == nil && cq.configured,
                           error: cq.error, lastSync: cq.lastSync,
                           refresh: { claudeQuota.refresh(force: true) }) {
            ForEach(windows, id: \.label) { item in
                quotaColumn(item.label, usedPercent: Double(item.window.usedPercent),
                            captions: [resetText(absolute: item.window.resetAt)].compactMap { $0 },
                            color: ToolKind.claude.color)
            }
        }
    }

    private var ccCard: some View {
        let cc = ccQuota.state
        return accountCard(title: "Command Code", symbol: "c.circle.fill", color: TMDesign.commandCode,
                           isLoading: cc.isLoading && cc.lastSync <= 0, error: cc.error, lastSync: cc.lastSync,
                           refresh: { ccQuota.refresh() }) {
            if let total = cc.monthlyCreditsTotal, let pct = cc.monthlyUsedPercent {
                quotaColumn("Monthly", usedPercent: pct,
                            captions: [resetText(absolute: cc.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) })]
                                .compactMap { $0 },
                            color: TMDesign.commandCode)
                FigureColumn(label: "Credits used",
                             value: Format.money(min(max(pct, 0), 100) / 100 * total),
                             captions: ["of \(Format.money(total))"])
            } else if let remaining = cc.monthlyCreditsRemaining {
                // Unknown plan or no allowance reported: the raw balance,
                // never a fabricated percentage.
                FigureColumn(label: "Credits left", value: Format.money(remaining))
            }
            if let plan = cc.planName {
                FigureColumn(label: "Plan", value: plan)
            }
        }
    }

    private var goCard: some View {
        let go = goClient.state
        let limit = OpenCodeGoClient.monthlyLimitUSD
        let absolute: (Int64?) -> Int64? = { reset in
            reset.flatMap { go.lastSync > 0 ? go.lastSync + $0 : nil }
        }
        return accountCard(title: "OpenCode Go", symbol: "g.circle.fill", color: ToolKind.opencode.color,
                           isLoading: go.isLoading && go.lastOK <= 0, error: go.error, lastSync: go.lastOK,
                           refresh: goClient.configured ? { goClient.refresh() } : nil) {
            if let pct = go.monthlyPct {
                quotaColumn("Monthly", usedPercent: pct,
                            captions: ["\(Format.money(min(max(pct, 0), 100) / 100 * limit)) of \(Format.money(limit))",
                                       resetText(absolute: absolute(go.monthlyReset))].compactMap { $0 },
                            color: ToolKind.opencode.color)
            }
            if let pct = go.weeklyPct {
                quotaColumn("Weekly", usedPercent: pct,
                            captions: [resetText(absolute: absolute(go.weeklyReset))].compactMap { $0 },
                            color: ToolKind.opencode.color)
            }
            if let pct = go.rollingPct {
                quotaColumn("5h", usedPercent: pct,
                            captions: [resetText(absolute: absolute(go.rollingReset))].compactMap { $0 },
                            color: ToolKind.opencode.color)
            }
        }
    }

    private var orCard: some View {
        let or = orClient.state
        return accountCard(title: "OpenRouter", symbol: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color,
                           isLoading: or.isLoading && or.lastOK <= 0, error: or.error, lastSync: or.lastOK,
                           refresh: { orClient.refresh() }) {
            if or.lastOK > 0 {
                FigureColumn(label: "Balance", value: or.accountBalance.map(Format.money) ?? "—")
                FigureColumn(label: "Today", value: Format.money(or.usageDaily))
                FigureColumn(label: "This month", value: Format.money(or.usageMonthly))
                if let remaining = or.limitRemaining, let limit = or.limit, limit > 0 {
                    // Bar semantics are "used": a fresh key renders empty.
                    quotaColumn("Key", usedPercent: (limit - remaining) / limit * 100,
                                captions: ["\(Format.money(remaining)) of \(Format.money(limit)) left"],
                                color: ToolKind.openrouter.color)
                }
            }
        }
    }

    private var deepseekCard: some View {
        let state = deepseek.state
        let wallets = state.expired ? [] : state.balance?.wallets ?? []
        // Same reading as the popover: funded wallets only, symbol amounts.
        let funded = wallets.filter { $0.total.amount != 0 }
        let shown = funded.isEmpty ? Array(wallets.prefix(1)) : funded
        let unavailable = state.balance?.available == false
        let spend = deepseek.spend(for: .today, configuration: UsagePeriodSettings.shared.configuration)
        let updated = state.balanceUpdated.map { Int64($0.timeIntervalSince1970) } ?? 0
        return accountCard(title: "DeepSeek", symbol: "d.circle.fill", color: ToolKind.dsh.color,
                           isLoading: state.loadingBalance && updated == 0,
                           error: state.expired ? "Sign-in expired" : (state.balanceError ?? state.spendError),
                           lastSync: updated,
                           refresh: { deepseek.refresh(force: true) }) {
            if !shown.isEmpty {
                FigureColumn(label: "Balance",
                             value: shown.map { $0.total.symbolFormatted }.joined(separator: " · "),
                             tint: unavailable ? TMDesign.danger : .primary,
                             captions: unavailable ? ["Unavailable for API calls"] : [],
                             captionTint: unavailable ? TMDesign.danger : TMDesign.quiet)
            }
            if state.kind == .platform {
                FigureColumn(label: "Today",
                             value: spend.map { $0.amounts.isEmpty ? "—"
                                 : $0.amounts.map(\.symbolFormatted).joined(separator: " · ") } ?? "—",
                             captions: ["Account spend"])
            }
        }
    }

    private var subsCard: some View {
        let subs = app.subscriptions
        return plainCard(title: "Subscriptions", symbol: "calendar", color: TMDesign.accent) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(subs.prefix(3)) { sub in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sub.name)
                            .font(TMType.medium(TMType.body))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                            Text("renews \(Self.shortDate(info.end))")
                                .font(TMType.regular(TMType.caption))
                                .foregroundStyle(TMDesign.quiet)
                        }
                        Text("\(Format.money(sub.price))/\(sub.cycle == "yearly" ? "yr" : "mo")")
                            .font(TMType.semibold(TMType.body))
                            .tmMonospacedDigit()
                    }
                }
                if subs.count > 3 {
                    Text("\(subs.count - 3) more in Settings")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
        }
    }

    private var unconnectedCard: some View {
        plainCard(title: "Not connected", symbol: "plus", color: TMDesign.quiet) {
            VStack(alignment: .leading, spacing: 10) {
                Text(unconnected.joined(separator: " · "))
                    .font(TMType.regular(TMType.body))
                    .foregroundStyle(TMDesign.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up…", action: openAccountSettings)
                    .tmGlassButton(circle: false)
            }
        }
    }

    // MARK: - Card template

    /// Header, then the figure columns centered in the space below it. An account
    /// that failed before producing any figure says so in the body, where the
    /// figures would be; with figures on screen the reason stays in the header.
    private func accountCard<Columns: View>(
        title: String, symbol: String, color: Color,
        isLoading: Bool, error: String?, lastSync: Int64,
        refresh: (() -> Void)?,
        @ViewBuilder columns: () -> Columns
    ) -> some View {
        let failedEmpty = error != nil && lastSync <= 0
        return DashCard {
            VStack(alignment: .leading, spacing: 0) {
                header(title: title, symbol: symbol, color: color) {
                    if !failedEmpty {
                        freshness(isLoading: isLoading, error: error, lastSync: lastSync)
                    }
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
                Group {
                if failedEmpty, let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(TMType.regular(TMType.body))
                            .foregroundStyle(TMDesign.danger)
                            .lineLimit(2)
                        Button("Open Settings…", action: openAccountSettings)
                            .tmGlassButton(circle: false)
                    }
                } else if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    // Labels on one line across columns, whether or not a
                    // column carries a bar.
                    HStack(alignment: .top, spacing: 24) { columns() }
                }
                }
                // The body sits centered in the space under the header, so
                // cards with a short body balance their space above and below
                // instead of leaving it all at one end.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// A card that is not an account (subscriptions, the not-connected list):
    /// same size and header, free-form body centered below it.
    private func plainCard<Content: View>(title: String, symbol: String, color: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                header(title: title, symbol: symbol, color: color) { EmptyView() }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private func header<Trailing: View>(title: String, symbol: String, color: Color,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            DashGlyph(symbol: symbol, color: color)
            Text(title)
                .font(TMType.semibold(15))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// Trailing status: how long ago the account updated; a colored mark
    /// only for states that need attention.
    @ViewBuilder
    private func freshness(isLoading: Bool, error: String?, lastSync: Int64) -> some View {
        let age = Int64(Date().timeIntervalSince1970) - lastSync
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.danger)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(error)
        } else if isLoading {
            EmptyView()
        } else if lastSync <= 0 {
            TMStatusPill(text: "Idle", color: TMDesign.quiet, symbol: "circle.dashed")
        } else if age > 120 {
            TMStatusPill(text: "Stale", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                .help("Updated \(Format.dateTime(lastSync))")
        } else {
            Text(age < 60 ? "Just now" : "\(Format.remaining(age)) ago")
                .font(TMType.regular(TMType.caption))
                .tmMonospacedDigit()
                .foregroundStyle(TMDesign.quiet)
                .help("Updated \(Format.dateTime(lastSync))")
        }
    }

    /// A quota window as a figure column. The bar always encodes usage; the
    /// used/remaining preference from the popover changes only the figure.
    private func quotaColumn(_ label: String, usedPercent: Double, captions: [String],
                             color: Color) -> FigureColumn {
        let p = min(max(usedPercent, 0), 100)
        let shown = Int((showsRemaining ? 100 - p : p).rounded())
        return FigureColumn(label: label, value: "\(shown)%",
                            unit: showsRemaining ? "left" : "used",
                            usedPercent: p, barTint: color, captions: captions)
    }

    /// "resets in 4.8d" for an absolute unix-seconds reset; nil once passed.
    private func resetText(absolute: Int64?) -> String? {
        guard let absolute else { return nil }
        let remaining = absolute - Int64(Date().timeIntervalSince1970)
        return remaining > 0 ? "resets in \(Format.remaining(remaining))" : nil
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()

    private static func shortDate(_ date: Date) -> String { dateFormatter.string(from: date) }
}

/// One figure in an account card: a small label, the figure, an optional
/// usage bar, and up to two caption lines. Columns share the card's width.
private struct FigureColumn: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = .primary
    var usedPercent: Double?
    var barTint: Color = .accentColor
    var captions: [String] = []
    var captionTint: Color = TMDesign.quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(TMType.regular(TMType.caption))
                .foregroundStyle(TMDesign.quiet)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(TMType.semibold(24))
                    .tmMonospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
            if let usedPercent {
                DashUsageBar(usedPercent: usedPercent, tint: barTint, height: 5)
                    .padding(.vertical, 2)
            }
            ForEach(captions, id: \.self) { caption in
                Text(caption)
                    .font(TMType.regular(TMType.caption))
                    .tmMonospacedDigit()
                    .foregroundStyle(captionTint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
