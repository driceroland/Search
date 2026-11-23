import AppKit
import WebKit
import XCTest
@testable import Search

/// Dedicated workers against a real page, as Chrome DevTools shows them: a
/// Console context of their own, their logs, their scripts in Sources, a
/// thread in the debugger's Threads pane and breakpoints set by URL.
@MainActor
final class DeveloperWorkerTests: XCTestCase {
    // 1-based lines of worker.js, as the gutter counts them.
    private static let worker = """
        console.log("hello from worker");
        self.onmessage = (event) => {
            if (event.data === "pause") {
                debugger;
            }
            if (event.data === "compute") {
                const value = 21 * 2;
                self.postMessage(value);
            }
            self.postMessage("done:" + event.data);
        };
        """

    private var tab: Tab?

    func testWorkerContextConsoleSourcesAndPause() async throws {
        let (server, page, session) = try await open()
        do {
            let debugger = session.debugger
            let scriptURL = server.url("/worker.js").absoluteString
            try await trigger(page, "startWorker()")
            try await wait("worker listed") { session.workers.contains { $0.url.hasSuffix("/worker.js") } }
            let worker = try XCTUnwrap(session.workers.first { $0.url.hasSuffix("/worker.js") })
            XCTAssertEqual(worker.title, "fixture-worker")

            // Console: the worker's log, from the worker's target.
            try await wait("worker log") {
                session.console.contains { $0.text == "hello from worker" && $0.details?.targetID == worker.id }
            }

            // Console: the worker is a context, and evaluates in its own global.
            session.refreshConsoleContexts()
            try await wait("worker context") {
                session.consoleStore.contexts.contains { $0.isWorker && $0.targetID == worker.id }
            }
            let context = try XCTUnwrap(session.consoleStore.contexts.first { $0.isWorker && $0.targetID == worker.id })
            XCTAssertEqual(context.title, "fixture-worker")
            session.consoleStore.context = context
            session.evaluateInConsole("typeof importScripts")
            try await wait("evaluated in the worker") {
                session.console.contains { $0.level == "result" && $0.details?.targetID == worker.id }
            }
            let result = try XCTUnwrap(session.console.last { $0.level == "result" && $0.details?.targetID == worker.id })
            XCTAssertEqual(result.text, "'function'")
            session.consoleStore.context = nil

            // Sources: the worker's script, under the worker.
            try await wait("worker script in Sources") {
                session.workerScripts.contains { $0.url == scriptURL }
            }
            let nodes = SourceTree.workers(session.workers, scripts: session.workerScripts)
            XCTAssertEqual(nodes.first?.name, "fixture-worker")

            // Debugger: a pause in the worker, on its thread, resumed there.
            try await trigger(page, "window.worker.postMessage('pause')")
            try await wait("paused in the worker") { debugger.pause?.targetID == worker.id }
            XCTAssertEqual(debugger.currentThread, worker.id)
            XCTAssertTrue(debugger.pausedThreads.contains(worker.id))
            XCTAssertFalse(debugger.pausedThreads.contains(""))
            XCTAssertEqual(debugger.pause?.frames.first?.url, scriptURL)
            debugger.step("resume")
            try await wait("worker resumed") { debugger.pause == nil }
            try await wait("worker went on") { (try? await self.replies(page))?.contains("done:pause") == true }
            XCTAssertTrue(debugger.pausedThreads.isEmpty)

            // A breakpoint by URL applies in the worker too.
            debugger.setBreakpoint(url: scriptURL, line: 7, kind: .regular)
            await debugger.settled()
            // The worker's copy goes through the worker's own connection.
            try await Task.sleep(for: .milliseconds(300))
            try await trigger(page, "window.worker.postMessage('compute')")
            try await wait("breakpoint hit in the worker") {
                debugger.pause?.targetID == worker.id && debugger.pause?.frames.first?.line == 6
            }
            debugger.step("resume")
            try await wait("resumed after the breakpoint") { debugger.pause == nil }
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab as Any)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab as Any)
            throw error
        }
    }

    // MARK: Fixture

    private func open() async throws -> (LocalPageServer, WKWebView, DeveloperToolsSession) {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Worker fixture</title>
                <h1>Fixture</h1>
                <script>
                window.replies = [];
                window.startWorker = () => {
                    window.worker = new Worker("/worker.js", {name: "fixture-worker"});
                    window.worker.onmessage = (event) => window.replies.push(String(event.data));
                };
                </script>
                """),
            "/worker.js": .init(type: "text/javascript", body: Self.worker),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Worker fixture" }
        let tab = Tab(shy: true)
        self.tab = tab
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await wait("inspector to load the DOM") {
            session.ready && session.nodes.values.contains { $0.name == "body" }
        }
        return (server, page, session)
    }

    /// Runs page script that posts work, so a pause can't block the call.
    private func trigger(_ page: WKWebView, _ script: String) async throws {
        _ = try await page.evaluateJavaScript(script + "; 0")
    }

    private func replies(_ page: WKWebView) async throws -> String {
        try await page.evaluateJavaScript("window.replies.join(',')") as? String ?? ""
    }

    private func wait(_ action: String, until condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Recorded now: the teardown's gesture report (DeveloperTestSupport)
        // can stand in for the thrown error in XCTest's log.
        XCTFail("Timed out waiting for \(action)")
        throw NSError(domain: "DeveloperWorkerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}
