import XCTest
@testable import Search

@MainActor
final class BookmarkTabLabelTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "bookmark-tab-label-\(getpid())", 1)
        super.setUp()
    }

    func testLabelMatchesOnlyTheExactBookmarkAddress() {
        let bookmarks = Bookmarks()
        let local = URL(string: "http://127.0.0.1:9000/")!
        let staging = URL(string: "http://127.0.0.1:9001/")!
        let otherPath = URL(string: "http://127.0.0.1:9000/admin")!

        _ = bookmarks.add(local, title: "Local")
        _ = bookmarks.add(staging, title: "Staging")

        XCTAssertEqual(bookmarks.label(for: local), "Local")
        XCTAssertEqual(bookmarks.label(for: staging), "Staging")
        XCTAssertNil(bookmarks.label(for: otherPath), "A bookmark must not name another path on the same server")
    }

    func testBlankBookmarkDoesNotSupplyATabLabel() {
        let bookmarks = Bookmarks()
        let url = URL(string: "https://example.com/")!

        _ = bookmarks.add(url, title: "")

        XCTAssertNil(bookmarks.label(for: url), "An icon-only bookmark must leave the page title alone")
    }

    func testBookmarkLabelSurvivesSameOriginRestoreAndClearsCrossOrigin() {
        let tab = Tab(bench: true)
        let opened = URL(string: "https://staging.example.com:8443/start")!
        let inside = URL(string: "https://staging.example.com:8443/settings")!
        let outside = URL(string: "https://production.example.com:8443/")!

        tab.opened(fromBookmark: "Staging", at: opened)
        XCTAssertEqual(tab.bookmarkLabel, "Staging")

        tab.restore(url: inside, title: "Settings", bookmarkLabel: tab.bookmarkLabel,
                    bookmarkOrigin: "https://staging.example.com:8443")
        XCTAssertEqual(tab.bookmarkLabel, "Staging", "A page on the same server keeps its bookmark name")

        tab.restore(url: outside, title: "Production", bookmarkLabel: tab.bookmarkLabel,
                    bookmarkOrigin: "https://staging.example.com:8443")
        XCTAssertNil(tab.bookmarkLabel, "Going to another server clears the bookmark name")
    }

}
