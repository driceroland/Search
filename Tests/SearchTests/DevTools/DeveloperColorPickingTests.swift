import AppKit
import XCTest
@testable import Search

/// Opening the colour picker sends the panel's action with the colour it
/// opened with; that isn't a pick, so the value is left as written.
@MainActor final class DeveloperColorPickingTests: XCTestCase {
    func testTheOpeningColourCountsAsUnchanged() {
        let grey = NSColor(srgbRed: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255, alpha: 1)
        let panelGrey = grey.usingColorSpace(.genericRGB) ?? grey
        XCTAssertTrue(DeveloperColorPicking.same(grey, panelGrey))
        let darker = NSColor(srgbRed: 0x87 / 255, green: 0x88 / 255, blue: 0x88 / 255, alpha: 1)
        XCTAssertFalse(DeveloperColorPicking.same(grey, darker))
        XCTAssertFalse(DeveloperColorPicking.same(grey, grey.withAlphaComponent(0.5)))
    }
}
