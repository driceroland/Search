import AppKit
import XCTest
@testable import Search

@MainActor
final class TabSelectionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-selection-\(getpid())", 1)
        super.setUp()
    }

    func testCommandTogglesAndShiftSelectsVisibleRange() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        XCTAssertEqual(tabs.count, 4)

        browser.extendTabSelection(to: tabs[0], modifiers: .command)
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[0].id, tabs[2].id, tabs[3].id]))
        XCTAssertEqual(browser.selectedTabLinks, ["https://one.example/", "https://three.example/", "https://four.example/"])

        browser.extendTabSelection(to: tabs[1], modifiers: .shift)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[1].id, tabs[2].id]))
        XCTAssertEqual(browser.selectedTabLinks, ["https://two.example/", "https://three.example/"])

        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, [tabs[1].id])
        browser.clearTabSelection()
        XCTAssertTrue(browser.selectedTabIDs.isEmpty)
    }

    func testBothSplitHalvesCanBeSelectedAndRangesIncludeBoth() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[3])
        browser.extendTabSelection(to: tabs[0], modifiers: .command)
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[0].id, tabs[1].id, tabs[3].id]))
        XCTAssertEqual(browser.selectedTabLinks, ["https://one.example/", "https://two.example/", "https://four.example/"])

        browser.clearTabSelection()
        browser.extendTabSelection(to: tabs[0], modifiers: .shift)
        XCTAssertEqual(browser.selectedTabIDs, Set(tabs.map(\.id)))
        XCTAssertEqual(browser.visibleSelectedTabCount, 4)
        XCTAssertEqual(browser.selectedTabLinks.count, 4)
    }

    func testDraggingAPickedTabCarriesThePickedTabsTogether() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        // ⌘-click starts with the tab on screen picked; four goes back out.
        browser.extendTabSelection(to: tabs[0], modifiers: .command)
        browser.extendTabSelection(to: tabs[3], modifiers: .command)
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[0].id, tabs[2].id]))
        XCTAssertTrue(browser.isPickedAmongOthers(tabs[0]))
        XCTAssertFalse(browser.isPickedAmongOthers(tabs[1]))

        browser.moveDisplayedTab(tabs[0], to: 3)
        XCTAssertEqual(browser.shownTabs.map(\.title), ["two", "four", "one", "three"])
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[0].id, tabs[2].id]))

        // Dropped on one of its own, the block lands beside the nearest tab
        // that stays put.
        browser.moveDisplayedTab(tabs[2], to: 0)
        XCTAssertEqual(browser.shownTabs.map(\.title), ["one", "three", "two", "four"])
    }

    func testDraggingAnUnpickedTabCarriesItAlone() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([tabs[1].id, tabs[2].id, tabs[3].id]))

        browser.moveDisplayedTab(tabs[0], to: 2)
        XCTAssertEqual(browser.shownTabs.map(\.title), ["two", "three", "one", "four"])
    }

    private func makeBrowser() -> Browser {
        let browser = Browser(record: WindowRecord())
        // One session serves every suite in the process, so a Browser opens
        // with whatever tabs the last test left (see CloseTabsBelowTests).
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView)
        addTeardownBlock { @MainActor in
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
        }
        prefs.usesTabGroups = false
        for word in ["one", "two", "three", "four"] {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(word).example/")!, title: word)
        }
        return browser
    }
}
