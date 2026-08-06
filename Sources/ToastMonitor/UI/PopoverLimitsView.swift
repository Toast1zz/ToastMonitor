import SwiftUI

/// Popover 额度页：OpenCode Go 与 OpenRouter 完整卡 + 固定订阅列表。
struct PopoverLimitsView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("OpenCode Go")
                goCard
                Divider()
                sectionLabel("OpenRouter")
                orCard
                if !app.subscriptions.isEmpty {
                    Divider()
                    sectionLabel("固定订阅")
                    ForEach(app.subscriptions) { sub in
                        subRow(sub)
                    }
                }
                Spacer(minLength: 8)
            }
        }
    }

    // MARK: - OpenCode Go 完整卡（额度 + 窗口 + 订阅 + 预测）

    private var goCard: some View {
        let go = goClient.state
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "g.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text("OpenCode Go 套餐")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if go.isLoading {
                    ProgressView().controlSize(.mini)
                } else if !goClient.configured {
                    Text("未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else if let err = go.error {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }
            }

            if let pct = go.monthlyPct {
                // 月额度
                HStack(spacing: 8) {
                    Text("月额度")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("\(Format.money(pct / 100 * OpenCodeGoClient.monthlyLimitUSD)) / $\(Int(OpenCodeGoClient.monthlyLimitUSD))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Spacer()
                    Text("\(Int(pct))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(pct > 95 ? .red : (pct > 80 ? .orange : .green))
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(pct > 95 ? Color.red : (pct > 80 ? Color.orange : Color.green))
                            .frame(width: max(3, w * CGFloat(pct / 100)))
                        let breakEven = subForGo?.price ?? 10
                        Rectangle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 1)
                            .offset(x: w * CGFloat(min(breakEven / OpenCodeGoClient.monthlyLimitUSD, 1)) - 0.5)
                    }
                }
                .frame(height: 8)
            }

            // 窗口明细（绝对重置时间推算，倒计时递减）
            windowRow("5 小时", pct: go.rollingPct, reset: go.rollingReset)
            windowRow("本周", pct: go.weeklyPct, reset: go.weeklyReset)
            windowRow("本月", pct: go.monthlyPct, reset: go.monthlyReset)

            // 订阅
            if let sub = subForGo, let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
                HStack(spacing: 8) {
                    Text("订阅")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "月" : "年")")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                    Spacer()
                    Text("周期第 \(info.dayOfCycle)/\(info.totalDays) 天")
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                    let line = ForecastText.compact(for: fc, plan: sub.plan)
                    HStack(spacing: 8) {
                        Text("预测")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .font(.system(size: 10, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(ForecastText.color(line.status))
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func windowRow(_ label: String, pct: Double?, reset: Int64?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            if let pct {
                Text("\(Int(pct))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pct > 95 ? .red : (pct > 80 ? .orange : .secondary))
            } else {
                Text("—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if let reset, goClient.state.lastSync > 0 {
                let absReset = goClient.state.lastSync + reset
                Spacer()
                Text("重置 \(Format.remaining(absReset - Int64(Date().timeIntervalSince1970)))")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subForGo: Database.Subscription? {
        app.subscriptions.first { $0.plan == "go" }
    }

    // MARK: - OpenRouter 完整卡

    private var orCard: some View {
        let or = orClient.state
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ToolKind.openrouter.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ToolKind.openrouter.color)
                    .frame(width: 18)
                Text("OpenRouter")
                    .font(.system(size: 12.5, weight: .medium))
                if or.isManagementKey {
                    Text("管理 key")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(ToolKind.openrouter.color.opacity(0.14)))
                        .foregroundStyle(ToolKind.openrouter.color)
                }
                Spacer()
                if or.isLoading {
                    ProgressView().controlSize(.mini)
                } else if !orClient.hasKey {
                    Text("未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            if let err = or.error {
                VStack(alignment: .leading, spacing: 3) {
                    TMStatusPill(text: "部分同步失败", color: .red, symbol: "exclamationmark.triangle.fill")
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }
            }

            if orClient.hasKey && or.error == nil {
                metricRow("可用余额", Format.money(or.accountBalance ?? 0))
                metricRow("今日实际使用", Format.money(or.usageDaily))
                metricRow("本月实际使用", Format.money(or.usageMonthly))
                if let limit = or.limit {
                    metricRow("key 限额", "\(Format.money(limit)) · 剩余 \(Format.money(or.limitRemaining ?? 0))")
                }
                Text(or.isManagementKey ? "管理 key：可枚举全部 key 与账户额度"
                     : "普通 key：仅可查本 key 用量与账户余额")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
    }

    // MARK: - 订阅

    private func subRow(_ sub: Database.Subscription) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sub.plan == "go" ? "g.circle.fill" : (sub.plan == "openrouter" ? ToolKind.openrouter.symbol : "calendar"))
                .font(.system(size: 10))
                .foregroundStyle(sub.plan == "go" ? .orange : (sub.plan == "openrouter" ? ToolKind.openrouter.color : .gray))
                .frame(width: 16)
            Text(sub.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "月" : "年")")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
}
