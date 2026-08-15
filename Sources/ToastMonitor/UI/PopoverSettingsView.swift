import SwiftUI
import AppKit
import ServiceManagement

/// 开机自启动开关的系统状态封装（SMAppService.mainApp，macOS 13+）。
/// 状态始终以系统实际状态为准：注册失败/待批准时回滚开关并给出原因。
@MainActor
final class LaunchAtLoginSettings: ObservableObject {
    static let shared = LaunchAtLoginSettings()

    @Published private(set) var enabled: Bool
    /// 失败/待批准时的说明；nil = 正常。
    @Published private(set) var message: String?

    private init() {
        let st = SMAppService.mainApp.status
        enabled = st == .enabled
        message = Self.hint(for: st)
    }

    /// 从系统状态刷新（设置页出现时），不写系统。
    func refresh() {
        let st = SMAppService.mainApp.status
        enabled = st == .enabled
        message = Self.hint(for: st)
    }

    /// 切换开关。写入失败回滚并给出原因；部分系统上 register() 成功返回
    /// 但仍需用户在「系统设置 → 通用 → 登录项」里批准（.requiresApproval）。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            enabled = !on
            message = "Launch at login failed: \(error.localizedDescription)"
            return
        }
        refresh()
    }

    private static func hint(for st: SMAppService.Status) -> String? {
        switch st {
        case .requiresApproval:
            return "Approval required — System Settings → General → Login Items"
        case .notFound:
            return "Move ToastMonitor to /Applications to enable launch at login"
        default:
            return nil
        }
    }
}

// MARK: - Popover 内嵌设置页

/// Popover 的第二页（仿 Tusi：同一面板内 ZStack 切换，不做新窗口）。
/// 只放前端/外观类设置；订阅、凭据、来源等数据配置一律在主面板。
struct PopoverSettingsView: View {
    @ObservedObject private var launch = LaunchAtLoginSettings.shared
    @ObservedObject private var updates = UpdateManager.shared
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            fixedSlice(kind: "header") {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.7)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    generalSection
                    updatesSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .fixedSize(horizontal: false, vertical: true)
                .reportPopoverHeight(kind: "body", page: "settings")
            }
            fixedSlice(kind: "footer") {
                VStack(spacing: 0) {
                    Divider().opacity(0.7)
                    footerNote
                }
            }
        }
        .frame(width: 400)
        .environment(\.controlSize, .small)
        .onAppear { launch.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PanelController.settingsBackNotification)) { _ in
            onBack()
        }
    }

    private func fixedSlice<Content: View>(kind: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(kind: kind, page: "settings")
    }

    // MARK: - Header（Tusi 风格：返回按钮 + 标题 + 版本）

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")

            Text("Settings")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Text("v\(appVersion)")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0 (dev)"
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)

            Toggle("Launch at login", isOn: Binding(
                get: { launch.enabled },
                set: { launch.setEnabled($0) }
            ))
            .toggleStyle(TMSwitchStyle())
            .font(.system(size: 12.5, weight: .medium))
            .accessibilityHint("Open ToastMonitor in the menu bar when you sign in")

            Toggle("Close when clicking elsewhere", isOn: Binding(
                get: { PanelController.dismissOnResign },
                set: { Database.shared.setSetting(
                    PanelController.dismissOnResignKey, $0 ? "1" : "0") }
            ))
            .toggleStyle(TMSwitchStyle())
            .font(.system(size: 12.5, weight: .medium))
            .accessibilityHint("Keep the panel open when you click other windows or apps")

            if let msg = launch.message {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(TMDesign.danger)
            }
        }
    }

    // MARK: - 更新

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)

            Toggle("Automatically check for updates", isOn: Binding(
                get: { UpdateManager.autoCheckEnabled },
                set: { Database.shared.setSetting(
                    UpdateManager.autoCheckSetting, $0 ? "1" : "0") }
            ))
            .toggleStyle(TMSwitchStyle())
            .font(.system(size: 12.5, weight: .medium))
            .accessibilityHint("Check for new versions in the background at launch")

            HStack(spacing: 8) {
                Button("Check for Updates…") {
                    Task { await UpdateManager.shared.check(force: true) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))

                if updates.checking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let update = updates.available {
                    Text("ToastMonitor \(update.version) is available")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.accent)
                    Button("Download & Install") {
                        Task { await UpdateManager.shared.installAndRelaunch() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if let error = updates.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.danger)
                        .lineLimit(2)
                } else if updates.lastCheckAt != nil {
                    Text("You're up to date")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.quiet)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if updates.installing {
                Text("Downloading, verifying and installing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerNote: some View {
        HStack {
            Text("Subscriptions & credentials live in the Dashboard.")
                .font(.system(size: TMType.micro))
                .foregroundStyle(TMDesign.faint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

}
