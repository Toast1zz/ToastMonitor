import Foundation

enum UsagePeriodMode: String, CaseIterable, Identifiable {
    case recent
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recent windows"
        case .calendar: return "Calendar periods"
        }
    }

    var detail: String {
        switch self {
        case .recent: return "Today, 7 Days, 30 Days, All Time"
        case .calendar: return "Today, Weekly, Monthly, All Time"
        }
    }
}

enum UsagePeriodSlot: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }
}

enum UsageWeekStart: String, CaseIterable, Identifiable {
    case monday
    case sunday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monday: return "Monday"
        case .sunday: return "Sunday"
        }
    }
}

struct UsagePeriodRange: Equatable {
    let start: Int64
    let end: Int64
}

struct UsagePeriodConfiguration: Equatable {
    var mode: UsagePeriodMode
    var weekStart: UsageWeekStart

    init(mode: UsagePeriodMode = .recent, weekStart: UsageWeekStart = .monday) {
        self.mode = mode
        self.weekStart = weekStart
    }

    func label(for slot: UsagePeriodSlot) -> String {
        switch slot {
        case .today: return "Today"
        case .week: return mode == .calendar ? "Weekly" : "7 Days"
        case .month: return mode == .calendar ? "Monthly" : "30 Days"
        case .all: return "All Time"
        }
    }

    func title(for slot: UsagePeriodSlot) -> String {
        switch slot {
        case .today: return "Today's Usage"
        case .week: return mode == .calendar ? "Weekly Usage" : "Last 7 Days"
        case .month: return mode == .calendar ? "Monthly Usage" : "Last 30 Days"
        case .all: return "All Time"
        }
    }

    func configuredCalendar() -> Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStart == .sunday ? 1 : 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    func startOfConfiguredWeek(_ date: Date, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? configuredCalendar()
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    func range(for slot: UsagePeriodSlot, now: Date) -> UsagePeriodRange {
        let calendar = configuredCalendar()
        let today = calendar.startOfDay(for: now)
        let nowTimestamp = Int64(now.timeIntervalSince1970)

        let start: Date
        switch slot {
        case .today:
            start = today
        case .week:
            if mode == .calendar {
                start = startOfConfiguredWeek(now, calendar: calendar)
            } else {
                start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            }
        case .month:
            if mode == .calendar {
                start = calendar.dateInterval(of: .month, for: now)?.start ?? today
            } else {
                start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            }
        case .all:
            return UsagePeriodRange(start: 0, end: nowTimestamp)
        }

        return UsagePeriodRange(
            start: Int64(start.timeIntervalSince1970),
            end: nowTimestamp
        )
    }

    func cacheKey(now: Date) -> String {
        let calendar = configuredCalendar()
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return [
            mode.rawValue,
            weekStart.rawValue,
            TimeZone.current.identifier,
            "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        ].joined(separator: "|")
    }
}

@MainActor
final class UsagePeriodSettings: ObservableObject {
    static let shared = UsagePeriodSettings()

    private static let modeKey = "usage_period_mode"
    private static let weekStartKey = "usage_period_week_start"

    @Published private(set) var mode: UsagePeriodMode
    @Published private(set) var weekStart: UsageWeekStart

    private init() {
        mode = UsagePeriodMode(rawValue: Database.shared.setting(Self.modeKey) ?? "") ?? .recent
        weekStart = UsageWeekStart(rawValue: Database.shared.setting(Self.weekStartKey) ?? "") ?? .monday
    }

    var configuration: UsagePeriodConfiguration {
        UsagePeriodConfiguration(mode: mode, weekStart: weekStart)
    }

    func setMode(_ mode: UsagePeriodMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        _ = Database.shared.setSetting(Self.modeKey, mode.rawValue)
        notifyChanged()
    }

    func setWeekStart(_ weekStart: UsageWeekStart) {
        guard self.weekStart != weekStart else { return }
        self.weekStart = weekStart
        _ = Database.shared.setSetting(Self.weekStartKey, weekStart.rawValue)
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: TMNotifications.usagePeriodSettingsChanged, object: nil)
    }
}
