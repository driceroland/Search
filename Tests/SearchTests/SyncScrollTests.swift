import AppKit
import WebKit
import XCTest
@testable import Search

/// The divider's menu › Sync Scrolling: one page of a pair scrolled, the
/// other goes by as much — either way round, without the two bouncing one
/// another — and, off, each page scrolls alone.
@MainActor
final class SyncScrollTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testPagesOfAPairScrollTogetherOnlyWhileSyncIsOn() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let long = "<!doctype html><body style='margin:0'><div style='height:6000px'></div>"
        let server = try LocalPageServer([
            "/0": .init(type: "text/html; charset=utf-8", body: "<title>Long 0</title>" + long),
            "/1": .init(type: "text/html; charset=utf-8", body: "<title>Long 1</title>" + long),
        ])
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView)
        // On screen: off it, WebKit holds back animation frames, and the
        // page's scroll report waits for one (ScrollRelay.script).
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1300, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer {
            window.orderOut(nil)
            server.stop()
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
        }
        prefs.usesTabGroups = false
        prefs.splitView = true
        for number in 1...2 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let left = try XCTUnwrap(browser.tabs.dropLast().last), right = try XCTUnwrap(browser.tabs.last)
        browser.pair(right, with: left, onLeft: false)
        let pair = try XCTUnwrap(browser.split(for: left))
        XCTAssertFalse(pair.syncsScroll, "off to begin with")

        // Two long pages, side by side in a window, as on the stage.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 700))
        window.contentView = host
        window.orderFrontRegardless()
        for (index, tab) in [left, right].enumerated() {
            let web = tab.web
            web.frame = NSRect(x: CGFloat(index) * 650, y: 0, width: 640, height: 700)
            host.addSubview(web)
            tab.go(to: server.url("/\(index)"))
        }
        let deadline = Date().addingTimeInterval(10)
        while [left, right].contains(where: { $0.web.isLoading || !($0.web.title ?? "").hasPrefix("Long") }),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        func y(_ tab: Tab) async throws -> Double {
            try await (tab.web.evaluateJavaScript("window.scrollY", contentWorld: .page) as? NSNumber)?.doubleValue ?? -1
        }
        func scroll(_ tab: Tab, to target: Double) async throws {
            _ = try await tab.web.evaluateJavaScript("window.scrollTo(0, \(target)); 0", contentWorld: .page)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
        try await settle()
        // Off: each alone.
        try await scroll(left, to: 300)
        try await settle()
        let leftAlone = try await y(right)
        XCTAssertEqual(leftAlone, 0, "off, the other page stays")

        // On: the other goes by as much, whichever is scrolled.
        browser.toggleSyncScroll()
        XCTAssertTrue(browser.split(for: left)?.syncsScroll == true)
        try await scroll(left, to: 800)
        try await settle()
        let followed = try await y(right)
        XCTAssertEqual(followed, 500, "down by the 500 the left page went")
        try await scroll(right, to: 400)
        try await settle()
        let back = try await (y(left), y(right))
        XCTAssertEqual(back.0, 700, "the right page leads as well: up by 100")
        XCTAssertEqual(back.1, 400, "and wasn't bounced back by its partner")

        // Off again: alone again.
        browser.toggleSyncScroll()
        try await scroll(left, to: 1500)
        try await settle()
        let stays = try await y(right)
        XCTAssertEqual(stays, 400)
    }
}
