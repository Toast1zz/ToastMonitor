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

    private let tools: [ToolKind] = [.claude, .codex, .opencode, .hermes]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TMPageHeader("来源状态")
                HStack {
                    Text("采集器状态")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        testing = true
                        testOK = false
                        testResult = nil
                        CollectorEngine.shared.scheduleScan()
                        HermesRemoteClient.shared.poll()
                        testGeneration += 1
                        let gen = testGeneration
                        // No fixed 3s guess: wait for the collector's
                        // didCollect (listener below), with a 10s ceiling.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            guard gen == testGeneration else { return }
                            testing = false
                            testOK = false
                            testResult = "10 秒内未收到扫描心跳"
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
        .onReceive(NotificationCenter.default.publisher(for: CollectorEngine.didCollect)) { _ in
            // A scan cycle completed. Only react when a test is in flight;
            // success invalidates the pending 10s timeout.
            guard testing else { return }
            testGeneration += 1
            testing = false
            testOK = true
            testResult = "扫描完成"
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
                } else if h != nil {
                    TMStatusPill(text: "正常", color: TMDesign.quiet, symbol: "checkmark.circle.fill")
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
                    .foregroundStyle(TMDesign.accent)
                    .frame(width: 20)
                Text("远程 Feed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let err = st.error {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TMDesign.danger.opacity(0.9))
                } else if st.lastSync > 0 {
                    Label("已同步", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(TMDesign.quiet)
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
                .font(.system(size: TMType.caption))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: TMType.caption, design: .monospaced))
                .monospacedDigit()
        }
    }
}
