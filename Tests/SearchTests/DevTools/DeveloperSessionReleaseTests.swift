import AppKit
import WebKit
import XCTest
@testable import Search

/// A DevTools session used and then closed goes away: nothing it started
/// (the pump, selections, the Issues and Lighthouse models, even ones a
/// view asks for after the close, frontend calls in flight) keeps it alive.
/// (AppKit and SwiftUI let go of removed panes' view graphs on their own
/// time, so the panels' views aren't hosted here.)
@MainActor
final class DeveloperSessionReleaseTests: XCTestCase {
    func testAClosedSessionIsFreed() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Release fixture</title><body style=margin:0><div id=a style=width:200px;height:100px>one</div><script>console.log('hi')</script>"),
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
        try await DeveloperTestSupport.wait("page", in: "DeveloperSessionReleaseTests") { page.title == "Release fixture" }
        let tab = Tab(shy: true)
        weak var released: DeveloperToolsSession?
        do {
            let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
            released = session
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperSessionReleaseTests") { session.ready }
            session.inspect(at: NSPoint(x: 10, y: 10))
            try await DeveloperTestSupport.wait("picked node", in: "DeveloperSessionReleaseTests") {
                session.selectedNode.flatMap { session.nodes[$0]?.attributes }?.contains("a") == true
            }
            _ = DeveloperIssuesModel.model(for: session)
            _ = DeveloperLighthouseModel.model(for: session)
            for panel in DeveloperPanel.allCases { session.select(panel) }
            session.select(.console)
            session.evaluate("1 + 1")
            session.togglePicker(); session.togglePicker()
            try await Task.sleep(for: .milliseconds(600))
            let inFlight = Task { try? await session.evaluateInFrontend("return await new Promise(() => {});") }
            await session.disconnect().value
            _ = await inFlight.value
            // A view drawn once more after the close.
            _ = DeveloperIssuesModel.model(for: session)
            _ = DeveloperLighthouseModel.model(for: session)
        }
        for _ in 0..<50 where released != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(released, "the closed session is still alive")
        withExtendedLifetime(tab) {}
    }
}
