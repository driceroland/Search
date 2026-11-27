import AppKit
import XCTest
@testable import Search

/// Settings › Browsing › Return takes the top suggestion (#1556): the place on
/// top of the address field's list is picked as you type, so Return goes to
/// it instead of searching for the words. Off, as it ships, Return searches.
@available(macOS 14, *)
@MainActor
final class ReturnTakesTopTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A page found by a word from its title, which the grey ending can't
    /// finish: the case that needed ↓ before.
    private let page = URL(string: "https://wiki.example/teams/kettlebell-club")!

    func testOffAsItShipsReturnSearches() throws {
        try withBrowser(on: false) { browser in
            browser.typed = "kettlebell"
            XCTAssertEqual(browser.offers.first?.url, page, "the page is listed on top")
            XCTAssertNil(browser.ending, "with nothing in grey")
            XCTAssertNil(browser.picked, "and nothing picked")
            browser.submit()
            XCTAssertNotEqual(browser.active?.address, page, "Return searched the words")
        }
    }

    func testOnTheTopPlaceIsPickedAndReturnGoesThere() throws {
        try withBrowser(on: true) { browser in
            browser.typed = "kettlebell"
            XCTAssertEqual(browser.picked, 0, "the top row is picked as you type")
            XCTAssertEqual(browser.completed, "kettlebell", "the field keeps what was typed")
            browser.submit()
            XCTAssertEqual(browser.active?.address, page, "Return went to the page")
        }
    }

    func testUpLetsGoAndReturnSearches() throws {
        try withBrowser(on: true) { browser in
            browser.typed = "kettlebell"
            browser.walk(-1)
            XCTAssertNil(browser.picked, "↑ lets go of the row")
            browser.submit()
            XCTAssertNotEqual(browser.active?.address, page, "Return searched the words")
        }
    }

    func testDownStillWalksTheList() throws {
        try withBrowser(on: true) { browser in
            browser.typed = "kettlebell"
            browser.walk(1)
            XCTAssertEqual(browser.picked, 1, "↓ goes to the next row")
        }
    }

    func testAnAddressTypedOutGoesWhereItSays() throws {
        try withBrowser(on: true) { browser in
            browser.typed = "wiki.example/teams"
            XCTAssertNil(browser.picked, "an address is not swapped for a row")
        }
    }

    func testNoPlaceOnTopPicksNothing() throws {
        try withBrowser(on: true) { browser in
            browser.typed = "zzqx nothing like it"
            XCTAssertNotEqual(browser.offers.first?.kind.isPlace, true)
            XCTAssertNil(browser.picked, "a search on top is what Return does already")
        }
    }

    private func withBrowser(on: Bool, _ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.returnTakesTop
        browser.history.record(page, title: "Kettlebell club")
        defer {
            browser.history.forget(History.identity(for: page))
            browser.closeAll()
            prefs.returnTakesTop = saved
        }
        prefs.returnTakesTop = on
        browser.newTab()
        browser.edit()
        try body(browser)
    }
}
