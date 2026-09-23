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

/// Font picker button plus a Reset button once a custom font is chosen.
/// Hosted by the popover's Appearance group and the dashboard section.
struct MenuBarFontControls: View {
    static let footnote = "Used for the token count in the menu bar. Defaults to System UI (SF Pro)."

    @ObservedObject private var settings = MenuBarFontSettings.shared

    var body: some View {
        HStack(spacing: 6) {
            Button(settings.selection.displayName) {
                MenuBarFontPanel.shared.present(current: settings.selection.resolvedFont) { font in
                    settings.set(.from(font))
                }
            }
            .help("Choose the font used for the menu bar token count")
            .accessibilityLabel("Menu bar font")
            .accessibilityValue(settings.selection.displayName)
            if !settings.selection.isSystemDefault {
                Button("Reset") { settings.resetToDefault() }
                    .help("Use the system UI font (SF Pro)")
                    .accessibilityLabel("Reset menu bar font")
            }
        }
    }
}

/// "Appearance" section of the dashboard Settings form.
struct AppearanceSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent("Menu bar font") {
                MenuBarFontControls()
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(MenuBarFontControls.footnote)
        }
    }
}
