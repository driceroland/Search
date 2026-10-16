import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class PopupGestureRelayTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "popup-relay-\(getpid())", 1)
        super.setUp()
    }

    func testRelayLooksUpTheMessageViewInsteadOfTheLastBuiltTab() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let first = browser.benchOpen(url)
        let second = browser.benchOpen(url)
        // A shared controller can call the very same handler for either view.
        // A handler bound to `second` must not steal or discard `first`'s input.
        XCTAssertTrue(PopupGestureRelay.tab(for: first.web) === first)
        XCTAssertTrue(PopupGestureRelay.tab(for: second.web) === second)
        XCTAssertNil(PopupGestureRelay.tab(for: WKWebView(frame: .zero)))
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
        XCTAssertFalse(NSApp.isActive)
    }

    func testPeekAndLittleWindowKeepTheirOwnPopupPermission() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let source = browser.benchOpen(url)
        browser.peek(url, from: source)
        let peek = try XCTUnwrap(browser.peekTab)
        XCTAssertTrue(PopupGestureRelay.tab(for: peek.web) === peek)
        browser.closePeek()
        LittleWindow.show(url, for: browser, front: false)
        let little = try XCTUnwrap(LittleWindow.all.last)
        defer { little.close() }
        XCTAssertTrue(PopupGestureRelay.tab(for: little.tab.web) === little.tab)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }

    @available(macOS 15.4, *)
    func testClosingSharedExtensionViewPreservesPopupRelayAndScript() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        _ = Extensions.shared
        let saved = Extensions.pages
        let controller = WKUserContentController()
        Extensions.pages = controller
        defer { Extensions.pages = saved }
        func makeTab() -> Tab {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController = controller
            let tab = Tab(bench: true, configuration: config)
            browser.prepare(tab)
            browser.insert(tab, at: browser.tabs.count)
            _ = tab.web
            return tab
        }
        let first = makeTab()
        let second = makeTab()
        first.popupGesture.record(origin: nil, kind: "menu", now: 10)
        first.close()
        XCTAssertFalse(first.popupGesture.take(origin: nil, mainFrame: true, now: 11))
        XCTAssertTrue(PopupGestureRelay.tab(for: second.web) === second)
        XCTAssertEqual(controller.userScripts.filter { $0.source == PopupGestureRelay.script }.count, 1)
        try await checkMessageDelivery(to: second)
        // Installing the next tab must still replace the retained name cleanly.
        let third = makeTab()
        second.close()
        XCTAssertTrue(PopupGestureRelay.tab(for: third.web) === third)
        XCTAssertEqual(controller.userScripts.filter { $0.source == PopupGestureRelay.script }.count, 1)
        try await checkMessageDelivery(to: third)
        third.close()
    }

    private func checkMessageDelivery(to tab: Tab) async throws {
        _ = try await tab.web.evaluateJavaScript(
            "window.webkit.messageHandlers.officePopupGesture.postMessage('input'); true",
            in: nil, in: Web.world)
        // Message delivery is asynchronous; spending the grant is evidence
        // that the native handler routed it to this surviving view's tab.
        for _ in 0..<100 {
            if tab.popupGesture.take(origin: nil, mainFrame: true) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the surviving shared-controller view lost its popup handler")
    }

}
