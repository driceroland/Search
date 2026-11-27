import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Idea 1317: ⌘S on a glass window. The column keeps the glass it sat on
/// while it leaves, its own pane over the page that already has its room,
/// and takes the folded column's opaque ground only once it has gone: it
/// snapped to a flat colour mid-slide, and the white page showed through it
/// while the page was waited for.
@available(macOS 14, *)
@MainActor
final class FoldGlassTests: XCTestCase {
    private var browser: Browser?
    private var restore: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        browser?.closeAll()
        restore?()
        try await super.tearDown()
    }

    func testTheColumnKeepsTheGlassUntilItHasGone() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let previous = (prefs.glass, prefs.tabsLayout, prefs.sideHides)
        restore = { (prefs.glass, prefs.tabsLayout, prefs.sideHides) = previous }
        prefs.tabsLayout = .left
        prefs.sideHides = false
        prefs.glass = true
        let browser = Browser(record: WindowRecord())
        self.browser = browser
        browser.folded = false
        XCTAssertTrue(browser.glassUnder)
        XCTAssertFalse(browser.columnGround, "at rest on glass: no ground of its own")

        browser.toggleFold()
        XCTAssertTrue(browser.folded)
        XCTAssertTrue(browser.columnGlass, "leaving: the glass comes along")
        XCTAssertFalse(browser.columnGround, "leaving: no opaque ground mid-slide")

        try await Task.sleep(for: .seconds(Motion.columnAway + 0.4))
        XCTAssertFalse(browser.columnGlass)
        XCTAssertTrue(browser.columnGround, "gone: the folded column's own ground, for when it comes out over the page")

        // Out over the page: opaque, as before.
        browser.toggleFold()
        XCTAssertFalse(browser.folded)
        XCTAssertFalse(browser.columnGlass)
        XCTAssertFalse(browser.columnGround)

        // Pressed twice at once: the second calls it off, the column stays.
        browser.toggleFold()
        browser.peek(true)
        XCTAssertFalse(browser.columnGlass, "a peek is the opaque folded column, as before")

        // Without glass, nothing changes.
        prefs.glass = false
        browser.peeking = false
        browser.folded = false
        browser.toggleFold()
        XCTAssertFalse(browser.columnGlass)
        XCTAssertTrue(browser.columnGround)
    }
}
