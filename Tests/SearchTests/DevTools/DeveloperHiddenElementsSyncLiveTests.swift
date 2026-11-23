import AppKit
import WebKit
import XCTest
@testable import Search

/// While Elements is hidden, a node the page changes isn't read back each
/// drain; showing Elements reads it, so the tree shows the change.
@MainActor
final class DeveloperHiddenElementsSyncLiveTests: XCTestCase {
    func testNodeChangesWaitForElements() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Hidden sync</title><body style=margin:0><div id=a class=one style=width:200px;height:100px>one</div>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page", in: "DeveloperHiddenElementsSyncLiveTests") { page.title == "Hidden sync" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperHiddenElementsSyncLiveTests") { session.ready }
            session.select(.elements)
            session.inspect(at: NSPoint(x: 10, y: 10))
            try await DeveloperTestSupport.wait("picked node", in: "DeveloperHiddenElementsSyncLiveTests") {
                session.selectedNode.flatMap { session.nodes[$0]?.attributes }?.contains("one") == true
            }
            let id = try XCTUnwrap(session.selectedNode)
            session.select(.console)
            _ = try await page.evaluateJavaScript("document.getElementById('a').className = 'two'; 1")
            try await Task.sleep(for: .milliseconds(1_200))
            XCTAssertTrue(session.nodes[id]?.attributes.contains("one") == true, "read back while Elements was hidden")
            session.select(.elements)
            try await DeveloperTestSupport.wait("change shown", in: "DeveloperHiddenElementsSyncLiveTests") {
                session.nodes[id]?.attributes.contains("two") == true
            }
            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }
}
