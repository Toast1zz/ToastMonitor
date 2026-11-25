import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications

enum QuotaAlertPolicy {
    struct BadgeState: Codable, Equatable {
        var resetAt: Int64?
        var triggered = false
        var unread = false

        mutating func update(remaining: Double, threshold: Double, resetAt nextReset: Int64?,
                             viewed: Bool = false, jitterTolerance: Int64 = 300) {
            guard remaining.isFinite else { return }
            // Relative reset countdowns can drift slightly between fetches.
            if let old = resetAt, let nextReset, Double(nextReset) - Double(old) > Double(jitterTolerance) {
                triggered = false
                unread = false
                resetAt = nextReset
            } else if resetAt == nil {
                resetAt = nextReset
            }
            if remaining > threshold {
                unread = false
                if resetAt == nil { triggered = false }
            } else if !triggered {
                triggered = true
                unread = true
            }
            if viewed { unread = false }
        }
    }

    enum Event: Equatable {
        case low
        case recovered
    }

    static func transition(previous: String?, remaining: Double,
                           threshold: Double) -> Event? {
        let isLow = remaining <= threshold
        if isLow, previous != "low" { return .low }
        if !isLow, previous == "low" { return .recovered }
        return nil
    }
}

@MainActor
final class QuotaAlertManager: ObservableObject {
    struct Reading {
        let id: String
        let name: String
        let remaining: Double
        var resetAt: Int64? = nil
        var resetJitterTolerance: Int64 = 300
    }

    static let shared = QuotaAlertManager()
    static let enabledKey = "quota_alerts_enabled"
    static let thresholdKey = "quota_alerts_threshold"

    @Published private(set) var enabled: Bool
    @Published private(set) var unreadCount = 0
    /// Remaining percent at or below which a quota alerts.
    @Published private(set) var threshold: Double
    static let thresholdChoices: [Double] = [10, 20, 30, 50]

