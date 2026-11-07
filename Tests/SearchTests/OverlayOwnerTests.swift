import AppKit
import XCTest
@testable import Search

/// Overlays that hold the keyboard end when what they belong to goes away,
/// so ⌃Tab isn't left refused with nothing on screen.
@MainActor
final class OverlayOwnerTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "overlay-owner-\(getpid())", 1)
        super.setUp()
    }

    func testPuttingTheFieldAwayEndsTheSwitcher() {
        let browser = makeBrowser()
        browser.summon()
        XCTAssertTrue(browser.summoning)
        XCTAssertEqual(browser.fieldMode, .switcher)

        // What arrive, pasteAndGo and opening a tab each do to the field.
        browser.editing = false
        XCTAssertFalse(browser.summoning)
        XCTAssertEqual(browser.fieldMode, .blank)
    }

    func testRaisingAnOverlayPutsAwayTheOneUp() {
        let browser = makeBrowser()
        browser.welcoming = true
        browser.reviewing = true
        XCTAssertTrue(browser.reviewing)
        XCTAssertFalse(browser.welcoming)

        // The switcher's field goes with the switcher.
        browser.summon()
        XCTAssertFalse(browser.reviewing)
        XCTAssertTrue(browser.editing)
        browser.bookmarksOpen = true
        XCTAssertFalse(browser.summoning)
        XCTAssertFalse(browser.editing)

        // Closing one that isn't up leaves the one that is.
        browser.reviewing = false
        XCTAssertTrue(browser.bookmarksOpen)
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.tabs.last?.restore(url: URL(string: "https://one.example/")!, title: "one")
        return browser
    }
}
