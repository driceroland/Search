import AppKit
import XCTest
@testable import Search

final class PopoverSideTests: XCTestCase {
    private let clear = PopoverSide.clearance
    private let screen = NSRect(x: 0, y: 0, width: 2560, height: 1400)

    /// A 26-point button whose middle is at `x`, `y`.
    private func button(_ x: CGFloat, _ y: CGFloat) -> NSRect {
        NSRect(x: x - 13, y: y - 13, width: 26, height: 26)
    }

    func testAnArrowClearOfTheScreensEdgesStaysWhereItIs() {
        XCTAssertEqual(PopoverSide.shift(400, low: 0, high: 1400), 0)
        XCTAssertEqual(PopoverSide.shift(clear, low: 0, high: 1400), 0, "exactly clear")
        XCTAssertEqual(PopoverSide.shift(1400 - clear, low: 0, high: 1400), 0)
        XCTAssertEqual(PopoverSide.placement(of: button(400, 400), in: screen, beside: true),
                       .init(turn: .none, move: .zero))
    }

    func testAShiftIsJustFarEnough() {
        XCTAssertEqual(PopoverSide.shift(20, low: 0, high: 1400), clear - 20)
        XCTAssertEqual(PopoverSide.shift(90, low: 70, high: 1400), clear - 20, "measured from above the Dock")
        XCTAssertEqual(PopoverSide.shift(1390, low: 0, high: 1400), 1400 - clear - 1390)
        XCTAssertEqual(PopoverSide.shift(2550, low: 1440, high: 2560), 2560 - clear - 2550, "a second screen")
        XCTAssertEqual(PopoverSide.shift(10, low: 0, high: 2 * clear - 1), 0, "too small to be clear of both ends")
    }

    /// Beside a button a little near the foot of the screen, the arrow moves
    /// up while it still points at the button: no further than its edge.
    func testBesideAButtonTheArrowMovesUpWhileItStillPointsAtIt() {
        XCTAssertEqual(PopoverSide.placement(of: button(400, 45), in: screen, beside: true),
                       .init(turn: .none, move: CGVector(dx: 0, dy: clear - 45)))
        XCTAssertEqual(PopoverSide.placement(of: button(400, clear - 13), in: screen, beside: true),
                       .init(turn: .none, move: CGVector(dx: 0, dy: 13)), "up to the button's top edge")
    }

    /// The column's foot buttons stand about 20 points above the window's
    /// bottom: a window down to the foot of the screen puts them too near it
    /// for the arrow to stay on the button, and the popover hangs above.
    func testNearerItHangsAbove() {
        XCTAssertEqual(PopoverSide.placement(of: button(400, 20), in: screen, beside: true),
                       .init(turn: .above, move: .zero))
        XCTAssertEqual(PopoverSide.placement(of: button(400, 1390), in: screen, beside: true),
                       .init(turn: .under, move: .zero), "at the top of the screen, under")
    }

    /// In the screen's bottom-left corner, hung above, and moved right to
    /// keep the arrow clear of the side corner.
    func testInTheCornerItHangsAboveMovedAlong() {
        XCTAssertEqual(PopoverSide.placement(of: button(37, 20), in: screen, beside: true),
                       .init(turn: .above, move: CGVector(dx: clear - 37, dy: 0)))
    }

    func testAboveOrUnderAButtonOnlyMovesAlong() {
        XCTAssertEqual(PopoverSide.placement(of: button(23, 20), in: screen, beside: false),
                       .init(turn: .none, move: CGVector(dx: clear - 23, dy: 0)))
        XCTAssertEqual(PopoverSide.placement(of: button(400, 20), in: screen, beside: false),
                       .init(turn: .none, move: .zero))
    }

