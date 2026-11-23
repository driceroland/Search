import AppKit
import WebKit
import XCTest
@testable import Search

/// Event Listeners › Remove and Breakpoint, on a real page and inspector.
@MainActor
final class DeveloperElementsListenersLiveTests: XCTestCase {
    private static let fixture = """
        <!doctype html><title>Listener fixture</title>
        <button id="target">Activate</button>
        <script>
        window.clicks = 0;
        window.taps = 0;
        const target = document.getElementById("target");
        function countClick() { window.clicks += 1; document.title = "clicks " + window.clicks; }
        function countTap() { window.taps += 1; }
        target.addEventListener("click", countClick);
        target.addEventListener("mousedown", countTap);
        </script>
        """

    func testAListenerCanBeRemoved() async throws {
        try await withElements { session, page in
            let node = try await find("#target", in: session)
            session.selectNode(node)
            session.listenerAncestors = false
            session.loadListeners()
            try await wait("listeners") { session.listeners.contains { $0.handler == "countClick" } }
            let click = try XCTUnwrap(session.listeners.first { $0.handler == "countClick" })

            let source = await session.listenerSource(click)
            XCTAssertEqual(source.map { DeveloperListenerPreview.firstLine($0) },
                           #"function countClick() { window.clicks += 1; document.title = "clicks " + window.clicks; }"#)

            session.removeListener(click)
            try await wait("the listener to go") {
                !session.listeners.isEmpty && !session.listeners.contains { $0.handler == "countClick" }
            }
            XCTAssertTrue(session.listeners.contains { $0.handler == "countTap" })
            let clicks = try await page.callAsyncJavaScript(
                "document.getElementById('target').click(); return window.clicks;",
                arguments: [:], in: nil, contentWorld: .page) as? Int
            XCTAssertEqual(clicks, 0)
        }
    }

    func testTheBreakpointTogglePausesOnDispatch() async throws {
        try await withElements { session, page in
            let node = try await find("#target", in: session)
            session.selectNode(node)
            session.listenerAncestors = false
            session.loadListeners()
            try await wait("listeners") { session.listeners.contains { $0.handler == "countClick" } }
            let click = try XCTUnwrap(session.listeners.first { $0.handler == "countClick" })
            let debugger = session.debugger

            session.setListenerBreakpoint(click, on: true)
            XCTAssertTrue(session.elements.listenerBreakpoints.contains(click.id))
            try await readBreakpoints(session, until: { $0.contains(click.id) })
            do {
                _ = try await page.evaluateJavaScript("setTimeout(() => document.getElementById('target').click(), 0); 0")
                try await wait("the pause in the listener") { debugger.pause != nil }
                debugger.step("resume")
                try await wait("resume") { debugger.pause == nil }
                let clicks = try await page.callAsyncJavaScript("return window.clicks;", arguments: [:], in: nil,
                                                                contentWorld: .page) as? Int
                XCTAssertEqual(clicks, 1)

                session.setListenerBreakpoint(click, on: false)
                try await readBreakpoints(session, until: { !$0.contains(click.id) })
                // Dispatched later, so a pause (were the breakpoint still
                // set) can't hold up this call.
                _ = try await page.evaluateJavaScript("setTimeout(() => document.getElementById('target').click(), 0); 0")
                try await wait("the second click") { debugger.pause != nil || page.title == "clicks 2" }
                XCTAssertNil(debugger.pause)
            } catch {
                if debugger.pause != nil { debugger.step("resume") }
                throw error
            }
        }
    }

    private func find(_ selector: String, in session: DeveloperToolsSession) async throws -> Int {
        let matches = await session.searchDOM(selector)
        return try XCTUnwrap(matches.first, "Expected a DOM node for \(selector).")
    }

    /// Reads WebKit's hasBreakpoint until `condition` holds of it: the
    /// toggle's command runs on the session's queue, after this starts.
    private func readBreakpoints(_ session: DeveloperToolsSession, until condition: (Set<Int>) -> Bool) async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            await session.readListenerBreakpoints()
            if condition(session.elements.listenerBreakpoints) { return }
        }
        XCTFail("WebKit never reported the listener breakpoints as expected: \(session.elements.listenerBreakpoints)")
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: 10, in: "DeveloperElementsListenersLiveTests", until: condition)
    }

    private func withElements(check: (DeveloperToolsSession, WKWebView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer(["/": .init(type: "text/html", body: Self.fixture)])
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
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperElementsListenersLiveTests") {
            page.title == "Listener fixture"
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector and document", in: "DeveloperElementsListenersLiveTests") {
                session.ready && session.root != nil
            }
            try await check(session, page)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
            throw error
        }
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
    }
}
