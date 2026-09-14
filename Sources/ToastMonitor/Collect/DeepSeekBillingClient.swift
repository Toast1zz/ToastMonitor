import Foundation
import Combine

@MainActor
final class DeepSeekBillingClient: ObservableObject {
    static let shared = DeepSeekBillingClient()
    nonisolated static let keychainAccount = "deepseek-billing-credential"
    nonisolated static let configuredKey = "deepseek_billing_configured"
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    struct State {
        var kind: DeepSeekBilling.Credential.Kind?
        var balance: DeepSeekBilling.Balance?
        var spend: DeepSeekBilling.Spend?
        var balanceUpdated: Date?
        var spendUpdated: Date?
        var balanceError: String?
        var spendError: String?
        var expired = false
        var loadingBalance = false
        var loadingSpend = false
    }

    @Published private(set) var state = State()
    @Published private(set) var connecting = false
    @Published private(set) var connectionError: String?
    @Published private(set) var selectedSlot: UsagePeriodSlot = .today
    @Published private(set) var window: DeepSeekBilling.Window?
    private var configuration = UsagePeriodConfiguration()
    private var credential: DeepSeekBilling.Credential?
    private let fetch: Fetch
    private let readCredential: () async -> DeepSeekBilling.Credential?
    private let saveCredential: (DeepSeekBilling.Credential?) async -> Bool
    private var revision: UInt64 = 0
    private var credentialRevision: UInt64 = 0
    private var connectionRevision: UInt64 = 0
    private var started = false
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var popoverVisible = false
    private var dashboardVisible = false
    private var failures = 0
    private var nextRefresh = Date.distantPast

    init(fetch: Fetch? = nil,
         readCredential: (() async -> DeepSeekBilling.Credential?)? = nil,
         saveCredential: ((DeepSeekBilling.Credential?) async -> Bool)? = nil) {
        let transport = DeepSeekBillingTransport()
        self.fetch = fetch ?? { try await transport.fetch($0) }
        self.readCredential = readCredential ?? {
            await Task.detached(priority: .utility) {
                guard let raw = KeychainStore.get(account: Self.keychainAccount),
                      let data = raw.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(DeepSeekBilling.Credential.self, from: data) else { return nil }
                return try? DeepSeekBilling.Credential.make(decoded.secret, kind: decoded.kind)
            }.value
        }
        self.saveCredential = saveCredential ?? { value in
            await Task.detached(priority: .userInitiated) {
                if let value {
                    guard let data = try? JSONEncoder().encode(value), let raw = String(data: data, encoding: .utf8),
                          KeychainStore.set(raw, account: Self.keychainAccount, allowPrompt: true) else { return false }
                    // This marker is advisory, never the credential source.
                    // A settings failure cannot undo a successful Keychain write.
                    _ = Database.shared.setSetting(Self.configuredKey, "1")
                    return true
                }
                // An empty value is an atomic overwrite: failed writes leave
                // the old session usable instead of silently claiming logout.
                guard KeychainStore.set("", account: Self.keychainAccount, allowPrompt: true) else { return false }
                _ = Database.shared.setSetting(Self.configuredKey, nil)
                return true
            }.value
        }
        window = DeepSeekBilling.Window.make(slot: .today, configuration: configuration, now: Date())
    }

