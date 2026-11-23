import AppKit
import WebKit
import XCTest
@testable import Search

/// The Elements tree on a real page: rooted at the document, `<html>` open,
/// `<body>` ready to expand, after a navigation and after DevTools reopens.
@MainActor
final class DeveloperElementsTreeTests: XCTestCase {
    private static func page(_ title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(title)</title>
        <style>pre.formula { color: rgb(1, 2, 3) }</style>
        <script>window.addEventListener("load", () => console.log("loaded", document.title));</script>
        </head>
        <body>
        <header><nav><a href="/">Home</a></nav></header>
        <main id="article">
        <h1>\(title)</h1>
        <p>A paragraph with <em>emphasis</em> and <code>code</code>.</p>
        <ol id="steps">\((1...12).map { "<li>Step \($0)</li>" }.joined())</ol>
        <pre class="formula">E = mc^2</pre>
        \((1...60).map { "<p>Filler paragraph \($0) <span>inline</span></p>" }.joined(separator: "\n"))
        </main>
        <footer>End</footer>
        <script>document.body.dataset.ready = "yes";</script>
        </body>
        </html>
        """
    }

    func testTreeIsRootedAtTheDocumentAcrossNavigationAndReopening() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: Self.page("First article")),
            "/second": .init(type: "text/html", body: Self.page("Second article")),
        ])
        let page = makePage(url: server.url("/"))
        try await wait("page to load") { page.title == "First article" }
        let tab = Tab(shy: true)

        var session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await assertDocumentTree(session, "first open")

            // A pick on the list, as Inspect Element opens DevTools.
            let list = try await point(of: "#steps", in: page)
            session.inspect(at: list)
            try await wait("picked list") {
                session.selectedNode.flatMap { session.nodes[$0] }?.name == "ol"
            }
            try await assertDocumentTree(session, "after a pick")
            XCTAssertTrue(rowNames(session).contains("ol"), "the picked list shows in the tree")

            page.load(URLRequest(url: server.url("/second")))
            try await wait("second page") { page.title == "Second article" }
            try await wait("tree for the new document") {
                session.root.flatMap { session.nodes[$0] }.map { root in
                    root.children.contains { session.nodes[$0].map { $0.name == "html" && $0.type == 1 } == true }
                } == true && session.selectedNode == nil
            }
            try await assertDocumentTree(session, "after navigating")

            // Reopen only once the old inspector has closed, and keep the old
            // session alive until then so nothing it owns deallocates mid-close.
            let previous = session
            let closing = previous.disconnect()
            await closing.value
            session = DeveloperToolsSession(tab: tab, web: page, after: closing)
            withExtendedLifetime(previous) {}
            try await assertDocumentTree(session, "after reopening")
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }

    /// Text nodes show their text, collapsed as Chrome does, never `"<>"`;
    /// an element whose only child is short text shows it inline.
    func testTextNodesShowTheirTextAndShortTextShowsInline() async throws {
        _ = NSApplication.shared
        let short = "steps, the gait flag, the mean gravity vector (posture) and covered seconds."
        let long = String(repeating: "A long paragraph of text that runs well past the inline limit. ", count: 3)
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><html><head><title>Text rows</title></head><body>
                <ul id="list"><li>\(short)</li><li>  Spaced
                   out   text </li></ul>
                <p id="long">\(long)<em>mixed</em></p>
                </body></html>
                """),
        ])
        let page = makePage(url: server.url("/"))
        try await wait("page to load") { page.title == "Text rows" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await wait("document tree") {
                session.ready && session.root.flatMap { session.nodes[$0] } != nil
                    && session.nodes.values.contains { $0.name == "body" }
            }
            func element(_ name: String, id: String? = nil) -> DeveloperToolsSession.DOMNode? {
                session.nodes.values.first { node in
                    node.name == name && (id == nil || node.attributes.firstIndex(of: "id").map {
                        $0 + 1 < node.attributes.count && node.attributes[$0 + 1] == id
                    } == true)
                }
            }
            func open(_ name: String, id: String? = nil) async throws -> DeveloperToolsSession.DOMNode {
                try await wait("\(name) in the tree") { element(name, id: id) != nil }
                let node = try XCTUnwrap(element(name, id: id))
                if !session.expanded.contains(node.id) { session.expand(node) }
                try await wait("\(name)'s children") {
                    guard let now = session.nodes[node.id] else { return false }
                    return now.children.count >= min(now.count, 1) && now.children.allSatisfy { session.nodes[$0] != nil }
                }
                return try XCTUnwrap(session.nodes[node.id])
            }
            _ = try await open("body")
            let list = try await open("ul", id: "list")
            try await wait("list items with their text") {
                let items = (session.nodes[list.id]?.children ?? []).compactMap { session.nodes[$0] }.filter { $0.type == 1 }
                return items.count == 2 && items.allSatisfy { item in
                    item.children.count == 1 && session.nodes[item.children[0]].map { !$0.text.isEmpty } == true
                }
            }
            let rows = DeveloperDOMTreeModel.flatten(nodes: session.nodes, root: session.root, expanded: session.expanded)
            let items = rows.filter { $0.node.name == "li" }
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items.first?.inline, short, "a short only-text child shows on the element's row")
            XCTAssertEqual(items.last?.inline, "Spaced out text", "whitespace collapses as in Chrome")
            XCTAssertFalse(items.first?.expandable ?? true, "nothing to expand")
            XCTAssertEqual(String(DeveloperDOMTreeModel.styledLine(items[0].node, closed: false, inline: items[0].inline).characters),
                           "<li>\(short)</li>")
            XCTAssertFalse(rows.contains { $0.node.type == 3 && $0.node.parent == items[0].id },
                           "the inline text is not a row of its own")

            // Long text beside an element: its own row, quoted, with the text.
            let paragraph = try await open("p", id: "long")
            try await wait("the paragraph's text") {
                (session.nodes[paragraph.id]?.children ?? []).contains { session.nodes[$0].map { $0.type == 3 && !$0.text.isEmpty } == true }
            }
            let shown = DeveloperDOMTreeModel.flatten(nodes: session.nodes, root: session.root, expanded: session.expanded)
            let text = try XCTUnwrap(shown.first { $0.node.type == 3 && $0.node.parent == paragraph.id })
            let line = String(DeveloperDOMTreeModel.styledLine(text.node, closed: false).characters)
            XCTAssertNotEqual(line, "\"<>\"")
            let expected = String(long.trimmingCharacters(in: .whitespaces).prefix(300))
            XCTAssertEqual(line, "\"" + expected + "\"")
            XCTAssertEqual(text.node.name, "#text")
            XCTAssertNil(shown.first { $0.id == paragraph.id }?.inline, "mixed content isn't inline")
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }

    /// The tree's first rows are the document's own: doctype, then `<html>`
    /// open with `<head>` and `<body>` under it, and `<body>` can expand.
    private func assertDocumentTree(_ session: DeveloperToolsSession, _ when: String,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait("document tree \(when)") {
            guard session.ready, let root = session.root, let document = session.nodes[root],
                  let html = document.children.first(where: { session.nodes[$0].map { $0.name == "html" && $0.type == 1 } == true }),
                  session.expanded.contains(html), let node = session.nodes[html] else { return false }
            return node.children.contains { session.nodes[$0]?.name == "body" }
        }
        let root = try XCTUnwrap(session.root)
        XCTAssertEqual(session.nodes[root]?.type, 9, "the root is the document \(when)", file: file, line: line)
        let names = rowNames(session)
        XCTAssertEqual(Array(names.prefix(3)), ["!doctype", "html", "head"],
                       "rows \(when): \(names.prefix(6))", file: file, line: line)
        let html = try XCTUnwrap(session.nodes[root]?.children.first { session.nodes[$0].map { $0.name == "html" && $0.type == 1 } == true })
        let body = try XCTUnwrap(session.nodes[html]?.children.first { session.nodes[$0]?.name == "body" })
        XCTAssertGreaterThan(session.nodes[body]?.count ?? 0, 0, "body can expand \(when)", file: file, line: line)
        // A few pump cycles: no drain error on a plain page.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(session.message, "no error \(when)", file: file, line: line)
        // The document may have been sent again meanwhile (WebKit does on a
        // reopen), with new ids: the body is looked for again each time.
        func currentBody() -> DeveloperToolsSession.DOMNode? {
            guard let root = session.root,
                  let html = session.nodes[root]?.children.first(where: { session.nodes[$0].map { $0.name == "html" && $0.type == 1 } == true })
            else { return nil }
            return session.nodes[html]?.children.compactMap { session.nodes[$0] }.first { $0.name == "body" }
        }
        _ = body
        try await wait("body children \(when)") {
            guard let node = currentBody() else { return false }
            if !session.expanded.contains(node.id) { session.expand(node) }
            return node.children.contains { session.nodes[$0]?.name == "main" }
        }
        XCTAssertTrue(rowNames(session).contains("main"), "main shows under body \(when)", file: file, line: line)
    }

    /// Element and doctype rows in tree order, as DeveloperDOMTreeView lists them.
    private func rowNames(_ session: DeveloperToolsSession) -> [String] {
        var names: [String] = []
        func walk(_ id: Int) {
            guard let node = session.nodes[id] else { return }
            if node.type == 1 { names.append(node.name) } else if node.type == 10 { names.append("!doctype") }
            if session.expanded.contains(id) { node.children.forEach(walk) }
        }
        if let root = session.root { walk(root) }
        return names
    }

    private func point(of selector: String, in page: WKWebView) async throws -> NSPoint {
        let raw = try await page.callAsyncJavaScript("""
            const box = document.querySelector(selector).getBoundingClientRect();
            return [box.left + 8, box.top + 6];
            """, arguments: ["selector": selector], in: nil, contentWorld: .page) as? [Double]
        let xy = try XCTUnwrap(raw)
        return NSPoint(x: xy[0], y: xy[1])
    }

    private func makePage(url: URL) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, in: "DeveloperElementsTreeTests", until: condition)
    }
}
