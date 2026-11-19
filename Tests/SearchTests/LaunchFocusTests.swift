import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A window opened over a page gives the page the keys. Left with the
/// window, the Mac's keyboard navigation hands them to the first button
/// that takes them: Reload, with a focus ring round it.
@MainActor
final class LaunchFocusTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "launch-focus-\(getpid())", 1)
        super.setUp()
    }

    func testPageHasTheKeysWhenItsWindowOpens() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.go(to: URL(string: "about:blank")!)
        XCTAssertFalse(browser.fieldShowing)

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        window.orderFrontRegardless()
        defer {
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder === tab.web, "first responder: \(String(describing: window.firstResponder))")
    }

    /// A blank tab's field keeps them: it is what the window opened for.
    func testFieldKeepsTheKeysOverABlankTab() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        defer { browser.closeAll() }
        browser.newTab()
        XCTAssertTrue(browser.fieldShowing)

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        window.orderFrontRegardless()
        defer {
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder is NSTextView, "first responder: \(String(describing: window.firstResponder))")
    }
}
