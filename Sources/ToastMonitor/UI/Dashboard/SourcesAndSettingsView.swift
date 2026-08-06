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
                VStack(alignment: .leading, spacing: 2) {
                    Text("来源与设置")
                        .font(.title2.weight(.semibold))
                    Text(section == .sources ? "确认采集器、Feed 与数据新鲜度" : "管理来源、凭据与固定订阅")
                        .font(.subheadline)
                        .foregroundStyle(TMDesign.quiet)
                }
                Spacer()
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
