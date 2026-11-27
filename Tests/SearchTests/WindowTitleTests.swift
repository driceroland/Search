import AppKit
import XCTest
@testable import Search

@MainActor
final class WindowTitleTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A page's title going and coming back as a link is followed names the
    /// window once, for the last of them, a moment on: never "Search" for
    /// the empty one in between, and the title bar laid out once (idea
    /// 1327). The window is never ordered in.
    func testAQuickRunOfTitlesNamesTheWindowOnce() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = "The page before"
        let tab = Search.Tab(configuration: Web.configuration())
        tab.restore(url: URL(string: "https://example.com/")!, title: "")
        WindowTitle.soon(tab, in: window)
        tab.restore(url: URL(string: "https://example.com/")!, title: "Example Domain")
        WindowTitle.soon(tab, in: window)
        XCTAssertEqual(window.title, "The page before", "not yet, and never the empty title in between")
        try await Task.sleep(for: .seconds(WindowTitle.settle + 0.25))
        XCTAssertEqual(window.title, "Example Domain")
    }

    func testWindowIsNamedForItsPage() {
        XCTAssertEqual(WindowTitle.name(page: "Example Domain", private: false), "Example Domain")
        XCTAssertEqual(WindowTitle.name(page: "  Example Domain \n", private: false), "Example Domain")
    }

    func testWindowWithoutAPageTitleIsNamedForTheApp() {
        XCTAssertEqual(WindowTitle.name(page: "", private: false), "Search")
        XCTAssertEqual(WindowTitle.name(page: "   ", private: false), "Search")
    }

    func testPrivateTabNeverGivesItsPageAway() {
        XCTAssertEqual(WindowTitle.name(page: "Something personal", private: true), "Private Tab")
    }
}
