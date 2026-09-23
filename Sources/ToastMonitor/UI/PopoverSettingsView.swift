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
    @ObservedObject private var periods = UsagePeriodSettings.shared
    /// Optimistic local mirrors of the persisted settings so a toggle flips
    /// instantly; the database write happens off the main thread (the shared
    /// DB lock can be held by background scans, which made synchronous writes
    /// feel like a ~1s delay).
    @State private var closeOnResign: Bool = PanelController.dismissOnResign
    @State private var dockIconOn: Bool = WindowManager.dockIconEnabled
    @State private var autoCheckOn: Bool = UpdateManager.autoCheckEnabled
    @State private var rowVisible: [String: Bool] = [:]
    /// Same key the home page's eye buttons write (comma-separated keys).
    @AppStorage("popoverHiddenSections") private var hiddenSectionsRaw = ""
    let onBack: () -> Void

    /// Posted when a quota row is shown/hidden here so the resident home
    /// page picks it up without waiting for its next appearance.
    static let quotaRowsChanged = Notification.Name("tmQuotaRowsChanged")

    private static let accountRows: [(key: String, title: String)] = [
        ("claude", "Claude"), ("go", "OpenCode Go"), ("codex", "Codex Plus"),
        ("cc", "Command Code"), ("router", "OpenRouter"), ("deepseek", "DeepSeek"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            fixedSlice(.header) {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.7)
                }
            }
            // One visual system with the home page: title-case group labels,
            // tonal cards, label left / control right, hairlines between rows.
            // Scrolls (indicator hidden, like the home page) once the page is
            // taller than the screen allows; the measured height still drives
            // the panel size, so it only scrolls when it truly has to.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    generalGroup
                    homeGroup
                    accountsGroup
                    dateRangeGroup
                    appearanceGroup
                    updatesGroup
                }
                .padding(.horizontal, TMLayout.popoverCardInset)
                .padding(.vertical, 12)
                .fixedSize(horizontal: false, vertical: true)
                .reportPopoverHeight(.body, page: .settings)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
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
            for row in Self.accountRows {
                rowVisible[row.key] = Database.shared.setting("hide_quota_row_\(row.key)") != "1"
            }
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
        .padding(.horizontal, TMLayout.popoverCardInset + 4)
        .padding(.vertical, 10)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0 (dev)"
    }

    // MARK: - Groups

    private var generalGroup: some View {
        SettingsGroup("General", footnote: launch.message) {
            SettingsToggleRow("Launch at login", isOn: Binding(
                get: { launch.enabled },
                set: { launch.setEnabled($0) }
            ))
            .accessibilityHint("Open ToastMonitor in the menu bar when you sign in")
            SettingsDivider()
            SettingsToggleRow("Quota & renewal alerts", isOn: Binding(
                get: { alerts.enabled },
                set: { alerts.setEnabled($0) }
            ))
            .accessibilityHint("Notify when quota falls below 20%, resets, or a subscription renews tomorrow")
            SettingsDivider()
            SettingsToggleRow("Close when clicking elsewhere", isOn: $closeOnResign)
                .onChange(of: closeOnResign) { newValue in
                    // Persisted off the main thread; the panel reads the
                    // setting per event, so it applies immediately after.
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(PanelController.dismissOnResignKey, v)
                    }
                }
            SettingsDivider()
            SettingsToggleRow("Dock icon while Dashboard is open", isOn: $dockIconOn)
                .onChange(of: dockIconOn) { newValue in
                    let v = newValue ? "1" : "0"
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = Database.shared.setSetting(WindowManager.dockIconSetting, v)
                    }
                    // Policy switch is cheap; do it now so the Dock reacts
                    // immediately, using the optimistic value, not the DB.
                    WindowManager.shared.applyDockIconSetting(newValue)
                }
        }
    }

    /// The home page's cards; the eye button on a card writes the same key.
    /// A multi-select, so chips rather than a column of switches.
    private var homeGroup: some View {
        SettingsGroup("Show on Home") {
            ChipGrid(columns: 4) {
                ForEach([("sources", "Sources"), ("quota", "Quota"),
                         ("balance", "Balance"), ("activity", "Activity")], id: \.0) { key, title in
                    ChipToggle(title, isOn: sectionBinding(key))
                }
            }
        }
    }

    private func sectionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenSectionsRaw.split(separator: ",").contains(Substring(key)) },
            set: { visible in
                var keys = hiddenSectionsRaw.split(separator: ",").map(String.init).filter { $0 != key }
                if !visible { keys.append(key) }
                hiddenSectionsRaw = keys.joined(separator: ",")
            }
        )
    }

    /// Per-account rows inside Quota / Balance (setting `hide_quota_row_<key>`).
    private var accountsGroup: some View {
        SettingsGroup("Accounts") {
            ChipGrid(columns: 3) {
                ForEach(Self.accountRows, id: \.key) { row in
                    ChipToggle(row.title, isOn: Binding(
                        get: { rowVisible[row.key] ?? true },
                        set: { visible in
                            rowVisible[row.key] = visible
                            let v = visible ? nil : "1"
                            DispatchQueue.global(qos: .userInitiated).async {
                                _ = Database.shared.setSetting("hide_quota_row_\(row.key)", v)
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(name: Self.quotaRowsChanged, object: nil)
                                }
                            }
                        }
                    ))
                }
            }
        }
    }

    private var dateRangeGroup: some View {
        SettingsGroup("Date range", footnote: periods.mode.detail) {
            SettingsRow("Periods") {
                Picker("Periods", selection: Binding(
                    get: { periods.mode },
                    set: { periods.setMode($0) }
                )) {
                    ForEach(UsagePeriodMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            // Kept mounted in every mode so switching modes cannot change the
            // floating panel's intrinsic height.
            VStack(spacing: 0) {
                SettingsDivider()
                SettingsRow("Week starts on") {
                    Picker("Week starts on", selection: Binding(
                        get: { periods.weekStart },
                        set: { periods.setWeekStart($0) }
                    )) {
                        ForEach(UsageWeekStart.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .opacity(periods.mode == .calendar ? 1 : 0.35)
            .disabled(periods.mode != .calendar)
            .animation(.easeOut(duration: 0.16), value: periods.mode)
        }
    }

    private var appearanceGroup: some View {
        SettingsGroup("Appearance", footnote: MenuBarFontControls.footnote) {
            SettingsRow("Menu bar font") {
                MenuBarFontControls()
            }
        }
    }

    private var updatesGroup: some View {
        SettingsGroup("Updates") {
            SettingsToggleRow("Check automatically", isOn: $autoCheckOn)
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
            SettingsDivider()
            SettingsRow(updateStatusText, tone: updateStatusTone) {
                if updates.installing || updates.checking {
                    ProgressView().controlSize(.small)
                } else if updates.available != nil {
                    Button("Install") {
                        Task { await UpdateManager.shared.installAndRelaunch() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") {
                        Task { await UpdateManager.shared.check(force: true) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var updateStatusText: String {
        if updates.installing { return "Installing…" }
        if updates.checking { return "Checking…" }
        if let update = updates.available { return "Version \(update.version) available" }
        if let error = updates.lastError { return error }
        if updates.lastCheckAt != nil { return "Up to date" }
        return "Current version \(appVersion)"
    }

    private var updateStatusTone: SettingsTone {
        if updates.available != nil { return .accent }
        if updates.lastError != nil { return .danger }
        return .normal
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

// MARK: - Settings building blocks

/// Title-case label over a tonal card (same fill and radius as the home
/// page cards), with an optional quiet footnote under the card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    let footnote: String?
    @ViewBuilder let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TMType.semibold(12))
                .foregroundStyle(TMDesign.quiet)
                .padding(.leading, TMLayout.popoverCardPadding)
            VStack(spacing: 0) { content }
                .padding(.horizontal, TMLayout.popoverCardPadding)
                .background(Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footnote {
                Text(footnote)
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.faint)
                    .padding(.leading, TMLayout.popoverCardPadding)
            }
        }
    }
}

/// Label on the left, control on the right edge — every row, every group.
private enum SettingsTone { case normal, accent, danger }

private struct SettingsRow<Control: View>: View {
    let title: String
    var tone: SettingsTone = .normal
    @ViewBuilder let control: Control

    init(_ title: String, tone: SettingsTone = .normal, @ViewBuilder control: () -> Control) {
        self.title = title
        self.tone = tone
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TMType.regular(TMType.body))
                .foregroundStyle(tone == .accent ? AnyShapeStyle(TMDesign.accent)
                                 : tone == .danger ? AnyShapeStyle(TMDesign.danger)
                                 : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 30)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        // System hairline: always exactly one device pixel, never dropped
        // by fractional-point rounding the way a 0.5pt Rectangle can be.
        Divider().opacity(0.6)
    }
}

/// Equal-width grid of chips inside a settings card.
private struct ChipGrid<Content: View>: View {
    let columns: Int
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                  spacing: 6) {
            content
        }
        .padding(.vertical, 10)
    }
}

/// A multi-select option: tinted when on, quiet when off. One click flips it.
private struct ChipToggle: View {
    let title: String
    @Binding var isOn: Bool
    @State private var hovering = false

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Text(title)
                .font(TMType.medium(TMType.caption))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                // On must read as the stronger state: filled tint + accent
                // ink. Off recedes to faint ink on an almost-bare capsule.
                .foregroundStyle(isOn ? AnyShapeStyle(TMDesign.accent)
                                      : AnyShapeStyle(TMDesign.faint))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? TMDesign.accent.opacity(0.24)
                                   : Color.primary.opacity(hovering ? 0.06 : 0.03))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
    }
}
