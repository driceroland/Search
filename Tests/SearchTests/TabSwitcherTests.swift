import AppKit
import XCTest
@testable import Search

@MainActor
final class TabSwitcherTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-switcher-\(getpid())", 1)
        super.setUp()
    }

    func testResetCancelsDelayedRevealAndDiscardsPictures() async throws {
        let switcher = TabSwitcher()
        let first = UUID(), second = UUID()
        let address = try XCTUnwrap(URL(string: "https://example.test"))
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        XCTAssertNotNil(switcher.preview(for: first, address: address))

        switcher.reset()
        XCTAssertNil(switcher.preview(for: first, address: address))
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

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    private func makeTab(pinned: Bool = false, browser: Browser) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        if pinned {
            tab.pin = "P"
            tab.pinID = UUID()
        }
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    func testEntirelyUnpinnedCollectionReturnsAllTabs() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab1 = makeTab(pinned: false, browser: browser)
        let tab2 = makeTab(pinned: false, browser: browser)
        let tab3 = makeTab(pinned: false, browser: browser)

        XCTAssertEqual(browser.switcherRow, [tab1.id, tab2.id, tab3.id])
    }

    func testEntirelyPinnedCollectionReturnsNoTabs() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        _ = makeTab(pinned: true, browser: browser)
        _ = makeTab(pinned: true, browser: browser)
        _ = makeTab(pinned: true, browser: browser)

        XCTAssertTrue(browser.switcherRow.isEmpty)
    }

    func testMixedCollectionReturnsOnlyUnpinnedTabs() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let pin1 = makeTab(pinned: true, browser: browser)
        let reg1 = makeTab(pinned: false, browser: browser)
        let pin2 = makeTab(pinned: true, browser: browser)
        let reg2 = makeTab(pinned: false, browser: browser)

        XCTAssertEqual(browser.switcherRow, [reg1.id, reg2.id])
        XCTAssertFalse(browser.switcherRow.contains(pin1.id))
        XCTAssertFalse(browser.switcherRow.contains(pin2.id))
    }

    func testEmptyCollectionReturnsEmptyCollection() {
        let browser = makeBrowser()
        defer { browser.closeAll() }

        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertTrue(browser.switcherRow.isEmpty)
    }

    func testPinningTabRemovesItFromFilteredSwitcherRow() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = makeTab(pinned: false, browser: browser)
        XCTAssertTrue(browser.switcherRow.contains(tab.id))

        tab.pin = "P"
        tab.pinID = UUID()
        XCTAssertFalse(browser.switcherRow.contains(tab.id))
    }

    func testUnpinningTabRestoresItToFilteredSwitcherRow() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = makeTab(pinned: true, browser: browser)
        XCTAssertFalse(browser.switcherRow.contains(tab.id))

        tab.pin = nil
        tab.pinID = nil
        XCTAssertTrue(browser.switcherRow.contains(tab.id))
    }

    func testClosingTabUpdatesSwitcherRow() {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab1 = makeTab(pinned: false, browser: browser)
        let tab2 = makeTab(pinned: false, browser: browser)
        XCTAssertEqual(browser.switcherRow, [tab1.id, tab2.id])

        browser.close(tab1)
        XCTAssertEqual(browser.switcherRow, [tab2.id])
    }
}
