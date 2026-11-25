import AppKit
import Foundation

enum MonotonicClock {
    /// Continuous monotonic uptime (advances across system sleep on Darwin).
    static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

/// Failure backoff shared by the quota clients: after a failed refresh the
/// next attempt waits 1, 2, 4, 8, then 15 minutes; a success resets the
/// schedule. Measured on continuous monotonic time so sleep advances backoff.
struct RefreshBackoff {
    private var delay: TimeInterval = 0
    private(set) var nextAllowed: TimeInterval = 0

    func isWaiting(now: TimeInterval = MonotonicClock.now()) -> Bool { now < nextAllowed }
    var isWaiting: Bool { isWaiting() }

    mutating func failed(now: TimeInterval = MonotonicClock.now()) {
        delay = min(max(delay, 60), 15 * 60)
        nextAllowed = now + delay
        delay *= 2
    }

    mutating func succeeded() {
        delay = 0
        nextAllowed = 0
    }

    /// Lifts the current wait but keeps the delay, so another failure
    /// continues the schedule instead of starting over.
    mutating func allowNow() { nextAllowed = 0 }
}

/// Refresh timer for a quota client: the foreground cadence while the
/// popover or dashboard is visible, the background cadence otherwise, and an
/// immediate refresh when either becomes visible or the Mac wakes. Main thread only.
final class ForegroundPoller {
    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false
    private var timer: Timer?
    private var tick: (() -> Void)?
    private var onWake: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let visible = (note.object as? Bool) ?? false
                if name == TMNotifications.popoverVisibility {
                    self.popoverVisible = visible
                } else {
                    self.dashboardVisible = visible
                }
                self.update()
            }
            observers.append(token)
        }
        let wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.tick != nil else { return }
            if let onWake = self.onWake {
                onWake()
            } else if self.foreground {
                self.tick?()
            }
        }
        workspaceObservers.append(wakeToken)
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Installs the timer; `tick` runs on the main thread on every fire.
    func start(onWake: (() -> Void)? = nil, tick: @escaping () -> Void) {
        self.onWake = onWake
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
        onWake = nil
        foreground = false
    }
}
