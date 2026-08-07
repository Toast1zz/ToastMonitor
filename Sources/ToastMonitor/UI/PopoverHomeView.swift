import SwiftUI
import AppKit

/// Compact, single-purpose menu bar home. It answers three questions quickly:
/// how much was used, where it came from, and whether a limit needs attention.
struct PopoverHomeView: View {
    static let testPeriodNotification = Notification.Name("tmTestPopoverPeriod")

    enum Period: String, CaseIterable, Identifiable {
        case today = "今日"
        case week = "7 天"
        case month = "近 30 天"
        case all = "全部"
        var id: String { rawValue }
    }

    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var codexQuota = CodexQuotaClient.shared
    @ObservedObject private var health = SourceHealthHub.shared
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
                            .onAppear { postPanelHeight(kind: "pinned", height: geo.size.height) }
                            .onChange(of: geo.size.height) { h in
                                postPanelHeight(kind: "pinned", height: h)
                            }
                    }
                )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .padding(.bottom, 12)
                    sourceBar
                        .padding(.bottom, 12)
                    metricsTable
                        .padding(.bottom, 14)
                    Divider()
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
                            .onAppear { postPanelHeight(kind: "body", height: geo.size.height) }
                            .onChange(of: geo.size.height) { h in
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

    /// Hero: the decision number is TOKENS. Spend lives in the table below.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fullTokens ? Format.full(tokens) : Format.compact(tokens))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: Double(tokens)))
                    .animation(.easeOut(duration: 0.35), value: tokens)
                Text("tokens")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TMDesign.quiet)
                Button {
                    fullTokens.toggle()
                } label: {
                    Image(systemName: fullTokens ? "number.circle.fill" : "number.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.faint)
                }
                .buttonStyle(.borderless)
                .help(fullTokens ? "当前为完整数字，点击切换为缩写 (1.2M)" : "当前为缩写，点击切换为完整数字")
                .accessibilityLabel("切换数字格式")
            }
            Text("\(Format.count(totals.count)) 次调用")
                .font(.caption2)
                .foregroundStyle(TMDesign.quiet)
        }
    }

    private var periodControl: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { p in
                Button {
                    period = p
                } label: {
                    Text(p.rawValue)
                        .font(.subheadline.weight(period == p ? .semibold : .regular))
                        .foregroundStyle(period == p ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(period == p ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.rawValue)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// 成本拆解表。口径（用户 2026-08-05 定义）：
    /// 实际支出 = 订阅摊销 + PAYG 实际（OpenRouter 今日 + 直连 turns actual）；
    /// 估算成本 = turns 估算（未知真实价的估算）。
    /// 布局：两列三行，每行左 token 指标、右成本指标，label 左 value 右。
    private var metricsTable: some View {
        VStack(spacing: 8) {
            metricPair("输入", Format.compact(totals.input),
                       "实际花费", actualShown > 0 ? Format.money(actualShown) : "—")
            Divider()
            metricPair("输出", Format.compact(totals.output),
                       "API 价值", estimatedShown > 0 ? Format.money(estimatedShown) : "—")
            Divider()
            metricPair("缓存命中", Format.compact(totals.cacheRead),
                       "缓存率", cacheRateText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("缓存率：缓存命中 token 占全部 token 的比例")
    }

    /// 缓存率 = 缓存命中 / (输入 + 输出 + 缓存命中)。
    private var cacheRateText: String {
        let total = totals.input + totals.output + totals.cacheRead
        guard total > 0 else { return "—" }
        return "\(Int(Double(totals.cacheRead) / Double(total) * 100))%"
    }

    private func metricPair(_ l1: String, _ v1: String, _ l2: String, _ v2: String) -> some View {
        HStack(spacing: 0) {
            metricItem(l1, v1)
                .padding(.trailing, 10)
            Divider().frame(height: 28)
            metricItem(l2, v2)
                .padding(.leading, 10)
        }
    }

    private func metricItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TMDesign.quiet)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
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

    private func compactMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costLine: String {
        if cost.actual > 0 { return "已确认 \(Format.money(cost.actual))" }
        if cost.estimated > 0 { return "估算 \(Format.money(cost.estimated))" }
        return "成本暂无覆盖"
    }

    /// 来源分段条 + 每来源一行（行尾直接显示占比，无隐式交互）。
    private var sourceBar: some View {
        let rows = sortedRows
        let total = rows.reduce(Int64(0)) {
            $0 + (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? ($1.input + $1.output))
        }
        return VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("暂无来源数据")
                    .font(.caption)
                    .foregroundStyle(TMDesign.quiet)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(rows, id: \.tool) { row in
                            let value = ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)
                            let ratio = total > 0 ? CGFloat(value) / CGFloat(total) : 0
                            Rectangle()
                                .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                ForEach(rows, id: \.tool) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                            .frame(width: 6, height: 6)
                        Text(ToolKind(rawValue: row.tool)?.displayName ?? row.tool)
                            .font(.caption.weight(.medium))
                        Text("(\(percentText(row, total: total)))")
                            .font(.caption.monospacedDigit())
                            .monospacedDigit()
                            .foregroundStyle(TMDesign.quiet)
                        Spacer()
                        Text(Format.compact(ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(TMDesign.quiet)
                    }
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

    private func sourceRow(_ row: Database.ToolTotals) -> some View {
        let kind = ToolKind(rawValue: row.tool)
        let value = kind?.totalTokens(row) ?? (row.input + row.output)
        let source = health.sources.first { $0.tool == row.tool }
        let stateColor = TMDesign.statusColor(isError: source?.error != nil, isStale: source?.isStale == true)
        return HStack(spacing: 9) {
            Text(kind?.displayName ?? row.tool)
                .font(.headline.weight(.semibold))
            // 状态灯只在异常时出现（错误/过期）；正常保持安静。
            if let source, source.error != nil || source.isStale {
                Image(systemName: source.error != nil ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(stateColor)
                    .help(source.error ?? "来源数据过期")
            }
            Spacer()
            Text(Format.compact(value))
                .font(.subheadline.monospacedDigit())
        }
    }

    // MARK: - 额度状态（实时账户快照，与所选周期无关）

    /// Quota/balance is a live account snapshot — it only changes as time
    /// passes, never with the selected period. Showing it inside the period
    /// switcher implied it varied per dimension, so it now lives in its own
    /// fixed section below the period content, labelled as such.
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("额度状态")
                .font(.system(size: 13, weight: .semibold))
            goStatusRow
            codexStatusRow
            routerStatusRow
        }
    }

    private func resetText(_ at: Int64?) -> String? {
        guard let at, at > Int64(now.timeIntervalSince1970) else { return nil }
        return "\(Format.remaining(at - Int64(now.timeIntervalSince1970))) 后重置"
    }

    private var goStatusRow: some View {
        let state = goClient.state
        let remaining = state.monthlyPct.map { 100 - $0 }
        var status = "未配置"
        if goClient.configured {
            if let remaining {
                status = "剩余 \(Int(remaining))%"
                if let r = resetText(state.monthlyReset.map { state.lastSync + $0 }) {
                    status += " · \(r)"
                }
            } else {
                status = state.error != nil ? "读取失败" : "同步中"
            }
        }
        return statusRow(name: "OpenCode Go", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false)
    }

    /// 窗口标签由 limit_window_seconds 决定：604800 = 每周（Plus 现状）。
    private var windowLabel: String {
        guard let s = codexQuota.state.windowSeconds else { return "限额" }
        if s >= 7 * 86400 { return "每周" }
        if s >= 86400 { return "每 \(s / 86400) 天" }
        if s >= 3600 { return "每 \(s / 3600) 小时" }
        return "限额"
    }

    private var codexStatusRow: some View {
        let state = codexQuota.state
        let remaining = state.primaryPct.map { 100 - Double($0) }
        let sub = app.subscriptions.first { $0.plan == "codex" }
        var status = "未订阅"
        if state.primaryPct != nil, let remaining {
            status = "\(windowLabel)剩余 \(Int(remaining))%"
            if let r = resetText(state.resetAt) {
                status += " · \(r)"
            }
        } else if state.error != nil {
            status = "限额读取失败"
        } else if let sub {
            status = "已订阅 \(Format.money(sub.price))/月"
        }
        return statusRow(name: "Codex Plus", status: status,
                         statusColor: .primary,
                         critical: remaining.map { $0 < 20 } ?? false)
    }

    private var routerStatusRow: some View {
        let state = orClient.state
        let status = orClient.hasKey
            ? "余额 \(Format.money(state.accountBalance ?? 0))"
            : "未配置"
        return statusRow(name: "OpenRouter", status: status,
                         statusColor: orClient.hasKey ? .primary : TMDesign.quiet)
    }

    private func statusRow(name: String, status: String, statusColor: Color,
                           critical: Bool = false) -> some View {
        Button(action: openPlans) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: TMType.body, weight: .medium))
                Spacer()
                Text((critical ? "★ " : "") + status)
                    .font(.system(size: TMType.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TMDesign.faint)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("打开计划与余额")
    }

    private func openPlans() {
        WindowManager.shared.show(tab: .plans)
        NSApp.keyWindow?.close()
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
