import SwiftUI

/// 数据来源 (spec §3.2): 每个采集器一张状态卡 — 模式/最后扫描/条数/失败/耗时/错误，
/// 测试连接 + 立即重扫入口。来源切换立即保存并反馈。
struct SourcesView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var remote = HermesRemoteClient.shared
    @State private var testing = false
    @State private var testResult: String?
    /// True when the last test ended in a completed scan (colors the result).
    @State private var testOK = false
    /// Bumped per test start; stale 10s timeouts check it before firing.
    @State private var testGeneration = 0

    private let tools: [ToolKind] = [.claude, .codex, .opencode, .hermes, .omp]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("采集器状态")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        testing = true
                        testOK = false
                        testResult = nil
                        testGeneration += 1
                        let gen = testGeneration
                        CollectorEngine.shared.scheduleScan(force: true) { receipt in
                            guard gen == testGeneration, testing else { return }
                            testing = false
                            testGeneration += 1
                            if receipt.failedSources.isEmpty {
                                testOK = true
                                testResult = "扫描完成（\(receipt.turns) 条新增）"
                            } else {
                                testOK = false
                                testResult = "来源异常：\(receipt.failedSources.joined(separator: "、"))"
                            }
                        }
                        HermesRemoteClient.shared.poll()
                        // A completion belongs to this forced scan; the timeout
                        // only covers a genuinely stalled collector.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            guard gen == testGeneration else { return }
                            testing = false
                            testOK = false
                            testResult = "10 秒内未完成扫描"
                        }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("测试连接", systemImage: "bolt")
                        }
                    }
                    .disabled(testing)
                    .accessibilityLabel("测试连接")
                    .accessibilityValue(testing ? "等待首次扫描" : "准备就绪")
                    .accessibilityHint("启动一次立即扫描并检查各来源状态")
                    Button {
                        CollectorEngine.shared.scheduleScan()
                        OpenRouterClient.shared.refresh()
                        OpenCodeGoClient.shared.refresh()
                    } label: {
                        Label("立即重扫", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("立即重扫")
                    .accessibilityHint("重新扫描所有本机来源并刷新远程额度")
                }
                if let tr = testResult {
                    Text(tr)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("连接测试结果")
                        .accessibilityValue(Text(tr))
                        .font(.system(size: 11))
                        .foregroundStyle(testOK ? TMDesign.accent : TMDesign.danger)
                }

                ForEach(tools) { t in
                    sourceCard(t)
                }
                remoteCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private func sourceCard(_ tool: ToolKind) -> some View {
        let h = health.sources.first { $0.tool == tool.rawValue }
        let isRemote = tool.sourceIsRemote
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tool.color)
                    .frame(width: 20)
                Text(tool.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(isRemote ? "远程" : "本机")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                if h?.error != nil {
                    TMStatusPill(text: "异常", color: TMDesign.danger, symbol: "xmark.circle.fill")
                } else if h?.isStale == true {
                    TMStatusPill(text: "过期", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                } else if (h?.lastScan ?? 0) > 0 {
                    TMStatusPill(text: "已同步", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                } else {
                    TMStatusPill(text: "未知", color: TMDesign.quiet, symbol: "questionmark.circle")
                }
            }
            HStack(spacing: 16) {
                infoItem("最后扫描", h.map { Format.dateTime($0.lastScan) } ?? "—")
                infoItem("最近导入", h.map { "\($0.lastRows) 条" } ?? "—")
                infoItem("解析失败", h.map { "\($0.failedRows)" } ?? "—")
                infoItem("耗时", h.map { String(format: "%.0fms", $0.durationMs) } ?? "—")
            }
            if let err = h?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(TMDesign.danger.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.displayName) 来源")
        .accessibilityValue(Text(sourceAccessibilityValue(h)))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }

    private func sourceAccessibilityValue(_ health: SourceHealth?) -> String {
        guard let health else { return "未知，等待首次扫描" }
        let status: String
        if health.error != nil {
            status = "异常"
        } else if health.isStale {
            status = "过期"
        } else if health.lastScan > 0 {
            status = "已同步"
        } else {
            status = "未知，等待首次扫描"
        }
        let scannedAt = health.lastScan > 0 ? Format.dateTime(health.lastScan) : "—"
        return "\(status)，最后扫描 \(scannedAt)，最近导入 \(health.lastRows) 条，解析失败 \(health.failedRows) 条"
    }

    private var remoteCard: some View {
        let st = remote.status
        let stale = st.lastSync > 0
            && Date().timeIntervalSince1970 - TimeInterval(st.lastSync) > 120
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TMDesign.accent)
                    .frame(width: 20)
                Text("远程 Feed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if st.error != nil {
                    TMStatusPill(text: "异常", color: TMDesign.danger, symbol: "xmark.circle.fill")
                } else if stale {
                    TMStatusPill(text: "过期", color: TMDesign.accent, symbol: "clock.badge.exclamationmark")
                } else if st.lastSync > 0 {
                    TMStatusPill(text: "已同步", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
                } else {
                    TMStatusPill(text: "未知", color: TMDesign.quiet, symbol: "questionmark.circle")
                }
            }
            HStack(spacing: 16) {
                infoItem("上次同步", st.lastSync > 0 ? Format.dateTime(st.lastSync) : "—")
                infoItem("最近导入", "\(st.lastRows) 条")
                infoItem("数据延迟", st.lastSync > 0 ? Format.remaining(Int64(Date().timeIntervalSince1970) - st.lastSync) : "—")
            }
            if let err = st.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(TMDesign.danger.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("远程 Feed")
        .accessibilityValue(Text(remoteAccessibilityValue(st, stale: stale)))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }

    private func remoteAccessibilityValue(_ status: HermesRemoteClient.SyncStatus, stale: Bool) -> String {
        let state: String
        if status.error != nil {
            state = "异常"
        } else if stale {
            state = "过期"
        } else if status.lastSync > 0 {
            state = "已同步"
        } else {
            state = "未知，等待首次扫描"
        }
        return "\(state)，上次同步 \(status.lastSync > 0 ? Format.dateTime(status.lastSync) : "—")，最近导入 \(status.lastRows) 条"
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: TMType.caption))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: TMType.caption, design: .monospaced))
                .monospacedDigit()
        }
    }
}
