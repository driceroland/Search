import AppKit
import XCTest
@testable import Search

/// A pin's ⌘ number pressed again on that pin goes back to the tab before
/// it, with the switch on; with it off, nothing moves (idea 216).
@MainActor
final class PinNumberBackTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "pin-number-back-\(getpid())", 1)
        super.setUp()
    }

    func testOffByDefault() {
        let saved = Store.settings.object(forKey: "pins.numberBack")
        defer { Store.settings.set(saved, forKey: "pins.numberBack") }
        Store.settings.removeObject(forKey: "pins.numberBack")
        XCTAssertFalse(Preferences().pinNumberGoesBack)
    }

    func testSecondPressGoesBackOnlyWhenOn() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.pinNumberGoesBack, prefs.usesTabGroups)
        defer {
            browser.closeAll()
            prefs.pinNumberGoesBack = saved.0
            prefs.usesTabGroups = saved.1
        }
        prefs.usesTabGroups = false
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let pin = browser.tabs[0]
        browser.pin(pin)
        defer { browser.unpin(pin) }
        let reading = browser.tabs.first { $0.pin == nil && $0.title == "Tab 3" }!
        XCTAssertEqual(browser.tabShortcutTargets.first?.tab.id, pin.id, "The pin is ⌘1")

        prefs.pinNumberGoesBack = false
        browser.select(reading)
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, pin.id)
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, pin.id, "Off: a second press stays on the pin")

        prefs.pinNumberGoesBack = true
        browser.select(reading)
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, pin.id, "The first press still goes to the pin")
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, reading.id, "The second goes back to where you were")
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, pin.id, "And again to the pin")

        // A tab's number, not a pin's, never goes back.
        let other = browser.tabShortcutTargets[1].tab
        browser.select(index: 1)
        XCTAssertEqual(browser.activeID, other.id)
        browser.select(index: 1)
        XCTAssertEqual(browser.activeID, other.id)
    }
}
