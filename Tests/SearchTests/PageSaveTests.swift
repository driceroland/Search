import AppKit
import WebKit
import XCTest
@testable import Search

/// File › Save Page As…: one web archive of the tab it was asked for, that
/// opens again.
@MainActor
final class PageSaveTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "page-save-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() async throws {
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        XCTAssertFalse(NSApp.isActive)
    }

    func testSaveKeepsRequestedTabAfterActiveTabChanges() async throws {
        let browser = Browser(record: WindowRecord())
        let requested = try await page("Requested page", in: browser)
        let other = try await page("Different active page", in: browser)
        browser.activeID = requested.id
        let captured = try XCTUnwrap(browser.active)
        browser.activeID = other.id

        let file = try await save(captured, in: browser)
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let main = try XCTUnwrap(archive["WebMainResource"] as? [String: Any])
        let html = String(decoding: try XCTUnwrap(main["WebResourceData"] as? Data), as: UTF8.self)
        XCTAssertTrue(html.contains("Requested page"), "Saved the wrong tab: \(html)")
        XCTAssertFalse(html.contains("Different active page"))
    }

    func testSavedArchiveOpensAgain() async throws {
        let browser = Browser(record: WindowRecord())
        let tab = try await page("Kept for later", in: browser)
        let file = try await save(tab, in: browser)
        defer { try? FileManager.default.removeItem(at: file) }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        web.load(try Data(contentsOf: file), mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                 baseURL: try XCTUnwrap(URL(string: "https://example.invalid/")))
        try await waitFor("Kept for later", in: web)
    }

    private func save(_ tab: Search.Tab, in browser: Browser) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Search-Page-\(UUID().uuidString).webarchive")
        let worked = await withCheckedContinuation { continuation in
            browser.savePage(tab, to: file) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(worked)
        return file
    }

    private func page(_ text: String, in browser: Browser) async throws -> Search.Tab {
        let tab = browser.open(try XCTUnwrap(URL(string: "about:blank")), foreground: true)
        tab.web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        tab.web.loadHTMLString("<html><body><h1>\(text)</h1></body></html>", baseURL: URL(string: "https://example.invalid/"))
        try await waitFor(text, in: tab.web)
        XCTAssertFalse(tab.isBlank)
        return tab
    }

    private func waitFor(_ text: String, in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !web.isLoading,
               let body = try? await web.evaluateJavaScript("document.body.innerText"),
               (body as? String)?.contains(text) == true {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PageSaveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\"\(text)\" did not load"])
    }
}
