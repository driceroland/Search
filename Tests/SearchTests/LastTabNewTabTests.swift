import AppKit
import XCTest
@testable import Search

/// #1577: the last tab that isn't a pin closed, with only pins beside it,
/// leaves a new tab rather than taking you into a pin, as it comes, with
/// nothing set (Settings › Tabs › Leave a new tab when the last tab closes,
/// on since 26 Nov 2026). Turned off, a pin is picked, as before.
@MainActor
final class LastTabNewTabTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testOnAsItComes() {
        let store = Store.settings
        let saved = store.object(forKey: "tabs.newAfterLast")
        defer { if let saved { store.set(saved, forKey: "tabs.newAfterLast") } else { store.removeObject(forKey: "tabs.newAfterLast") } }
        store.removeObject(forKey: "tabs.newAfterLast")
        XCTAssertTrue(Preferences().newTabAfterLast)
        store.set(false, forKey: "tabs.newAfterLast")
        XCTAssertFalse(Preferences().newTabAfterLast, "turned off, it stays off")
    }

    func testTheLastTabBesidePinsLeavesANewTab() throws {
        try withPinsAndOneTab(newTabAfterLast: true) { browser, pins, tab in
            browser.closeTab(tab)
            let now = try XCTUnwrap(browser.active)
            XCTAssertNil(now.pin, "not a pin")
            XCTAssertTrue(now.isBlank, "a new tab")
            XCTAssertEqual(browser.tabs.filter { $0.pin != nil }.map(\.id), pins.map(\.id), "the pins stay")
            XCTAssertFalse(browser.tabs.contains { $0.id == tab.id })
        }
    }

    func testTurnedOffAPinIsPicked() throws {
        try withPinsAndOneTab(newTabAfterLast: false) { browser, pins, tab in
            browser.closeTab(tab)
            XCTAssertNotNil(browser.active?.pin, "a pin, as before")
        }
    }

    private func withPinsAndOneTab(newTabAfterLast: Bool, _ body: (Browser, [Tab], Tab) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let store = Store.settings
        let saved = store.object(forKey: "tabs.newAfterLast")
        defer {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            if let saved { store.set(saved, forKey: "tabs.newAfterLast") } else { store.removeObject(forKey: "tabs.newAfterLast") }
            prefs.newTabAfterLast = Preferences().newTabAfterLast
        }
        prefs.newTabAfterLast = newTabAfterLast
        for number in 1...3 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.com/\(number)")!, title: "Tab \(number)")
        }
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.pin(tabs[1])
        let loose = try XCTUnwrap(browser.tabs.first { $0.pin == nil })
        browser.select(loose)
        // Every other tab that isn't a pin closed: this one is the last.
        for other in browser.tabs where other.pin == nil && other.id != loose.id { browser.close(other) }
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.map(\.id), [loose.id])
        XCTAssertEqual(browser.active?.id, loose.id)
        try body(browser, browser.tabs.filter { $0.pin != nil }, loose)
    }
}
