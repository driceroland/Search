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

    /// Top-level await, as in Chrome's Console: an awaited expression gives
    /// its value, a declaration made with await stays for the next input,
    /// and a rejection is reported as thrown.
    func testTopLevelAwaitGivesTheSettledValue() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Await fixture</title><p>await</p>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperConsoleInspectTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Await fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        func result(after count: Int) async throws -> DeveloperToolsSession.ConsoleLine {
            try await DeveloperTestSupport.wait("a result", in: domain, state: { "\(session.console.suffix(3).map(\.text))" }) {
                session.console.count > count && ["result", "error"].contains(session.console.last?.level ?? "")
            }
            return try XCTUnwrap(session.console.last)
        }
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) { session.ready }
            session.select(.console)
            var count = session.console.count
            session.evaluateInConsole("await new Promise(r => setTimeout(() => r(6 * 7), 50))")
            var line = try await result(after: count)
            XCTAssertEqual(line.level, "result")
            XCTAssertEqual(line.text, "42")

            count = session.console.count
            session.evaluateInConsole("const answer = await Promise.resolve('kept')\nanswer.toUpperCase()")
            line = try await result(after: count)
            XCTAssertEqual(line.text, "'KEPT'")
            count = session.console.count
            session.evaluateInConsole("answer")
            line = try await result(after: count)
            XCTAssertEqual(line.text, "'kept'")

            // `{...}` alone is an object, as in Chrome.
            count = session.console.count
            session.evaluateInConsole("{a: 1}")
            line = try await result(after: count)
            XCTAssertEqual(line.level, "result")
            XCTAssertTrue(line.text.contains("a: 1"), line.text)

            count = session.console.count
            session.evaluateInConsole("await Promise.reject(new Error('nope'))")
            line = try await result(after: count)
            XCTAssertEqual(line.level, "error")
            XCTAssertTrue(line.text.contains("nope"), line.text)
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }

    func testPromptPreparationMatchesChromes() {
        let plain = DeveloperConsoleSyntax.prepare("1 + 1", paused: false)
        XCTAssertEqual(plain, .init(expression: "1 + 1"))
        XCTAssertEqual(DeveloperConsoleSyntax.prepare("{a: 1}", paused: false).expression, "({a: 1}\n)")
        // A block that isn't an object literal stays a block.
        XCTAssertEqual(DeveloperConsoleSyntax.prepare("{ let x = 1; x }", paused: false).expression, "{ let x = 1; x }")
        // Already valid: `await` inside an async function of its own.
        XCTAssertFalse(DeveloperConsoleSyntax.prepare("(async () => await 1)()", paused: false).awaited)
        let awaited = DeveloperConsoleSyntax.prepare("await fetch('/')", paused: false)
        XCTAssertTrue(awaited.awaited)
        XCTAssertTrue(awaited.expression.hasPrefix("(async () => { return ("))
        let statements = DeveloperConsoleSyntax.prepare("const r = await fetch('/')\nr.status", paused: false)
        XCTAssertTrue(statements.awaited)
        XCTAssertTrue(statements.expression.contains("globalThis.r ="), statements.expression)
        XCTAssertTrue(statements.expression.contains("return (\nr.status\n)"), statements.expression)
        // Paused: run as typed, the page can't settle a promise then.
        XCTAssertFalse(DeveloperConsoleSyntax.prepare("await fetch('/')", paused: true).awaited)
    }
}
