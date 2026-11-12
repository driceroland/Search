import AppKit
import XCTest
@testable import Search

@MainActor
final class SidePanelRetirementTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "panel-retirement-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testRetiringAWindowLetsItsPanelAndAllBindingsGo() throws {
        let browser = Browser(record: WindowRecord())
        let other = Browser(record: WindowRecord())
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        browser.window = window
        other.window = otherWindow
        Browsers.register(browser)
        Browsers.register(other)
        let pages = SidePanelPages.shared
        let first = Tab(shy: true)
        let second = Tab()
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let content = SidePanelContent.page(extensionID: "gone", url: url, tab: first.id)
        defer {
            pages.drop(in: browser)
            pages.drop(in: other)
            pages.unbind(first.id, in: browser)
            pages.unbind(second.id, in: browser)
            pages.unbind(second.id, in: other)
            if Browsers.all.contains(where: { $0 === browser }) { Browsers.discard(browser) }
            Browsers.discard(other)
            browser.window = nil
            other.window = nil
        }
        browser.receive(first)
        pages.loadSite(url, space: browser.spaceID, in: browser)
        browser.sidePanel = content
        browser.sidePanelShown = true
        pages.bind(content, to: first.id, in: browser)
        pages.bind(content, to: second.id, in: browser)
        pages.loadSite(url, space: other.spaceID, in: other)
        pages.bind(content, to: second.id, in: other)
        XCTAssertTrue(browser.sidePanelHeld, "a panel held back beside a private tab is still kept")
        XCTAssertNotNil(pages.web(in: browser))
        XCTAssertNotNil(pages.bound(to: second.id, in: browser))

        Browsers.closing(window)

        XCTAssertFalse(Browsers.all.contains { $0 === browser })
        XCTAssertNil(pages.web(in: browser), "the retired window's panel page goes")
        XCTAssertNil(pages.bound(to: first.id, in: browser))
        XCTAssertNil(pages.bound(to: second.id, in: browser), "bindings for other tabs go too")
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertNotNil(pages.web(in: other), "another window keeps its page")
        XCTAssertNotNil(pages.bound(to: second.id, in: other))
    }

    func testClosingTheLastWindowKeepsItsPanel() throws {
        let browser = Browser(record: WindowRecord())
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        Browsers.register(browser)
        let pages = SidePanelPages.shared
        defer {
            pages.drop(in: browser)
            Browsers.discard(browser)
            browser.window = nil
        }
        let url = try XCTUnwrap(URL(string: "about:blank"))
        pages.loadSite(url, space: browser.spaceID, in: browser)
        browser.sidePanel = .site(url: url, space: browser.spaceID)
        browser.sidePanelShown = true
        let web = try XCTUnwrap(pages.web(in: browser))

        Browsers.closing(window)

        XCTAssertTrue(browser.shut)
        XCTAssertTrue(pages.web(in: browser) === web)
        XCTAssertTrue(browser.sidePanelShown)
    }
}
