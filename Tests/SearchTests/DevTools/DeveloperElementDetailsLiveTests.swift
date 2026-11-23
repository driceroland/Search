import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperElementDetailsLiveTests: XCTestCase {
    func testAccessibilityTreeAndRelationsRevealTheirElements() async throws {
        try await withElements("""
            <!doctype html><title>Element details fixture</title>
            <main id="parent">
                <p id="name">Panel controls</p>
                <section id="selected" role="region" aria-labelledby="name" aria-controls="panel">
                    <button id="child">Open panel</button>
                </section>
                <aside id="panel">Panel content</aside>
            </main>
            """) { session in
            let node = try await find("#selected", in: session)
            let parent = try await find("#parent", in: session)
            let child = try await find("#child", in: session)
            let name = try await find("#name", in: session)
            let panel = try await find("#panel", in: session)

            session.selectNode(node)
            let result = await session.accessibility(of: node)
            XCTAssertEqual(result.properties["label"] as? String, "Panel controls")
            XCTAssertEqual(result.ancestors.last?.id, parent)
            XCTAssertEqual(result.selected?.id, node)
            XCTAssertEqual(result.children.map(\.id), [child])
            XCTAssertEqual(result.relations.first { $0.title == "Labelled by" }?.nodes.map(\.id), [name])
            let relation = try XCTUnwrap(result.relations.first { $0.title == "Controls" }?.nodes.first)
            XCTAssertEqual(relation.id, panel)
            session.selectNode(relation.id)
            XCTAssertEqual(session.selectedNode, panel)
        }
    }

    func testFrameworkListenersFindTheUserHandlersOnTheInspectedNode() async throws {
        try await withElements("""
            <!doctype html><title>Element details fixture</title>
            <button id="target">Activate</button>
            <form id="form" class=" "><input name="id"></form>
            <script>
            const target = document.getElementById("target");
            function appClick() { document.body.dataset.clicked = "yes"; }
            function jqueryDispatch(event) { appClick(event); }
            function plainKeyDown(event) { return event.key; }
            const jqueryCache = {events: {click: [{handler: appClick}]}, handle: jqueryDispatch};
            // The form's id property is its input and its class is blank, so
            // only a match by node finds the dispatcher in the native list.
            const form = document.getElementById("form");
            function formSubmit() {}
            const formCache = {events: {submit: [{handler: formSubmit}]}, handle: jqueryDispatch};
            window.jQuery = {_data: (node, field) =>
                node === target ? jqueryCache[field] : node === form ? formCache[field] : undefined};
            target.addEventListener("click", jqueryDispatch);
            form.addEventListener("submit", jqueryDispatch);
            target.addEventListener("keydown", plainKeyDown);
            target.__reactProps$fixture = {onDoubleClickCapture: function reactCapture() {}, onChange: function reactChange() {}};
            // A framework of its own, through Chrome's hook.
            function customDispatch(event) {}
            function customPointer() {}
            target.addEventListener("pointerdown", customDispatch);
            window.devtoolsFrameworkEventListeners = [(node) => node === target
                ? {eventListeners: [{type: "pointerdown", useCapture: false, handler: customPointer}],
                   internalHandlers: [customDispatch]}
                : {eventListeners: []}];
            </script>
            """) { session in
            let node = try await find("#target", in: session)
            session.selectNode(node)
            session.listenerAncestors = false
            session.loadListeners()
            try await DeveloperTestSupport.wait("native listeners", in: "DeveloperElementDetailsLiveTests") {
                session.listeners.contains { $0.handler == "jqueryDispatch" }
            }
            XCTAssertFalse(session.listeners.contains { $0.framework != nil })

            session.listenerFramework = true
            session.loadListeners()
            try await DeveloperTestSupport.wait("framework handlers", in: "DeveloperElementDetailsLiveTests") {
                session.listeners.contains { $0.handler == "appClick" && $0.framework == "jQuery" }
                    && session.listeners.contains { $0.handler == "reactCapture" && $0.framework == "React" }
            }
            let click = try XCTUnwrap(session.listeners.first { $0.handler == "appClick" })
            XCTAssertEqual(click.type, "click")
            XCTAssertEqual(click.target, "button#target")
            XCTAssertNotNil(click.line)
            let capture = try XCTUnwrap(session.listeners.first { $0.handler == "reactCapture" })
            XCTAssertEqual(capture.type, "dblclick")
            XCTAssertTrue(capture.useCapture)
            XCTAssertTrue(session.listeners.contains { $0.handler == "plainKeyDown" && $0.framework == nil })
            XCTAssertFalse(session.listeners.contains { $0.handler == "jqueryDispatch" })
            XCTAssertEqual(Set(session.listeners.filter { $0.handler == "reactChange" }.map(\.type)), ["input", "change"])
            XCTAssertTrue(session.listeners.contains { $0.handler == "customPointer" && $0.framework == "Framework" && $0.type == "pointerdown" })
            XCTAssertFalse(session.listeners.contains { $0.handler == "customDispatch" })

            let form = try await find("#form", in: session)
            session.selectNode(form)
            session.loadListeners()
            try await DeveloperTestSupport.wait("form handlers", in: "DeveloperElementDetailsLiveTests") {
                session.listeners.contains { $0.handler == "formSubmit" && $0.framework == "jQuery" }
            }
            XCTAssertFalse(session.listeners.contains { $0.handler == "jqueryDispatch" })
        }
    }

    private func find(_ selector: String, in session: DeveloperToolsSession) async throws -> Int {
        let matches = await session.searchDOM(selector)
        return try XCTUnwrap(matches.first, "Expected a DOM node for \(selector).")
    }

    private func withElements(_ html: String, check: (DeveloperToolsSession) async throws -> Void) async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer(["/": .init(type: "text/html", body: html)])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperElementDetailsLiveTests") {
            page.title == "Element details fixture"
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        defer { withExtendedLifetime((tab, server)) {} }
        do {
            try await DeveloperTestSupport.wait("inspector and document", in: "DeveloperElementDetailsLiveTests") {
                session.ready && session.root != nil
            }
            try await check(session)
        } catch {
            await session.disconnect().value
            throw error
        }
        await session.disconnect().value
    }
}
