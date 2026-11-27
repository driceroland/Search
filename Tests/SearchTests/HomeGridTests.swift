import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The bookmark folder called Home fills a blank tab's grid: its sites by
/// their saved titles, sixteen at most, and nothing without the folder.
@available(macOS 14, *)
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
        defer { list.retire() }

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

    /// The chips and tiles get a backing of their own over a theme only
    /// (idea 881): a light picture with the Mac in dark mode left their ink
    /// on near white. A chosen picture that can't be read is no theme.
    func testABackingGoesUnderTheTilesOverATheme() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let was = (prefs.homeTheme, prefs.homeThemeImage)
        defer { (prefs.homeTheme, prefs.homeThemeImage) = was }
        prefs.homeTheme = .off
        XCTAssertFalse(HomeBackground.behind(prefs))
        prefs.homeTheme = .mountainLake
        XCTAssertTrue(HomeBackground.behind(prefs))
        prefs.homeTheme = .custom
        prefs.homeThemeImage = "/nowhere/\(UUID().uuidString).png"
        XCTAssertFalse(HomeBackground.behind(prefs))
        let shape = RoundedRectangle(cornerRadius: 14)
        prefs.homeTheme = .solid
        XCTAssertGreaterThan(NSHostingView(rootView: WallBacking(shape: shape).frame(width: 40, height: 20)).fittingSize.width, 0)
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
        XCTAssertEqual(HomeGrid.height(browser), 0, "and what lies under it doesn't make room for it (#1381)")

    }

    /// A Split View's empty side lists the open tabs under the field; with
    /// the grid there too, they go under its tiles rather than over them.
    func testGridHeightIsWhatItDraws() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.bookmarks.roots
        defer { browser.bookmarks.adopt(saved); browser.closeAll() }
        let was = browser.prefs.homeGrid
        defer { browser.prefs.homeGrid = was }
        browser.prefs.homeGrid = true
        func drawn() -> CGFloat {
            let host = NSHostingView(rootView: HomeGrid(browser: browser).frame(width: 800, height: 800))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
            host.layoutSubtreeIfNeeded()
            return HomeGrid.height(browser)
        }
        browser.bookmarks.adopt([])
        XCTAssertEqual(drawn(), 0)
        browser.bookmarks.adopt([.folder("Home", (0..<5).map { site("S\($0)") })])
        XCTAssertEqual(drawn(), 2 * 50 + 8, "two rows of 50 and the gap between")
        browser.bookmarks.adopt([.folder("Home", (0..<16).map { site("S\($0)") })])
        XCTAssertEqual(drawn(), 4 * 50 + 3 * 8, "four rows at most")
        browser.prefs.homeGrid = false
        XCTAssertEqual(drawn(), 0, "nothing with the switch off")

    }
}
