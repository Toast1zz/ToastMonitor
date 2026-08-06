import SwiftUI

/// 预测文案统一生成（Popover / 设置 / 计划与余额共用）。
enum ForecastText {
    enum Status { case ok, warn, danger, neutral }

    /// 主预测行 + 状态。
    static func line(for fc: SubscriptionMath.Forecast, plan: String) -> (text: String, status: Status) {
        switch plan {
        case "go":
            if let exhaust = fc.exhaustDate {
                let daysLeft = max(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                                   to: Calendar.current.startOfDay(for: exhaust)).day ?? 0, 0)
                return ("预计 \(date(exhaust)) 用尽 $60 额度 · 日均 \(Format.money(fc.dailyRate))",
                        daysLeft <= 5 ? .danger : .warn)
            }
            let remaining = max(fc.limit - (fc.projectedEnd ?? 0), 0)
            let util = fc.limit > 0 ? Int(((fc.projectedEnd ?? 0) / fc.limit) * 100) : 0
            return ("日均 \(Format.money(fc.dailyRate)) → 期末预计 \(Format.money(fc.projectedEnd ?? 0)) · 剩 \(Format.money(remaining))（利用率 \(util)%）", .ok)
        case "openrouter":
            if let exhaust = fc.exhaustDate {
                return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate)) → 约 \(date(exhaust)) 耗尽", .warn)
            }
            return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate)) · 无耗尽风险", .ok)
        default:
            return ("已付 \(Format.money(fc.used)) · 未关联用量源", .neutral)
        }
    }

    /// 紧凑单行（Popover / 设置行）。
    static func compact(for fc: SubscriptionMath.Forecast, plan: String) -> (text: String, status: Status) {
        switch plan {
        case "go":
            if let exhaust = fc.exhaustDate {
                return ("已用 \(Format.money(fc.used)) · 预计 \(date(exhaust)) 用尽", .warn)
            }
            let remaining = max(fc.limit - (fc.projectedEnd ?? 0), 0)
            return ("已用 \(Format.money(fc.used)) · 日均 \(Format.money(fc.dailyRate)) · 期末剩 \(Format.money(remaining))", .ok)
        case "openrouter":
            if let exhaust = fc.exhaustDate {
                return ("余额 \(Format.money(fc.limit)) · 约 \(date(exhaust)) 耗尽", .warn)
            }
            return ("余额 \(Format.money(fc.limit)) · 日均 \(Format.money(fc.dailyRate))", .ok)
        default:
            return ("已付 \(Format.money(fc.used)) · 未关联用量源", .neutral)
        }
    }

    static func color(_ status: Status) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .danger: return .red
        case .neutral: return .secondary
        }
    }

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
}

/// 订阅（固定成本侧）: cycle progress + renewal + 用量预测。
struct SubscriptionsView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("订阅")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    app.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            if app.subscriptions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .foregroundStyle(.secondary)
                    Text("还没有订阅记录 —— 在「设置」里添加开始日期、周期和费用，这里会显示续期倒计时与用量预测")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(app.subscriptions) { sub in
                    SubscriptionCard(sub: sub)
                }
            }
        }
    }
}

struct SubscriptionCard: View {
    let sub: Database.Subscription
    @ObservedObject private var goClient = OpenCodeGoClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: planSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(planColor)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 9).fill(planColor.opacity(0.14)))
                Text(sub.name)
                    .font(.system(size: 13, weight: .semibold))
                if !sub.plan.isEmpty {
                    Text(planLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Text("\(Format.money(sub.price))/\(cycleLabel)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }

            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
                HStack(spacing: 8) {
                    Text("第 \(info.dayOfCycle) 天 / 共 \(info.totalDays) 天")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(planColor)
                                .frame(width: max(3, geo.size.width * info.progress))
                        }
                    }
                    .frame(height: 4)
                    let daysLeft = max(Int(info.end.timeIntervalSinceNow / 86400), 0)
                    Text("\(daysLeft) 天后续期 (\(SubscriptionMath.dateStr(info.end)))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("日均 \(Format.money(sub.price / Double(info.totalDays)))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                        if sub.plan == "go" {
                            Text(fc.isBreakeven ? "价值已覆盖订阅价" : "价值尚未覆盖订阅价")
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill((fc.isBreakeven ? Color.green : Color.red).opacity(0.14)))
                                .foregroundStyle(fc.isBreakeven ? .green : .red)
                        }
                        Spacer()
                        let line = ForecastText.line(for: fc, plan: sub.plan)
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(ForecastText.color(line.status))
                    } else {
                        Spacer()
                        Text("已付 \(Format.money(sub.price)) · 未关联用量源")
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("开始日期未设置")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func valueLine(info: SubscriptionMath.CycleInfo) -> some View {
        EmptyView()
    }

    private var planColor: Color {
        switch sub.plan {
        case "go": return .orange
        case "openrouter": return ToolKind.openrouter.color
        default: return .gray
        }
    }

    private var planSymbol: String {
        switch sub.plan {
        case "go": return "g.circle.fill"
        case "openrouter": return ToolKind.openrouter.symbol
        default: return "calendar"
        }
    }

    private var planLabel: String {
        switch sub.plan {
        case "go": return "OpenCode Go"
        case "openrouter": return "OpenRouter"
        default: return ""
        }
    }

    private var cycleLabel: String {
        switch sub.cycle {
        case "yearly": return "年"
        case "weekly": return "周"
        default: return "月"
        }
    }
}
