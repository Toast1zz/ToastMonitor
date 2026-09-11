import SwiftUI
import AppKit

/// Bridges the process-wide macOS font panel to a single pick callback.
/// `NSFontPanel` reports changes through the `changeFont:` action on
/// `NSFontManager.shared.target`; the panel itself is a singleton, so one
/// target object owns that callback for the settings row.
@MainActor
final class MenuBarFontPanel: NSObject, NSFontChanging {
    static let shared = MenuBarFontPanel()

    private var onPick: ((NSFont) -> Void)?

    func present(current: NSFont, onPick: @escaping (NSFont) -> Void) {
        self.onPick = onPick
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender, let onPick else { return }
        let converted = sender.convert(
            sender.selectedFont ?? NSFont.systemFont(ofSize: MenuBarTextFont.defaultSize))
        onPick(converted)
    }

    /// Only family/face/size apply to a status-bar title; the text-effect and
    /// document-color modes would be no-ops for it.
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }
}

/// "Appearance" section, shown on the popover settings page and the dashboard
/// Settings tab.
struct AppearanceSettingsSection: View {
    @ObservedObject private var settings = MenuBarFontSettings.shared
    var surface: SettingsSectionSurface = .popover
    private let labelWidth: CGFloat = 150

    private var isPopover: Bool { surface == .popover }

    var body: some View {
        VStack(alignment: .leading, spacing: isPopover ? 10 : 12) {
            SettingsSectionHeading(title: "Appearance", surface: surface)
            row
            detail
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text("Menu Bar Text Font")
                // The dashboard's label column inherits the default body font,
                // matching its other form rows; the popover's rows are
                // medium-weight like the toggles above this section.
                .font(isPopover ? TMType.medium(TMType.body) : nil)
                .frame(width: isPopover ? nil : labelWidth, alignment: .leading)
            if isPopover { Spacer(minLength: 8) }
            Button(settings.selection.displayName) {
                MenuBarFontPanel.shared.present(current: settings.selection.resolvedFont) { font in
                    settings.set(.from(font))
                }
            }
            .controlSize(.small)
            .help("Choose the font used for the menu bar token count")
            if !settings.selection.isSystemDefault {
                Button("Reset") { settings.resetToDefault() }
                    .controlSize(.small)
                    .help("Use the system UI font (SF Pro)")
            }
            if !isPopover { Spacer(minLength: 0) }
        }
        .accessibilityLabel("Menu Bar Text Font")
    }

    private var detail: some View {
        Text("Used for the token count in the menu bar. Defaults to System UI (SF Pro).")
            .font(TMType.regular(TMType.micro))
            .foregroundStyle(TMDesign.quiet)
            .padding(.leading, isPopover ? 0 : labelWidth + 10)
    }
}
