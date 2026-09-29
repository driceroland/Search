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

    private func makeBrowser() -> Browser {
        let browser = Browser(record: WindowRecord())
        for word in ["one", "two", "three", "four"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(word).example/")!, title: word)
        }
        return browser
    }
}
