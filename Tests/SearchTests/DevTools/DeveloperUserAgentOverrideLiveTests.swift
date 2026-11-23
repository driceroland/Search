import AppKit
import WebKit
import XCTest
@testable import Search

/// Network conditions' user agent: a preset is what the page sees after a
/// reload, and Use browser default (or DevTools closing) puts the tab's own back.
@MainActor
final class DeveloperUserAgentOverrideLiveTests: XCTestCase {
    func testAPresetAppliesOnReloadAndTheDefaultComesBack() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer(["/": .init(type: "text/html", body: "<!doctype html><title>UA fixture</title>")])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page", in: "DeveloperUserAgentOverrideLiveTests") { page.title == "UA fixture" }
        let original = try await page.evaluateJavaScript("navigator.userAgent") as? String
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperUserAgentOverrideLiveTests") { session.ready }
            let android = DeveloperNetworkConditionsView.presets.first { $0.name.contains("Android") }!.agent
            session.setUserAgentOverride(android)
            page.reload()
            try await Task.sleep(for: .milliseconds(300))
            try await DeveloperTestSupport.wait("reload", in: "DeveloperUserAgentOverrideLiveTests") { !page.isLoading }
            let seen = try await page.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(seen, android)

            session.setUserAgentOverride(nil)
            XCTAssertNil(session.userAgentOverride)
            page.reload()
            try await Task.sleep(for: .milliseconds(300))
            try await DeveloperTestSupport.wait("reload back", in: "DeveloperUserAgentOverrideLiveTests") { !page.isLoading }
            let back = try await page.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(back, original)

            // Closing DevTools takes an override away too.
            session.setUserAgentOverride("Perch test agent")
            await session.disconnect().value
            XCTAssertNotEqual(page.customUserAgent, "Perch test agent")
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }
}
