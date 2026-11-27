import XCTest
@testable import Search

/// The column's right-click menu and View say what ⌘S does now
/// (Browser.foldTitle): a hidden column, even one out over the page because
/// the pointer brought it, is shown; one in its place is hidden.
@MainActor
final class FoldTitleTests: XCTestCase {
    func testColumn() {
        XCTAssertEqual(Browser.foldTitle(sidebar: true, folded: false, shrinks: false, icons: false), "Hide Sidebar")
        XCTAssertEqual(Browser.foldTitle(sidebar: true, folded: true, shrinks: false, icons: false), "Show Sidebar")
    }

    func testTabBar() {
        XCTAssertEqual(Browser.foldTitle(sidebar: false, folded: false, shrinks: false, icons: false), "Hide Tab Bar")
        XCTAssertEqual(Browser.foldTitle(sidebar: false, folded: true, shrinks: false, icons: false), "Show Tab Bar")
    }

    func testIconsOnlyInsteadOfHiding() {
        XCTAssertEqual(Browser.foldTitle(sidebar: true, folded: false, shrinks: true, icons: false), "Show Sidebar as Icons Only")
        XCTAssertEqual(Browser.foldTitle(sidebar: true, folded: false, shrinks: true, icons: true), "Show Sidebar Titles")
        // Folded before the switch was turned on: it comes out first.
        XCTAssertEqual(Browser.foldTitle(sidebar: true, folded: true, shrinks: true, icons: true), "Show Sidebar")
    }
}