    private var started = false
    private var panelVisible = false
    private let readingProvider: (() -> [Reading])?
    private var badgeStates: [String: QuotaAlertPolicy.BadgeState] = [:]
    private static let badgeStateKey = "quota_alert_badge_states"
    private static let writeQueue = DispatchQueue(label: "toastmonitor.quota-alerts.write", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var pendingEvaluation: DispatchWorkItem?
    private var alertStates: [String: String] = [:]
    /// Direct SwiftPM/headless render binaries have no application bundle
    /// proxy, and UserNotifications throws an Objective-C exception if its
    /// center is created there. Resolve it only when normal app startup or an
    /// explicit settings action actually needs notification delivery.
    private lazy var center = UNUserNotificationCenter.current()

    init(readingProvider: (() -> [Reading])? = nil) {
        self.readingProvider = readingProvider
        self.enabled = false
        self.threshold = 20
        loadFromDatabase()
    }

    func reloadFromDatabase() {
        loadFromDatabase()
        if started {
            evaluate()
            scheduleRenewalReminders()
        }
    }

    private func loadFromDatabase() {
        alertStates = [:]
        enabled = Database.shared.setting(Self.enabledKey) == "1"
        let saved = Double(Database.shared.setting(Self.thresholdKey) ?? "") ?? 20
        threshold = Self.thresholdChoices.contains(saved) ? saved : 20
        if let raw = Database.shared.setting(Self.badgeStateKey), let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: QuotaAlertPolicy.BadgeState].self, from: data) {
            badgeStates = decoded
        } else {
            badgeStates = [:]
        }
    }

    private func persistSetting(_ key: String, _ value: String?) {
        Self.writeQueue.async {
            _ = Database.shared.setSetting(key, value)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        loadFromDatabase()
        NotificationCenter.default.publisher(for: PanelController.visibilityNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let visible = notification.object as? Bool else { return }
                self.panelVisible = visible
                if visible { self.evaluate() }
            }.store(in: &cancellables)
        let publishers: [AnyPublisher<Void, Never>] = [
            ClaudeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            CodexQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            OpenCodeGoClient.shared.objectWillChange.eraseToAnyPublisher(),
            CommandCodeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            GrokQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            AntigravityQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            OpenRouterClient.shared.objectWillChange.eraseToAnyPublisher(),
            AppState.shared.objectWillChange.eraseToAnyPublisher(),
        ]
        for publisher in publishers {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.scheduleEvaluation()
            }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: Database.subscriptionsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRenewalReminders() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Database.didResetState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromDatabase() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRenewalReminders() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRenewalReminders() }
            .store(in: &cancellables)
        evaluate()
        scheduleRenewalReminders()
    }

    func setThreshold(_ newValue: Double) {
        guard newValue != threshold, Self.thresholdChoices.contains(newValue) else { return }
        let previousThreshold = threshold
        threshold = newValue
        persistSetting(Self.thresholdKey, "\(Int(newValue))")
        if newValue < previousThreshold {
            // Lowering the threshold must not falsely announce a "quota reset"
            // for readings that were only "low" under the old higher bar.
            for reading in currentReadings() where reading.remaining > newValue {
                let key = "quota_alert_state_\(reading.id)"
                if (alertStates[reading.id] ?? Database.shared.setting(key)) == "low" {
                    alertStates[reading.id] = "ok"
                    persistSetting(key, "ok")
                }
            }
        }
        evaluate()
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        if !newValue {
            enabled = false
            persistSetting(Self.enabledKey, nil)
            clearPendingRenewalReminders()
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enabled = granted
                self.persistSetting(Self.enabledKey, granted ? "1" : nil)
                if granted {
                    self.evaluate()
                    self.scheduleRenewalReminders()
                }
            }
        }
    }

    func evaluate() {
        let readings = currentReadings()
        let previousBadges = badgeStates
        if panelVisible {
            for id in Array(badgeStates.keys) { badgeStates[id]?.unread = false }
        }
        for reading in readings {
            var state = badgeStates[reading.id] ?? QuotaAlertPolicy.BadgeState()
            state.update(remaining: reading.remaining, threshold: threshold,
                         resetAt: reading.resetAt, viewed: panelVisible,
                         jitterTolerance: reading.resetJitterTolerance)
            badgeStates[reading.id] = state
        }
        let count = readings.filter { badgeStates[$0.id]?.unread == true }.count
        if unreadCount != count { unreadCount = count }
        if badgeStates != previousBadges,
           let data = try? JSONEncoder().encode(badgeStates),
           let raw = String(data: data, encoding: .utf8) {
            persistSetting(Self.badgeStateKey, raw)
        }
        guard enabled else { return }
        for reading in readings {
            let key = "quota_alert_state_\(reading.id)"
            let previous = alertStates[reading.id] ?? Database.shared.setting(key)
            guard let event = QuotaAlertPolicy.transition(previous: previous,
                                                          remaining: reading.remaining,
                                                          threshold: threshold) else { continue }
            switch event {
            case .low:
                alertStates[reading.id] = "low"
                post(identifier: "quota-low-\(reading.id)",
                     title: "\(reading.name) quota is low",
                     body: "\(Int(reading.remaining.rounded()))% remaining")
                persistSetting(key, "low")
            case .recovered:
                alertStates[reading.id] = "ok"
                post(identifier: "quota-reset-\(reading.id)",
                     title: "\(reading.name) quota reset",
                     body: "Capacity is back to \(Int(reading.remaining.rounded()))% remaining")
                persistSetting(key, "ok")
            }
        }
    }

    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingEvaluation = nil
                self?.evaluate()
            }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func currentReadings() -> [Reading] {
        if let readingProvider { return readingProvider() }
        var readings: [Reading] = []
        if ClaudeQuotaClient.shared.enabled,
           let used = ClaudeQuotaClient.shared.state.sevenDay?.usedPercent {
            readings.append(.init(id: "claude-weekly", name: "Claude weekly",
                                  remaining: Double(100 - used),
                                  resetAt: ClaudeQuotaClient.shared.state.sevenDay?.resetAt))
        }
        if CodexQuotaClient.shared.enabled,
           let used = CodexQuotaClient.shared.state.primaryPct {
            readings.append(.init(id: "codex", name: "Codex",
                                  remaining: Double(100 - used), resetAt: CodexQuotaClient.shared.state.resetAt))
        }
        if let used = OpenCodeGoClient.shared.state.monthlyPct {
            readings.append(.init(id: "opencode-go", name: "OpenCode Go",
                                  remaining: 100 - used,
                                  resetAt: OpenCodeGoClient.shared.state.monthlyReset.map {
                                      OpenCodeGoClient.shared.state.lastSync + $0
                                  },
                                  resetJitterTolerance: 7_200))
        }
        if let used = CommandCodeQuotaClient.shared.state.monthlyUsedPercent {
            readings.append(.init(id: "command-code", name: "Command Code",
                                  remaining: 100 - used,
                                  resetAt: CommandCodeQuotaClient.shared.state.billingPeriodEnd.map {
                                      Int64($0.timeIntervalSince1970)
                                  }))
        }
        if GrokQuotaClient.shared.enabled,
           let used = GrokQuotaClient.shared.state.usedPercent {
            readings.append(.init(id: "supergrok-weekly", name: "Grok weekly",
                                  remaining: 100 - used, resetAt: GrokQuotaClient.shared.state.resetAt))
        }
        if AntigravityQuotaClient.shared.enabled {
            for model in AntigravityQuotaClient.shared.state.current() {
                readings.append(.init(id: "antigravity-\(model.label)", name: "Antigravity \(model.label)",
                                      remaining: model.remaining, resetAt: model.resetAt))
            }
        }
        let router = OpenRouterClient.shared.state
        if OpenRouterClient.shared.hasKey,
           let limit = router.limit, limit > 0, let remaining = router.limitRemaining {
            readings.append(.init(id: "openrouter", name: "OpenRouter",
                                  remaining: min(max(remaining / limit * 100, 0), 100)))
        }
        return readings
    }

    private func clearPendingRenewalReminders(then: (@MainActor @Sendable () -> Void)? = nil) {
        let center = self.center
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix("renewal-") }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            if let then {
                Task { @MainActor in then() }
            }
        }
    }

    private func scheduleRenewalReminders() {
        guard enabled else { return }
        Self.writeQueue.async { [weak self] in
            let subscriptions = Database.shared.subscriptions()
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }
                self.clearPendingRenewalReminders { [weak self] in
                    guard let self, self.enabled else { return }
                    let now = Date()
                    for subscription in subscriptions {
                        guard let cycle = SubscriptionMath.cycleInfo(start: subscription.startDate,
                                                                     end: subscription.endDate,
                                                                     cycle: subscription.cycle,
                                                                     now: now) else { continue }
                        let fireDate = cycle.end.addingTimeInterval(-86400)
                        guard fireDate > now else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "Subscription renews tomorrow"
                        content.body = "\(subscription.name) renews for \(Format.money(subscription.price))"
                        content.sound = .default
                        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                                          from: fireDate)
                        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                        self.center.add(UNNotificationRequest(identifier: "renewal-\(subscription.id)",
                                                              content: content, trigger: trigger))
                    }
                }
            }
        }
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier,
                                         content: content, trigger: nil))
    }
}
