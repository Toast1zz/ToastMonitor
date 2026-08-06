import SwiftUI

/// 数据来源 (spec §3.2): 每个采集器一张状态卡 — 模式/最后扫描/条数/失败/耗时/错误，
/// 测试连接 + 立即重扫入口。来源切换立即保存并反馈。
struct SourcesView: View {
    @ObservedObject private var health = SourceHealthHub.shared
    @ObservedObject private var remote = HermesRemoteClient.shared
    @State private var testing = false
    @State private var testResult: String?

    private let tools: [ToolKind] = [.claude, .codex, .opencode, .hermes]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TMPageHeader(
                    title: "来源状态",
                    subtitle: "确认本机日志、远程 Feed 和最近一次采集结果",
                    eyebrow: "数据状态"
                )
                HStack {
                    Text("采集器状态")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        testing = true
                        testResult = nil
                        let baseline = health.sources.map(\.lastScan).max() ?? 0
                        CollectorEngine.shared.scheduleScan()
                        HermesRemoteClient.shared.start()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            testing = false
                            let scanned = health.sources.contains { $0.lastScan > baseline }
                            testResult = scanned ? "本次扫描已完成，结果见各卡片" : "扫描已触发，尚未收到新的完成心跳（请查看各卡片）"
                        }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("测试连接", systemImage: "bolt")
                        }
                    }
                    .disabled(testing)
                    Button {
                        CollectorEngine.shared.scheduleScan()
                        OpenRouterClient.shared.refresh()
                        OpenCodeGoClient.shared.refresh()
                    } label: {
                        Label("立即重扫", systemImage: "arrow.clockwise")
                    }
                }
                if let tr = testResult {
                    Text(tr)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
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
                    TMStatusPill(text: "异常", color: .red, symbol: "xmark.circle.fill")
                } else if h?.isStale == true {
                    TMStatusPill(text: "过期", color: .orange, symbol: "clock.badge.exclamationmark")
                } else if h != nil {
                    TMStatusPill(text: "正常", color: .green, symbol: "checkmark.circle.fill")
                }
            }
            HStack(spacing: 16) {
                infoItem("最后扫描", h.map { Format.dateTime($0.lastScan) } ?? "—")
                infoItem("最近导入", h.map { "\($0.lastRows) 条" } ?? "—")
                infoItem("解析失败", h.map { "\($0.failedRows)" } ?? "—")
                infoItem("耗时", h.map { String(format: "%.0fms", $0.durationMs) } ?? "—")
            }
            Text(isRemote ? "实际生效配置：远程 VPS feed（\(remote.feedURL)）"
                 : "实际生效配置：本机日志目录")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            if let err = h?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }

    private var remoteCard: some View {
        let st = remote.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text("远程 Feed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let err = st.error {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red.opacity(0.9))
                } else if st.lastSync > 0 {
                    Label("已同步", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                } else {
                    Text("未同步")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                infoItem("上次同步", st.lastSync > 0 ? Format.dateTime(st.lastSync) : "—")
                infoItem("最近导入", "\(st.lastRows) 条")
                infoItem("数据延迟", st.lastSync > 0 ? Format.remaining(Int64(Date().timeIntervalSince1970) - st.lastSync) : "—")
            }
            Text("Feed: \(remote.feedURL) · 校验 scheme/host/MIME/schema，未知工具拒绝导入")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TMDesign.divider, lineWidth: 1)
        }
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
        }
    }
}
