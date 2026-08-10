import SwiftUI

/// One destination for operational setup. The segmented switch is a local
/// context switch, not another top-level navigation branch.
struct SourcesAndSettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case sources = "Sources"
        case settings = "Settings"
        var id: String { rawValue }
    }

    @State private var section: Section = .sources

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .accessibilityLabel("Sources and Settings")
                .accessibilityHint("Switch between source status and configuration")
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch section {
                case .sources: SourcesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
