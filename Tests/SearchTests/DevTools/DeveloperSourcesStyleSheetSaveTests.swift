import AppKit
import WebKit
import XCTest
@testable import Search

/// A style sheet saved in Sources (workspace or Local Overrides) applies
/// to the page at once, as in Chrome, without a reload.
@MainActor
final class DeveloperSourcesStyleSheetSaveTests: XCTestCase {
    func testSavedStyleSheetAppliesToThePage() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Sheet fixture</title><link rel="stylesheet" href="/style.css"><h1>Sheet</h1>
                """),
            "/style.css": .init(type: "text/css", body: "h1 { color: rgb(102, 51, 153); }"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperSourcesStyleSheetSaveTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Sheet fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) { session.ready }
            let url = server.url("/style.css").absoluteString
            DeveloperWorkspace.applyStyleSheet(url: url, text: "h1 { color: rgb(46, 139, 87); }", session: session)
            var color = ""
            for _ in 0..<60 {
                color = try await page.evaluateJavaScript("getComputedStyle(document.querySelector('h1')).color") as? String ?? ""
                if color == "rgb(46, 139, 87)" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(color, "rgb(46, 139, 87)")
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }
}
