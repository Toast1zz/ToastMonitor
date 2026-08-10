import SwiftUI
import Combine
import AppKit

/// Compact, single-purpose menu bar home. It answers three questions quickly:
/// how much was used, where it came from, and whether a limit needs attention.
struct PopoverHomeView: View {
    static let testPeriodNotification = Notification.Name("tmTestPopoverPeriod")

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case month = "30 Days"
        case all = "All Time"
        var id: String { rawValue }
    }

    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @State private var period: Period = .today
    /// Drives countdown refresh (resets etc.) once a minute.
    @State private var now = Date()
    /// Full-number mode (1,234,567 instead of 1.2M) — switch to watch the
    /// counter tick up during streaming.
    @AppStorage("popoverFullTokens") private var fullTokens = false
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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

    var body: some View {
        VStack(spacing: 0) {
            // Keep the period selector outside the scroll view. Long 7-day
            // and 30-day pages may need to scroll after the panel reaches the
            // screen-height limit, but the selector must always remain visible.
            periodControl
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                // Defer past the first layout pass: the initial
                                // size can be a stale viewport value, which
                                // made the panel height wrong until a period
                                // switch re-measured it.
                                DispatchQueue.main.async {
                                    postPanelHeight(kind: "pinned", height: geo.size.height)
                                }
                            }
                            .onChange(of: geo.size.height) { _, h in
                                postPanelHeight(kind: "pinned", height: h)
                            }
                    }
                )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .padding(.bottom, 12)
                    sourceBar
                        .padding(.bottom, 14)
                    Divider().opacity(0.4)
                    quotaSection
                        .padding(.top, 14)
                }
                .padding(.horizontal, 20)
                // A ScrollView normally accepts the viewport's proposed
                // height, which made every period report the same 684pt panel
                // height. Force the document to keep its natural vertical
                // size so 7-day / 30-day pages can actually grow the panel.
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                DispatchQueue.main.async {
                                    postPanelHeight(kind: "body", height: geo.size.height)
                                }
                            }
                            .onChange(of: geo.size.height) { _, h in
                                postPanelHeight(kind: "body", height: h)
                            }
                    }
                )
            }
            .onChange(of: period) { _, _ in
                // Reset the underlying NSClipView after SwiftUI updates the
                // document and PanelController resizes the NSPanel.
                NotificationCenter.default.post(
                    name: PanelController.resetScrollNotification,
                    object: nil
                )
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(minuteTicker) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: Self.testPeriodNotification)) { note in
            guard let raw = note.object as? String else { return }
            switch raw {
            case "week": period = .week
            case "month": period = .month
            default: period = .today
            }
        }
    }

    /// Hero: the decision number is TOKENS. Below it, Spent and Value
    /// (official-rate revaluation) each get their own row.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fullTokens ? Format.full(tokens) : Format.compact(tokens))
                    .font(TMType.bold(34))
                    .tmMonospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: Double(tokens)))
                    // Both the token count and the display format drive the
                    // transition, so toggling 缩写/完整 animates the same way
                    // as a live token update.
                    .animation(.easeOut(duration: 0.35), value: HeroValue(tokens: tokens, full: fullTokens))
                    .accessibilityLabel("\(period.rawValue) token usage")
                    .accessibilityValue(Text("\(Format.full(tokens)) tokens"))
                Text("tokens")
                    .font(TMType.regular(13))
                    .foregroundStyle(.tertiary)
                Button {
                    fullTokens.toggle()
                } label: {
                    Image(systemName: fullTokens ? "number.circle.fill" : "number.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.faint)
                }
                .buttonStyle(.borderless)
                .help(fullTokens ? "Showing full number; click for compact (1.2M)" : "Showing compact number; click for full")
                .accessibilityLabel("Toggle number format")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Spent")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                    Text(actualShown > 0 ? Format.money(actualShown) : "—")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Spent")
                .accessibilityValue(Text(actualShown > 0 ? Format.money(actualShown) : "—"))
                HStack(spacing: 6) {
                    Text("Value")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                    Text(estimatedShown > 0 ? Format.money(estimatedShown) : "—")
                        .font(TMType.monoRegular(12))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Value")
                .accessibilityValue(Text(estimatedShown > 0 ? Format.money(estimatedShown) : "—"))
            }
        }
    }

    private var periodControl: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { p in
                Button {
                    period = p
                } label: {
                    Text(p.rawValue)
                        .font(TMType.medium(13))
                        .foregroundStyle(period == p ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(period == p ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.rawValue)
                .accessibilityValue(period == p ? "Selected" : "Not selected")
                .accessibilityAddTraits(period == p ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// 实际支出 = turns 实际 + OpenRouter 今日实际 + 全部订阅摊销。
    private var actualShown: Double {
        cost.actual + periodOrUsage + subsAmortized
    }

    /// API 价值 = 全部工具（含 hermes）turns 按模型官方单价重估。
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
        // OpenRouter 只提供月窗口；全部时按最近月近似。
        case .all: orClient.state.usageMonthly
        }
    }

    private var subsAmortized: Double {
        let days: Int
        switch period {
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        // 全部：10 年窗口覆盖全部订阅期（含已结束的），全额计入。
        case .all: days = 3650
        }
        return SubscriptionMath.amortized(days: days, subscriptions: app.subscriptions)
    }

    /// 来源分段条 + 每来源一行（行尾直接显示占比，无隐式交互）。
    private var sourceBar: some View {
        let rows = sortedRows
        let total = rows.reduce(Int64(0)) {
            $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
        return VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No source data yet")
                    .font(.caption)
                    .foregroundStyle(TMDesign.quiet)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // 轨道：系统低层级填充（不发光）
                        Capsule().fill(Color.primary.opacity(0.06))
                        HStack(spacing: 0) {
                            ForEach(rows, id: \.tool) { row in
                                let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
                                let ratio = total > 0 ? CGFloat(value) / CGFloat(total) : 0
                                Rectangle()
                                    .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                                    .frame(width: geo.size.width * ratio)
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)

                ForEach(rows, id: \.tool) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                            .frame(width: 7, height: 7)
                        Text(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                            .font(TMType.medium(TMType.body))
                            .italic()
                            .foregroundStyle(.primary)
                        Text("(\(percentText(row, total: total)))")
                            .font(TMType.monoRegular(TMType.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.compact(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)))
                            .font(TMType.monoRegular(TMType.body))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                    .accessibilityValue(Text("\(Format.full(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output))) tokens, \(percentText(row, total: total)) of total"))
                }
            }
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

    // MARK: - 额度状态（实时账户快照，与所选周期无关）

    /// Quota/balance is a live account snapshot — it only changes as time
    /// passes, never with the selected period. Showing it inside the period
    /// switcher implied it varied per dimension, so it now lives in its own
    /// fixed section below the period content, labelled as such.
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Quota")
                .font(TMType.semibold(13))
                .foregroundStyle(.primary)
            goStatusRow
            codexStatusRow
            routerStatusRow
        }
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
        var status = "Not configured"
        var resetSuffix: String?
        if goClient.configured {
            if state.error != nil {
                status = "Error"
            } else if stale {
                status = "Stale"
            } else if let remaining {
                status = "\(Int(remaining))% left"
                resetSuffix = resetText(state.monthlyReset.map { state.lastSync + $0 })
            } else if state.isLoading {
                status = "Loading"
            } else {
                status = "Idle"
            }
        }
        return statusRow(name: "OpenCode Go", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix)
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
        let sub = app.subscriptions.first { $0.plan == "codex" }
        let stale = state.lastSync > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastSync) > 120
        var status = sub == nil ? "Not configured" : "Loading"
        var resetSuffix: String?
        if state.error != nil {
            status = "Error"
        } else if stale, state.primaryPct != nil {
            status = "Stale"
        } else if let remaining {
            status = "\(Int(remaining))% of \(windowLabel) left"
            resetSuffix = resetText(state.resetAt)
        } else if let sub {
            status = "Subscribed · \(Format.money(sub.price))/mo"
        }
        return statusRow(name: "Codex Plus", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false,
                         resetSuffix: resetSuffix)
    }

    private var routerStatusRow: some View {
        let state = orClient.state
        let stale = state.lastOK > 0
            && now.timeIntervalSince1970 - TimeInterval(state.lastOK) > 120
        let status: String
        if !orClient.hasKey {
            status = "Not configured"
        } else if state.error != nil {
            status = "Error"
        } else if stale {
            status = "Stale"
        } else if let balance = state.accountBalance {
            status = "Balance \(Format.money(balance))"
        } else if state.isLoading {
            status = "Loading"
        } else {
            status = "Idle"
        }
        return statusRow(name: "OpenRouter", status: status,
                         statusColor: orClient.hasKey ? .primary : TMDesign.quiet)
    }

    private func statusRow(name: String, status: String, statusColor: Color,
                           critical: Bool = false, resetSuffix: String? = nil) -> some View {
        StatusRow(name: name, status: status, statusColor: statusColor,
                  critical: critical, resetSuffix: resetSuffix)
    }

    /// Post a measured height slice straight to the panel controller.
    /// Notifications bypass SwiftUI's preference chain, which is unreliable
    /// across ScrollView boundaries (the pinned slice was stuck at 0 and the
    /// bottom rows — OpenRouter — got cut off).
    private func postPanelHeight(kind: String, height: CGFloat) {
        NotificationCenter.default.post(
            name: PanelController.contentHeightNotification,
            object: nil,
            userInfo: ["kind": kind, "height": height]
        )
    }
}


/// Drives the hero number transition: any change to the token count OR the
/// 缩写/完整 format toggle re-runs the same numericText animation.
private struct HeroValue: Equatable {
    let tokens: Int64
    let full: Bool
}

/// 额度状态行：名称 primary，状态按健康状态着色。纯信息行，不引导跳转。
/// 状态主文本是 SF Pro Regular + 等宽数字；可选的 "resets in …" 后缀单独用
/// SF Mono Regular，不让整行变成等宽。
private struct StatusRow: View {
    let name: String
    let status: String
    let statusColor: Color
    var critical = false
    var resetSuffix: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(TMType.medium(TMType.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text((critical ? "★ " : "") + status)
                    .font(TMType.monoRegular(TMType.body))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if let resetSuffix {
                    Text(resetSuffix)
                        .font(TMType.monoRegular(TMType.micro))
                        .foregroundStyle(statusColor.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Text([status, resetSuffix].compactMap { $0 }.joined(separator: " · ")))
    }
}
