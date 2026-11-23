import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Settings › Preferences › Appearance › Theme: Chrome's three choices and
/// what each puts on DevTools' views.
final class DeveloperToolsThemeTests: XCTestCase {
    func testChoicesAreChromesAndSystemFollowsTheBrowser() {
        XCTAssertEqual(DeveloperToolsTheme.allCases.map(\.title), ["System preference", "Light", "Dark"])
        XCTAssertNil(DeveloperToolsTheme.system.appearance)
        XCTAssertNil(DeveloperToolsTheme.system.colorScheme)
        XCTAssertEqual(DeveloperToolsTheme.light.appearance?.name, .aqua)
        XCTAssertEqual(DeveloperToolsTheme.dark.appearance?.name, .darkAqua)
        XCTAssertEqual(DeveloperToolsTheme.dark.colorScheme, .dark)
        XCTAssertEqual(DeveloperToolsTheme(rawValue: "dark"), .dark)
    }
}
