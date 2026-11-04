import AppKit
import XCTest
@testable import Search

@MainActor
final class PeekReloadTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "peek-reload-\(getpid())", 1)
        super.setUp()
    }

    func testReloadCommandsUsePeekUntilItCloses() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let origin = try LocalDownloadServer(size: 0)
        let destination = try LocalDownloadServer(size: 0)
        defer { origin.stop(); destination.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closePeek(); browser.closeAll() }
        let tab = browser.benchOpen(origin.url("page"))
        browser.activeID = tab.id
        try await waitForPage(tab)
        _ = try await tab.web.evaluateJavaScript("window.reloadMarker = 'untouched'")

        browser.peek(destination.url("page"), from: tab)
        let peek = try XCTUnwrap(browser.peekTab)
        try await waitForPage(peek)
        let originalRequests = origin.count("/page")

        for id in ["view.reload", "view.reloadOrigin"] {
            let requests = destination.count("/page")
            _ = try await peek.web.evaluateJavaScript("window.reloadMarker = 'before reload'")
            try XCTUnwrap(Command.named(id)).run(browser)
            try await waitForPage(peek, afterReload: true)
            XCTAssertGreaterThan(destination.count("/page"), requests)
            XCTAssertEqual(origin.count("/page"), originalRequests)
            let marker = try await tab.web.evaluateJavaScript("window.reloadMarker")
            XCTAssertEqual(marker as? String, "untouched")
            XCTAssertEqual(browser.activeID, tab.id)
            XCTAssertTrue(browser.peekTab === peek)
        }

        browser.closePeek()
        let peekRequests = destination.count("/page")
        try XCTUnwrap(Command.named("view.reload")).run(browser)
        try await waitForPage(tab, afterReload: true)
        XCTAssertGreaterThan(origin.count("/page"), originalRequests)
        XCTAssertEqual(destination.count("/page"), peekRequests)
    }

    private func waitForPage(_ tab: Search.Tab, afterReload: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !tab.loading, !tab.web.isLoading,
               let ready = try? await tab.web.evaluateJavaScript("document.readyState === 'complete' && document.title === 'Download fixture' && \(afterReload ? "window.reloadMarker === undefined" : "true")"),
               ready as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The requested page did not finish loading")
        throw NSError(domain: "PeekReloadTests", code: 1)
    }
}
