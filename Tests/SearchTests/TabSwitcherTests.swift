import AppKit
import XCTest
@testable import Search

@MainActor
final class TabSwitcherTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-switcher-\(getpid())", 1)
        super.setUp()
    }

    func testDisablingResetsEveryBrowsersSwitcher() throws {
        _ = NSApplication.shared
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let previous = first.prefs.mruSwitcher
        let saved = Store.settings.object(forKey: "tabs.mru")
        defer {
            first.prefs.mruSwitcher = previous
            if let saved { Store.settings.set(saved, forKey: "tabs.mru") }
            else { Store.settings.removeObject(forKey: "tabs.mru") }
        }
        first.prefs.mruSwitcher = true
        let address = try XCTUnwrap(URL(string: "https://example.test"))
        let a = UUID(), b = UUID()
        for browser in [first, second] {
            let switcher = browser.tabSwitcher
            switcher.step(row: [a, b], current: a, backwards: false)
            switcher.step(row: [a, b], current: a, backwards: false)
            switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: a, address: address)
            XCTAssertTrue(switcher.visible)
            XCTAssertNotNil(switcher.preview(for: a, address: address))
        }

        first.prefs.mruSwitcher = false
        for browser in [first, second] {
            XCTAssertFalse(browser.prefs.mruSwitcher)
            XCTAssertFalse(browser.tabSwitcher.visible)
            XCTAssertTrue(browser.tabSwitcher.candidates.isEmpty)
            XCTAssertNil(browser.tabSwitcher.preview(for: a, address: address))
        }
    }

    func testResetCancelsDelayedRevealAndDiscardsPictures() async throws {
        let switcher = TabSwitcher()
        let first = UUID(), second = UUID()
        let address = try XCTUnwrap(URL(string: "https://example.test"))
        switcher.partners = [first: second]
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        XCTAssertNotNil(switcher.preview(for: first, address: address))

        switcher.reset()
        XCTAssertNil(switcher.preview(for: first, address: address))
        XCTAssertTrue(switcher.partners.isEmpty)
        // A result arriving after reset cannot repopulate the cache.
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        XCTAssertNil(switcher.preview(for: first, address: address))

        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.reset()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(switcher.visible)
        XCTAssertFalse(switcher.active)
        XCTAssertNil(switcher.selectedID)
    }
}
