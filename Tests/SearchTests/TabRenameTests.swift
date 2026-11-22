import AppKit
import WebKit
import XCTest
@testable import Search

/// Rename types over the title where the tab has one drawn, and asks in a
/// sheet where it hasn't: a pinned square, the column of icons (#1354).
/// There, the field never came and the edit stayed open, unseen.
@MainActor
final class TabRenameTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func tab(pin: Bool) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://example.com")!)
        if pin { tab.pin = "P" }
        return tab
    }

    func testWhereTheNameCanBeTyped() {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let before = (prefs.sidebar, prefs.sideIcons, prefs.listsPins)
        defer { (prefs.sidebar, prefs.sideIcons, prefs.listsPins) = before }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let loose = tab(pin: false), pinned = tab(pin: true)
        defer { loose.close(); pinned.close() }

        // Tabs across the top: as before.
        prefs.sidebar = false
        XCTAssertTrue(browser.renamesInPlace(loose))
        XCTAssertTrue(browser.renamesInPlace(pinned))

        // The column with titles: a row, but a pin is a square.
        prefs.sidebar = true
        prefs.sideIcons = false
        prefs.listsPins = false
        XCTAssertTrue(browser.renamesInPlace(loose))
        XCTAssertFalse(browser.renamesInPlace(pinned))
        // Pins as rows: a listed pin has its row.
        prefs.listsPins = true
        pinned.listed = true
        XCTAssertTrue(browser.renamesInPlace(pinned))

        // Icons only: no titles anywhere.
        prefs.sideIcons = true
        XCTAssertFalse(browser.renamesInPlace(loose))
        XCTAssertFalse(browser.renamesInPlace(pinned))
    }
}
