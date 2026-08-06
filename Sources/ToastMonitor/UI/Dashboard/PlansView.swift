import SwiftUI

/// 计划与余额 (spec §3.2): 一个服务一张主卡，额度/固定费用/续期/余额在同一上下文，
/// 清楚区分「额度消耗」「现金余额」「固定订阅价格」「估算价值」。
struct PlansView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var goClient = OpenCodeGoClient.shared
    @ObservedObject private var orClient = OpenRouterClient.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TMPageHeader(
                    title: "计划与余额",
                    subtitle: "把实际支出、估算、固定订阅和额度消耗分开显示",
                    eyebrow: "财务"
                )
                goCard
                Divider()
                orCard
                Divider()
                subsCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    // MARK: - OpenCode Go

    private var goCard: some View {
        let go = goClient.state
        return serviceCard(title: "OpenCode Go", icon: "g.circle.fill", color: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("状态")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if go.isLoading {
                        ProgressView().controlSize(.mini)
                    } else if !goClient.configured {
                        Text("未配置")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else if go.error != nil {
                        TMStatusPill(text: "同步失败", color: .red, symbol: "xmark.circle.fill")
                    } else {
                        Label("已同步", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }

                if let err = go.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }

                if let pct = go.monthlyPct {
                    HStack {
                        Text("额度消耗")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Format.money(pct / 100 * OpenCodeGoClient.monthlyLimitUSD)) / $\(Int(OpenCodeGoClient.monthlyLimitUSD))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                        Text("\(Int(pct))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(pct > 95 ? .red : (pct > 80 ? .orange : .green))
                    }
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(pct > 95 ? Color.red : (pct > 80 ? Color.orange : Color.green))
                                .frame(width: max(3, w * CGFloat(pct / 100)))
                            let breakEven = subForGo?.price ?? 10
                            Rectangle()
                                .fill(Color.primary.opacity(0.45))
                                .frame(width: 1)
                                .offset(x: w * CGFloat(min(breakEven / OpenCodeGoClient.monthlyLimitUSD, 1)) - 0.5)
                        }
                    }
                    .frame(height: 8)
                    Text("竖线 = 订阅价格参考线（\(Format.money(subForGo?.price ?? 10))），非官方回本结论")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                windowRow("5 小时窗口", pct: go.rollingPct, reset: go.rollingReset)
                windowRow("本周窗口", pct: go.weeklyPct, reset: go.weeklyReset)
                windowRow("本月窗口", pct: go.monthlyPct, reset: go.monthlyReset)

                if let sub = subForGo, let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
                    Divider()
                    HStack {
                        Text("固定订阅")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "月" : "年")")
                            .font(.system(size: 12, design: .monospaced))
                            .monospacedDigit()
                        Text("周期第 \(info.dayOfCycle)/\(info.totalDays) 天")
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                        let line = ForecastText.compact(for: fc, plan: sub.plan)
                        HStack {
                            Text("预测")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(ForecastText.color(line.status))
                        }
                    }
                }
            }
        }
    }

    private func windowRow(_ label: String, pct: Double?, reset: Int64?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if let pct {
                Text("\(Int(pct))%")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pct > 95 ? .red : (pct > 80 ? .orange : .primary))
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let reset, goClient.state.lastSync > 0 {
                let absReset = goClient.state.lastSync + reset
                Text("重置 \(Format.remaining(absReset - Int64(Date().timeIntervalSince1970)))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subForGo: Database.Subscription? {
        app.subscriptions.first { $0.plan == "go" }
    }

    // MARK: - OpenRouter

    private var orCard: some View {
        let or = orClient.state
        return serviceCard(title: "OpenRouter", icon: ToolKind.openrouter.symbol, color: ToolKind.openrouter.color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("状态")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else if or.error != nil {
                        TMStatusPill(text: "部分失败", color: .red, symbol: "exclamationmark.triangle.fill")
                    } else {
                        Label("已同步", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }

                if let err = or.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }

                if orClient.hasKey {
                    metricRow("现金余额", Format.money(or.accountBalance ?? 0))
                    metricRow("今日实际使用", Format.money(or.usageDaily))
                    metricRow("本月实际使用", Format.money(or.usageMonthly))
                    if let limit = or.limit {
                        metricRow("key 限额", "\(Format.money(limit)) · 剩余 \(Format.money(or.limitRemaining ?? 0))")
                    }
                    Text(or.isManagementKey
                         ? "能力：管理 key 可枚举全部 key 与账户额度；余额来自账户级 credits。"
                         : "能力：普通 key 仅可查本 key 用量与账户余额；key 限额仅管理 key 可见。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("未配置 API key，无法读取 OpenRouter 额度")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
    }

    // MARK: - 固定订阅

    private var subsCard: some View {
        serviceCard(title: "固定订阅", icon: "calendar", color: .gray) {
            if app.subscriptions.isEmpty {
                Text("暂无订阅 — 在设置页添加（如 OpenCode Go $10/月）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(app.subscriptions) { sub in
                        HStack {
                            Text(sub.name)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(Format.money(sub.price))/\(sub.cycle == "monthly" ? "月" : "年")")
                                .font(.system(size: 11.5, design: .monospaced))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        if sub.id != app.subscriptions.last?.id { Divider() }
                    }
                }
                Text("固定订阅金额不与其他口径相加（不计入 API 支出统计）")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 容器

    private func serviceCard<Content: View>(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }
}
