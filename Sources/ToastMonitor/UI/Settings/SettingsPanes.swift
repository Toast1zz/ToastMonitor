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

/// Persists a boolean setting off the main thread. The shared database lock
/// can be held by a background scan, and a synchronous write made switches
/// feel about a second late.
private func persistFlag(_ key: String, _ on: Bool) {
    let value = on ? "1" : "0"
    DispatchQueue.global(qos: .userInitiated).async {
        _ = Database.shared.setSetting(key, value)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject private var launch = LaunchAtLoginSettings.shared
    @ObservedObject private var alerts = QuotaAlertManager.shared
    /// Local mirrors so a switch flips instantly; see `persistFlag`.
    @State private var closeOnResign = PanelController.dismissOnResign
    @State private var dockIconOn = WindowManager.dockIconEnabled

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { launch.enabled },
                set: { launch.setEnabled($0) }
            ))
            Toggle("Show Dock icon while the Dashboard is open", isOn: $dockIconOn)
                .onChange(of: dockIconOn) { on in
                    persistFlag(WindowManager.dockIconSetting, on)
                    WindowManager.shared.applyDockIconSetting(on)
                }
            Toggle("Close the popover when clicking elsewhere", isOn: $closeOnResign)
                .onChange(of: closeOnResign) { on in
                    persistFlag(PanelController.dismissOnResignKey, on)
                }
            Toggle("Quota and renewal alerts", isOn: Binding(
                get: { alerts.enabled },
                set: { alerts.setEnabled($0) }
            ))
        } footer: {
            if let message = launch.message {
                Text(message)
            }
        }

        Section {
            LabeledContent("Menu bar font") {
                MenuBarFontControls()
            }
        }

        UsagePeriodSettingsSection()
            .onAppear { launch.refresh() }
    }
}

// MARK: - Popover

/// What the popover's home page shows. Cards can also be hidden in place
/// with the eye button on a card's title; this pane is where they come back
/// individually and where account rows are chosen.
struct PopoverSettingsPane: View {
    /// Posted when an account row is shown or hidden, so the resident home
    /// page picks it up without waiting for its next appearance.
    static let quotaRowsChanged = Notification.Name("tmQuotaRowsChanged")

    static let cards: [(key: String, title: String)] = [
        ("sources", "Sources"), ("quota", "Quota"),
        ("balance", "Balance"), ("activity", "Activity"),
    ]

    static let accountRows: [(key: String, title: String)] = [
        ("claude", "Claude"), ("go", "OpenCode Go"), ("codex", "Codex Plus"),
        ("cc", "Command Code"), ("router", "OpenRouter"), ("deepseek", "DeepSeek"),
    ]

    /// Same key the home page's eye buttons write (comma-separated keys).
    @AppStorage("popoverHiddenSections") private var hiddenSectionsRaw = ""
    @AppStorage("popoverFullTokens") private var fullTokens = false
    @State private var rowVisible: [String: Bool] = [:]

    var body: some View {
        Section {
            Picker("Token count", selection: $fullTokens) {
                Text("3.7M").tag(false)
                Text("3,712,456").tag(true)
            }
        }

        Section {
            ForEach(Self.cards, id: \.key) { card in
                Toggle(card.title, isOn: cardBinding(card.key))
            }
        } header: {
            Text("Cards")
        }

        Section {
            ForEach(Self.accountRows, id: \.key) { row in
                Toggle(row.title, isOn: accountBinding(row.key))
            }
        } header: {
            Text("Accounts")
        }
        .onAppear {
            for row in Self.accountRows {
                rowVisible[row.key] = Database.shared.setting("hide_quota_row_\(row.key)") != "1"
            }
        }
    }

    private func cardBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenSectionsRaw.split(separator: ",").contains(Substring(key)) },
            set: { visible in
                var keys = hiddenSectionsRaw.split(separator: ",").map(String.init).filter { $0 != key }
                if !visible { keys.append(key) }
                hiddenSectionsRaw = keys.joined(separator: ",")
            }
        )
    }

    private func accountBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { rowVisible[key] ?? true },
            set: { visible in
                rowVisible[key] = visible
                let value = visible ? nil : "1"
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Database.shared.setSetting("hide_quota_row_\(key)", value)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.quotaRowsChanged, object: nil)
                    }
                }
            }
        )
    }
}

// MARK: - Updates

struct UpdatesSettingsPane: View {
    @ObservedObject private var updates = UpdateManager.shared
    @State private var autoCheckOn = UpdateManager.autoCheckEnabled

    var body: some View {
        Section {
            LabeledContent("Current version", value: appVersion)
            LabeledContent {
                if updates.installing || updates.checking {
                    ProgressView().controlSize(.small)
                } else if updates.available != nil {
                    Button("Install and Relaunch") {
                        Task { await UpdateManager.shared.installAndRelaunch() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") {
                        Task { await UpdateManager.shared.check(force: true) }
                    }
                }
            } label: {
                Text(statusText)
                    .foregroundStyle(statusStyle)
            }
        }

        Section {
            Toggle("Check for updates automatically", isOn: $autoCheckOn)
                .onChange(of: autoCheckOn) { on in
                    persistFlag(UpdateManager.autoCheckSetting, on)
                    // Turning auto-check on starts the launch + 24h cadence
                    // immediately (including one check right away).
                    if on { UpdateManager.shared.startAutoCheckIfEnabled() }
                }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0 (dev)"
    }

    private var statusText: String {
        if updates.installing { return "Installing…" }
        if updates.checking { return "Checking…" }
        if let update = updates.available { return "Version \(update.version) is available" }
        if let error = updates.lastError { return error }
        if updates.lastCheckAt != nil { return "ToastMonitor is up to date" }
        return "Not checked yet"
    }

    private var statusStyle: AnyShapeStyle {
        if updates.available != nil { return AnyShapeStyle(TMDesign.accent) }
        if updates.lastError != nil { return AnyShapeStyle(TMDesign.danger) }
        return AnyShapeStyle(.primary)
    }
}
