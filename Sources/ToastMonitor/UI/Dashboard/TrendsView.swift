import SwiftUI
import Charts

/// 趋势: 30-day stacked bars per tool + cost line.
struct TrendsView: View {
    @EnvironmentObject var app: AppState

    struct DayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let tool: String
        let tokens: Int64
        let cost: Double
    }

    private var points: [DayPoint] {
        app.dailyAggs.map {
            DayPoint(date: dateFromDay($0.day), tool: $0.tool,
                     tokens: ToolKind(rawValue: $0.tool)?.totalTokens(input: $0.input, output: $0.output, cacheRead: $0.cacheRead)
                         ?? ($0.input + $0.output), cost: $0.cost)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("近 35 天 token 用量（按工具堆叠）")
                        .font(.system(size: 13, weight: .semibold))
                    Chart(points) { p in
                        BarMark(
                            x: .value("日期", p.date, unit: .day),
                            y: .value("Tokens", p.tokens)
                        )
                        .foregroundStyle(by: .value("工具", ToolKind(rawValue: p.tool)?.displayName ?? p.tool))
                    }
                    .chartForegroundStyleScale([
                        "Claude Code": ToolKind.claude.color,
                        "Codex": ToolKind.codex.color,
                        "OpenCode": ToolKind.opencode.color,
                        "Hermes": ToolKind.hermes.color,
                    ])
                    .frame(height: 260)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("近 35 天成本")
                        .font(.system(size: 13, weight: .semibold))
                    Chart(points) { p in
                        LineMark(
                            x: .value("日期", p.date, unit: .day),
                            y: .value("成本", p.cost)
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                        .symbol(.circle)
                        .symbolSize(22)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(Format.moneyShort(v))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
            .padding(18)
        }
    }

    private func dateFromDay(_ day: Int64) -> Date {
        let s = String(day)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.date(from: s) ?? Date()
    }
}
