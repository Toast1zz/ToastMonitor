import SwiftUI
import Charts

/// OpenCode Go 套餐配额面板: 5小时 / 每周 / 每月 用量条 + 重置倒计时 + 历史。
struct OpenCodeGoView: View {
    @ObservedObject var client = OpenCodeGoClient.shared
    @State private var snapshots: [Database.OGSnapshot] = []
    @State private var wsInput = ""
    @State private var ckInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header / config status
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "g.circle.fill")
                                .foregroundStyle(.orange)
                            Text("OpenCode Go 套餐")
                                .font(.system(size: 15, weight: .semibold))
                            Text("$10/月 · 订阅制")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Text("套餐独立于 OpenCode 工具 —— 统计的是 Go 订阅本身的花费")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if client.state.isLoading {
                        ProgressView().controlSize(.mini)
                    } else if let err = client.state.error {
                        Text(err).font(.system(size: 11)).foregroundStyle(.red)
                    } else if client.state.lastOK > 0 {
                        Text("更新于 \(Format.dateTime(client.state.lastOK))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        client.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .disabled(!client.configured)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))

                if client.configured {
                    // Quota bars
                    VStack(alignment: .leading, spacing: 16) {
                        quotaBar("5 小时滚动", pct: client.state.rollingPct, reset: client.state.rollingReset,
                                 limit: OpenCodeGoClient.rollingLimitUSD, color: .orange)
                        quotaBar("每周", pct: client.state.weeklyPct, reset: client.state.weeklyReset,
                                 limit: OpenCodeGoClient.weeklyLimitUSD, color: .yellow)
                        quotaBar("每月", pct: client.state.monthlyPct, reset: client.state.monthlyReset,
                                 limit: OpenCodeGoClient.monthlyLimitUSD, color: .red)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))

                    // History
                    if !snapshots.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("月度用量历史")
                                .font(.system(size: 13, weight: .semibold))
                            Chart(snapshots.reversed()) { s in
                                if let pct = s.monthlyPct {
                                    LineMark(
                                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                                        y: .value("用量 %", pct)
                                    )
                                    .foregroundStyle(.red.opacity(0.8))
                                    .interpolationMethod(.catmullRom)
                                }
                                if let pct = s.weeklyPct {
                                    LineMark(
                                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                                        y: .value("用量 %", pct)
                                    )
                                    .foregroundStyle(.yellow.opacity(0.7))
                                    .interpolationMethod(.catmullRom)
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let v = value.as(Double.self) { Text("\(Int(v))%") }
                                    }
                                }
                            }
                            .frame(height: 200)
                        }
                    }

                    Text("额度按美元计：5h=$12 · 周=$30 · 月=$60；用超后可继续用免费模型（或开启 Zen 余额兜底）")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)

                    // Subscriptions (fixed-cost side)
                    Divider()
                    SubscriptionsView()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.slash")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("未配置 Go 套餐凭据")
                            .font(.system(size: 13, weight: .medium))
                        VStack(spacing: 8) {
                            TextField("workspaceId (wrk_...)", text: $wsInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 380)
                            SecureField("authCookie (Fe26.2**...)", text: $ckInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 380)
                            HStack(spacing: 12) {
                                Button("保存并查询") {
                                    let ws = wsInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let ck = ckInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !ws.isEmpty, !ck.isEmpty else { return }
                                    if client.provision(workspaceId: ws, cookie: ck) {
                                        client.refresh()
                                    }
                                }
                                .font(.system(size: 12))
                                Text("或命令行: --provision-go <workspaceId>，cookie 从 stdin 输入")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            }
            .padding(18)
        }
        .onAppear { loadSnapshots() }
        .onReceive(client.$state) { _ in loadSnapshots() }
    }

    private func loadSnapshots() {
        UsageQueryService.shared.loadOGSnapshots(limit: 200) { snapshots = $0 }
    }

    private func quotaBar(_ title: String, pct: Double?, reset: Int64?,
                          limit: Double, color: Color) -> some View {
        let p = pct ?? 0
        let used = p / 100 * limit
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if pct != nil {
                    Text("已用 \(Format.money(used)) / \(Format.money(limit))")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: p / 100)
                .tint(p > 80 ? .red : p > 50 ? .orange : color)
            HStack {
                Text("\(Int(p))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset {
                    Text("重置于 \(Self.countdown(reset))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func countdown(_ secs: Int64) -> String {
        if secs <= 0 { return "即将重置" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分后"
    }
}