    func testAViewInNoWindowHangsAsAsked() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        XCTAssertEqual(PopoverSide.placement(of: view.bounds, in: view, beside: true), .init(turn: .none, move: .zero))
    }

    /// A real window at the foot of the screen, at its left edge: measured
    /// on the screen the button is on, in screen points.
    func testAButtonInAWindowAtTheScreensCorner() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let room = screen.visibleFrame
        try XCTSkipIf(room.width < 4 * clear || room.height < 4 * clear, "screen too small")
        let window = NSWindow(contentRect: NSRect(origin: room.origin, size: NSSize(width: 200, height: 200)),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(room.origin)
        defer { window.close() }
        let button = NSView(frame: NSRect(x: 10, y: 7, width: 26, height: 26))
        window.contentView?.addSubview(button)
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        try XCTSkipIf(abs(frame.minX - (room.minX + 10)) > 1 || abs(frame.minY - (room.minY + 7)) > 1, "window not placed where asked")

        let beside = PopoverSide.placement(of: button.bounds, in: button, beside: true)
        XCTAssertEqual(beside.turn, .above)
        XCTAssertEqual(beside.move.dx, clear - 23, accuracy: 0.5)
        XCTAssertEqual(beside.move.dy, 0)
    }

    // MARK: - the view the popover is shown from

    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    /// The first button at the column's foot: a view of the button's own
    /// size, as SwiftUI wraps it, in the column, in the window's content.
    private func foot(column: NSView = NSView()) -> (button: NSView, column: NSView, content: NSView) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        column.frame = NSRect(x: 0, y: 0, width: 220, height: 300)
        let wrap = NSView(frame: NSRect(x: 10, y: 10, width: 26, height: 26))
        let button = NSView(frame: wrap.bounds)
        content.addSubview(column)
        column.addSubview(wrap)
        wrap.addSubview(button)
        return (button, column, content)
    }

    func testARectStillOnItsButtonIsShownFromTheButton() throws {
        let (button, _, _) = foot()
        for dx in [0, 13, 25] as [CGFloat] {
            let rect = button.bounds.offsetBy(dx: dx, dy: 0)
            let hung = try XCTUnwrap(PopoverSide.holder(of: rect, in: button, edge: .maxY))
            XCTAssertTrue(hung.view === button, "moved \(dx)")
            XCTAssertEqual(hung.rect, rect)
            XCTAssertEqual(hung.edge, .maxY)
        }
    }

    /// Moved the 29 points a button 23 points from the screen's edge is
    /// moved, the rect is off the 26-point button, and off the wrapper of
    /// the same size: NSPopover would show nothing from either. The column
    /// holds it, at the same place in the window.
    func testARectMovedOffItsButtonIsShownFromTheViewThatHoldsIt() throws {
        let (button, column, _) = foot()
        let moved = button.bounds.offsetBy(dx: clear - 23, dy: 0)
        XCTAssertFalse(button.bounds.intersects(moved))
        let hung = try XCTUnwrap(PopoverSide.holder(of: moved, in: button, edge: .maxY))
        XCTAssertTrue(hung.view === column)
        XCTAssertEqual(hung.rect, NSRect(x: 10 + clear - 23, y: 10, width: 26, height: 26))
        XCTAssertEqual(hung.edge, .maxY, "both count y upwards: above stays above")
    }

    /// SwiftUI's views count y downwards: the same place, and the side
    /// turned over so the popover still hangs above.
    func testAViewThatCountsTheOtherWayTurnsTheSideOver() throws {
        let (button, column, _) = foot(column: Flipped())
        let moved = button.bounds.offsetBy(dx: clear - 23, dy: 0)
        let hung = try XCTUnwrap(PopoverSide.holder(of: moved, in: button, edge: .maxY))
        XCTAssertTrue(hung.view === column)
        XCTAssertEqual(hung.rect, column.convert(moved, from: button))
        XCTAssertEqual(hung.edge, .minY)
        XCTAssertEqual(PopoverSide.holder(of: moved, in: button, edge: .maxX)?.edge, .maxX, "left and right stay")
    }

    func testARectOffEveryViewHasNoHolder() {
        let (button, _, _) = foot()
        XCTAssertNil(PopoverSide.holder(of: button.bounds.offsetBy(dx: -500, dy: 0), in: button, edge: .maxY))
    }

    /// What it is for, in a real window at the screen's corner: the popover
    /// comes up. Shown straight from the moved rect, it does not.
    func testAPopoverFromTheFirstButtonInTheCornerComesUp() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let room = screen.visibleFrame
        try XCTSkipIf(room.width < 4 * clear || room.height < 4 * clear, "screen too small")
        let window = NSWindow(contentRect: NSRect(origin: room.origin, size: NSSize(width: 400, height: 300)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(room.origin)
        defer { window.close() }
        let (button, _, content) = foot()
        window.contentView = content
        window.orderFrontRegardless()
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        try XCTSkipIf(abs(frame.minX - (room.minX + 10)) > 1 || !window.isVisible, "window not placed where asked")
        XCTAssertGreaterThanOrEqual(PopoverSide.placement(of: button.bounds, in: button, beside: false).move.dx, button.bounds.width,
                                    "the case: moved off the button")

        let popover = NSPopover()
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        popover.contentViewController = host
        popover.contentSize = host.view.frame.size
        popover.animates = false
        defer { popover.close() }
        PopoverSide.show(popover, relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        XCTAssertTrue(popover.isShown)
        XCTAssertNotNil(host.view.window)
    }

    /// Moved further along than its button's own edge, the arrow points at
    /// what stands beside the button.
    func testAnArrowMovedOffItsButtonStrays() {
        let size = CGSize(width: 26, height: 26)
        XCTAssertFalse(PopoverSide.strays(.zero, from: size))
        XCTAssertFalse(PopoverSide.strays(CGVector(dx: 13, dy: 0), from: size), "to the button's edge")
        XCTAssertTrue(PopoverSide.strays(CGVector(dx: 14, dy: 0), from: size))
        XCTAssertTrue(PopoverSide.strays(CGVector(dx: -14, dy: 0), from: size), "by the screen's right edge")
        XCTAssertTrue(PopoverSide.strays(CGVector(dx: clear - 23, dy: 0), from: size), "the first button in the corner")
        XCTAssertFalse(PopoverSide.strays(CGVector(dx: clear - 23, dy: 0), from: CGSize(width: 200, height: 26)),
                       "a tab is wide enough")
        // Beside a button the arrow is never moved past its edge.
        XCTAssertFalse(PopoverSide.strays(PopoverSide.placement(of: button(400, clear - 13), in: screen, beside: true).move, from: size))
        // In the corner it hangs above, moved along: off a 26-point button.
        XCTAssertTrue(PopoverSide.strays(PopoverSide.placement(of: button(23, 20), in: screen, beside: true).move, from: size))
    }
}
