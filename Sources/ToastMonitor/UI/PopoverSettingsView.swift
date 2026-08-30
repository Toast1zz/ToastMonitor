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
    @ObservedObject private var alerts = QuotaAlertManager.shared
    /// Optimistic local mirrors of the persisted settings so a toggle flips
    /// instantly; the database write happens off the main thread (the shared
    /// DB lock can be held by background scans, which made synchronous writes
    /// feel like a ~1s delay).
    @State private var closeOnResign: Bool = PanelController.dismissOnResign
    @State private var dockIconOn: Bool = WindowManager.dockIconEnabled
    @State private var autoCheckOn: Bool = UpdateManager.autoCheckEnabled
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            fixedSlice(.header) {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.7)
                }
            }
            VStack(alignment: .leading, spacing: 22) {
                generalSection
                UsagePeriodSettingsSection()
                updatesSection
            }
            // This page is intentionally an intrinsic-height settings sheet,
            // not a scrolling document. A ScrollView would enter its
            // overflow state for one layout pass when Calendar periods adds
            // the week-start row, showing a scrollbar before the panel can
            // apply the new measured height.
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(.body, page: .settings)
            fixedSlice(.footer) {
                VStack(spacing: 0) {
                    Divider().opacity(0.7)
                    footerNote
                }
            }
        }
        .frame(width: TMLayout.popoverWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.controlSize, .small)
        .onAppear {
            launch.refresh()
            closeOnResign = PanelController.dismissOnResign
            dockIconOn = WindowManager.dockIconEnabled
            autoCheckOn = UpdateManager.autoCheckEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: PanelController.settingsBackNotification)) { _ in
            onBack()
        }
    }

    private func fixedSlice<Content: View>(_ slice: PopoverHeightSlice,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .reportPopoverHeight(slice, page: .settings)
    }

    // MARK: - Header（Tusi 风格：返回按钮 + 标题 + 版本）

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(TMType.semibold(12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")

            Text("Settings")
                .font(TMType.semibold(TMType.section))

            Spacer()

            Text("v\(appVersion)")
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0 (dev)"
    }

    // MARK: - 通用

    /// Restore toggle for a Quota row hidden from the popover's Quota section
    /// (setting key `hide_quota_row_<key>`; on = row visible).
    private func quotaRowToggle(_ key: String, title: String) -> some View {
        Toggle("Show \(title) quota", isOn: Binding(
            get: { Database.shared.setting("hide_quota_row_\(key)") != "1" },
            set: { visible in
                let v = visible ? nil : "1"
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Database.shared.setSetting("hide_quota_row_\(key)", v)
                }
            }
        ))
        .toggleStyle(.switch)
        .font(TMType.medium(TMType.body))
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)

            Toggle("Launch at login", isOn: Binding(
                get: { launch.enabled },
                set: { launch.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(TMType.medium(TMType.body))
            .accessibilityHint("Open ToastMonitor in the menu bar when you sign in")

            Toggle("Quota and renewal notifications", isOn: Binding(
                get: { alerts.enabled },
                set: { alerts.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(TMType.medium(TMType.body))
            .accessibilityHint("Notify when quota falls below 20%, resets, or a subscription renews tomorrow")

            Toggle("Close when clicking elsewhere", isOn: $closeOnResign)
                .toggleStyle(.switch)
                .font(TMType.medium(TMType.body))
                .accessibilityHint("Keep the panel open when you click other windows or apps")
                .onChange(of: closeOnResign) { newValue in
                    // Persisted off the main thread; the panel reads the
                    // setting per event, so it applies immediately after.
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(PanelController.dismissOnResignKey, v)
                    }
                }

            Toggle("Show icon in Dock when the dashboard is open", isOn: $dockIconOn)
                .toggleStyle(.switch)
                .font(TMType.medium(TMType.body))
                .accessibilityHint("Appear as a Dock application while the dashboard window is open")
                .onChange(of: dockIconOn) { newValue in
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(WindowManager.dockIconSetting, v)
                    }
                    // Policy switch is cheap; do it now so the Dock reacts
                    // immediately, using the optimistic value, not the DB.
                    WindowManager.shared.applyDockIconSetting(newValue)
                }

            // Quota rows hidden in the Quota section can be restored here.
            Divider().opacity(0.5)
            Text("Quota rows")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)
            quotaRowToggle("claude", title: "Claude")
            quotaRowToggle("go", title: "OpenCode Go")
            quotaRowToggle("codex", title: "Codex Plus")
            quotaRowToggle("cc", title: "Command Code GOAT")
            quotaRowToggle("router", title: "OpenRouter")

            if let msg = launch.message {
                Text(msg)
                    .font(TMType.regular(TMType.caption))
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

            Toggle("Automatically check for updates", isOn: $autoCheckOn)
                .toggleStyle(.switch)
                .font(TMType.medium(TMType.body))
                .accessibilityHint("Check for new versions in the background at launch")
                .onChange(of: autoCheckOn) { newValue in
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(UpdateManager.autoCheckSetting, v)
                    }
                    // Turning auto-check on starts the launch + 24h cadence
                    // immediately (including one check right away).
                    if newValue {
                        UpdateManager.shared.startAutoCheckIfEnabled()
                    }
                }

            HStack(spacing: 10) {
                if updates.checking {
                    Button("Checking…") {}
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                } else if let update = updates.available {
                    Text("ToastMonitor \(update.version) is available")
                        .font(TMType.regular(TMType.caption))
                        .foregroundStyle(TMDesign.accent)
                    Button("Download & Install") {
                        Task { await UpdateManager.shared.installAndRelaunch() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    // A real button (bordered + icon), not bare text, so it
                    // reads as the manual trigger; it stays visible after a
                    // check so a re-check is always one click away.
                    Button {
                        Task { await UpdateManager.shared.check(force: true) }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                            .font(TMType.regular(TMType.caption))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let error = updates.lastError {
                        Text(error)
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.danger)
                            .lineLimit(2)
                    } else if updates.lastCheckAt != nil {
                        Text("You're up to date")
                            .font(TMType.regular(TMType.caption))
                            .foregroundStyle(TMDesign.quiet)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if updates.installing {
                Text("Downloading, verifying and installing…")
                    .font(TMType.regular(TMType.caption))
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
