import AppKit
import WebKit
import XCTest
@testable import Search

/// Application's Local and Session storage tables update as the page
/// changes them, as Chrome's do: the session counts WebKit's DOMStorage
/// events while Application shows, and the view reads the table again.
@MainActor
final class DeveloperApplicationLiveStorageTests: XCTestCase {
    func testStorageChangesAreNotedWhileApplicationShows() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Storage fixture</title><p>Storage</p>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperApplicationLiveStorageTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Storage fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) { session.ready }
            // Elsewhere than Application: storage events aren't asked for.
            _ = try await page.evaluateJavaScript("localStorage.setItem('before', '1'); 0")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(session.domStorageRevision, 0)

            session.select(.storage)
            try await Task.sleep(for: .milliseconds(400))
            let start = session.domStorageRevision
            _ = try await page.evaluateJavaScript("localStorage.setItem('live', JSON.stringify({a: 1})); 0")
            try await DeveloperTestSupport.wait("a Local storage change", in: domain, state: {
                "revision \(session.domStorageRevision)"
            }) { session.domStorageRevision > start }
            let afterLocal = session.domStorageRevision
            _ = try await page.evaluateJavaScript("sessionStorage.setItem('tab', 'x'); 0")
            try await DeveloperTestSupport.wait("a Session storage change", in: domain) {
                session.domStorageRevision > afterLocal
            }
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }
}
