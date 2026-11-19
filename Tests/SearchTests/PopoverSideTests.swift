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
}
