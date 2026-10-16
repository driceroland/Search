import AppKit
import PDFKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class PDFExportTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "pdf-export-\(getpid())", 1)
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

    func testExportKeepsRequestedTabAfterActiveTabChanges() async throws {
        let browser = Browser(record: WindowRecord())
        let requested = try await page("Requested page", in: browser)
        let other = try await page("Different active page", in: browser)
        browser.activeID = requested.id
        let captured = try XCTUnwrap(browser.active)
        browser.activeID = other.id

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Search-PDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let worked = await withCheckedContinuation { continuation in
            browser.exportPDF(captured, to: file) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(worked)
        let text = try XCTUnwrap(PDFDocument(url: file)?.string)
        XCTAssertTrue(text.contains("Requested page"), "Exported the wrong tab: \(text)")
        XCTAssertFalse(text.contains("Different active page"))
    }

    private func page(_ text: String, in browser: Browser) async throws -> Search.Tab {
        let tab = browser.open(try XCTUnwrap(URL(string: "about:blank")), foreground: true)
        tab.web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        tab.web.loadHTMLString("<html><body><h1>\(text)</h1></body></html>", baseURL: URL(string: "https://example.invalid/"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !tab.web.isLoading,
               let body = try? await tab.web.evaluateJavaScript("document.body.innerText"),
               (body as? String)?.contains(text) == true {
                XCTAssertFalse(tab.isBlank)
                return tab
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PDFExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Page did not load"])
    }
}
