import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

private typealias BrowserTab = Search.Tab

/// Handoff (Handoff.swift): the page on screen is offered from its window,
/// and a private tab's never is.
@MainActor
final class HandoffTests: XCTestCase {
    private var browser: Browser!
    private var fixture: LocalPageServer!
    private var window: NSWindow!
    private var opened: [BrowserTab] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "handoff-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world {
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
            try? FileManager.default.removeItem(at: Store.folder)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.history.forget()
        fixture = try LocalPageServer(["/page": .init(type: "text/html", body: "<title>Page</title>")])
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
    }

    override func tearDown() async throws {
        window.userActivity = nil
        opened.forEach { browser.close($0) }
        browser.history.forget()
        window.close()
        fixture.stop()
        try await super.tearDown()
    }

    func testThePageOnScreenIsOfferedAndWithdrawn() async throws {
        let tab = try await loaded(from: nil)
        XCTAssertEqual(Handoff.address(of: tab), fixture.url("/page"))

        Handoff.offer(tab, in: window)
        XCTAssertEqual(window.userActivity?.activityType, NSUserActivityTypeBrowsingWeb)
        XCTAssertEqual(window.userActivity?.webpageURL, fixture.url("/page"))

        Handoff.offer(nil, in: window)
        XCTAssertNil(window.userActivity)
    }

    func testAPrivateTabIsNeverOffered() async throws {
        let tab = try await loaded(from: BrowserTab(shy: true))
        XCTAssertNil(Handoff.address(of: tab))

        Handoff.offer(tab, in: window)
        XCTAssertNil(window.userActivity)
    }

    func testATabWithNoPageIsNeverOffered() {
        let tab = BrowserTab()
        XCTAssertNil(Handoff.address(of: tab))
    }

    /// A space signed out of the others keeps its pages to itself: none is
    /// offered, though its store is kept on disk.
    func testASignedOutSpaceIsNeverOffered() async {
        let space = UUID()
        let tab = BrowserTab(configuration: Web.configuration(space: space))
        XCTAssertTrue(tab.store.isPersistent)
        XCTAssertEqual(Spaces.owner(of: tab.store), space)
        XCTAssertNil(Handoff.address(of: tab))
        try? await WKWebsiteDataStore.remove(forIdentifier: space)
    }

    /// Off unless turned on.
    func testOffByDefault() {
        XCTAssertFalse(browser.prefs.handoff)
    }

    /// Picked up from another device: only a web page opens, never a file,
    /// a script or another app's link.
    func testOnlyAWebPageIsTakenFromAnotherDevice() {
        let web = NSUserActivityTypeBrowsingWeb
        let page = NSUserActivity(activityType: web)
        page.webpageURL = URL(string: "https://example.com/a")
        XCTAssertEqual(Handoff.incoming(page), URL(string: "https://example.com/a"))
        XCTAssertEqual(Handoff.incoming(type: web, url: URL(string: "HTTP://example.com/")), URL(string: "HTTP://example.com/"))
        XCTAssertNil(Handoff.incoming(type: "com.example.other", url: URL(string: "https://example.com/")))
        XCTAssertNil(Handoff.incoming(type: web, url: nil))
        for address in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "mailto:a@example.com",
                        "httpx://example.com/", "search://settings", "ftp://example.com/", "https:///nohost"] {
            XCTAssertNil(Handoff.incoming(type: web, url: URL(string: address)), address)
        }
    }

    /// A tab on the fixture's page, opened as a link from `source` would be:
    /// a private source makes a private tab.
    private func loaded(from source: BrowserTab?) async throws -> BrowserTab {
        let tab = browser.open(fixture.url("/page"), foreground: true, from: source)
        opened.append(tab)
        window.contentView = tab.web
        for _ in 0..<500 where tab.committed != fixture.url("/page") || tab.loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tab.committed, fixture.url("/page"))
        return tab
    }
}
