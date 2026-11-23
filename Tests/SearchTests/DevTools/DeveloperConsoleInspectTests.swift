import AppKit
import WebKit
import XCTest
@testable import Search

/// The Console's inspect(node), as in Chrome: the node is selected in
/// Elements, which comes forward.
@MainActor
final class DeveloperConsoleInspectTests: XCTestCase {
    func testInspectSelectsTheNodeInElements() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Inspect fixture</title>
                <section><div><main id="target">Target</main></div></section>
                """),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperConsoleInspectTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Inspect fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) {
                session.ready && session.nodes.values.contains { $0.name == "body" }
            }
            session.select(.console)
            session.evaluateInConsole("inspect(document.getElementById('target'))")
            try await DeveloperTestSupport.wait("the node selected in Elements", in: domain, state: {
                "selected \(String(describing: session.selectedNode.flatMap { session.nodes[$0]?.name })), panel \(session.panel)"
            }) {
                session.selectedNode.flatMap { session.nodes[$0]?.name } == "main"
            }
            XCTAssertEqual(session.panel, .elements)
            // Revealed in the tree: every ancestor open, after Elements has
            // read the document it shows.
            try await DeveloperTestSupport.wait("the node revealed in the tree", in: domain) {
                guard let selected = session.selectedNode, session.nodes[selected]?.name == "main" else { return false }
                var parent = session.nodes[selected]?.parent
                while let id = parent {
                    if !session.expanded.contains(id) { return false }
                    parent = session.nodes[id]?.parent
                }
                return true
            }
            try await Task.sleep(for: .milliseconds(500))
            let selected = try XCTUnwrap(session.selectedNode)
            XCTAssertEqual(session.nodes[selected]?.name, "main", "still selected after Elements settles")
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }
}
