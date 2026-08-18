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
    /// Optimistic local mirrors of the persisted settings so a toggle flips
    /// instantly; the database write happens off the main thread (the shared
    /// DB lock can be held by background scans, which made synchronous writes
    /// feel like a ~1s delay).
    @State private var closeOnResign: Bool = PanelController.dismissOnResign
    @State private var dockIconOn: Bool = WindowManager.dockIconEnabled
    @State private var autoCheckOn: Bool = UpdateManager.autoCheckEnabled
    @ObservedObject private var ccQuota = CommandCodeQuotaClient.shared
    @State private var showCCForm = false
    @State private var ccCookie = ""
    @State private var ccFormMessage: String?
    let onBack: () -> Void

    private var ccLastSyncText: String {
        guard ccQuota.state.lastSync > 0 else { return "never" }
        return Format.remaining(Int64(Date().timeIntervalSince1970) - ccQuota.state.lastSync) + " ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            fixedSlice(kind: "header") {
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
            .reportPopoverHeight(kind: "body", page: "settings")
            fixedSlice(kind: "footer") {
                VStack(spacing: 0) {
                    Divider().opacity(0.7)
                    footerNote
                }
            }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.controlSize, .small)
        .sheet(isPresented: $showCCForm) {
            ccSessionForm
        }
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
        .toggleStyle(TMSwitchStyle())
        .font(.system(size: 12.5, weight: .medium))
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
            .toggleStyle(TMSwitchStyle())
            .font(.system(size: 12.5, weight: .medium))
            .accessibilityHint("Open ToastMonitor in the menu bar when you sign in")

            Toggle("Close when clicking elsewhere", isOn: $closeOnResign)
                .toggleStyle(TMSwitchStyle())
                .font(.system(size: 12.5, weight: .medium))
                .accessibilityHint("Keep the panel open when you click other windows or apps")
                .onChange(of: closeOnResign) { _, newValue in
                    // Persisted off the main thread; the panel reads the
                    // setting per event, so it applies immediately after.
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(PanelController.dismissOnResignKey, v)
                    }
                }

            Toggle("Show icon in Dock when the dashboard is open", isOn: $dockIconOn)
                .toggleStyle(TMSwitchStyle())
                .font(.system(size: 12.5, weight: .medium))
                .accessibilityHint("Appear as a Dock application while the dashboard window is open")
                .onChange(of: dockIconOn) { _, newValue in
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
            quotaRowToggle("go", title: "OpenCode Go")
            quotaRowToggle("codex", title: "Codex Plus")
            quotaRowToggle("cc", title: "Command Code GOAT")
            quotaRowToggle("router", title: "OpenRouter")

            // Command Code session management (experimental).
            Divider().opacity(0.5)
            Text("Command Code GOAT (experimental)")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)
            if ccQuota.state.configured {
                Text("Session configured · last sync \(ccLastSyncText)")
                    .font(.system(size: 11))
                    .foregroundStyle(TMDesign.quiet)
                HStack(spacing: 8) {
                    Button("Refresh Now") { CommandCodeQuotaClient.shared.refresh() }
                    Button("Update Session…") { showCCForm = true }
                    Button("Clear Session") { CommandCodeQuotaClient.shared.clear() }
                        .foregroundStyle(TMDesign.danger)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Configure Command Code…") { showCCForm = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let ccError = ccQuota.state.error {
                Text(ccError)
                    .font(.system(size: 11))
                    .foregroundStyle(TMDesign.danger)
                    .lineLimit(2)
            }

            if let msg = launch.message {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(TMDesign.danger)
            }
        }
    }

    // MARK: - 更新

    /// Secure session form for Command Code (experimental). Accepts the full
    /// Cookie header from the Studio browser session, or a bare session token.
    private var ccSessionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Command Code GOAT Session")
                .font(.system(size: 14, weight: .semibold))
            Text("Paste the Cookie header from your logged-in commandcode.ai "
                 + "browser session (or just the session token). Stored only "
                 + "in the macOS Keychain; experimental private API.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Cookie header or session token",
                        text: $ccCookie, prompt: Text("__Secure-commandcode_prod_.session_token=…"))
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            if let message = ccFormMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(TMDesign.danger)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCCForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save Session") {
                    let raw = ccCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return }
                    if CommandCodeQuotaClient.shared.provision(cookie: raw) {
                        showCCForm = false
                        ccCookie = ""
                        ccFormMessage = nil
                    } else {
                        ccFormMessage = CommandCodeQuotaClient.shared.state.error
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(ccCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)

            Toggle("Automatically check for updates", isOn: $autoCheckOn)
                .toggleStyle(TMSwitchStyle())
                .font(.system(size: 12.5, weight: .medium))
                .accessibilityHint("Check for new versions in the background at launch")
                .onChange(of: autoCheckOn) { _, newValue in
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
                        .font(.system(size: 11))
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
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let error = updates.lastError {
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
