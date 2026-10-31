import SwiftUI
import Combine
import AppKit
import Charts

/// yyyymmdd -> Date (local calendar).
private func dayFromKey(_ key: Int64) -> Date {
    var c = DateComponents()
    c.year = Int(key / 10_000)
    c.month = Int(key / 100) % 100
    c.day = Int(key % 100)
    return Calendar.current.date(from: c) ?? .distantPast
}

/// "Aug 5" short date for hover readouts. Fixed en_US locale: the
/// popover is English even when the system language is not.
private let shortDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d"
    return f
}()


private struct PopoverBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where the scrolled card stack sits in the viewport (0 at the top, negative
/// as it scrolls up).
private struct PopoverScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Compact, single-purpose menu bar home. It answers three questions quickly:
/// how much was used, where it came from, and whether a limit needs attention.
struct PopoverHomeView: View {
    static let testPeriodNotification = Notification.Name("tmTestPopoverPeriod")

    /// The minute tick is skipped while the panel is hidden.
    static func minuteTickAllowed(panelVisible: Bool) -> Bool {
        panelVisible
    }

    /// Visibility notification -> (new visibility, reload heatmap now?).
    /// Only a hidden -> visible transition reloads.
    static func visibilityTransition(visible: Bool, wasVisible: Bool) -> (visible: Bool, reload: Bool) {
        (visible, visible && !wasVisible)
    }

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case month = "30 Days"
        case all = "All Time"
        var id: String { rawValue }

        var slot: UsagePeriodSlot {
            switch self {
            case .today: return .today
            case .week: return .week
            case .month: return .month
            case .all: return .all
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @ObservedObject private var grokQuota = GrokQuotaClient.shared
    @ObservedObject private var claudeQuota = ClaudeQuotaClient.shared
    @ObservedObject private var deepseek: DeepSeekBillingClient
    @AppStorage(DeepSeekBilling.exchangeRateKey) private var cnyPerUSD = DeepSeekBilling.defaultCNYPerUSD
    @ObservedObject private var periodSettings = UsagePeriodSettings.shared
    @State private var period: Period = {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--period"), flag + 1 < args.count else {
            return .today
        }
        switch args[flag + 1] {
        case "week": return .week
        case "month": return .month
        case "all": return .all
        default: return .today
        }
    }()
    /// Drives countdown refresh (resets etc.) once a minute.
    @State private var now: Date
    /// Full-number mode (1,234,567 instead of 1.2M) — switch to watch the
    /// counter tick up during streaming.
    @AppStorage("popoverFullTokens") private var fullTokens = false
    @AppStorage(CodexPlanName.customNameKey) private var codexCustomName = ""
    /// Activity card shows one history view at a time: heatmap or trend.
    @AppStorage("popoverHistoryMode") private var historyMode = HistoryMode.heatmap
    /// Cards hidden in Settings › Appearance (comma-separated keys).
    @AppStorage("popoverHiddenSections") private var hiddenSectionsRaw = ""
    /// Daily usage for a year. The popover loads its own: AppState fills its heatmap only while the dashboard is visible.
    @State private var heatmapData: [Int64: Int64] = [:]
    @State private var detectedTools: [ToolKind] = []
    /// Whether the panel is visible. The view stays alive while hidden, so the
    /// minute tick and heatmap reload must stop or a 371-day aggregation runs every 60s.
    @State private var panelVisible = false
    @State private var bodyContentHeight: CGFloat = 0
    /// True once the scrolled content reaches the bottom of the viewport.
    @State private var scrolledToEnd = true
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @MainActor init(deepseek: DeepSeekBillingClient? = nil) {
        _deepseek = ObservedObject(wrappedValue: deepseek ?? .shared)
        _now = State(initialValue: Self.initialNow)
    }

    /// The screenshot harness can freeze popover-only dates without changing
    /// the live clock used by ordinary app launches or unconfigured renders.
    static var visualReferenceUnixTime: Double? {
        guard CommandLine.arguments.contains("--render-popover"),
              let raw = ProcessInfo.processInfo.environment["TM_VISUAL_REFERENCE_UNIX_TIME"],
              let unixTime = Double(raw), unixTime.isFinite else {
            return nil
        }
        return unixTime
    }

    private static var initialNow: Date {
        guard let unixTime = visualReferenceUnixTime else { return Date() }
        return Date(timeIntervalSince1970: unixTime)
    }

    private var totals: Database.ToolTotals {
        switch period {
        case .today: app.today
        case .week: app.week
        case .month: app.month
        case .all: app.all
        }
    }

    private var tokens: Int64 {
        switch period {
        case .today: app.todayTokens
        case .week: app.weekTokens
        case .month: app.monthTokens
        case .all: app.allTokens
        }
    }

    private var cost: UsageQueryService.CostQuality {
        switch period {
        case .today: app.costToday
        case .week: app.costWeek
        case .month: app.costMonth
        case .all: app.costAll
        }
    }

    private var byTool: [Database.ToolTotals] {
        switch period {
        case .today: app.byToolToday
        case .week: app.byToolWeek
        case .month: app.byToolMonth
        case .all: app.byToolAll
        }
    }

    private static let scrollTopID = "popover-scroll-top"

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                // Cards fade out at the bottom edge while more content is below
                // the viewport. A mask, not a colored overlay: the panel is
                // translucent, so any fixed color would show as a band.
                let overflows = bodyContentHeight > viewport.size.height + 1
                let fading = overflows && !scrolledToEnd
                ZStack(alignment: .bottom) {
                    ScrollViewReader { scroller in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                if let problem = app.databaseProblem {
                                    PopoverCard(title: "") { DatabaseProblemView(problem: problem) }
                                }
                                // Everything the period selector changes lives in
                                // this one card; Quota and Balance below are
                                // current state and sit outside it.
                                // The selector heads the card instead of a title: it
                                // names what the card shows and has the full width.
                                if app.databaseProblem == nil {
                                    PopoverCard(title: "") {
                                        VStack(alignment: .leading, spacing: 14) {
                                            periodControl
                                            hero
                                            if !isSectionHidden("sources") { sourceBar }
                                        }
                                    }
                                }
                                if !isSectionHidden("quota") { quotaSection }
                                if !isSectionHidden("balance") { balanceSection }
                                if !isSectionHidden("activity"), app.databaseProblem == nil {
                                    PopoverCard(title: "Activity",
                                                accessory: { historyAccessory },
                                                trailing: { historyPicker }) { historyBlock }
                                }
                            }
                            .padding(.horizontal, TMLayout.popoverCardInset)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { content in
                                Color.clear.preference(key: PopoverBodyHeightKey.self,
                                                       value: content.size.height)
                            })
                            .reportPopoverHeight(.body)
                            .id(Self.scrollTopID)
                            .background(GeometryReader { content in
                                Color.clear.preference(key: PopoverScrollOffsetKey.self,
                                                       value: content.frame(in: .named("popoverScroll")).minY)
                            })
                        }
                        .coordinateSpace(name: "popoverScroll")
                        .mask {
                            VStack(spacing: 0) {
                                Rectangle()
                                if fading {
                                    LinearGradient(colors: [.black, .clear],
                                                   startPoint: .top, endPoint: .bottom)
                                        .frame(height: 22)
                                }
                            }
                        }
                        // A new period starts at the top. Scrolling instead of
                        // rebuilding the stack (`.id(period)`) keeps the native
                        // selector alive and the panel from collapsing and
                        // re-growing on every switch.
                        .onChange(of: period) { _ in scroller.scrollTo(Self.scrollTopID, anchor: .top) }
                    }
                }
                .onPreferenceChange(PopoverBodyHeightKey.self) { bodyContentHeight = $0 }
                .onPreferenceChange(PopoverScrollOffsetKey.self) { offset in
                    let atEnd = bodyContentHeight + offset <= viewport.size.height + 1
                    if atEnd != scrolledToEnd { scrolledToEnd = atEnd }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            deepseek.select(period.slot, configuration: periodSettings.configuration)
            loadQuotaRowHidden()
            loadDetectedTools()
            reloadHeatmap()
        }
        .onChange(of: period) { selected in
            deepseek.select(selected.slot, configuration: periodSettings.configuration)
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.usagePeriodSettingsChanged)) { _ in
            deepseek.select(period.slot, configuration: periodSettings.configuration)
        }
        .onReceive(minuteTicker) { tick in
            // Hidden panel: skip the whole tick. Becoming visible reloads at once,
            // so the data never waits for the next minute.
            guard Self.minuteTickAllowed(panelVisible: panelVisible) else { return }
            now = tick
            deepseek.select(period.slot, configuration: periodSettings.configuration, now: tick)
            reloadHeatmap()
        }
        .onReceive(NotificationCenter.default.publisher(for: TMNotifications.popoverVisibility)) { note in
            // Only a hidden -> visible transition reloads the heatmap; onAppear
            // handles the first load.
            let visible = (note.object as? Bool) ?? false
            let transition = Self.visibilityTransition(visible: visible, wasVisible: panelVisible)
            panelVisible = transition.visible
            if transition.reload {
                now = Date()
                deepseek.select(period.slot, configuration: periodSettings.configuration, now: now)
                reloadHeatmap()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AccountsSettingsSection.quotaRowsChanged)) { _ in
            loadQuotaRowHidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.testPeriodNotification)) { note in
            guard let raw = note.object as? String else { return }
            switch raw {
            case "week": period = .week
            case "month": period = .month
            case "all": period = .all
            default: period = .today
            }
        }
    }

    /// Hero: the decision number is TOKENS. Below it, Spent and Value
    /// (official-rate revaluation) sit side by side as two quiet chips.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fullTokens ? Format.full(tokens) : Format.compact(tokens))
                    .font(TMType.bold(30))
                    .tmMonospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .tmNumericTextTransition(value: Double(tokens))
                    // Both the token count and the display format drive the
                    // transition, so toggling compact/full numbers animates the same way
                    // as a live token update.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: HeroValue(tokens: tokens, full: fullTokens))
                    .accessibilityLabel("\(periodSettings.configuration.label(for: period.slot)) token usage")
                    .accessibilityValue(Text("\(Format.full(tokens)) tokens"))
                Text("tokens")
                    .font(TMType.regular(13))
                    .foregroundStyle(TMDesign.quiet)
            }
            HStack(spacing: 16) {
                // OpenRouter only reports a monthly window, as the Overview says too.
                HeroChip(label: period == .all && AccountConnection.openRouter ? "Spent · OR recent month" : "Spent",
                         value: combinedSpentText,
                         problem: deepseekSpendPending
                             ? RowProblem(title: "DeepSeek spending not included yet",
                                          detail: "Spent leaves out DeepSeek's account billing for this "
                                              + "period until it loads"
                                              + (deepseek.state.spendError.map { " (\($0))" } ?? "")
                                              + ". ToastMonitor tries again on its own.")
                             : nil)
                HeroChip(label: "Value",
                         value: estimatedShown > 0 ? Format.money(estimatedShown) : "—")
            }
        }
    }

    /// DeepSeek account billing is part of Spent but has not landed (or is
    /// stale) for this window — flagged on the Spent chip.
    private var deepseekSpendPending: Bool {
        deepseek.state.kind == .platform
            && (includedDeepSeekSpend == nil
                || deepseek.stale(deepseek.state.spendUpdated, error: deepseek.state.spendError, now: now))
    }

    private var includedDeepSeekSpend: DeepSeekBilling.Spend? {
        deepseek.spend(for: period.slot, configuration: periodSettings.configuration, now: now)
    }

    private var combinedSpentText: String {
        DeepSeekBilling.combinedSpend(localUSD: actualShown, coveredLocalUSD: cost.deepseekActual,
                                      spend: includedDeepSeekSpend, cnyPerUSD: cnyPerUSD)
    }

    @ViewBuilder
    private var periodControl: some View {
        let selector = NativePeriodSelector(
            selection: $period,
            labels: Period.allCases.map { periodSettings.configuration.label(for: $0.slot) })
        // PopoverRootView makes ordinary controls small; without its own
        // controlSize the selector is created small and only corrects itself
        // after a rebuild (switching periods), so its height jumped.
        Group {
            if #available(macOS 26.0, *) {
                selector.environment(\.controlSize, .extraLarge)
            } else {
                selector.environment(\.controlSize, .large)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Period")
    }

    /// Actual spend = billed turns + OpenRouter + amortized subscriptions.
    private var actualShown: Double {
        cost.actual + periodOrUsage + subsAmortized
    }

    /// API value = every tool's turns (Hermes included) at list prices.
    private var estimatedShown: Double {
        switch period {
        case .today: return app.apiValueToday
        case .week: return app.apiValueWeek
        case .month: return app.apiValueMonth
        case .all: return app.apiValueAll
        }
    }

    private var periodOrUsage: Double {
        switch period {
        case .today: orClient.state.usageDaily
        case .week: orClient.state.usageWeekly
        case .month: orClient.state.usageMonthly
        // OpenRouter only reports a monthly window; All uses the latest month.
        case .all: orClient.state.usageMonthly
        }
    }

    private var subsAmortized: Double {
        SubscriptionMath.amortized(slot: period.slot, configuration: periodSettings.configuration,
                                   subscriptions: app.subscriptions, now: now)
    }

    /// Source share bar plus one row per source.
    private var sourceBar: some View {
        let rows = sortedRows
        let total = rows.reduce(Int64(0)) {
            $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
        // "Never configured" means no data at all, ever. An empty current
        // period must not show Get Started at the start of every day.
        let neverConfigured = rows.isEmpty && app.byToolAll.isEmpty
        return VStack(alignment: .leading, spacing: 7) {
            if neverConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get Started")
                        .font(TMType.semibold(TMType.body))
                    Text(detectedTools.isEmpty
                         ? "No supported local tools detected"
                         : "Detected: \(detectedTools.map(\.displayName).joined(separator: ", "))")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(2)
                    Button("Configure Sources…") {
                        SettingsWindowController.shared.show(pane: .accounts)
                        NotificationCenter.default.post(name: PanelController.hideNotification,
                                                        object: nil)
                    }
                    .controlSize(.small)
                }
            } else if rows.isEmpty {
                Text("No usage yet this period")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                SourceBar(segments: rows.map { row in
                    (Double(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)),
                     TMDesign.sourceColor(row.tool))
                })

                ForEach(rows, id: \.tool) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(TMDesign.sourceColor(row.tool))
                            .frame(width: 7, height: 7)
                        Text(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                            .font(TMType.medium(TMType.body))
                            .foregroundStyle(.primary)
                        Text("(\(percentText(row, total: total)))")
                            .font(TMType.number(TMType.caption))
                            .foregroundStyle(TMDesign.quiet)
                        Spacer()
                        let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
                        Text(Format.compact(value))
                            .font(TMType.number(TMType.body))
                            .foregroundStyle(TMDesign.quiet)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                    .accessibilityValue(Text("\(Format.full(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output))) tokens, \(percentText(row, total: total)) of total"))
                }
            }
        }
    }

    private func loadDetectedTools() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var tools: [ToolKind] = []
            if fm.fileExists(atPath: ClaudeCodeParser.root)
                || fm.fileExists(atPath: ClaudeCodeParser.coworkLocalAgentRoot) { tools.append(.claude) }
            if fm.fileExists(atPath: CodexParser.sessionsRoot) { tools.append(.codex) }
            if fm.fileExists(atPath: OpenCodeParser.dbPath) { tools.append(.opencode) }
            if !HermesParser.dbPaths.isEmpty { tools.append(.hermes) }
            if fm.fileExists(atPath: OmpParser.root) { tools.append(.omp) }
            if fm.fileExists(atPath: DSHParser.projCachePath)
                || !DSHParser.listSessionFiles().isEmpty { tools.append(.dsh) }
            DispatchQueue.main.async { detectedTools = tools }
        }
    }

    private func percentText(_ row: Database.ToolTotals, total: Int64) -> String {
        let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
        let ratio = total > 0 ? Double(value) / Double(total) : 0
        return String(format: "%.1f%%", ratio * 100)
    }

    private var sortedRows: [Database.ToolTotals] {
        byTool.sorted {
            (ToolKind(rawValue: $0.tool)?.totalTokens($0) ?? ($0.input + $0.output)) >
                (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
    }

    // MARK: - Quota (live account state, independent of the period)

    /// Quota/balance is a live account snapshot — it only changes as time
    /// passes, never with the selected period. Showing it inside the period
    /// switcher implied it varied per dimension, so it now lives in its own
    /// fixed section below the period content, labelled as such.
    private var quotaSection: some View {
        sourceSection(title: "Quota", group: .quota)
    }

    private var balanceSection: some View {
        sourceSection(title: "Balance", group: .balance)
    }

    /// One card per kind of account: subscription quotas (percent windows
    /// that reset) and prepaid balances (money left). Mixing them made a
    /// "61% weekly left" line sit next to "CNY 7.67" as if comparable.
    @ViewBuilder
    private func sourceSection(title: String, group: SourceGroup) -> some View {
        let sources = quotaSources.filter { $0.group == group }
        let visible = sources.filter { $0.connected && !(quotaRowHidden[$0.key] ?? false) }
        let unconnected = sources.filter { !$0.connected && !(quotaRowHidden[$0.key] ?? false) }
        if !visible.isEmpty || !unconnected.isEmpty {
            // Balances with nothing to act on share one line; one that is
            // running out, empty or failing gets its own full row.
            let calm = group == .balance
                ? visible.compactMap { src in calmBalance(src.key).map { (key: src.key, name: src.name, value: $0) } }
                : []
            let rows = visible.map(\.key).filter { key in !calm.contains { $0.key == key } }
            PopoverCard(title: title) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element) { index, key in
                        if index > 0 { rowDivider }
                        quotaRow(key)
                    }
                    if !calm.isEmpty {
                        if !rows.isEmpty { rowDivider }
                        BalanceLine(items: calm.map { ($0.name, $0.value) })
                    }
                    if !unconnected.isEmpty {
                        if !visible.isEmpty { rowDivider }
                        UnconnectedSourcesRow(names: unconnected.map(\.name)) {
                            // Quota and balance accounts are connected in
                            // Settings › Accounts.
                            SettingsWindowController.shared.show(pane: .accounts)
                            NotificationCenter.default.post(name: PanelController.hideNotification,
                                                            object: nil)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quotaRow(_ key: String) -> some View {
        switch key {
        case "claude": claudeStatusRow
        case "go": goStatusRow
        case "codex": codexStatusRow
        case "cc": commandCodeStatusRow
        case "grok": grokStatusRow
        case "router": routerStatusRow
        default: deepseekStatusRow
        }
    }

    private enum SourceGroup { case quota, balance }

    /// Hairline between accounts inside a card.
    private var rowDivider: some View {
        Divider().opacity(0.6)
            .padding(.vertical, 6)
    }

    /// Quota rows in display order. `connected == false` means the source
    /// was never set up (or deliberately left off) — such a row carries no
    /// number, only "Not configured", so it is folded into one summary line
    /// instead of taking a full two-line row each.
    private var quotaSources: [(key: String, name: String, group: SourceGroup, connected: Bool)] {
        [
            ("claude", "Claude", .quota, AccountConnection.claude),
            ("go", "OpenCode Go", .quota, AccountConnection.openCodeGo),
            ("codex", "Codex", .quota, AccountConnection.codex(subscriptions: app.subscriptions)),
            ("cc", "Command Code", .quota, AccountConnection.commandCode),
            ("grok", "Grok", .quota, AccountConnection.grok),
            ("router", "OpenRouter", .balance, AccountConnection.openRouter),
            ("deepseek", "DeepSeek", .balance, AccountConnection.deepSeek),
        ]
    }

    /// Per-row visibility (key = "go" / "codex" / "router"), mirrored from
    /// the `hide_quota_row_<key>` setting. Mutations update this state
    /// immediately so the row disappears on click; persistence is instant too.
    @State private var quotaRowHidden: [String: Bool] = [:]

    private static func quotaRowHiddenKey(_ key: String) -> String {
        "hide_quota_row_\(key)"
    }

    private func loadQuotaRowHidden() {
        for key in PopoverAccountRows.keys {
            quotaRowHidden[key] = Database.shared.setting(Self.quotaRowHiddenKey(key)) == "1"
        }
    }

    // MARK: - Activity and trend (history, independent of the period)

    /// Heatmap and trend share one card with a small switch in its title
    /// row (persisted). Both views have one height, so switching never jumps.
    private var historyBlock: some View {
        Group {
            switch historyMode {
            case .heatmap:
                PopoverHeatmap(weeks: activityWeeks, heatmap: heatmapData)
            case .trend:
                TrendChartView(series: trendSeries)
            }
        }
        .frame(height: PopoverHeatmap.totalHeight, alignment: .top)
    }

    private var historyAccessory: some View {
        Text(historyMode == .heatmap
             ? "\(activeDays) active days"
             : trendPeak > 0 ? "Peak \(Format.compact(trendPeak))" : "")
            .font(TMType.number(TMType.caption))
            .foregroundStyle(TMDesign.quiet)
    }

    /// Same native capsule as the period selector, so the two switches in
    /// the panel look alike instead of one in accent blue.
    private var historyPicker: some View {
        NativeHistorySelector(selection: $historyMode)
            .environment(\.controlSize, .small)
            .fixedSize()
            .accessibilityLabel("History view")
    }

    // MARK: - Hidden sections

    private var hiddenSections: [String] {
        hiddenSectionsRaw.split(separator: ",").map(String.init)
    }

    private func isSectionHidden(_ key: String) -> Bool { hiddenSections.contains(key) }

    /// Last heatmap data, persisted so a cold start draws it immediately
    /// instead of an empty Activity/Trend card.
    private static let heatmapCacheKey = "popoverHeatmapCache"

    private func cachedHeatmap() -> [Int64: Int64]? {
        guard let data = UserDefaults.standard.data(forKey: Self.heatmapCacheKey),
              let dict = try? JSONDecoder().decode([String: Int64].self, from: data) else { return nil }
        var out: [Int64: Int64] = [:]
        for (k, v) in dict {
            if let key = Int64(k) { out[key] = v }
        }
        return out.isEmpty ? nil : out
    }

    private func saveHeatmapCache(_ map: [Int64: Int64]) {
        let dict = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.heatmapCacheKey)
        }
    }

    private func reloadHeatmap() {
        // Draw from the cache at once, then refresh asynchronously.
        if heatmapData.isEmpty, let cached = cachedHeatmap() {
            heatmapData = cached
        }
        UsageQueryService.shared.loadHeatmap { map in
            guard map != self.heatmapData else { return }
            self.heatmapData = map
            self.saveHeatmapCache(map)
        }
    }

    /// Keys shown by the heatmap grid (the visible 20 weeks only).
    private var visibleHeatmapKeys: [Int64] {
        activityWeeks.flatMap { $0.compactMap { $0 } }
    }

    private var activeDays: Int {
        visibleHeatmapKeys.filter { (heatmapData[$0] ?? 0) > 0 }.count
    }

    /// Daily usage for the last 60 days (today included), oldest first.
    private var trendSeries: [(key: Int64, tokens: Int64)] {
        heatmapData.sorted { $0.key < $1.key }
            .suffix(60)
            .map { ($0.key, $0.value) }
    }

    private var trendPeak: Int64 {
        trendSeries.map(\.tokens).max() ?? 0
    }

    /// Last 24 weeks; keys match heatmapData's local yyyymmdd days.
    private var activityWeeks: [[Int64?]] {
        Self.buildHeatmapWeeks(now: now, configuration: periodSettings.configuration)
    }

    private static func buildHeatmapWeeks(now: Date,
                                          configuration: UsagePeriodConfiguration) -> [[Int64?]] {
        var weeks: [[Int64?]] = []
        let calendar = configuration.configuredCalendar()
        let weekStart = configuration.startOfConfiguredWeek(now, calendar: calendar)
        let count = PopoverHeatmap.weekCount
        for week in 0..<count {
            var column: [Int64?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day - (count - 1) * 7, to: weekStart) else {
                    column.append(nil)
                    continue
                }
                if date > now {
                    column.append(nil)
                } else {
                    let components = calendar.dateComponents([.year, .month, .day], from: date)
                    let key = (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
                    column.append(Int64(key))
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    private func resetText(_ at: Int64?) -> String? {
        guard let at, at > Int64(now.timeIntervalSince1970) else { return nil }
        return "resets in \(Format.remaining(at - Int64(now.timeIntervalSince1970)))"
    }

    private var goStatusRow: some View {
        let state = goClient.state
        let remaining = state.monthlyPct.map { 100 - $0 }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = goClient.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        // Same "prefer the cached number" reasoning as Claude's row: a
        // stale percentage is still more useful than the word "Stale", so
        // the last known value stays on screen with a small freshness badge
        // instead of being replaced.
        var staleBadge: String?
        if !goClient.configured {
            // A locked/re-authorized Keychain reads back exactly like
            // "never configured" from credentials() — surface which one it
            // actually is instead of always saying "Not configured", or a
            // real credentials loss looks identical to a rebuild-triggered
            // Keychain re-auth prompt that never happened.
            status = (state.error?.localizedCaseInsensitiveContains("keychain") == true) ? "Keychain locked" : "Not configured"
        } else if let remaining {
            status = "\(Int(remaining))% monthly left"
            resetSuffix = resetText(state.monthlyReset.map { state.lastSync + $0 })
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        }
        // Go also reports a weekly window alongside the monthly one; shown
        // as a quiet subtitle only once real data has loaded, same pattern
        // as Claude's 5h line — a plan with unlimited/no weekly cap simply
        // never sets weeklyPct, so this stays hidden rather than showing 0%.
        let windows = [
            window("Rolling", state.rollingPct, reset: state.rollingReset.map { state.lastSync + $0 }, duration: 5 * 3600),
            window("Weekly", state.weeklyPct, reset: state.weeklyReset.map { state.lastSync + $0 }, duration: 7 * 86400),
            window("Monthly", state.monthlyPct, reset: state.monthlyReset.map { state.lastSync + $0 }, duration: 30 * 86400),
        ].compactMap { $0 }
        return statusRow(name: "OpenCode Go", status: status, tint: ToolKind.opencode.color,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix,
                         staleBadge: staleBadge,
                         windows: windows,
                         problem: state.error.map { RowProblem.from(service: "OpenCode Go", error: $0) })
    }

    /// Claude subscription quota, from the same OAuth usage endpoint Claude
    /// Code's own status line reads. Claude bills against two independent
    /// windows at once (a 5h rolling one and a weekly one). The weekly one
    /// is the number that matters day to day, so it takes the value column
    /// — same two-line shape (status + reset) as every other Quota row, so
    /// rows stay the same height. The 5h window goes under the name instead,
    /// as a quiet subtitle; it still turns the row critical (★) on its own
    /// if it's the one running low, even though it isn't the headline number.
    ///
    /// Claude's cadence (5min foreground-only, plus real backoff after a
    /// 429) means it sits without a fresh answer far more often than the
    /// other quota rows. A cached number that's a few minutes old is still
    /// useful; the word "Stale" on its own is not — so, matching how
    /// Command Code GOAT already handles this, the last known percentage
    /// stays on screen instead of being replaced by a status word, and a
    /// bare "Error" only appears once there's truly nothing cached to fall
    /// back on. The reset countdown on the second line is unaffected by any
    /// of this — it comes straight from the server and stays accurate
    /// whether or not the percentage above it is fresh, so it's shown as-is
    /// either way. Staleness gets its own small pill next to the percentage
    /// instead — a single signal, not a second one stacked on top via a
    /// dimmed color as well.
    private var claudeStatusRow: some View {
        let state = claudeQuota.state
        let weekly = state.sevenDay
        let remaining = weekly.map { 100 - $0.usedPercent }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = state.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        var staleBadge: String?
        if !claudeQuota.enabled {
            // Opt-in, off by default (see ClaudeQuotaClient) — distinct from
            // "Not configured" so it reads as a choice, not a missing login.
            status = "Off — enable in Settings"
        } else if let remaining, let weekly {
            status = "\(remaining)% weekly left"
            resetSuffix = resetText(weekly.resetAt)
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        }
        // The star has to sit on whichever number is actually low — the
        // weekly line if that's the tight one, the 5h/Opus subtitle if
        // that's the one about to run out, never just the primary line by
        // default regardless of which window earned it.
        return statusRow(name: claudeRowName, status: status, tint: ToolKind.claude.color,
                         statusColor: .primary,
                         critical: claudeQuota.enabled && (remaining.map { $0 < 20 } ?? false),
                         resetSuffix: resetSuffix,
                         subtitle: claudeQuota.enabled ? claudeSubtitle(state) : nil,
                         subtitleCritical: claudeQuota.enabled && state.hasCriticalSecondaryWindow,
                         staleBadge: staleBadge,
                         windows: claudeQuota.enabled ? claudeWindows(state) : [],
                         problem: claudeQuota.enabled
                             ? state.error.map { RowProblem.from(service: claudeRowName, error: $0) } : nil)
    }

    /// The 5h window (and, rarely, a weekly-Opus one) rendered as a compact
    /// caption under the name — "84% 5h left", joined with " · " if both are
    /// present. Shown whenever cached data exists, even mid-error or while
    /// stale — same "prefer the cached number" reasoning as the row above.
    /// Claude bills against 5h and weekly windows at once (plus, on some
    /// plans, a weekly Opus one) — each gets its own usage bar.
    private func claudeWindows(_ state: ClaudeQuotaClient.State) -> [QuotaWindow] {
        [
            state.fiveHour.flatMap { window("5h", Double($0.usedPercent), reset: $0.resetAt, duration: 5 * 3600) },
            state.sevenDay.flatMap { window("Weekly", Double($0.usedPercent), reset: $0.resetAt, duration: 7 * 86400) },
            state.sevenDayOpus.flatMap { window("Opus", Double($0.usedPercent), reset: $0.resetAt, duration: 7 * 86400) },
        ].compactMap { $0 }
    }

    /// A quota window: `usedPercent` always stores how much is used (0…100).
    private func window(_ label: String, _ usedPercent: Double?, reset: Int64?,
                         duration: Int64? = nil) -> QuotaWindow? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let resetIn = reset.flatMap { $0 > nowSeconds ? Format.remaining($0 - nowSeconds) : nil }
        // Share of the window already elapsed, from the reset time and the
        // window length; nil when either is unknown.
        let elapsed: Double? = {
            guard let reset, let duration, duration > 0, reset > nowSeconds else { return nil }
            return min(max(1 - Double(reset - nowSeconds) / Double(duration), 0), 1)
        }()
        return QuotaWindow(label: label, usedPercent: min(max(usedPercent, 0), 100),
                           resetIn: resetIn, elapsed: elapsed)
    }

    private var codexWindowShortLabel: String {
        guard let s = codexQuota.state.windowSeconds else { return "Limit" }
        if s >= 7 * 86400 { return "Weekly" }
        if s >= 86400 { return "\(s / 86400)d" }
        if s >= 3600 { return "\(s / 3600)h" }
        return "Limit"
    }

    private func claudeSubtitle(_ state: ClaudeQuotaClient.State) -> String? {
        let windows = [state.fiveHour, state.sevenDayOpus].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return windows.map { "\(100 - $0.usedPercent)% \($0.label) left" }.joined(separator: " · ")
    }

    /// "Claude Max" / "Claude Pro" when the plan is known, plain "Claude"
    /// otherwise — the credentials blob does not always carry a plan.
    private var claudeRowName: String {
        let plan = claudeQuota.state.planType?.lowercased() ?? ""
        if plan.contains("max") { return "Claude Max" }
        if plan.contains("pro") { return "Claude Pro" }
        return "Claude"
    }

    /// Window label derives from limit_window_seconds: 604800 = weekly (Plus today).
    private var windowLabel: String {
        guard let s = codexQuota.state.windowSeconds else { return "limit" }
        if s >= 7 * 86400 { return "weekly" }
        if s >= 86400 { return "every \(s / 86400) days" }
        if s >= 3600 { return "every \(s / 3600) hours" }
        return "limit"
    }

    private var codexStatusRow: some View {
        let state = codexQuota.state
        let remaining = state.primaryPct.map { 100 - Double($0) }
        // The plan picker stores "openai" for the ChatGPT/Codex subscription;
        // "codex" alone never matched anything a user could actually save.
        let sub = app.subscriptions.first { $0.plan == "openai" || $0.plan == "codex" }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        // Keep the last result while refreshing; Loading only before the first sync.
        var status = sub == nil
                    ? (codexQuota.enabled ? "Not configured" : "Off")
                    : (codexQuota.enabled && state.lastSync <= 0 ? "Loading" : "Idle")
        var resetSuffix: String?
        var staleBadge: String?
        if let remaining {
            status = "\(Int(remaining))% of \(windowLabel) left"
            resetSuffix = resetText(state.resetAt)
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if let sub {
            status = "Subscribed · \(Format.money(sub.price))/mo"
        }
        let name = CodexPlanName.resolve(custom: codexCustomName, apiPlan: state.planType,
                                         subscription: sub)
        return statusRow(name: name, status: status, tint: ToolKind.codex.color,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix,
                         staleBadge: staleBadge,
                         windows: [window(codexWindowShortLabel, state.primaryPct.map(Double.init),
                                          reset: state.resetAt,
                                          duration: state.windowSeconds.map(Int64.init))].compactMap { $0 },
                         problem: state.error.map { RowProblem.from(service: name, error: $0) })
    }

    /// Command Code GOAT quota (experimental private billing API).
    /// Shows the last good snapshot while a refresh is in flight — never a
    /// Stale interstitial — and replaces it when fresh data lands.
    private var commandCodeStatusRow: some View {
        let state = ccQuota.state
        let name = "Command Code GOAT"
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = state.configured ? "Loading" : "Not configured"
        var resetSuffix: String?
        var staleBadge: String?
        if let percent = state.monthlyUsedPercent {
            // Known plan: remaining = 100 − used. Cached value is shown
            // while refreshing; it updates in place when new data lands.
            status = "\(Int((100 - percent).rounded()))% monthly left"
            if let end = state.billingPeriodEnd {
                let remaining = end.timeIntervalSince1970 - now.timeIntervalSince1970
                if remaining > 0 {
                    resetSuffix = "resets in \(Format.remaining(Int64(remaining)))"
                }
            }
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if let remaining = state.monthlyCreditsRemaining {
            // Unknown plan or no allowance: show remaining only, no percent.
            status = "$\(Format.money(remaining)) left"
        } else if state.configured && state.lastSync <= 0 {
            status = "Loading"
        }
        return statusRow(name: name, status: status, tint: TMDesign.commandCode,
                         statusColor: .primary,
                         // Star = running low: remaining below 20% (used > 80%).
                         critical: state.monthlyUsedPercent.map { $0 > 80 } ?? false,
                         resetSuffix: resetSuffix,
                         staleBadge: staleBadge,
                         windows: [window("Monthly", state.monthlyUsedPercent,
                                          reset: state.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) },
                                          duration: 30 * 86400)].compactMap { $0 },
                         problem: state.error.map { RowProblem.from(service: name, error: $0) })
    }

    /// Grok's one weekly pool (Chat, Imagine, Build, Grok Bot), named after
    /// the linked subscription, else "Grok · <plan>" from the API. The subtitle splits the used
    /// share by product when the API reports it.
    private var grokStatusRow: some View {
        let state = grokQuota.state
        // A recorded subscription is named in full ("X Subscription
        // Premium"); the API only gives a tier, so that one gets "Grok · ".
        let recorded = GrokQuotaClient.plan(subscriptions: app.subscriptions, apiPlan: nil, now: now)
        let plan = recorded ?? state.planName.map { "Grok · \($0)" } ?? "Grok"
        let name = plan
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = state.configured ? "Loading" : (grokQuota.enabled ? "Not configured" : "Off")
        var resetSuffix: String?
        var staleBadge: String?
        if let used = state.usedPercent {
            status = "\(Int((100 - used).rounded()))% weekly left"
            resetSuffix = resetText(state.resetAt)
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastSync)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        }
        let breakdown = state.products
            .map { "\($0.displayName) \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: " · ")
        return statusRow(name: name, status: status, tint: TMDesign.grok,
                         statusColor: .primary,
                         critical: state.usedPercent.map { $0 > 80 } ?? false,
                         resetSuffix: resetSuffix,
                         subtitle: breakdown.isEmpty ? nil : breakdown,
                         staleBadge: staleBadge,
                         windows: [window("Weekly", state.usedPercent, reset: state.resetAt, duration: 7 * 86400)].compactMap { $0 },
                         problem: state.error.map { RowProblem.from(service: name, error: $0) })
    }

    private var routerStatusRow: some View {
        let state = orClient.state
        let stale = state.lastOK > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastOK) > 120
        var status: String
        var staleBadge: String?
        var runway: String?
        if !orClient.hasKey {
            status = "Not configured"
        } else if state.authInvalid {
            // Every key came back 401/403 — typically the key (or its
            // account) was deleted on openrouter.ai. A bare "Error" gave no
            // hint that the fix is re-adding a key, not waiting it out.
            status = "Key rejected"
        } else if let balance = state.accountBalance {
            status = Format.money(balance)
            let since = Int64(now.timeIntervalSince1970) - BalanceRunway.lookback
            runway = BalanceRunway.lowText(
                balance: balance,
                dailySpend: BalanceRunway.dailySpend(cumulative: Database.shared.orCreditUsage(since: since)))
            if stale {
                let age = now.timeIntervalSince1970 - TimeInterval(state.lastOK)
                staleBadge = "\(Format.remaining(Int64(age))) ago"
            }
        } else if state.error != nil {
            status = "Error"
        } else if state.isLoading && state.lastOK <= 0 {
            status = "Loading"
        } else {
            status = "Idle"
        }
        return statusRow(name: "OpenRouter", status: status,
                         statusColor: orClient.hasKey ? .primary : TMDesign.quiet,
                         critical: runway != nil || state.accountBalance.map { $0 <= 0 } == true,
                         staleBadge: staleBadge,
                         nameDetail: runway,
                         problem: routerProblem(state))
    }

    private func routerProblem(_ state: OpenRouterClient.State) -> RowProblem? {
        guard orClient.hasKey else { return nil }
        if state.authInvalid {
            return RowProblem(title: "OpenRouter rejected the key",
                              detail: "The key, or the account it belongs to, may have been deleted on "
                                  + "openrouter.ai. Add a new key in Settings › Accounts.",
                              opensSettings: true)
        }
        return state.error.map { RowProblem.from(service: "OpenRouter", error: $0) }
    }

    private var deepseekStatusRow: some View {
        let state = deepseek.state
        let stale = deepseek.stale(state.balanceUpdated, error: state.balanceError, now: now)
        let wallets = state.expired ? [] : state.balance?.wallets ?? []
        // One line, side by side; an empty wallet adds nothing. If every
        // wallet is empty, the first one still shows its zero.
        let funded = wallets.filter { $0.total.amount != 0 }
        let shown = funded.isEmpty ? Array(wallets.prefix(1)) : funded
        let balance = shown.isEmpty ? nil : shown.map { $0.total.symbolFormatted }.joined(separator: "  ·  ")
        return statusRow(name: "DeepSeek", status: balance ?? deepseek.balanceText,
                         statusColor: state.kind == nil ? TMDesign.quiet : .primary,
                         critical: state.balance?.available == false || deepseekLow(shown) != nil,
                         subtitle: state.balance?.available == false ? "Unavailable for API calls" : nil,
                         staleBadge: stale ? "Stale" : nil,
                         nameDetail: deepseekLow(shown),
                         problem: deepseekProblem(state))
    }

    private func deepseekProblem(_ state: DeepSeekBillingClient.State) -> RowProblem? {
        if state.expired {
            return RowProblem(title: "DeepSeek sign-in expired",
                              detail: "Sign in to DeepSeek again in Settings › Accounts.",
                              opensSettings: true)
        }
        return state.balanceError.map { RowProblem.from(service: "DeepSeek", error: $0) }
    }

    /// "3.2d left" when the DeepSeek balance is running out. Platform
    /// logins report this month's spend directly; API-key logins fall back
    /// to how the recorded balance has been falling. Several funded wallets
    /// have no single answer, so they say nothing.
    private func deepseekLow(_ shown: [DeepSeekBilling.Wallet]) -> String? {
        guard shown.count == 1 else { return nil }
        let wallet = shown[0].total
        let balance = NSDecimalNumber(decimal: wallet.amount).doubleValue
        let nowSeconds = Int64(now.timeIntervalSince1970)
        var daily: Double?
        if let spend = deepseek.spend(for: .month, configuration: periodSettings.configuration, now: now),
           nowSeconds - spend.window.start >= BalanceRunway.minCoverage {
            let spent = spend.amounts.first { $0.currency == wallet.currency }
                .map { NSDecimalNumber(decimal: $0.amount).doubleValue } ?? 0
            daily = spent / Double(nowSeconds - spend.window.start) * 86_400
        } else {
            daily = BalanceRunway.dailySpend(balances: Database.shared.deepSeekBalances(
                currency: wallet.currency, since: nowSeconds - BalanceRunway.lookback))
        }
        return BalanceRunway.lowText(balance: balance, dailySpend: daily)
    }

    /// The balance text when the account needs nothing from the user —
    /// fresh, positive, not running out, no error. Nil sends it to a full row.
    private func calmBalance(_ key: String) -> String? {
        switch key {
        case "router":
            let state = orClient.state
            guard orClient.hasKey, !state.authInvalid, state.error == nil,
                  let balance = state.accountBalance, balance > 0,
                  now.timeIntervalSince1970 - TimeInterval(state.lastOK) <= 120 else { return nil }
            let since = Int64(now.timeIntervalSince1970) - BalanceRunway.lookback
            let low = BalanceRunway.lowText(
                balance: balance,
                dailySpend: BalanceRunway.dailySpend(cumulative: Database.shared.orCreditUsage(since: since)))
            return low == nil ? Format.money(balance) : nil
        case "deepseek":
            let state = deepseek.state
            guard state.kind != nil, !state.expired, state.balanceError == nil,
                  let wallets = state.balance?.wallets, state.balance?.available != false,
                  !deepseek.stale(state.balanceUpdated, error: state.balanceError, now: now) else { return nil }
            let funded = wallets.filter { $0.total.amount > 0 }
            guard !funded.isEmpty, deepseekLow(funded) == nil else { return nil }
            return funded.map { $0.total.symbolFormatted }.joined(separator: " · ")
        default:
            return nil
        }
    }

    private func statusRow(name: String, status: String, tint: Color = .accentColor,
                           statusColor: Color,
                           critical: Bool = false, resetSuffix: String? = nil,
                           subtitle: String? = nil, subtitleCritical: Bool = false,
                           staleBadge: String? = nil,
                           windows: [QuotaWindow] = [],
                           nameDetail: String? = nil,
                           problem: RowProblem? = nil) -> some View {
        StatusRow(name: name, status: status, statusColor: statusColor,
                  critical: critical, resetSuffix: resetSuffix, subtitle: subtitle,
                  subtitleCritical: subtitleCritical, staleBadge: staleBadge,
                  windows: windows, nameDetail: nameDetail, problem: problem, tint: tint)
    }

}

/// Trend line chart. Hover state lives here, so hovering re-renders only
/// this view; the readout row above the chart keeps a fixed height.
private struct TrendChartView: View {
    /// Daily usage for the last 60 days (today included), oldest first.
    let series: [(key: Int64, tokens: Int64)]

    @State private var hoveredTrend: (key: Int64, tokens: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let h = hoveredTrend {
                    Text("\(shortDayFormatter.string(from: dayFromKey(h.key))) · \(Format.compact(h.tokens))")
                        .font(TMType.number(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
                Spacer()
            }
            .frame(height: 16)
            // Monotone, as on the Performance page: a curve that overshoots
            // would show usage that never happened. The persisted heatmap cache
            // covers the cold start; fresh data replaces it asynchronously.
            Chart(series, id: \.key) { d in
                AreaMark(
                    x: .value("Day", dayFromKey(d.key)),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(TMDesign.accent.opacity(0.16))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Day", dayFromKey(d.key)),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(TMDesign.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            .chartXAxis {
                // Three date labels, colored like the Activity month labels.
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        .font(.system(size: 10))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
            .chartYAxis(.hidden)
            .frame(maxHeight: .infinity)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let date = proxy.value(atX: location.x, as: Date.self) else { return }
                                let day = Calendar.current.startOfDay(for: date)
                                if let hit = series.first(where: {
                                    Calendar.current.isDate(dayFromKey($0.key), inSameDayAs: day)
                                }) {
                                    hoveredTrend = hit
                                } else {
                                    hoveredTrend = nil
                                }
                            case .ended:
                                hoveredTrend = nil
                            }
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily usage trend")
            .accessibilityChildren {
                ForEach(series, id: \.key) { day in
                    Text(shortDayFormatter.string(from: dayFromKey(day.key)))
                        .accessibilityValue("\(Format.full(day.tokens)) tokens")
                }
            }
        }
    }
}

/// The period choices replace the visible dashboard content, so on macOS 27
/// this is a tabs control rather than an inspector-style value picker. The
/// tabs role is also what supplies the native draggable Liquid Glass selection
/// island shown by system apps. The control draws all chrome itself; there is
/// no material or glass wrapper.
private struct NativePeriodSelector: NSViewRepresentable {
    @Binding var selection: PopoverHomeView.Period
    var labels: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.selectedSegment = selectedIndex
        control.controlSize = Self.nativeSize
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        control.setAccessibilityLabel("Period")
        control.setAccessibilityHelp("Changes the usage time range")
        return control
    }

    /// Takes the width it is offered and claims none of its own. Its
    /// intrinsic width (366 pt with these labels) is wider than a card, and
    /// once the panel measured its content's ideal width that pushed every
    /// card past the panel's right inset.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: control.intrinsicContentSize.height)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, label) in labels.enumerated() where index < control.segmentCount {
            if control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
            }
        }
        // SwiftUI can push the root `.small` environment into the control
        // after makeNSView; reassert the native size.
        if control.controlSize != Self.nativeSize {
            control.controlSize = Self.nativeSize
            control.invalidateIntrinsicContentSize()
        }
        if control.selectedSegment != selectedIndex {
            control.selectedSegment = selectedIndex
        }
    }

    /// The system's metric for a value-selection capsule: extra-large
    /// (36 pt) on macOS 26 and later, large (28 pt) before.
    private static var nativeSize: NSControl.ControlSize {
        if #available(macOS 26.0, *) { return .extraLarge }
        return .large
    }

    private var selectedIndex: Int {
        PopoverHomeView.Period.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PopoverHomeView.Period>

        init(selection: Binding<PopoverHomeView.Period>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let periods = PopoverHomeView.Period.allCases
            guard periods.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = periods[sender.selectedSegment]
        }
    }
}


/// Drives the hero number transition: any change to the token count OR the
/// compact/full format toggle re-runs the same numericText animation.
private struct HeroValue: Equatable {
    let tokens: Int64
    let full: Bool
}

/// Quota status row: primary name, status colored by health. Information only.
/// Status text is SF Pro with tabular digits; the optional "resets in …"
/// suffix alone is SF Mono, so the whole row is not monospaced.
private struct StatusRow: View {
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false
    let name: String
    let status: String
    let statusColor: Color
    var critical = false
    /// Now sits under the name rather than under the value, so the name
    /// column and the value column both read top-to-bottom as "headline,
    /// then detail" — name/when on the left, percent/percent on the right.
    var resetSuffix: String?
    /// A quiet second value under the primary one — for a source that bills
    /// against more than one window at once (Claude's 5h + weekly), this
    /// carries the window not already shown as the primary value.
    var subtitle: String?
    /// Puts the ★ on the subtitle line instead of the status line — for a
    /// source with more than one window, the one running low isn't always
    /// the one shown as the primary value, and the star has to follow
    /// whichever number actually earned it.
    var subtitleCritical = false
    /// A small pill next to the status text (e.g. "6m ago") flagging that
    /// the number is cached rather than fresh. Deliberately a capsule, not
    /// plain text appended to the status string — plain text read as part
    /// of the sentence and was easy to miss at a glance; a distinct chip
    /// reads as metadata immediately.
    var staleBadge: String?
    /// Usage windows with live numbers. When present the row becomes
    /// "name + one bar per window"; the plain status text is only for
    /// states without numbers (Loading / Error / Off / Subscribed).
    var windows: [QuotaWindow] = []
    /// Quiet text on the name's line, right after it (a balance's days left).
    var nameDetail: String?
    /// Why the row could not refresh; shown as a "?" after the name.
    var problem: RowProblem?
    /// The service's color; every window bar of one service shares it.
    var tint: Color = .accentColor

    var body: some View {
        Group {
            if windows.isEmpty {
                content
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    ForEach(windows, id: \.label) { window in
                        QuotaWindowLine(window: window, tint: tint)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Text(windows.isEmpty
            ? [status, resetSuffix].compactMap { $0 }.joined(separator: " · ")
            : windows.map { showsRemaining
                ? "\($0.label) \(Int((100 - $0.usedPercent).rounded()))% left"
                : "\($0.label) \(Int($0.usedPercent.rounded()))% used" }.joined(separator: ", ")))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(TMType.medium(TMType.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let problem { RowProblemButton(problem: problem) }
            Spacer(minLength: 8)
            if let staleBadge {
                Text(staleBadge)
                    .font(TMType.number(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
            }
        }
        .frame(height: TMLayout.quotaPrimaryLineHeight)
    }

    /// Only rows that actually carry a detail line reserve its height; a
    /// single-value row (OpenRouter's balance) stays one line tall.
    private var hasSecondLine: Bool { resetSuffix != nil || subtitle != nil }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Fixed two-line height: an empty Text collapses to zero, so an explicit
            // frame keeps the row height constant from Loading to data.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(TMType.medium(TMType.body))
                        .foregroundStyle(.primary)
                    if let problem { RowProblemButton(problem: problem) }
                    if let nameDetail {
                        Text(nameDetail)
                            .font(TMType.number(TMType.caption))
                            .foregroundStyle(critical ? TMDesign.danger : TMDesign.quiet)
                    }
                }
                .lineLimit(1)
                .frame(height: TMLayout.quotaPrimaryLineHeight, alignment: .leading)
                if hasSecondLine {
                    Text(resetSuffix ?? "")
                        .font(TMType.number(TMType.micro))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                        .frame(height: TMLayout.quotaSecondaryLineHeight, alignment: .leading)
                        .opacity(resetSuffix == nil ? 0 : 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    // Badge first, status text last: the HStack is
                    // trailing-aligned, so the status text's right edge —
                    // where every other row's number also lands — never
                    // moves whether or not the badge is present.
                    if let staleBadge {
                        Text(staleBadge)
                            .font(TMType.number(TMType.micro))
                            .foregroundStyle(TMDesign.quiet)
                    }
                    if critical {
                        TMStatusCapsule(text: status, compact: true)
                            .lineLimit(1)
                    } else {
                        Text(status)
                            .font(TMType.number(TMType.body))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                }
                .frame(height: TMLayout.quotaPrimaryLineHeight, alignment: .trailing)
                if hasSecondLine {
                    Text((subtitleCritical ? "★ " : "") + (subtitle ?? ""))
                        .font(TMType.number(TMType.micro))
                        .foregroundStyle(TMDesign.quiet)
                        .lineLimit(1)
                        .frame(height: TMLayout.quotaSecondaryLineHeight, alignment: .trailing)
                        .opacity(subtitle == nil ? 0 : 1)
                }
            }
            .layoutPriority(1)
        }
    }
}

/// Healthy balances, one compact row each — the same name-left,
/// amount-right rows and spacing as the Sources card.
private struct BalanceLine: View {
    let items: [(name: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.name) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(TMType.medium(TMType.body))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(item.value)
                        .font(TMType.number(TMType.body))
                        .foregroundStyle(TMDesign.quiet)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private enum HistoryMode: String, CaseIterable {
    case heatmap, trend

    var symbol: String { self == .heatmap ? "square.grid.3x3.fill" : "chart.xyaxis.line" }
    var title: String { self == .heatmap ? "Heatmap" : "Trend" }
}

/// Icon-only NSSegmentedControl for the Activity card, styled like
/// `NativePeriodSelector`.
private struct NativeHistorySelector: NSViewRepresentable {
    @Binding var selection: HistoryMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let modes = HistoryMode.allCases
        let control = NSSegmentedControl(
            images: modes.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)))
        control.controlSize = .small
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        for (index, mode) in modes.enumerated() {
            control.setToolTip(mode.title, forSegment: index)
        }
        control.selectedSegment = modes.firstIndex(of: selection) ?? 0
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = HistoryMode.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<HistoryMode>
        init(selection: Binding<HistoryMode>) { self.selection = selection }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let modes = HistoryMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}

/// Popover section card: faint tonal fill, continuous corners, and a title
/// row. Which cards appear is a Settings › Appearance choice.
private struct PopoverCard<Accessory: View, Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    // Title case, matching the dashboard cards.
                    Text(title)
                        .font(TMType.semibold(12))
                    accessory
                    Spacer(minLength: 6)
                    trailing
                }
                .frame(height: 16)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TMLayout.popoverCardPadding)
        // Fill only: a hairline brighter than the fill reads as a lit rim
        // on the vibrant panel; grouped surfaces separate by tone alone.
        .background(Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct QuotaWindow {
    /// Settings key: true shows how much of each window is left instead of
    /// how much is used.
    static let showsRemainingKey = "popoverQuotaShowsRemaining"

    let label: String
    /// 0…100, how much of the window is used.
    let usedPercent: Double
    /// Compact countdown ("3.9d", "2.1h"), nil once passed / unknown.
    let resetIn: String?
    /// 0…1, how much of the window's time has passed; nil if unknown.
    var elapsed: Double?

    /// What a number or bar shows, 0…100, in the selected used or remaining mode.
    static func shownPercent(used: Double, showsRemaining: Bool) -> Double {
        showsRemaining ? 100 - used : used
    }

    /// The time the bar compares against. Pace is a reading of usage, so the
    /// remaining mode is a plain gauge without it.
    func barElapsed(showsRemaining: Bool) -> Double? {
        showsRemaining ? nil : elapsed
    }
}

/// ```
/// 5h · resets in 4.3h                29%
/// ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
/// ```
/// The reset belongs to the window, so it sits with the window's name; the
/// number sits at the end of the bar it measures, and the bar gets the full
/// row width instead of being squeezed between columns.
private struct QuotaWindowLine: View {
    let window: QuotaWindow
    let tint: Color
    @AppStorage(QuotaWindow.showsRemainingKey) private var showsRemaining = false

    private var shownPercent: Double {
        QuotaWindow.shownPercent(used: window.usedPercent, showsRemaining: showsRemaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Fixed label column so every "resets in" starts on the same
                // vertical line, whether the window is "5h" or "Monthly".
                Text(window.label)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                    .frame(width: 58, alignment: .leading)
                if let resetIn = window.resetIn {
                    Text("resets in \(resetIn)")
                        .font(TMType.number(TMType.caption))
                        .foregroundStyle(TMDesign.quiet)
                }
                Spacer(minLength: 8)
                Text("\(Int(shownPercent.rounded()))%")
                    .font(TMType.number(TMType.caption, weight: .medium))
                    .foregroundStyle(.primary)
            }
            QuotaBar(fillPercent: shownPercent,
                     tint: tint,
                     elapsed: window.barElapsed(showsRemaining: showsRemaining))
        }
    }
}

/// Quota bar: fills rightward to the selected used or remaining percentage.
/// Filled with the service's color at every usage level.
///
/// With a time mark, solid color runs to whichever comes first, usage or
/// elapsed time; the stretch between the two is one step lighter. Behind
/// time it is a darker track (headroom); past time it is a paler fill
/// (using the window faster than it passes). Either way the solid edge is
/// the time mark, so it never disappears under the fill.
private struct QuotaBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0…100, in the selected used or remaining mode.
    let fillPercent: Double
    let tint: Color
    /// 0…1 share of the window's time already passed; nil draws a plain gauge.
    var elapsed: Double?

    var body: some View {
        let fill = min(max(fillPercent / 100, 0), 1)
        GeometryReader { geo in
            let fillWidth = fill > 0 ? max(geo.size.width * fill, 4) : 0
            let timeWidth = elapsed.map { $0 > 0 ? max(geo.size.width * min($0, 1), 4) : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                if let timeWidth, fillWidth > timeWidth {
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: fillWidth)
                    Capsule()
                        .fill(tint)
                        .frame(width: timeWidth)
                } else {
                    if let timeWidth, timeWidth > 0 {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: timeWidth)
                    }
                    Capsule()
                        .fill(tint)
                        .frame(width: fillWidth)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fill)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Composition bar for Sources: the parts always fill the whole width, each
/// its own rounded segment with a gap between, like the storage bar in
/// System Settings. Deliberately unlike `QuotaBar`, which is a gauge on an
/// empty track.
struct SourceBar: View {
    static let gap: CGFloat = 2
    static let minSegment: CGFloat = 4

    let segments: [(value: Double, color: Color)]

    var body: some View {
        let visible = segments.filter { $0.value > 0 }
        GeometryReader { geo in
            let widths = Self.widths(for: visible.map(\.value), in: geo.size.width)
            HStack(spacing: Self.gap) {
                ForEach(visible.indices, id: \.self) { i in
                    Capsule()
                        .fill(visible[i].color)
                        .frame(width: widths[i])
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    /// Proportional widths that, with the gaps, sum to `width`. Every segment
    /// gets at least `minSegment` so a tiny share stays a visible pill; the
    /// difference comes out of the larger segments.
    static func widths(for values: [Double], in width: CGFloat) -> [CGFloat] {
        let total = values.reduce(0, +)
        guard !values.isEmpty, total > 0 else { return [] }
        let available = max(width - gap * CGFloat(values.count - 1), 0)
        let floor = min(minSegment, available / CGFloat(values.count))
        var widths = values.map { max(available * CGFloat($0 / total), floor) }
        let excess = widths.reduce(0, +) - available
        let slack = widths.reduce(0) { $0 + ($1 - floor) }
        if excess > 0, slack > 0 {
            widths = widths.map { $0 - excess * ($0 - floor) / slack }
        }
        return widths
    }
}

/// Spent / Value under the hero figure: a secondary label and its value as
/// plain text. No capsule: a filled capsule reads as a button on macOS, and
/// these are not clickable.
private struct HeroChip: View {
    let label: String
    let value: String
    var problem: RowProblem?

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Text(label)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                Text(value)
                    .font(TMType.number(TMType.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(Text(value))
            if let problem { RowProblemButton(problem: problem) }
        }
    }
}

/// Every quota source that was never set up, folded into one line instead of
/// a full "Not configured" row each.
private struct UnconnectedSourcesRow: View {
    let names: [String]
    let setUp: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                Text(names.joined(separator: " · "))
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Set Up…", action: setUp)
                .controlSize(.small)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not connected: \(names.joined(separator: ", "))")
    }
}

/// Compact activity heatmap for the popover: 24 weeks × 7 days, month
/// labels above the grid, and a hover readout row.
struct PopoverHeatmap: View {
    let weeks: [[Int64?]]
    let heatmap: [Int64: Int64]

    /// 24 weeks keeps cells large enough with a 2 pt gutter.
    static let weekCount = 24
    /// Vertical gap between the month labels and the grid.
    private static let labelGap: CGFloat = 16
    private static let cellGutter: CGFloat = 2
    private var labelGap: CGFloat { Self.labelGap }
    private var cellGutter: CGFloat { Self.cellGutter }

    /// Grid cells divide the card content width evenly.
    static var gridHeight: CGFloat {
        let contentWidth = TMLayout.popoverCardContentWidth
        let cell = max((contentWidth - CGFloat(weekCount - 1) * cellGutter) / CGFloat(weekCount), 2)
        return labelGap + 7 * cell + 6 * cellGutter
    }

    /// The trend view reuses it so the card keeps one height in both modes.
    static var totalHeight: CGFloat { gridHeight }

    /// Opacity of the accent for levels 1…4 — one hue, light to strong.
    static let levelOpacity: [Double] = [0.28, 0.5, 0.75, 1]

    /// Quartile cut points of the active days' totals. Levels follow rank,
    /// not share of the peak, so one huge day can't flatten every other day
    /// into the same shade.
    static func thresholds(_ values: [Int64]) -> [Int64] {
        let active = values.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return [] }
        return [1, 2, 3].map { active[min(active.count - 1, active.count * $0 / 4)] }
    }

    /// 0 for no usage, else 1…4 by quartile.
    static func level(_ value: Int64, thresholds: [Int64]) -> Int {
        guard value > 0 else { return 0 }
        return 1 + thresholds.filter { value >= $0 }.count
    }

    /// Month labels sit on each month's first column; the first label is
    /// dropped when it would overlap the next.
    private var monthLabels: [(index: Int, label: String)] {
        var out: [(Int, String)] = []
        var lastMonth = -1
        for (wi, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = Int((first / 100) % 100)
            guard month != lastMonth, (1...12).contains(month) else { continue }
            lastMonth = month
            out.append((wi, MonthAxis.names[month - 1]))
        }
        if out.count > 1, out[1].0 - out[0].0 < 3 { out.removeFirst() }
        return out
    }

    var body: some View {
        let cuts = Self.thresholds(weeks.joined().compactMap { $0.flatMap { heatmap[$0] } })
        GeometryReader { geo in
            let cell = max((geo.size.width - CGFloat(weeks.count - 1) * cellGutter) / CGFloat(weeks.count), 2)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: cellGutter) {
                    ForEach(weeks.indices, id: \.self) { wi in
                        VStack(spacing: cellGutter) {
                            ForEach(0..<7, id: \.self) { di in
                                heatCell(weeks[wi][di], size: cell, thresholds: cuts)
                            }
                        }
                    }
                }
                .padding(.top, labelGap)
                ForEach(monthLabels, id: \.index) { m in
                    Text(m.label)
                        .font(TMType.number(9))
                        .foregroundStyle(TMDesign.quiet)
                        .fixedSize()
                        .offset(x: CGFloat(m.index) * (cell + cellGutter), y: 0)
                }
            }
        }
        .frame(height: Self.gridHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity heatmap, last \(Self.weekCount) weeks")
    }

    private func heatCell(_ key: Int64?, size: CGFloat, thresholds: [Int64]) -> some View {
        let v = key.flatMap { heatmap[$0] } ?? 0
        let level = Self.level(v, thresholds: thresholds)
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(level > 0
                  ? TMDesign.accent.opacity(Self.levelOpacity[level - 1])
                  : Color.primary.opacity(0.08))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(key.map { shortDayFormatter.string(from: dayFromKey($0)) } ?? "")
            .accessibilityValue("\(Format.full(v)) tokens")
            .accessibilityHidden(key == nil)
    }
}
