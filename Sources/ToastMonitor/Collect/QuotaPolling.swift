import Foundation

/// Failure backoff shared by the quota clients: after a failed refresh the
/// next attempt waits 1, 2, 4, 8, then 15 minutes; a success resets the
/// schedule. Measured on systemUptime.
struct RefreshBackoff {
    private var delay: TimeInterval = 0
    private(set) var nextAllowed: TimeInterval = 0

    var isWaiting: Bool { ProcessInfo.processInfo.systemUptime < nextAllowed }

    mutating func failed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        delay = min(max(delay, 60), 15 * 60)
        nextAllowed = now + delay
        delay *= 2
    }

    mutating func succeeded() { delay = 0 }

    /// Lifts the current wait but keeps the delay, so another failure
    /// continues the schedule instead of starting over.
    mutating func allowNow() { nextAllowed = 0 }
}

/// Refresh timer for a quota client: the foreground cadence while the
/// popover or dashboard is visible, the background cadence otherwise, and an
/// immediate refresh when either becomes visible. Main thread only.
final class ForegroundPoller {
    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false
    private var timer: Timer?
    private var tick: (() -> Void)?

    init() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let visible = (note.object as? Bool) ?? false
                if name == TMNotifications.popoverVisibility {
                    self.popoverVisible = visible
                } else {
                    self.dashboardVisible = visible
                }
                self.update()
            }
        }
    }

    /// Installs the timer; `tick` runs on the main thread on every fire.
    func start(tick: @escaping () -> Void) {
        guard self.tick == nil else { return }
        self.tick = tick
        update()
    }

    private func update() {
        guard let tick else { return }
        let fg = popoverVisible || dashboardVisible
        // The first call installs the timer even though visibility is unchanged.
        guard fg != foreground || timer == nil else { return }
        foreground = fg
        timer?.invalidate()
        let t = Timer(timeInterval: TMRefreshPolicy.quotaInterval(foreground: fg), repeats: true) { [weak self] _ in
            self?.tick?()
        }
        t.tolerance = TMRefreshPolicy.quotaInterval(foreground: fg) * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if fg { tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tick = nil
        foreground = false
    }
}
