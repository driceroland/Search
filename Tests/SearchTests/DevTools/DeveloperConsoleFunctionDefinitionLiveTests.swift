import AppKit
import WebKit
import XCTest
@testable import Search

/// The console's "Show function definition" on a real page: a logged
/// function's definition is found by Debugger.getFunctionDetails and
/// Sources is asked to show its file at the line it was written on.
@MainActor
final class DeveloperConsoleFunctionDefinitionLiveTests: XCTestCase {
    // 1-based: `function greet` is on line 4.
    private static let script = """
        // A fixture script.
        window.unrelated = 1;

        function greet(name) {
            return "hello " + name;
        }
        """

    func testShowFunctionDefinitionRevealsItsLine() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Function fixture</title>
                <script src="/app.js"></script>
                """),
            "/app.js": .init(type: "text/javascript", body: Self.script),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperConsoleFunctionDefinitionLiveTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Function fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) { session.ready }
            _ = try await page.evaluateJavaScript("console.log(greet); 0")
            try await DeveloperTestSupport.wait("logged function", in: domain) {
                session.console.contains { $0.details?.parameters.first?.type == "function" }
            }
            let line = try XCTUnwrap(session.console.last { $0.details?.parameters.first?.type == "function" })
            let function = try XCTUnwrap(line.details?.parameters.first)
            let id = try XCTUnwrap(function.objectId)

            let definition = try await session.consoleFunctionDefinition(objectId: id, targetID: line.details?.targetID)
            XCTAssertEqual(definition?.url, server.url("/app.js").absoluteString)
            XCTAssertEqual(definition?.line, 4)

            session.showConsoleFunctionDefinition(function, targetID: line.details?.targetID)
            try await DeveloperTestSupport.wait("source reveal", in: domain,
                                                state: { "\(String(describing: session.sourceReveal))" }) {
                session.sourceReveal?.line == 4
            }
            XCTAssertEqual(session.panel, .sources)
            XCTAssertTrue(session.sourceReveal?.url.hasSuffix("/app.js") == true)
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
            throw error
        }
    }
}
