import XCTest
@testable import Search

/// Which permission a shim call is checked against: `system.*` are each
/// their own permission in Chrome, everything else is named by its first part.
@available(macOS 15.4, *)
@MainActor
final class ExtensionShimGateTests: XCTestCase {
    func testFamilies() {
        XCTAssertEqual(ExtensionShims.family(of: "system.cpu.getInfo"), "system.cpu")
        XCTAssertEqual(ExtensionShims.family(of: "system.display.getInfo"), "system.display")
        XCTAssertEqual(ExtensionShims.family(of: "fontSettings.getFontList"), "fontSettings")
        XCTAssertEqual(ExtensionShims.family(of: "history.search"), "history")
    }
}
