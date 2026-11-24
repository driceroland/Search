import AppKit
import XCTest
@testable import Search

/// A right-click on a console row's text shows that row's menu: the
/// innermost row under the pointer, not one beside it.
@MainActor
final class DeveloperConsoleMenuAnchorTests: XCTestCase {
    func testTheInnermostRowUnderThePointIsChosen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let message = ConsoleMenuAnchor.AnchorView(frame: NSRect(x: 0, y: 100, width: 400, height: 60))
        let property = ConsoleMenuAnchor.AnchorView(frame: NSRect(x: 20, y: 110, width: 380, height: 20))
        let next = ConsoleMenuAnchor.AnchorView(frame: NSRect(x: 0, y: 160, width: 400, height: 20))
        [message, property, next].forEach(content.addSubview)

        XCTAssertTrue(ConsoleMenuAnchor.innermost(at: NSPoint(x: 50, y: 115), in: window) === property)
        XCTAssertTrue(ConsoleMenuAnchor.innermost(at: NSPoint(x: 50, y: 150), in: window) === message)
        XCTAssertTrue(ConsoleMenuAnchor.innermost(at: NSPoint(x: 50, y: 170), in: window) === next)
        XCTAssertNil(ConsoleMenuAnchor.innermost(at: NSPoint(x: 50, y: 20), in: window))

        next.removeFromSuperview()
        XCTAssertNil(ConsoleMenuAnchor.innermost(at: NSPoint(x: 50, y: 170), in: window))
    }
}
