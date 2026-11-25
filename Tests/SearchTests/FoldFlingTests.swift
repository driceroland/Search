import AppKit
import XCTest
@testable import Search

/// The column folded with ⌘S, the window away from the screen's left edge
/// (another app beside it): a hand flung at the edge goes from the page to
/// well past it between two samples of the pointer, and was seen neither at
/// the edge nor in the band just past it (idea 1144). The crossing itself
/// counts now, and only a crossing through the column's side, between the
/// window's top and bottom.
final class FoldFlingTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 800)

    /// What caught the pointer before: the edge inside the window, or the
    /// band just past it beside the window.
    private func caughtBefore(_ point: NSPoint, right: Bool = false) -> Bool {
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        let distance = right ? size.width - point.x : point.x
        let past = right ? point.x - size.width : -point.x
        let beside = past > 0 && past < Fold.overshoot && point.y >= 0 && point.y < size.height
        return (inWindow && distance < Fold.edge) || beside
    }

    func testAFlingPastTheBandWasMissedAndNowCounts() {
        // From the page, 180 pt in, to 90 pt past the left edge in one move.
        let last = NSPoint(x: 180, y: 400)
        let point = NSPoint(x: -90, y: 410)
        XCTAssertFalse(caughtBefore(last))
        XCTAssertFalse(caughtBefore(point), "the old edge and band both miss this move")
        XCTAssertTrue(Fold.flung(from: last, to: point, size: size, right: false))
    }

    func testTheColumnOnTheRight() {
        let last = NSPoint(x: 1000, y: 300)
        let point = NSPoint(x: 1300, y: 300)
        XCTAssertFalse(caughtBefore(point, right: true))
        XCTAssertTrue(Fold.flung(from: last, to: point, size: size, right: true))
        // Out through the left, with the column on the right: nothing.
        XCTAssertFalse(Fold.flung(from: last, to: NSPoint(x: -100, y: 300), size: size, right: true))
    }

    func testOtherEdgesAndCornersDoNotCount() {
        // Out through the bottom, then beside the window's left: the move
        // crossed the left edge's line below the window.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: 40, y: 20), to: NSPoint(x: -60, y: -120), size: size, right: false))
        // Out through the top.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: 40, y: 780), to: NSPoint(x: -60, y: 900), size: size, right: false))
        // Out through the right with the column on the left.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: 1100, y: 400), to: NSPoint(x: 1300, y: 400), size: size, right: false))
        // Straight down out of the window.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: 300, y: 10), to: NSPoint(x: 300, y: -50), size: size, right: false))
    }

    func testOnlyFromInsideTheWindow() {
        // Already off the window: moving further away isn't a crossing.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: -20, y: 400), to: NSPoint(x: -120, y: 400), size: size, right: false))
        XCTAssertFalse(Fold.flung(from: nil, to: NSPoint(x: -120, y: 400), size: size, right: false))
        // Coming back in.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: -120, y: 400), to: NSPoint(x: 100, y: 400), size: size, right: false))
        // Moving within the page.
        XCTAssertFalse(Fold.flung(from: NSPoint(x: 300, y: 400), to: NSPoint(x: 100, y: 400), size: size, right: false))
    }

    /// A window against its screen's edge keeps the old behaviour: the fling
    /// is only taken where there is room beside the window.
    @MainActor
    func testAgainstTheScreenEdge() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first).frame
        let window = NSWindow(contentRect: NSRect(x: screen.minX, y: screen.minY + 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: screen.minX, y: screen.minY + 100, width: 600, height: 400), display: false)
        XCTAssertTrue(Fold.againstScreenEdge(window, right: false))
        XCTAssertFalse(Fold.againstScreenEdge(window, right: true))
        window.setFrame(NSRect(x: screen.minX + 400, y: screen.minY + 100, width: 600, height: 400), display: false)
        XCTAssertFalse(Fold.againstScreenEdge(window, right: false))
    }
}
