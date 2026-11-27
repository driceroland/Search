import AppKit
import WebKit
import XCTest
@testable import Search

/// A video in full screen, listed by screen-share pickers (idea 1245):
/// WebKit's full-screen window takes the page's title, and the window server
/// has that name (what Discord, Zoom and Meet read, kCGWindowName). Real full
/// screen can't be entered in a test run; a window never ordered in stands in
/// for WebKit's own.
@available(macOS 14, *)
@MainActor
final class FullScreenTitleTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testTheLabelIsThePagesTitleOrItsSite() {
        let url = URL(string: "https://www.youtube.com/watch?v=x")
        XCTAssertEqual(FullScreenTitle.label(title: "Big Buck Bunny - YouTube", url: url), "Big Buck Bunny - YouTube")
        XCTAssertEqual(FullScreenTitle.label(title: "  ", url: url), "www.youtube.com")
        XCTAssertEqual(FullScreenTitle.label(title: nil, url: nil), "Search")
    }

    /// WebKit's full-screen window is borderless with no title: named, the
    /// window server lists it under the page's title, and it stays out of
    /// the Window menu.
    func testTheWindowServerListsTheFullScreenWindowByName() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 80, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertEqual(window.title, "")
        FullScreenTitle.name(window, title: "Big Buck Bunny - YouTube", url: nil)
        XCTAssertEqual(window.title, "Big Buck Bunny - YouTube")
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        // The window server takes the name a moment later, longer on a busy Mac.
        func listed() -> String? {
            (CGWindowListCopyWindowInfo([.optionAll], 0) as? [[String: Any]])?
                .first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }?[kCGWindowName as String] as? String
        }
        let deadline = Date().addingTimeInterval(3)
        while listed() != "Big Buck Bunny - YouTube", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(listed(), "Big Buck Bunny - YouTube")
        // The title changes in full screen: so does the name.
        FullScreenTitle.name(window, title: "Next video - YouTube", url: nil)
        XCTAssertEqual(window.title, "Next video - YouTube")
    }

    /// A page not in full screen renames nothing, nor a browser's own window.
    func testAPageNotInFullScreenRenamesNothing() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let before = browser.window?.title
        let page = WKWebView(frame: .zero)
        browser.window?.contentView?.addSubview(page)
        defer { page.removeFromSuperview() }
        FullScreenTitle.follow(page)
        XCTAssertEqual(browser.window?.title, before)
    }
}
