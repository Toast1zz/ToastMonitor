import SwiftUI

/// One destination for operational setup. The segmented switch is a local
/// context switch, not another top-level navigation branch.
struct SourcesAndSettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case sources = "来源状态"
        case settings = "配置"
        var id: String { rawValue }
    }

    @State private var section: Section = .sources

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("部分", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
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
