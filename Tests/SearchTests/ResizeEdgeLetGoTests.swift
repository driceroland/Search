import AppKit
import XCTest
@testable import Search

/// The column's edge pill shows only under the pointer or while held: let go
/// with the pointer elsewhere (a pull that ended off the edge sends no exit),
/// the edge asks where the pointer is and puts the pill out.
@MainActor
final class ResizeEdgeLetGoTests: XCTestCase {
    func testLetGoAwayFromTheEdgePutsTheHoverOut() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = ResizeEdgeCursor.EdgeCursorView(frame: NSRect(x: 100, y: 0, width: 12, height: 200))
        window.contentView?.addSubview(view)
        var states: [Bool] = []
        view.hover = { states.append($0) }

        view.resync(pointer: NSPoint(x: 105, y: 50))
        XCTAssertTrue(view.inside, "on the edge")
        view.resync(pointer: NSPoint(x: 105, y: 50))
        XCTAssertEqual(states, [true], "no repeat while still on it")
        view.resync(pointer: NSPoint(x: 40, y: 50))
        XCTAssertFalse(view.inside, "let go well away from it")
        XCTAssertEqual(states, [true, false])
    }
}
