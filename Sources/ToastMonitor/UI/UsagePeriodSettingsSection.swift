import SwiftUI

/// "Date Range" section of the dashboard Settings form.
struct UsagePeriodSettingsSection: View {
    @ObservedObject private var settings = UsagePeriodSettings.shared

    private var modeBinding: Binding<UsagePeriodMode> {
        Binding(
            get: { settings.mode },
            set: { settings.setMode($0) }
        )
    }

    private var weekStartBinding: Binding<UsageWeekStart> {
        Binding(
            get: { settings.weekStart },
            set: { settings.setWeekStart($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Period style", selection: modeBinding) {
                ForEach(UsagePeriodMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if settings.mode == .calendar {
                Picker("Week starts on", selection: weekStartBinding) {
                    ForEach(UsageWeekStart.allCases) { day in
                        Text(day.title).tag(day)
                    }
                }
            }
        } header: {
            Text("Date Range")
        } footer: {
            Text(settings.mode.detail)
        }
    }
}
