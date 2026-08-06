import SwiftUI

/// Overview is intentionally quiet: one hero metric, a small baseline of
/// supporting numbers, then activity and attribution. No nested card stack.
struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var health = SourceHealthHub.shared
    @State private var heatMetric: HeatMetric = .tokens

    enum HeatMetric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "成本"
        var id: String { rawValue }
    }

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                intro
                statusLine
                    .padding(.bottom, 14)
                TMPanel {
                    metrics
                }
                .padding(.bottom, 12)
                TMPanel {
                    heatmapSection
                }
                .padding(.bottom, 12)
                TMPanel {
                    rankings
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
        }
    }

    private var intro: some View {
        TMPageHeader(
            title: "概览",
            subtitle: "最近的用量、数据状态与来源分布",
            eyebrow: "工作台"
        )
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

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            TMMetric(title: "本月 tokens", value: Format.compact(app.monthTokens), detail: "输入 + 输出（含缓存命中）", emphasis: true)
            Divider().frame(height: 58).padding(.horizontal, 18)
            TMMetric(title: "调用", value: Format.count(app.month.count), detail: "本月")
            Divider().frame(height: 58).padding(.horizontal, 18)
            TMMetric(title: "已确认支出", value: Format.money(app.costMonth.actual), detail: app.costMonth.actual > 0 ? "实际口径" : "暂无实际数据")
            Divider().frame(height: 58).padding(.horizontal, 18)
            TMMetric(title: "估算覆盖", value: app.costMonth.totalCount > 0 ? "\(Int(app.costMonth.coverage * 100))%" : "—", detail: "成本数据")
        }
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                TMSectionHeader("活动", subtitle: "近一年每日用量")
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
                HStack(alignment: .top, spacing: 3) {
                    ForEach(heatmapWeeks.indices, id: \.self) { wi in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { di in
                                heatCell(heatmapWeeks[wi][di])
                            }
                        }
                    }
                }
                .padding(.vertical, 5)
            }
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
                    // Avoid allocating a DateFormatter for every cell during
                    // every SwiftUI graph pass. Database heatmap keys are
                    // yyyymmdd integers, so Calendar components are enough.
                    let components = calendar.dateComponents([.year, .month, .day], from: date)
                    let key = (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
                    column.append(Int64(key))
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    private func heatCell(_ day: Int64?) -> some View {
        let value = day.flatMap { heatMetric == .tokens ? Double(app.heatmap[$0] ?? 0) : app.heatmapCost[$0] } ?? 0
        let maxValue = heatMetric == .tokens ? Double(app.heatmap.values.max() ?? 0) : (app.heatmapCost.values.max() ?? 0)
        let intensity = value > 0 && maxValue > 0 ? max(0.18, min(1, value / maxValue)) : 0
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(value > 0 ? TMDesign.accent.opacity(0.18 + intensity * 0.72) : Color.primary.opacity(0.07))
            .frame(width: 12, height: 12)
            .help(day.map { "\(Format.day($0)): \(heatMetric == .tokens ? Format.compact(Int64(app.heatmap[$0] ?? 0)) : Format.money(app.heatmapCost[$0] ?? 0))" } ?? "")
    }

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 18) {
            TMSectionHeader("来源分布", subtitle: "帮助定位哪类工作消耗最多")
            HStack(alignment: .top, spacing: 32) {
                rankingColumn(title: "模型 · 近 7 天", rows: app.modelAggs.prefix(6).map { row in
                    let value = ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? row.input + row.output
                    return ("\(ToolKind(rawValue: row.tool)?.displayName ?? row.tool) · \(row.model)", value, row.cost, ToolKind(rawValue: row.tool)?.color ?? TMDesign.accent)
                })
                rankingColumn(title: "工具 · 本月", rows: app.byToolMonth.sorted {
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
        return VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if rows.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let ratio = total > 0 ? Double(row.1) / Double(total) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(row.3).frame(width: 6, height: 6)
                            Text(row.0)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.compact(row.1))
                                .font(.caption.monospacedDigit())
                        }
                        TMProgressBar(value: ratio, tint: row.3, height: 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
