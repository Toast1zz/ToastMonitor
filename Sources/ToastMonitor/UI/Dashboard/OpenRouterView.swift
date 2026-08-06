import SwiftUI
import Charts

/// OpenRouter 配额面板: key management + live state + snapshot history.
struct OpenRouterView: View {
    @ObservedObject var client = OpenRouterClient.shared
    @State private var keyInput = ""
    @State private var showKey = false
    @State private var appendMode = false
    @State private var snapshots: [Database.ORSnapshot] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Key management
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 10) {
                        if client.hasKey {
                            Text("已配置 \(client.state.keyCount) 个 key（存于钥匙串）")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        } else {
                            Text("未配置 — OpenRouter 配额需要 key 才能查询")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button(client.hasKey ? "更换" : "添加") {
                            keyInput = ""
                            showKey = true
                            appendMode = false
                        }
                        .font(.system(size: 12))
                        if client.hasKey {
                            Button("追加 Key") {
                                keyInput = ""
                                showKey = true
                                appendMode = true
                            }
                            .font(.system(size: 12))
                            .help("多 key 兜底：追加后按 key 分别查询并汇总")
                            Button("移除") {
                                client.setKey(nil)
                            }
                            .font(.system(size: 12))
                        }
                        Button {
                            client.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .font(.system(size: 12))
                        .disabled(!client.hasKey)
                    }
                    if showKey {
                        HStack {
                            SecureField("sk-or-...", text: $keyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("保存") {
                                let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                let ok: Bool
                                if appendMode {
                                    ok = client.addKey(k)
                                } else {
                                    ok = client.setKey(k)
                                }
                                if ok { showKey = false }
                            }
                            .font(.system(size: 12))
                            Button("取消") { showKey = false }
                                .font(.system(size: 12))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))

                // Live state
                if client.hasKey {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("当前状态")
                                .font(.system(size: 13, weight: .semibold))
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
                        }

                        HStack(spacing: 24) {
                            liveStat("账户总用量（所有 key）", client.state.accountUsage.map(Format.money) ?? "—")
                            liveStat("余额", Format.money(client.state.accountBalance ?? 0))
                            liveStat("今日（已配 key）", Format.money(client.state.usageDaily))
                            liveStat("本月（已配 key）", Format.money(client.state.usageMonthly))
                        }

                        if client.state.isManagementKey {
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                Text("管理级 key：账户内 \(client.state.keyCount) 个 key 全部可见")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            if !client.state.keys.isEmpty {
                                VStack(spacing: 4) {
                                    ForEach(Array(client.state.keys.enumerated()), id: \.offset) { _, k in
                                        HStack {
                                            Text(k.label)
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Text("今日 \(Format.money(k.usageDaily)) · 本月 \(Format.money(k.usageMonthly))")
                                                .font(.system(size: 10, design: .monospaced))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        } else {
                            Text("普通 key：账户总用量含全部 key，但「今日/本月」仅统计已配置的 \(client.state.keyCount) 个 key。建议在控制台创建管理级 key 获得全账户明细")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }

                        if let remaining = client.state.limitRemaining {
                            let total = client.state.limit ?? remaining
                            let pct = total > 0 ? remaining / total : 0
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("key 额度")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("剩余 \(Format.money(remaining)) / \(Format.money(total))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .monospacedDigit()
                                    if let reset = client.state.limitReset {
                                        Text("重置: \(reset)")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                ProgressView(value: pct)
                                    .tint(pct < 0.2 ? .red : pct < 0.5 ? .orange : .green)
                            }
                        }
                        if let credits = client.state.creditsTotal {
                            HStack {
                                Text("累计购买 credits")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Format.money(credits))（已用 \(Format.money(client.state.creditsUsage ?? 0))）")
                                    .font(.system(size: 11, design: .monospaced))
                                    .monospacedDigit()
                            }
                        }
                        if client.state.isFreeTier {
                            Text("免费层账户 — 有限制请求配额")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                }

                // History chart
                if !snapshots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用量快照历史")
                            .font(.system(size: 13, weight: .semibold))
                        Chart(snapshots.reversed()) { s in
                            LineMark(
                                x: .value("时间", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                                y: .value("用量", s.usage)
                            )
                            .foregroundStyle(.red.opacity(0.8))
                            .interpolationMethod(.catmullRom)
                            if let limit = s.limit {
                                RuleMark(y: .value("额度", limit))
                                    .foregroundStyle(.gray.opacity(0.4))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let v = value.as(Double.self) { Text(Format.moneyShort(v)) }
                                }
                            }
                        }
                        .frame(height: 220)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { loadSnapshots() }
        .onReceive(client.$state) { _ in loadSnapshots() }
    }

    private func loadSnapshots() {
        UsageQueryService.shared.loadORSnapshots(limit: 200) { snapshots = $0 }
    }

    private func liveStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced)).monospacedDigit()
        }
    }
}
