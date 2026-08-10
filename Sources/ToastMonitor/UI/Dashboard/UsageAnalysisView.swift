import SwiftUI

/// 用量分析 (spec §3.2): 集中控制条（日期范围 / 按工具·按模型 / 图型）+
/// token 堆叠图 + 成本图（按天聚合，禁止跨工具连线）+ 聚合表。
struct UsageAnalysisView: View {
    enum Range: String, CaseIterable, Identifiable {
        case d7 = "7 天"
        case d30 = "30 天"
        case d90 = "90 天"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .d7: 7
            case .d30: 30
            case .d90: 90
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case byTool = "按工具"
        case byModel = "按模型"
        var id: String { rawValue }
    }

    @State private var range: Range = .d30
    @State private var grouping: Grouping = .byTool
    @State private var aggs: [Database.DayAgg] = []
    @State private var modelAggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)] = []
    @State private var loading = true
    @State private var loadID = UUID()
    @State private var hoveredDayIdx: Int?
    @State private var hoveredCostIdx: Int?
    /// Model -> color, assigned by usage rank so distinct models always get
    /// distinct palette entries (hash-based mapping collided).
    @State private var modelColors: [String: Color] = [:]

    /// 归一化行：(day, groupKey, input, output, cacheRead, cost, calls)
    private var rows: [(day: Int64, key: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)] {
        if grouping == .byTool {
            return aggs.map { ($0.day, $0.tool, $0.input, $0.output, $0.cacheRead, $0.cost, $0.count) }
        }
        return modelAggs.map { ($0.day, $0.model, $0.input, $0.output, $0.cacheRead, $0.cost, $0.count) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TMPageHeader("用量分析")
            controls
                .padding(.bottom, 12)
            Divider()
            if loading {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text("该时间范围内暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TMPanel {
                            tokensChart
                        }
                        TMPanel {
                            costChart
                        }
                        TMPanel {
                            aggTable
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear { load() }
        .onChange(of: range) { load() }
        .onChange(of: grouping) { load() }
    }

    private func load() {
        loading = true
        let requestID = UUID()
        loadID = requestID
        if grouping == .byTool {
            UsageQueryService.shared.loadDailyAggs(days: range.days) { aggs in
                guard loadID == requestID else { return }
                self.aggs = aggs
                self.modelAggs = []
                self.loading = false
            }
        } else {
            UsageQueryService.shared.loadDailyAggsByModel(days: range.days) { aggs in
                guard loadID == requestID else { return }
                self.modelAggs = aggs
                self.modelColors = Self.assignModelColors(aggs)
                self.aggs = []
                self.loading = false
            }
        }
    }

    /// Rank models by total tokens (descending) and hand each the next
    /// palette color — the top model gets the first color, no collisions.
    private static func assignModelColors(_ aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)]) -> [String: Color] {
        let totals: [String: Int64] = aggs.reduce(into: [:]) { acc, row in
            acc[row.model, default: 0] += row.input + row.output + row.cacheRead
        }
        let ranked = totals.sorted { $0.value > $1.value }.map(\.key)
        var map: [String: Color] = [:]
        for (i, name) in ranked.enumerated() {
            map[name] = TMDesign.modelPalette[i % TMDesign.modelPalette.count]
        }
        return map
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("范围", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Picker("分组", selection: $grouping) {
                ForEach(Grouping.allCases) { g in Text(g.rawValue).tag(g) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            Spacer()
        }
    }

    // MARK: - Token 堆叠图（按天，按工具/模型分色叠加）

    private var tokensChart: some View {
        let days = groupedDays()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tokens（\(grouping.rawValue)）")
                .font(.system(size: 13, weight: .semibold))
            if days.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                let maxV = days.map { day in
                    day.segments.reduce(Int64(0)) { $0 + $1.value }
                }.max() ?? 1
                let axisH: CGFloat = 14
                if let idx = hoveredDayIdx, idx < days.count {
                    tokenHoverLine(days[idx])
                } else {
                    Color.clear.frame(height: 14)
                }
                GeometryReader { geo in
                    let yAxisW: CGFloat = 34
                    let width = max(geo.size.width - yAxisW, 10)
                    let barW = max(2, width / CGFloat(days.count) - 2)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            let chartH = size.height - axisH
                            // Y 轴：0 基线 + 4 档网格与刻度（open code data 惯例：
                            // 纵轴从 0 起、有梯度、数值缩写）。标签画在网格线
                            // 下方，顶部最大值不被裁掉。
                            for step in 0...3 {
                                let y = chartH * CGFloat(step) / 3
                                var grid = Path()
                                grid.move(to: CGPoint(x: yAxisW, y: y))
                                grid.addLine(to: CGPoint(x: size.width, y: y))
                                ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.045)), lineWidth: 1)
                                let v = Double(maxV) * Double(3 - step) / 3
                                let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                                let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                                ctx.draw(Text(Format.compact(Int64(v))).font(.system(size: 9)).foregroundStyle(.secondary),
                                         at: CGPoint(x: 2, y: labelY), anchor: anchor)
                            }
                            for (di, day) in days.enumerated() {
                                var y = chartH
                                for seg in day.segments {
                                    let h = max(0.5, chartH * CGFloat(seg.value) / CGFloat(maxV))
                                    let rect = CGRect(x: yAxisW + CGFloat(di) * (barW + 2), y: y - h, width: barW, height: h)
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(seg.color.opacity(0.85)))
                                    y -= h
                                }
                            }
                            for (idx, label) in monthTickIndices(days.map(\.date)) {
                                let x = yAxisW + CGFloat(idx) * (barW + 2) + barW / 2
                                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                                         at: CGPoint(x: x, y: chartH + 6))
                            }
                        }
                        // Per-day buttons keep the Canvas chart keyboard and
                        // VoiceOver reachable; hover is only an additional
                        // pointer affordance.
                        HStack(spacing: 2) {
                            ForEach(days.indices, id: \.self) { di in
                                let day = days[di]
                                let total = day.segments.reduce(Int64(0)) { $0 + $1.value }
                                Button {
                                    hoveredDayIdx = di
                                } label: {
                                    Color.clear
                                        .frame(width: barW)
                                        .frame(maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(Format.dayKeyString(day.date)))
                                .accessibilityValue(Text(tokenAccessibilityValue(day, total: total)))
                                .accessibilityHint("按空格查看当天各来源用量")
                                .onHover { hovering in
                                    if hovering { hoveredDayIdx = di }
                                    else if hoveredDayIdx == di { hoveredDayIdx = nil }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tokens 图表")
                    .accessibilityValue(Text(tokenChartAccessibilitySummary(days)))
                    .accessibilityHint("使用 Tab 键或 VoiceOver 浏览每日数据")
                }
                .frame(height: 174)
                legend
            }
        }
    }

    private func tokenHoverLine(_ day: DaySegments) -> some View {
        let total = day.segments.reduce(Int64(0)) { $0 + $1.value }
        let parts = day.segments.map { "\($0.name) \(Format.compact($0.value))" }
        return Text("\(Format.dayKeyString(day.date)) · \(Format.compact(total)) tokens"
                    + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
            .font(.system(size: TMType.caption, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 14)
    }
    private func tokenAccessibilityValue(_ day: DaySegments, total: Int64) -> String {
        let parts = day.segments.map { "\($0.name) \(Format.full($0.value)) tokens" }
        return "\(Format.full(total)) tokens" + (parts.isEmpty ? "" : "，" + parts.joined(separator: "，"))
    }

    private func tokenChartAccessibilitySummary(_ days: [DaySegments]) -> String {
        let total = days.reduce(Int64(0)) { partial, day in
            partial + day.segments.reduce(Int64(0)) { $0 + $1.value }
        }
        return "\(days.count) 天，共 \(Format.full(total)) tokens"
    }

    // MARK: - 成本图（按天单 series，不允许跨工具连线）

    private var costChart: some View {
        let days = costByDay()
        return VStack(alignment: .leading, spacing: 6) {
            Text("估算成本（按天聚合）")
                .font(.system(size: 13, weight: .semibold))
            if days.values.allSatisfy({ $0 <= 0 }) {
                Text("该范围内无估算成本数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                let keys = days.keys.sorted()
                let maxV = max(days.values.max() ?? 0, 0.001)
                let axisH: CGFloat = 14
                if let idx = hoveredCostIdx, idx < keys.count {
                    let k = keys[idx]
                    Text("\(Format.dayKeyString(k)) · \(Format.money(days[k] ?? 0))")
                        .font(.system(size: TMType.caption, design: .monospaced))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 14)
                } else {
                    Color.clear.frame(height: 14)
                }
                GeometryReader { geo in
                    let yAxisW: CGFloat = 34
                    Canvas { ctx, size in
                        guard keys.count >= 2 else { return }
                        let chartH = size.height - axisH
                        // Y grid: 4 ticks with labels (0 / ⅓ / ⅔ / max)。
                        // 标签画在网格线下方（顶部 max 不再被裁掉），0 基线
                        // 更实——open code data 的纵轴惯例：从 0 起、有梯度。
                        for step in 0...3 {
                            let y = chartH * CGFloat(step) / 3
                            var grid = Path()
                            grid.move(to: CGPoint(x: yAxisW, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.045)), lineWidth: 1)
                            let v = maxV * Double(3 - step) / 3
                            let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                            let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                            ctx.draw(Text(Format.moneyShort(v)).font(.system(size: 9)).foregroundStyle(.secondary),
                                     at: CGPoint(x: 2, y: labelY), anchor: anchor)
                        }
                        var path = Path()
                        for (i, k) in keys.enumerated() {
                            let x = yAxisW + CGFloat(i) / CGFloat(keys.count - 1) * (size.width - yAxisW)
                            let y = chartH - chartH * CGFloat(days[k] ?? 0) / CGFloat(maxV)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(path, with: .color(TMDesign.accent), lineWidth: 1.6)
                        var area = path
                        area.addLine(to: CGPoint(x: size.width, y: chartH))
                        area.addLine(to: CGPoint(x: yAxisW, y: chartH))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(TMDesign.accent.opacity(0.12)))
                        for (idx, label) in monthTickIndices(keys) {
                            let x = keys.count > 1 ? yAxisW + CGFloat(idx) / CGFloat(keys.count - 1) * (size.width - yAxisW) : yAxisW
                            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                                     at: CGPoint(x: x, y: chartH + 6))
                        }
                    }
                    // Per-day buttons keep the Canvas chart keyboard and
                    // VoiceOver reachable; hover is only an additional
                    // pointer affordance.
                    HStack(spacing: 0) {
                        ForEach(keys.indices, id: \.self) { i in
                            let day = keys[i]
                            Button {
                                hoveredCostIdx = i
                            } label: {
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(Format.dayKeyString(day)))
                            .accessibilityValue(Text("\(Format.money(days[day] ?? 0))"))
                            .accessibilityHint("按空格查看当天估算成本")
                            .onHover { hovering in
                                if hovering { hoveredCostIdx = i }
                                else if hoveredCostIdx == i { hoveredCostIdx = nil }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("估算成本图表")
                .accessibilityValue(Text(costChartAccessibilitySummary(keys, values: days)))
                .accessibilityHint("使用 Tab 键或 VoiceOver 浏览每日数据")
                .frame(height: 124)
            }
        }
    }
    private func costChartAccessibilitySummary(_ keys: [Int64], values: [Int64: Double]) -> String {
        let total = keys.reduce(0.0) { $0 + (values[$1] ?? 0) }
        return "\(keys.count) 天，共 \(Format.money(total))"
    }

    // MARK: - 聚合表

    private var aggTable: some View {
        let rows = aggregateRows()
        return VStack(alignment: .leading, spacing: 6) {
            Text("聚合明细（\(range.rawValue)）")
                .font(.system(size: 13, weight: .semibold))
            if rows.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.name) { r in
                        HStack(spacing: 10) {
                            Circle().fill(r.color).frame(width: 7, height: 7)
                            Text(r.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)
                            Text(r.cost > 0 ? Format.moneyShort(r.cost) : "—")
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            Spacer()
                            Text(Format.compact(r.tokens))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                            Text("\(Int(r.ratio * 100))%")
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                    Capsule().fill(r.color)
                                        .frame(width: max(2, geo.size.width * r.ratio))
                                }
                            }
                            .frame(width: 90)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 数据组装

    private struct DaySegments {
        let date: Int64
        let segments: [(name: String, value: Int64, color: Color)]
    }

    private func groupedDays() -> [DaySegments] {
        let groups = groupMap()
        let days = rows.map(\.day).sorted()
        return days.map { d in
            var segs: [(String, Int64, Color)] = []
            for (name, list) in groups {
                let v = list.filter { $0.day == d }.reduce(Int64(0)) {
                    if grouping == .byTool {
                        return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                                   ?? ($1.input + $1.output))
                    }
                    // by-model rows are keyed by model name (no tool);
                    // cacheRead counts toward the total like by-tool (the
                    // codex exception is not expressible at model granularity).
                    return $0 + $1.input + $1.output + $1.cacheRead
                }
                if v > 0 {
                    segs.append((name, v, color(for: name)))
                }
            }
            return DaySegments(date: d, segments: segs)
        }
    }

    private func costByDay() -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for a in rows where a.cost > 0 {
            out[a.day, default: 0] += a.cost
        }
        return out
    }

    private func aggregateRows() -> [(name: String, tokens: Int64, calls: Int64, cost: Double, ratio: Double, color: Color)] {
        let groups = groupMap()
        let total = groups.values.flatMap { $0 }.reduce(Int64(0)) {
            if grouping == .byTool {
                return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                           ?? ($1.input + $1.output))
            }
            // by-model: no tool info on model-keyed rows; include cacheRead.
            return $0 + $1.input + $1.output + $1.cacheRead
        }
        var out: [(name: String, tokens: Int64, calls: Int64, cost: Double, ratio: Double, color: Color)] = []
        for (name, list) in groups {
            let tokens = list.reduce(Int64(0)) {
                if grouping == .byTool {
                    return $0 + (ToolKind(rawValue: $1.key)?.totalTokens(input: $1.input, output: $1.output, cacheRead: $1.cacheRead)
                               ?? ($1.input + $1.output))
                }
                // by-model: no tool info on model-keyed rows; include cacheRead.
                return $0 + $1.input + $1.output + $1.cacheRead
            }
            if tokens == 0 { continue }
            let calls = list.reduce(Int64(0)) { $0 + $1.count }
            let cost = list.reduce(0.0) { $0 + $1.cost }
            out.append((name, tokens, calls, cost, total > 0 ? Double(tokens) / Double(total) : 0, color(for: name)))
        }
        return out.sorted { $0.tokens > $1.tokens }
    }

    private func groupMap() -> [String: [(day: Int64, key: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64)]] {
        var groups: [String: [(Int64, String, Int64, Int64, Int64, Double, Int64)]] = [:]
        for a in rows {
            groups[a.key, default: []].append(a)
        }
        return groups
    }

    private func color(for name: String) -> Color {
        if grouping == .byTool {
            return ToolKind(rawValue: name)?.color ?? TMDesign.accent
        }
        // 模型色：按用量排名预分配（assignModelColors），同一模型在
        // 图表/图例/表格里永远同色；新出现的模型兜底第一个色。
        return modelColors[name] ?? TMDesign.modelPalette[0]
    }

    /// Month labels for chart x-axes (yyyymmdd keys, one tick per month).
    private func monthTickIndices(_ days: [Int64]) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var last = -1
        for (i, d) in days.enumerated() {
            let m = (Int(d) / 100) % 100
            if m != last {
                out.append((i, "\(m)月"))
                last = m
            }
        }
        return out
    }

    private var legend: some View {
        // Sorted by usage (aggregateRows is descending), top 6.
        let top = aggregateRows().prefix(6)
        return HStack(spacing: 12) {
            ForEach(top, id: \.name) { r in
                HStack(spacing: 4) {
                    Circle().fill(r.color).frame(width: 6, height: 6)
                    Text(r.name)
                        .font(.system(size: TMType.micro))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
