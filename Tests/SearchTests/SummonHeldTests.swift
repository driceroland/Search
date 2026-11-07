import AppKit
import XCTest
@testable import Search

/// ⌘K pressed again with ⌘ still down walks the switcher's list; pressed
/// afresh it puts the switcher away. Raised from the menu with the mouse, ⌘
/// was never down, so the next ⌘K is a fresh press.
@MainActor
final class SummonHeldTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "summon-held-\(getpid())", 1)
        super.setUp()
    }

    func testMenuRaisedSwitcherIsPutAwayByNextCommandK() throws {
        let browser = try twoPages()
        defer { browser.closeAll() }
        becomeCurrent(modifiers: [])
        browser.summon()
        XCTAssertTrue(browser.summoning)
        XCTAssertEqual(browser.offers.count, 1)

        browser.searchTabsKey()

        XCTAssertFalse(browser.summoning)
        XCTAssertFalse(browser.editing)
    }

    func testCommandKHeldStillWalksTheList() throws {
        let browser = try twoPages()
        defer { browser.closeAll() }
        becomeCurrent(modifiers: .command)
        browser.summon()
        XCTAssertEqual(browser.picked, 0)

        browser.searchTabsKey()

        XCTAssertTrue(browser.summoning)
        XCTAssertTrue(browser.editing)
    }

    private func twoPages() throws -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        for path in ["a", "b"] {
            browser.newTab()
            try XCTUnwrap(browser.active).go(to: URL(string: "http://127.0.0.1:9/\(path)")!)
        }
        return browser
    }

    /// Makes NSApp.currentEvent an event with these keys down, as the menu's
    /// click or ⌘K's key would be while summon() runs.
    private func becomeCurrent(modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 0, data1: 0, data2: 0)!
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertEqual(NSApp.currentEvent?.modifierFlags.contains(.command), modifiers.contains(.command))
    }
}
