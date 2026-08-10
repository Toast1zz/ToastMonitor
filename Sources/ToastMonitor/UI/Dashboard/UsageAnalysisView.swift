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
            pageHeader
            Divider().opacity(0.5)
            if loading {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text("该时间范围内暂无数据")
                    .font(.system(size: TMType.body))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryStrip
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
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear { load() }
        .onChange(of: range) { load() }
        .onChange(of: grouping) { load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            SectionTitle("Analysis")
            Spacer(minLength: 8)
            controls
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var summaryStrip: some View {
        let days = Set(rows.map(\.day)).count
        let total = rows.reduce(Int64(0)) { $0 + tokenValue($1) }
        let cost = rows.reduce(0.0) { $0 + max($1.cost, 0) }
        let calls = rows.reduce(Int64(0)) { $0 + max($1.count, 0) }
        let daily = days > 0 ? total / Int64(days) : 0
        return HStack(spacing: 0) {
            summaryMetric("Tokens", Format.compact(total))
            Divider().frame(height: 34)
            summaryMetric("估算成本", Format.moneyShort(cost))
            Divider().frame(height: 34)
            summaryMetric("日均 Tokens", Format.compact(daily))
            Divider().frame(height: 34)
            summaryMetric("调用", Format.count(calls))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(TMDesign.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TMDesign.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: TMType.caption))
                .foregroundStyle(TMDesign.quiet)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokenValue(_ row: (day: Int64, key: String, input: Int64,
                                    output: Int64, cacheRead: Int64,
                                    cost: Double, count: Int64)) -> Int64 {
        if grouping == .byTool {
            return ToolKind(rawValue: row.key)?.totalTokens(input: row.input,
                                                            output: row.output,
                                                            cacheRead: row.cacheRead)
                ?? row.input + row.output
        }
        return row.input + row.output + row.cacheRead
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
        HStack(spacing: 10) {
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
        }
    }

    // MARK: - Token 堆叠图（按天，按工具/模型分色叠加）

    private var tokensChart: some View {
        let days = groupedDays()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens（\(grouping.rawValue)）")
                    .font(.system(size: TMType.section, weight: .semibold))
                Spacer()
                if !days.isEmpty {
                    legend
                }
            }
            if days.isEmpty {
                Text("暂无数据")
                    .font(.system(size: TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                let maxV = days.map { day in
                    day.segments.reduce(Int64(0)) { $0 + $1.value }
                }.max() ?? 1
                let axisH: CGFloat = 18
                if let idx = hoveredDayIdx, idx < days.count {
                    tokenHoverLine(days[idx])
                } else {
                    Color.clear.frame(height: 18)
                }
                GeometryReader { geo in
                    let yAxisW: CGFloat = 48
                    let width = max(geo.size.width - yAxisW, 10)
                    let barW = max(2, width / CGFloat(days.count) - 2)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            let chartH = size.height - axisH
                            for step in 0...3 {
                                let y = chartH * CGFloat(step) / 3
                                var grid = Path()
                                grid.move(to: CGPoint(x: yAxisW, y: y))
                                grid.addLine(to: CGPoint(x: size.width, y: y))
                                ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.055)), lineWidth: 1)
                                let v = Double(maxV) * Double(3 - step) / 3
                                let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                                let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                                ctx.draw(Text(Format.compact(Int64(v))).font(.system(size: 10)).foregroundStyle(.secondary),
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
                                ctx.draw(Text(label).font(.system(size: 10)).foregroundStyle(.secondary),
                                         at: CGPoint(x: x, y: chartH + 7))
                            }
                        }
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
                .frame(height: 180)
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
                .font(.system(size: TMType.section, weight: .semibold))
            if days.values.allSatisfy({ $0 <= 0 }) {
                Text("该范围内无估算成本数据")
                    .font(.system(size: TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                let keys = days.keys.sorted()
                let maxV = max(days.values.max() ?? 0, 0.001)
                let axisH: CGFloat = 18
                if let idx = hoveredCostIdx, idx < keys.count {
                    let k = keys[idx]
                    Text("\(Format.dayKeyString(k)) · \(Format.money(days[k] ?? 0))")
                        .font(.system(size: TMType.caption, design: .monospaced))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 18)
                } else {
                    Color.clear.frame(height: 18)
                }
                GeometryReader { _ in
                    let yAxisW: CGFloat = 48
                    Canvas { ctx, size in
                        guard keys.count >= 2 else { return }
                        let chartH = size.height - axisH
                        for step in 0...3 {
                            let y = chartH * CGFloat(step) / 3
                            var grid = Path()
                            grid.move(to: CGPoint(x: yAxisW, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(grid, with: .color(Color.primary.opacity(step == 0 ? 0.10 : 0.055)), lineWidth: 1)
                            let v = maxV * Double(3 - step) / 3
                            let labelY = step == 0 ? CGFloat(1) : (step == 3 ? y - 1 : y)
                            let anchor: UnitPoint = step == 0 ? .topLeading : (step == 3 ? .bottomLeading : .leading)
                            ctx.draw(Text(Format.moneyShort(v)).font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: 2, y: labelY), anchor: anchor)
                        }
                        var path = Path()
                        for (i, k) in keys.enumerated() {
                            let x = yAxisW + CGFloat(i) / CGFloat(keys.count - 1) * (size.width - yAxisW)
                            let y = chartH - chartH * CGFloat(days[k] ?? 0) / CGFloat(maxV)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(path, with: .color(TMDesign.accent), lineWidth: 1.8)
                        var area = path
                        area.addLine(to: CGPoint(x: size.width, y: chartH))
                        area.addLine(to: CGPoint(x: yAxisW, y: chartH))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(TMDesign.accent.opacity(0.12)))
                        for (idx, label) in monthTickIndices(keys) {
                            let x = keys.count > 1 ? yAxisW + CGFloat(idx) / CGFloat(keys.count - 1) * (size.width - yAxisW) : yAxisW
                            ctx.draw(Text(label).font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: x, y: chartH + 7))
                        }
                    }
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
                .frame(height: 146)
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
        return VStack(alignment: .leading, spacing: 8) {
            Text("聚合明细（\(range.rawValue)）")
                .font(.system(size: TMType.section, weight: .semibold))
            if rows.isEmpty {
                Text("暂无数据")
                    .font(.system(size: TMType.body))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(grouping == .byTool ? "工具" : "模型")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("成本")
                            .frame(width: 76, alignment: .trailing)
                        Text("Tokens")
                            .frame(width: 76, alignment: .trailing)
                        Text("调用")
                            .frame(width: 54, alignment: .trailing)
                        Text("占比")
                            .frame(width: 42, alignment: .trailing)
                        Color.clear.frame(width: 100, height: 1)
                    }
                    .font(.system(size: TMType.micro, weight: .medium))
                    .foregroundStyle(TMDesign.quiet)
                    .padding(.bottom, 6)

                    ForEach(rows, id: \.name) { r in
                        HStack(spacing: 10) {
                            HStack(spacing: 7) {
                                Circle().fill(r.color).frame(width: 7, height: 7)
                                Text(grouping == .byTool
                                     ? (ToolKind(rawValue: r.name)?.displayName ?? r.name)
                                     : r.name)
                                    .font(.system(size: TMType.body, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(r.cost > 0 ? Format.moneyShort(r.cost) : "—")
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                            Text(Format.compact(r.tokens))
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 76, alignment: .trailing)
                            Text(Format.count(r.calls))
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                            Text("\(Int(r.ratio * 100))%")
                                .font(.system(size: TMType.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                            TMProgressBar(value: r.ratio, tint: r.color, height: 5)
                                .frame(width: 100)
                        }
                        .padding(.vertical, 7)
                        Divider().opacity(0.65)
                    }
                }
                .padding(.vertical, 2)
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
        let orderedNames = aggregateRows().map(\.name)
        let days = rows.map(\.day).sorted()
        return days.map { d in
            var segs: [(String, Int64, Color)] = []
            for name in orderedNames {
                let list = groups[name] ?? []
                let v = list.filter { $0.day == d }.reduce(Int64(0)) {
                    $0 + tokenValue($1)
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
            $0 + tokenValue($1)
        }
        var out: [(name: String, tokens: Int64, calls: Int64, cost: Double, ratio: Double, color: Color)] = []
        for (name, list) in groups {
            let tokens = list.reduce(Int64(0)) { $0 + tokenValue($1) }
            if tokens == 0 { continue }
            let calls = list.reduce(Int64(0)) { $0 + max($1.count, 0) }
            let cost = list.reduce(0.0) { $0 + max($1.cost, 0) }
            out.append((name, tokens, calls, cost,
                        total > 0 ? Double(tokens) / Double(total) : 0,
                        color(for: name)))
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
                HStack(spacing: 5) {
                    Circle().fill(r.color).frame(width: 7, height: 7)
                    Text(grouping == .byTool
                         ? (ToolKind(rawValue: r.name)?.displayName ?? r.name)
                         : r.name)
                        .font(.system(size: TMType.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
