import SwiftUI

struct UsagePeriodSettingsSection: View {
    @ObservedObject private var settings = UsagePeriodSettings.shared
    var reservesWeekStartSpace = true
    private let labelWidth: CGFloat = 150

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
            Divider()

            HStack(spacing: 10) {
                Text("Period style")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("Period style", selection: modeBinding) {
                    ForEach(UsagePeriodMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .accessibilityLabel("Period style")

            Text(settings.mode.detail)
                .font(TMType.regular(TMType.micro))
                .foregroundStyle(TMDesign.quiet)
                .padding(.leading, labelWidth + 10)

            if settings.mode == .calendar || reservesWeekStartSpace {
                HStack(spacing: 10) {
                    Text("Week starts on")
                        .frame(width: labelWidth, alignment: .leading)
                    Picker("Week starts on", selection: weekStartBinding) {
                        ForEach(UsageWeekStart.allCases) { day in
                            Text(day.title).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .accessibilityLabel("Week starts on")
                    Spacer(minLength: 0)
                }
                .opacity(settings.mode == .calendar ? 1 : 0)
                // Popover keeps this row mounted so switching period modes
                // cannot change the floating panel's intrinsic height.
                .animation(.easeOut(duration: 0.16), value: settings.mode)
                .allowsHitTesting(settings.mode == .calendar)
                .accessibilityHidden(settings.mode != .calendar)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
