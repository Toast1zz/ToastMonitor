import SwiftUI

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
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Date Range")

            Picker("Period style", selection: modeBinding) {
                ForEach(UsagePeriodMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Period style")

            Text(settings.mode.detail)
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.quiet)

            // Always reserve the calendar-only row. Removing and reinserting
            // it changes the NSHostingView's intrinsic height, which makes the
            // AppKit panel resize in a second layout pass. Keeping one stable
            // layout means the native segmented control can switch modes
            // without moving the window at all.
            HStack {
                Text("Week starts on")
                Spacer()
                Picker("Week starts on", selection: weekStartBinding) {
                    ForEach(UsageWeekStart.allCases) { day in
                        Text(day.title).tag(day)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Week starts on")
            }
            .opacity(settings.mode == .calendar ? 1 : 0)
            // The row owns permanent layout space, so this animation changes
            // only its visibility and cannot trigger a panel resize.
            .animation(.easeOut(duration: 0.16), value: settings.mode)
            .allowsHitTesting(settings.mode == .calendar)
            .accessibilityHidden(settings.mode != .calendar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
