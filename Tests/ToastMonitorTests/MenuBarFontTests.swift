import XCTest
import AppKit
@testable import ToastMonitor

final class MenuBarFontTests: XCTestCase {
    func testUnsetOrInvalidSettingFallsBackToSystemDefault() {
        XCTAssertEqual(MenuBarTextFont.decode(nil), .systemDefault)
        XCTAssertEqual(MenuBarTextFont.decode("not json"), .systemDefault)
        XCTAssertEqual(MenuBarTextFont.decode("{\"name\":\"\",\"family\":\"\",\"size\":0}"), .systemDefault)
    }

    func testSelectionRoundTripsThroughStoredJSON() {
        let picked = MenuBarTextFont(name: "Menlo-Regular", family: "Menlo", size: 14)
        XCTAssertEqual(MenuBarTextFont.decode(picked.encoded), picked)
        XCTAssertEqual(MenuBarTextFont.decode(picked.encoded).displayName, "Menlo")
        XCTAssertEqual(MenuBarTextFont.systemDefault.displayName, "System UI (SF Pro)")
    }

    /// The font panel's "System Font" entry resolves to a private PostScript
    /// name that `NSFont(name:size:)` cannot recreate; it must collapse to
    /// the default instead of being stored as an unresolvable name.
    func testSystemFontPanelPickCollapsesToTheDefault() {
        let pick = MenuBarTextFont.from(NSFont.systemFont(ofSize: 15))
        XCTAssertTrue(pick.isSystemDefault)
        XCTAssertEqual(pick.size, 15)
    }

    func testNamedFontPanelPickKeepsNameFamilyAndSize() {
        let pick = MenuBarTextFont.from(NSFont(name: "Menlo-Regular", size: 14)!)
        XCTAssertEqual(pick.name, "Menlo-Regular")
        XCTAssertEqual(pick.family, "Menlo")
        XCTAssertEqual(pick.size, 14)
        XCTAssertFalse(pick.isSystemDefault)
    }

    func testResolvedFontUsesTabularDigitsByDefaultAndFallsBackWhenMissing() {
        XCTAssertEqual(MenuBarTextFont.systemDefault.resolvedFont,
                       NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        let missing = MenuBarTextFont(name: "NoSuchFont-XYZ", family: "NoSuchFont", size: 12)
        XCTAssertEqual(missing.resolvedFont.pointSize, 12)
        let named = MenuBarTextFont(name: "Menlo-Regular", family: "Menlo", size: 14)
        XCTAssertEqual(named.resolvedFont.fontName, "Menlo-Regular")
    }
}
