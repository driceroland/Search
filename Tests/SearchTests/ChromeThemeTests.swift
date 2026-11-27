import Foundation
import XCTest
@testable import Search

/// Idea 1326: a Chrome theme from the Web Store installed and changed
/// nothing. It is now refused before anything is asked, saying where
/// Search's own colours are.
@available(macOS 14, *)
final class ChromeThemeTests: XCTestCase {
    func testAThemeIsToldApartFromAnExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String, _ manifest: String) throws -> URL {
            let at = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: at.appendingPathComponent("manifest.json"))
            return at
        }
        let theme = try folder("theme", #"{"manifest_version": 3, "name": "Ocean", "version": "1", "theme": {"colors": {"frame": [10, 40, 90], "toolbar": [20, 60, 120]}}}"#)
        let ext = try folder("ext", #"{"manifest_version": 3, "name": "Tool", "version": "1", "action": {}}"#)
        XCTAssertTrue(Crx.isTheme(theme))
        XCTAssertFalse(Crx.isTheme(ext))
        XCTAssertFalse(Crx.isTheme(root.appendingPathComponent("missing")))
        let said = try XCTUnwrap(Crx.Refused.theme.errorDescription)
        XCTAssertTrue(said.contains("themes aren't supported"))
        XCTAssertTrue(said.contains("Settings › Themes"))
    }
}
