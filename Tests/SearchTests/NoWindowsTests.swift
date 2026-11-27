import AppKit
import XCTest

/// No window of the unit tests is ever on the person's screen
/// (Tests/NoWindows): ordered in, it is visible to AppKit, with its own frame,
/// but fully transparent — whatever alpha the code sets.
@available(macOS 14, *)
@MainActor
final class NoWindowsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// The window server's alpha for the window, nil if it isn't on screen.
    private func serverAlpha(_ window: NSWindow) -> Double? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
            as? [[String: Any]] ?? []
        guard let entry = list.first, entry[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return entry[kCGWindowAlpha as String] as? Double
    }

    func testWindowsPanelsAndPopoversAreTransparentOnScreen() {
        _ = NSApplication.shared
        let frame = NSRect(x: 40, y: 40, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        // Deferred: its window in the window server is made on ordering in.
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        defer { popover.close(); window.orderOut(nil); panel.orderOut(nil) }

        window.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        // A fade back to full.
        window.alphaValue = 0.5
        window.alphaValue = 1
        popover.show(relativeTo: NSRect(x: 0, y: 0, width: 10, height: 10),
                     of: window.contentView!, preferredEdge: .maxY)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let popoverWindow = popover.contentViewController?.view.window
        XCTAssertNotNil(popoverWindow)
        for shown in [window, panel, popoverWindow].compactMap({ $0 }) {
            XCTAssertTrue(shown.isVisible)
            XCTAssertEqual(serverAlpha(shown), 0, "\(shown) is drawn on the screen")
        }
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame), frame)
    }
}
