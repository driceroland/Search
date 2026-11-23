import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The bookmark folder called Home fills a blank tab's grid: its sites by
/// their saved titles, sixteen at most, and nothing without the folder.
@MainActor
final class HomeGridTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func site(_ title: String) -> Bookmark { .site(title, URL(string: "https://\(title.lowercased()).example/")!) }

    func testHomeSitesAreTheTopLevelHomeFoldersPages() {
        _ = NSApplication.shared
        let list = Bookmarks(file: "home-grid-test.json")

        list.adopt([site("Elsewhere")])
        XCTAssertTrue(list.homeSites.isEmpty, "no Home folder, no grid")

        let many = (0..<20).map { site("S\($0)") }
        list.adopt([.folder("Work", [.folder("Home", [site("Nested")])]),
                    .folder(" home ", [site("A"), .folder("Sub", [site("Deep")]), site("B")] + many)])
        XCTAssertEqual(list.homeSites.prefix(2).map(\.title), ["A", "B"], "any case, top level only, pages only")
        XCTAssertEqual(list.homeSites.count, 16, "four rows of four")

        list.adopt([.folder("Home", [site("A")])])
        XCTAssertEqual(list.homeSites.map(\.label), ["A"], "a change to the list shows at once")
    }

    func testGridIsDrawnOnABlankTabOnlyWithSites() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.bookmarks.roots
        defer { browser.bookmarks.adopt(saved); browser.closeAll() }
        let was = browser.prefs.homeGrid
        defer { browser.prefs.homeGrid = was }
        browser.prefs.homeGrid = true
        func size() -> CGSize { NSHostingView(rootView: HomeGrid(browser: browser)).fittingSize }

        browser.bookmarks.adopt([])
        XCTAssertEqual(size().height, 0, "nothing without a Home folder")
        browser.bookmarks.adopt([.folder("Home", [site("A"), site("B")])])
        XCTAssertEqual(browser.active?.isBlank, true)
        XCTAssertGreaterThan(size().height, 0, "drawn for a blank tab")
        browser.prefs.homeGrid = false
        XCTAssertEqual(size().height, 0, "gone with the switch off")
        browser.prefs.homeGrid = true
        browser.active?.restore(url: URL(string: "https://example.com/")!, title: "x")
        XCTAssertEqual(size().height, 0, "gone once the tab has a page")

    }
}
