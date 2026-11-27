import AppKit
import XCTest
@testable import Search

/// ⌘Tab away from a page in full screen and back (FullScreenReturn): the
/// window brought back is WebKit's full-screen window the app was left from,
/// not the browser's window with WebKit's placeholder in it. No window here
/// is ever ordered in: one that says it is on screen stands in.
@available(macOS 14, *)
@MainActor
final class FullScreenReturnTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A window AppKit would call on screen, never put on one.
    private final class Shown: NSWindow {
        override var isVisible: Bool { true }
    }

    private func window(shown: Bool = true) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 100)
        let made = shown ? Shown(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)
            : NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)
        made.isReleasedWhenClosed = false
        return made
    }

    func testBackToTheFullScreenWindowNotThePlaceholder() {
        _ = NSApplication.shared
        let browserWindow = window(), fullScreen = window()
        let fills: (NSWindow) -> Bool = { $0 === fullScreen }
        // Left from the video, come back with the browser's window made key:
        // the video's window again.
        XCTAssertTrue(FullScreenReturn.returning(left: fullScreen, key: browserWindow, clicked: false, fills: fills) === fullScreen)
        // Or with no window key yet.
        XCTAssertTrue(FullScreenReturn.returning(left: fullScreen, key: nil, clicked: false, fills: fills) === fullScreen)
    }

    func testOtherwiseLeftAsItIs() {
        _ = NSApplication.shared
        let browserWindow = window(), fullScreen = window()
        let fills: (NSWindow) -> Bool = { $0 === fullScreen }
        // Already key: nothing to do.
        XCTAssertNil(FullScreenReturn.returning(left: fullScreen, key: fullScreen, clicked: false, fills: fills))
        // Left from the browser's window (its own macOS full screen, or beside
        // a video kept in its Space): that is where it comes back.
        XCTAssertNil(FullScreenReturn.returning(left: browserWindow, key: browserWindow, clicked: false, fills: fills))
        XCTAssertNil(FullScreenReturn.returning(left: nil, key: browserWindow, clicked: false, fills: fills))
        // Brought back by a click, on the placeholder or anywhere: the click decides.
        XCTAssertNil(FullScreenReturn.returning(left: fullScreen, key: browserWindow, clicked: true, fills: fills))
        // The page has left full screen since (its window no longer holds one).
        XCTAssertNil(FullScreenReturn.returning(left: fullScreen, key: browserWindow, clicked: false, fills: { _ in false }))
        // WebKit's window gone from the screen.
        let gone = window(shown: false)
        XCTAssertNil(FullScreenReturn.returning(left: gone, key: browserWindow, clicked: false, fills: { $0 === gone }))
    }

    /// A browser's own window, and any window no page has in full screen,
    /// is never taken for WebKit's full-screen window.
    func testABrowsersOwnWindowIsNeverTheFullScreenOne() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        XCTAssertFalse(FullScreenReturn.holdsFullScreenPage(window()))
        if let own = browser.window { XCTAssertFalse(FullScreenReturn.holdsFullScreenPage(own)) }
        // Noted as the app is left, a window that holds no full-screen page
        // is not remembered: coming back changes nothing (and a test run
        // never fronts a window at all).
        FullScreenReturn.leaving(key: window())
        FullScreenReturn.back()
    }
}
