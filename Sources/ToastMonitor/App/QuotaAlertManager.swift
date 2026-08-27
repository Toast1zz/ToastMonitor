import Combine
import Foundation
import UserNotifications

enum QuotaAlertPolicy {
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
    }

    static let shared = QuotaAlertManager()
    static let enabledKey = "quota_alerts_enabled"
    static let thresholdKey = "quota_alerts_threshold"

    @Published private(set) var enabled: Bool
    @Published private(set) var criticalCount = 0
    let threshold: Double

    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    /// Direct SwiftPM/headless render binaries have no application bundle
    /// proxy, and UserNotifications throws an Objective-C exception if its
    /// center is created there. Resolve it only when normal app startup or an
    /// explicit settings action actually needs notification delivery.
    private lazy var center = UNUserNotificationCenter.current()

    private init() {
        enabled = Database.shared.setting(Self.enabledKey) == "1"
        threshold = Double(Database.shared.setting(Self.thresholdKey) ?? "20") ?? 20
    }

    func start() {
        guard !started else { return }
        started = true
        let publishers: [AnyPublisher<Void, Never>] = [
            ClaudeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            CodexQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            OpenCodeGoClient.shared.objectWillChange.eraseToAnyPublisher(),
            CommandCodeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
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
        evaluate()
        scheduleRenewalReminders()
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        if !newValue {
            enabled = false
            _ = Database.shared.setSetting(Self.enabledKey, nil)
            center.removePendingNotificationRequests(withIdentifiers: renewalIdentifiers())
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enabled = granted
                _ = Database.shared.setSetting(Self.enabledKey, granted ? "1" : nil)
                if granted {
                    self.evaluate()
                    self.scheduleRenewalReminders()
                }
            }
        }
    }

    func evaluate() {
        let readings = currentReadings()
        criticalCount = readings.filter { $0.remaining <= threshold }.count
        guard enabled else { return }
        for reading in readings {
            let key = "quota_alert_state_\(reading.id)"
            let previous = Database.shared.setting(key)
            guard let event = QuotaAlertPolicy.transition(previous: previous,
                                                          remaining: reading.remaining,
                                                          threshold: threshold) else { continue }
            switch event {
            case .low:
                post(identifier: "quota-low-\(reading.id)",
                     title: "\(reading.name) quota is low",
                     body: "\(Int(reading.remaining.rounded()))% remaining")
                _ = Database.shared.setSetting(key, "low")
            case .recovered:
                post(identifier: "quota-reset-\(reading.id)",
                     title: "\(reading.name) quota reset",
                     body: "Capacity is back to \(Int(reading.remaining.rounded()))% remaining")
                _ = Database.shared.setSetting(key, "ok")
            }
        }
    }

    private func scheduleEvaluation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.evaluate()
        }
    }

    private func currentReadings() -> [Reading] {
        var readings: [Reading] = []
        if let used = ClaudeQuotaClient.shared.state.sevenDay?.usedPercent {
            readings.append(.init(id: "claude-weekly", name: "Claude weekly",
                                  remaining: Double(100 - used)))
        }
        if let used = CodexQuotaClient.shared.state.primaryPct {
            readings.append(.init(id: "codex", name: "Codex",
                                  remaining: Double(100 - used)))
        }
        if let used = OpenCodeGoClient.shared.state.monthlyPct {
            readings.append(.init(id: "opencode-go", name: "OpenCode Go",
                                  remaining: 100 - used))
        }
        if let used = CommandCodeQuotaClient.shared.state.monthlyUsedPercent {
            readings.append(.init(id: "command-code", name: "Command Code",
                                  remaining: 100 - used))
        }
        let router = OpenRouterClient.shared.state
        if let limit = router.limit, limit > 0, let remaining = router.limitRemaining {
            readings.append(.init(id: "openrouter", name: "OpenRouter",
                                  remaining: min(max(remaining / limit * 100, 0), 100)))
        }
        return readings
    }

    private func scheduleRenewalReminders() {
        guard enabled else { return }
        let subscriptions = Database.shared.subscriptions()
        center.removePendingNotificationRequests(withIdentifiers: renewalIdentifiers())
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
            center.add(UNNotificationRequest(identifier: "renewal-\(subscription.id)",
                                             content: content, trigger: trigger))
        }
    }

    private func renewalIdentifiers() -> [String] {
        Database.shared.subscriptions().map { "renewal-\($0.id)" }
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