    func start() {
        guard !started else { return }
        started = true
        configuration = UsagePeriodSettings.shared.configuration
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility,
                     TMNotifications.usagePeriodSettingsChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let visible = note.object as? Bool ?? false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == TMNotifications.popoverVisibility { self.popoverVisible = visible }
                    if name == TMNotifications.dashboardVisibility { self.dashboardVisible = visible }
                    self.select(self.selectedSlot, configuration: UsagePeriodSettings.shared.configuration)
                    self.installTimer()
                    if self.popoverVisible || self.dashboardVisible { self.refresh() }
                }
            })
        }
        installTimer()
        Task { [weak self] in await self?.restoreSavedCredential() }
    }

    func restoreSavedCredential() async {
        let version = credentialRevision
        let saved = await readCredential()
        guard credentialRevision == version else { return }
        credential = saved
        state.kind = saved?.kind
        if saved == nil, Database.shared.setting(Self.configuredKey) == "1" {
            state.balanceError = "Saved DeepSeek session unavailable. Reconnect your account."
        }
        refresh()
    }

    private func installTimer() {
        timer?.invalidate()
        let interval = TMRefreshPolicy.quotaInterval(foreground: popoverVisible || dashboardVisible)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func select(_ slot: UsagePeriodSlot, configuration: UsagePeriodConfiguration, now: Date = Date()) {
        self.configuration = configuration
        selectedSlot = slot
        let next = DeepSeekBilling.Window.make(slot: slot, configuration: configuration, now: now)
        guard next != window else { return }
        window = next
        revision &+= 1
        task?.cancel(); task = nil
        state.loadingBalance = false
        state.loadingSpend = false
        state.spend = nil
        state.spendUpdated = nil
        state.spendError = nil
        // Period changes bypass only the success freshness window, not a
        // server failure backoff. A different window never reuses old spend.
        if failures == 0 { nextRefresh = .distantPast }
        refresh(now: now)
    }

    func connect(_ raw: String, kind: DeepSeekBilling.Credential.Kind) {
        guard !connecting else { return }
        connectionError = nil
        let candidate: DeepSeekBilling.Credential
        do { candidate = try .make(raw, kind: kind) }
        catch { connectionError = DeepSeekBilling.Failure.invalidCredential.localizedDescription; return }
        connecting = true
        connectionRevision &+= 1
        let version = connectionRevision
        connectionTask = Task { [weak self, fetch, saveCredential] in
            do {
                let data = try await fetch(DeepSeekBilling.request(credential: candidate))
                let balance = try await Task.detached {
                    try DeepSeekBilling.parseBalance(data, kind: candidate.kind)
                }.value
                guard let self, self.connectionRevision == version, !Task.isCancelled else { return }
                guard await saveCredential(candidate) else { throw DeepSeekBilling.Failure.keychain }
                guard self.connectionRevision == version else { return }
                self.revision &+= 1
                self.credentialRevision &+= 1
                self.task?.cancel(); self.task = nil
                self.credential = candidate
                self.state = State(kind: kind, balance: balance, balanceUpdated: Date())
                self.failures = 0; self.nextRefresh = .distantPast
                self.connecting = false
                self.refresh()
            } catch {
                guard let self, self.connectionRevision == version else { return }
                self.connecting = false
                self.connectionError = Self.message(error)
            }
        }
    }

    func disconnect() {
        guard !connecting else { return }
        connecting = true
        connectionError = nil
        connectionRevision &+= 1
        connectionTask = Task { [weak self, saveCredential] in
            let saved = await saveCredential(nil)
            guard let self else { return }
            self.connecting = false
            guard saved else { self.connectionError = DeepSeekBilling.Failure.keychain.localizedDescription; return }
            self.revision &+= 1
            self.credentialRevision &+= 1
            self.task?.cancel(); self.task = nil
            self.credential = nil
            self.state = State()
            self.failures = 0; self.nextRefresh = .distantPast
        }
    }

    func clearConnectionError() { connectionError = nil }

    func refresh(force: Bool = false, now: Date = Date()) {
        let current = DeepSeekBilling.Window.make(slot: selectedSlot, configuration: configuration, now: now)
        if current != window { select(selectedSlot, configuration: configuration, now: now); return }
        guard task == nil, let credential, !state.expired,
              (force && failures == 0) || now >= nextRefresh else { return }
        let version = revision
        let requestedWindow = window
        let needsSpend = credential.kind == .platform && requestedWindow != nil
        state.loadingBalance = true
        state.loadingSpend = needsSpend
        task = Task { [weak self, fetch] in
            // Balance and spend fail independently; neither is estimated from
            // the other. Both remain tied to this credential generation.
            async let balance = Self.loadBalance(credential, fetch: fetch)
            async let spend = Self.loadSpend(credential, window: requestedWindow, fetch: fetch)
            let (balanceResult, spendResult) = await (balance, spend)
            guard let self, self.revision == version, !Task.isCancelled else { return }
            self.task = nil
            self.state.loadingBalance = false
            self.state.loadingSpend = false
            var failed = false
            switch balanceResult {
            case .success(let value):
                self.state.balance = value; self.state.balanceUpdated = Date(); self.state.balanceError = nil
            case .failure(let error):
                failed = true
                self.state.balanceError = error.localizedDescription
                self.state.expired = error == .expired
            }
            if let spendResult {
                switch spendResult {
                case .success(let value):
                    self.state.spend = value; self.state.spendUpdated = Date(); self.state.spendError = nil
                case .failure(let error):
                    failed = true
                    self.state.spendError = error.localizedDescription
                    self.state.expired = self.state.expired || error == .expired
                }
            }
            self.failures = failed ? min(4, self.failures + 1) : 0
            let delay: TimeInterval = failed ? [60, 120, 300, 900][self.failures - 1] : 60
            self.nextRefresh = Date().addingTimeInterval(delay)
        }
    }

    nonisolated private static func loadBalance(_ credential: DeepSeekBilling.Credential, fetch: Fetch)
        async -> Result<DeepSeekBilling.Balance, DeepSeekBilling.Failure> {
        do {
            let data = try await fetch(DeepSeekBilling.request(credential: credential))
            return .success(try DeepSeekBilling.parseBalance(data, kind: credential.kind))
        } catch { return .failure(DeepSeekBilling.failure(error)) }
    }

    nonisolated private static func loadSpend(_ credential: DeepSeekBilling.Credential,
                                            window: DeepSeekBilling.Window?, fetch: Fetch)
        async -> Result<DeepSeekBilling.Spend, DeepSeekBilling.Failure>? {
        guard credential.kind == .platform, let window else { return nil }
        do {
            let data = try await fetch(DeepSeekBilling.request(credential: credential, window: window))
            return .success(try DeepSeekBilling.parseSpend(data, window: window))
        } catch { return .failure(DeepSeekBilling.failure(error)) }
    }

    private static func message(_ error: Error) -> String {
        DeepSeekBilling.failure(error).localizedDescription
    }

    var spendText: String {
        if state.kind == nil { return "Not connected" }
        if state.kind == .apiKey { return "Platform sign-in required" }
        if window == nil { return "Full history unavailable" }
        if state.expired { return "Sign-in expired" }
        if let spend = state.spend, spend.window == window { return spend.formatted }
        if state.loadingSpend { return "Loading" }
        if state.spendError != nil { return "Unavailable" }
        return "Waiting to refresh"
    }

    var balanceText: String {
        if state.expired { return "Sign-in expired" }
        if let balance = state.balance { return balance.formatted }
        if state.loadingBalance { return "Loading" }
        if state.balanceError != nil { return "Unavailable" }
        return "Not connected"
    }

    func stale(_ updated: Date?, error: String?, now: Date = Date()) -> Bool {
        updated != nil && (error != nil || now.timeIntervalSince(updated!) > 120)
    }
}
