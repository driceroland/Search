import XCTest
@testable import Search

final class SidebarResizeTests: XCTestCase {
    func testBoundsAndMidpointSnap() {
        XCTAssertEqual(SidebarResize.width(for: 140, expanded: true), 160)
        XCTAssertEqual(SidebarResize.width(for: 500, expanded: true), 440)
        XCTAssertEqual(SidebarResize.isCollapsed(width: 100), true)
        XCTAssertEqual(SidebarResize.isCollapsed(width: 102), false)
    }

    func testEdgeDeltasAndCollapsedExpansion() {
        XCTAssertEqual(SidebarResize.proposedWidth(start: 200, translation: 20, position: .left), 220)
        XCTAssertEqual(SidebarResize.proposedWidth(start: 200, translation: 20, position: .right), 180)
        XCTAssertEqual(SidebarResize.width(for: 130, expanded: false), 42)
    }

    func testInterruptedGestureAndSavedWideWidth() {
        XCTAssertEqual(SidebarResize.finish(start: 200, proposed: 90, position: .left), true, "in, to the rail")
        XCTAssertEqual(SidebarResize.finish(start: 200, proposed: 130, position: .left), false, "out, to titles")
        XCTAssertEqual(SidebarResize.savedWidth(current: 200, proposed: 90, collapsed: true), 200)
        XCTAssertEqual(SidebarResize.savedWidth(current: 200, proposed: 210, collapsed: false), 210)
        XCTAssertEqual(SidebarResize.finish(start: 200, proposed: 220, position: .right, interrupted: true), nil)
    }
}
