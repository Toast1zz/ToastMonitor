import SwiftUI

/// Overview is the one-page dashboard: a hero figure with a capacity ring,
/// the year heatmap, attribution, and recent sessions. No nested card stack —
/// the hero sits directly on the canvas, panels hold the rest.
struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var heatMetric: HeatMetric = .tokens
    @State private var selectedSession: Database.SessionRow?

    enum HeatMetric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "成本"
        var id: String { rawValue }
    }

    private let calendar = Calendar.current
    /// Heatmap cell geometry (13pt cells, 3pt gutter) — must match render.
    private let cellSize: CGFloat = 13
    private let cellGutter: CGFloat = 3

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                intro
                heroSection
                    .padding(.bottom, 18)
                statusLine
                    .padding(.bottom, 14)
                TMPanel {
                    heatmapSection
                }
                .padding(.bottom, 14)
                TMPanel {
                    rankings
                }
                .padding(.bottom, 14)
                TMPanel {
                    recentSessions
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session)
        }
    }

    private var intro: some View {
        TMPageHeader(
            title: "概览",
            subtitle: "今天烧了多少、还剩多少、花在了哪里",
            eyebrow: "工作台"
        )
    }

    // MARK: - Hero: today's usage + capacity ring

    private var heroSection: some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 5) {
                Text("今日用量")
                    .font(.system(size: TMType.section, weight: .semibold))
                    .foregroundStyle(TMDesign.quiet)
                Text(Format.compact(app.todayTokens))
                    .font(.system(size: TMType.hero, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text("tokens · 输入 + 输出 + 缓存命中")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.faint)
                HStack(spacing: 22) {
                    heroMini("本周", Format.compact(app.weekTokens), unit: "tokens")
                    heroMini("本月", Format.compact(app.monthTokens), unit: "tokens")
                    heroMini("已确认支出", Format.money(app.costToday.actual), unit: "实际")
                    heroMini("估算", Format.money(app.costToday.estimated), unit: "估算口径")
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 20)
            gauge
        }
    }

    private func heroMini(_ label: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: TMType.micro))
                        .foregroundStyle(TMDesign.faint)
                }
            }
        }
    }

    /// Today's tokens against the trailing-30-day daily average.
    private var gauge: some View {
        let avg = dailyAverage30d
        let ratio = avg > 0 ? Double(app.todayTokens) / avg : 0
        let caption = avg > 0
            ? String(format: "%.1f×", ratio)
            : (app.todayTokens > 0 ? "新" : "—")
        return ZStack {
            TMGauge(progress: ratio)
                .frame(width: 118, height: 118)
            VStack(spacing: 1) {
                Text(caption)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("vs 近 30 天日均")
                    .font(.system(size: TMType.micro))
                    .foregroundStyle(TMDesign.faint)
            }
        }
        .padding(.trailing, 8)
        .help(avg > 0 ? "今日用量是近 30 天日均的 \(String(format: "%.1f", ratio)) 倍" : "暂无足够历史计算日均")
    }

    private var dailyAverage30d: Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var sum: Double = 0
        for offset in 1...30 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = Int64((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
            sum += Double(app.heatmap[key] ?? 0)
        }
        return sum / 30
    }

    private var statusLine: some View {
        let broken = health.sources.filter { $0.error != nil }
        let stale = health.sources.filter { $0.error == nil && $0.isStale }
        let minutesAgo = app.lastScan > 0 ? Int(Date().timeIntervalSince1970 - TimeInterval(app.lastScan)) / 60 : -1
        if !broken.isEmpty {
            return AnyView(TMStatusLabel(text: "\(broken.count) 个来源异常，需要检查来源设置", color: .orange, symbol: "exclamationmark.triangle.fill"))
        }
        if !stale.isEmpty {
            return AnyView(TMStatusLabel(text: "\(stale.count) 个来源数据过期", color: .orange, symbol: "clock.badge.exclamationmark"))
        }
        if minutesAgo >= 0 {
            return AnyView(TMStatusLabel(text: minutesAgo < 1 ? "数据刚刚更新" : "数据已更新 \(minutesAgo) 分钟前", color: .green, symbol: "checkmark.circle.fill"))
        }
        return AnyView(TMStatusLabel(text: "等待首次扫描", color: TMDesign.quiet, symbol: "circle.dashed"))
    }

    // MARK: - Heatmap (one year, month axis)

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                TMSectionHeader("活动", subtitle: "近一年每日用量，色深 = 相对强度")
                Spacer()
                Picker("指标", selection: $heatMetric) {
                    ForEach(HeatMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            if heatMetric == .cost && app.costMonth.totalCount > 0 && app.costMonth.coverage < 0.8 {
                TMStatusLabel(text: "成本覆盖率较低，活动强度可能低估", color: .orange, symbol: "info.circle")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: cellGutter) {
                        ForEach(heatmapWeeks.indices, id: \.self) { wi in
                            VStack(spacing: cellGutter) {
                                ForEach(0..<7, id: \.self) { di in
                                    heatCell(heatmapWeeks[wi][di])
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    // Month labels overhang their column like GitHub's grid.
                    ForEach(monthLabels, id: \.index) { m in
                        Text(m.label)
                            .font(.system(size: TMType.micro, weight: .medium))
                            .foregroundStyle(TMDesign.quiet)
                            .fixedSize()
                            .offset(x: CGFloat(m.index) * (cellSize + cellGutter), y: 0)
                    }
                }
                .padding(.vertical, 5)
            }
            heatLegend
        }
    }

    private var heatLegend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.system(size: TMType.micro))
                .foregroundStyle(TMDesign.faint)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0
                          ? Color.primary.opacity(0.07)
                          : TMDesign.accent.opacity(0.18 + Double(level) / 4 * 0.72))
                    .frame(width: 11, height: 11)
            }
            Text("多")
                .font(.system(size: TMType.micro))
                .foregroundStyle(TMDesign.faint)
            Spacer()
            Text(heatMetric == .tokens ? "单位：tokens" : "单位：USD")
                .font(.system(size: TMType.micro))
                .foregroundStyle(TMDesign.faint)
        }
    }

    private var heatmapWeeks: [[Int64?]] {
        var weeks: [[Int64?]] = []
        let now = Date()
        guard let monday = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return weeks }
        for week in 0..<53 {
            var column: [Int64?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day - 52 * 7, to: monday) else {
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

    /// First week whose Monday falls in a new month gets that month's label.
    private var monthLabels: [(index: Int, label: String)] {
        var out: [(Int, String)] = []
        var lastMonth = -1
        for (wi, week) in heatmapWeeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = (Int(first) / 100) % 100
            if month != lastMonth {
                out.append((wi, "\(month)月"))
                lastMonth = month
            }
        }
        return out
    }

    private func heatCell(_ day: Int64?) -> some View {
        let value = day.flatMap { heatMetric == .tokens ? Double(app.heatmap[$0] ?? 0) : app.heatmapCost[$0] } ?? 0
        let maxValue = heatMetric == .tokens ? Double(app.heatmap.values.max() ?? 0) : (app.heatmapCost.values.max() ?? 0)
        let intensity = value > 0 && maxValue > 0 ? max(0.18, min(1, value / maxValue)) : 0
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(value > 0 ? TMDesign.accent.opacity(0.18 + intensity * 0.72) : Color.primary.opacity(0.07))
            .frame(width: cellSize, height: cellSize)
            .help(day.map { "\(Format.day($0)): \(heatMetric == .tokens ? Format.compact(Int64(app.heatmap[$0] ?? 0)) : Format.money(app.heatmapCost[$0] ?? 0))" } ?? "")
    }

    // MARK: - Attribution (same trailing-7d window on both columns)

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 18) {
            TMSectionHeader("来源分布", subtitle: "近 7 天，模型与工具两个维度看同一窗口")
            HStack(alignment: .top, spacing: 32) {
                rankingColumn(title: "模型 · 近 7 天", rows: app.modelAggs.prefix(6).map { row in
                    let value = ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? row.input + row.output
                    return ("\(ToolKind(rawValue: row.tool)?.displayName ?? row.tool) · \(row.model)", value, row.cost, ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                })
                rankingColumn(title: "工具 · 近 7 天", rows: app.byToolWeek.sorted {
                    (ToolKind(rawValue: $0.tool)?.totalTokens($0) ?? $0.input + $0.output) >
                        (ToolKind(rawValue: $1.tool)?.totalTokens($1) ?? $1.input + $1.output)
                }.prefix(6).map { row in
                    (ToolKind(rawValue: row.tool)?.displayName ?? row.tool,
                     ToolKind(rawValue: row.tool)?.totalTokens(row) ?? row.input + row.output,
                     row.cost,
                     ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                })
            }
        }
    }

    private func rankingColumn(title: String, rows: [(String, Int64, Double, Color)]) -> some View {
        let total = rows.reduce(Int64(0)) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: TMType.section, weight: .semibold))
            if rows.isEmpty {
                Text("暂无数据")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let ratio = total > 0 ? Double(row.1) / Double(total) : 0
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle().fill(row.3).frame(width: 6, height: 6)
                            Text(row.0)
                                .font(.system(size: TMType.caption))
                                .lineLimit(1)
                            Spacer()
                            Text(Format.compact(row.1))
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                        }
                        TMProgressBar(value: ratio, tint: row.3, height: 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            TMSectionHeader("最近会话", subtitle: "近 200 条中最新的 8 条，点击查看调用明细")
            if app.sessions.isEmpty {
                Text("暂无会话记录")
                    .font(.system(size: TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(app.sessions.prefix(8)) { session in
                    Button {
                        selectedSession = session
                    } label: {
                        SessionListRow(session: session)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if session.id != app.sessions.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}
