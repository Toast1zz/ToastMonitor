import AppKit
import Foundation

/// A user-chosen font for the menu-bar status text.
///
/// `name` is the PostScript name (`NSFont(name:size:)` needs it); `family`
/// is kept only for the settings label. An empty `name` is the default system
/// UI font — SF Pro rendered with tabular digits so the token count keeps a
/// stable width as it changes.
struct MenuBarTextFont: Equatable, Codable {
    static let defaultSize: CGFloat = 13
    /// The status bar is 22–24 pt tall; the font panel offers sizes up to
    /// 288 pt, which would clip the title, so picks are clamped to this.
    static let sizeRange: ClosedRange<CGFloat> = 10...16
    static let systemDefault = MenuBarTextFont(name: "", family: "", size: defaultSize)

    var name: String
    var family: String
    var size: CGFloat

    var isSystemDefault: Bool { name.isEmpty }

    /// Label for the settings row and its picker button.
    var displayName: String {
        if isSystemDefault { return "System UI (SF Pro)" }
        return family.isEmpty ? name : family
    }

    /// Resolves the stored choice to an AppKit font. An unavailable family
    /// (font uninstalled since it was chosen) falls back to the system UI
    /// font so the status item is never left blank. Custom fonts also get
    /// tabular digits where the font supports them, like the default.
    var resolvedFont: NSFont {
        let size = Self.clamped(size)
        if !isSystemDefault, let font = NSFont(name: name, size: size) {
            let tabular = font.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
            return NSFont(descriptor: tabular, size: size) ?? font
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// Normalizes a font picked in the macOS font panel. The panel's system
    /// entry resolves to a private PostScript name (".AppleSystemUIFont")
    /// that `NSFont(name:size:)` cannot recreate, so it collapses to the
    /// system default rather than being stored as an unresolvable name.
    static func from(_ font: NSFont) -> MenuBarTextFont {
        let family = font.familyName ?? ""
        let size = clamped(font.pointSize)
        let systemFamily = NSFont.systemFont(ofSize: font.pointSize).familyName ?? ""
        if font.fontName.hasPrefix(".") || (!systemFamily.isEmpty && family == systemFamily) {
            return MenuBarTextFont(name: "", family: "", size: size)
        }
        return MenuBarTextFont(name: font.fontName, family: family, size: size)
    }

    static func decode(_ raw: String?) -> MenuBarTextFont {
        guard let raw,
              let data = raw.data(using: .utf8),
              let font = try? JSONDecoder().decode(MenuBarTextFont.self, from: data),
              font.size.isFinite, font.size > 0
        else { return .systemDefault }
        return font
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Persisted "Menu Bar Text Font" choice (settings key `menu_bar_font`).
@MainActor
final class MenuBarFontSettings: ObservableObject {
    static let shared = MenuBarFontSettings()
    static let settingKey = "menu_bar_font"

    @Published private(set) var selection: MenuBarTextFont

    private init() {
        selection = MenuBarTextFont.decode(Database.shared.setting(Self.settingKey))
    }

    func set(_ font: MenuBarTextFont) {
        guard font != selection else { return }
        selection = font
        // Synchronous, like UsagePeriodSettings: the font panel emits a
        // stream of picks while the size control is dragged, and ordered
        // writes keep the stored value matching the last pick.
        if let encoded = font.encoded {
            _ = Database.shared.setSetting(Self.settingKey, encoded)
        }
    }

    func resetToDefault() {
        set(.systemDefault)
    }
}
