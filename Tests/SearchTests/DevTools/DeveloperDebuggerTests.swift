import AppKit
import WebKit
import XCTest
@testable import Search

/// The Sources panel's debugger sidebar against a real page: breakpoints
/// with conditions and log messages, scopes, watches, exceptions, and the
/// XHR, event listener and DOM breakpoints.
@MainActor
final class DeveloperDebuggerTests: XCTestCase {
    // 1-based lines of app.js, as the sidebar and gutter count them.
    private static let script = """
        function compute(n) {
            const doubled = n * 2;
            window.results.push(doubled);
            return doubled;
        }
        function thrower() {
            throw new Error("boom");
        }
        function catcher() {
            try { thrower(); } catch {}
        }
        window.results = [];
        window.run = (n) => setTimeout(() => compute(n), 0);
        document.addEventListener("click", function onClick() {});
        function scheduleWork() {
            setTimeout(function timedCallback() { compute(5); }, 0);
        }
        """

    func testAsyncCallersAppearBelowTheirTimerBoundary() async throws {
        let (server, page, session) = try await open()
        let debugger = session.debugger
        let url = server.url("/app.js").absoluteString
        let scheduledLine = try XCTUnwrap(Self.script.split(separator: "\n").firstIndex {
            $0.contains("setTimeout(function timedCallback")
        }) + 1
        do {
            debugger.setBreakpoint(url: url, line: 3, kind: .regular)
            try await wait("breakpoint set") { debugger.breakpoints.first?.protocolID != nil }
            try await trigger(page, "scheduleWork()")
            try await wait("paused inside timer") { debugger.pause?.reason == "Breakpoint" }

            let pause = try XCTUnwrap(debugger.pause)
            XCTAssertEqual(pause.frames.first?.functionName, "compute")
            let timer = try XCTUnwrap(pause.asyncStacks.first)
            XCTAssertEqual(timer.boundary, "setTimeout")
            let caller = try XCTUnwrap(timer.frames.first)
            XCTAssertEqual(caller.functionName, "scheduleWork")
            XCTAssertEqual(caller.url, url)
            XCTAssertEqual(caller.location, "app.js:\(scheduledLine)")
            XCTAssertTrue(pause.stackTrace.contains("\nsetTimeout\nscheduleWork (app.js:\(scheduledLine))"))

            debugger.revealAsync(caller)
            XCTAssertEqual(debugger.revealed?.line, scheduledLine)
            XCTAssertEqual(debugger.frame?.functionName, "compute")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            await session.disconnect().value
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    func testAsyncTraceDecodesParentBoundariesAndConsoleLineNumbers() {
        let caller: [String: Any] = [
            "functionName": "ready", "url": "https://example.test/app.js", "lineNumber": 6, "columnNumber": 4,
        ]
        let stacks = DeveloperDebugger.AsyncStack.groups([
            "topCallFrameIsBoundary": true,
            "callFrames": [["functionName": "Promise.then"], caller],
            "parentStackTrace": ["callFrames": [caller]],
        ])
        XCTAssertEqual(stacks.map(\.boundary), ["Promise.then", "Async"])
        XCTAssertEqual(stacks.map { $0.frames.map(\.functionName) }, [["ready"], ["ready"]])
        XCTAssertEqual(stacks.first?.frames.first?.line, 5)
        // Console.CallFrame columns are 1-based too.
        XCTAssertEqual(stacks.first?.frames.first?.column, 3)
        XCTAssertNil(stacks.first?.frames.first?.scriptID)
        XCTAssertFalse(stacks.contains(where: \.truncated))
    }

    func testTruncatedAsyncTraceEndsWithATruncatedRow() {
        let caller: [String: Any] = ["functionName": "ready", "url": "https://example.test/app.js", "lineNumber": 1]
        let stacks = DeveloperDebugger.AsyncStack.groups([
            "callFrames": [caller],
            "parentStackTrace": ["callFrames": [caller], "truncated": true],
        ])
        XCTAssertEqual(stacks.map(\.truncated), [false, true])
    }

    func testInlineValuesReadTopFrameBindingsAndClearOnResume() async throws {
        let (server, page, session) = try await open()
        let debugger = session.debugger
        do {
            debugger.setBreakpoint(url: server.url("/app.js").absoluteString, line: 3, kind: .regular)
            try await wait("breakpoint set") { debugger.breakpoints.first?.protocolID != nil }
            try await trigger(page, "scheduleWork()")
            try await wait("inline scope values") {
                debugger.inlineScopes.contains { $0.values["doubled"] == "10" }
            }
            XCTAssertEqual(debugger.pause?.frames.first?.functionName, "compute")
            XCTAssertTrue(debugger.inlineScopes.contains { $0.values["n"] == "5" })
            XCTAssertFalse(debugger.inlineScopes.contains { $0.values["results"] != nil })

            // The editor's request: each line through the paused one shows
            // the bindings it names, matched in the file the frame is in.
            let url = server.url("/app.js").absoluteString
            let document = SourceDocument(text: Self.script, url: url, type: "Script")
            let request = try XCTUnwrap(SourceInlineValues.request(for: document, debugger: debugger,
                                                                   sourceMaps: session.sourceMaps))
            XCTAssertEqual(request.throughLine, 3)
            let lines = request.annotations(in: document.display.text, lineStarts: document.display.lineStarts)
            XCTAssertEqual(lines[3], "doubled = 10")
            if debugger.pause?.frames.first?.scopes.first(where: { $0.kind == .local })?.start != nil {
                XCTAssertEqual(lines[2], "doubled = 10, n = 5")
            }
            let other = SourceDocument(text: Self.script, url: server.url("/other.js").absoluteString, type: "Script")
            XCTAssertNil(SourceInlineValues.request(for: other, debugger: debugger, sourceMaps: session.sourceMaps))

            // Selecting a caller loads its scopes; the inline values stay the top frame's.
            let top = debugger.inlineScopes
            let generation = debugger.inlineGeneration
            debugger.selectFrame(1)
            XCTAssertEqual(debugger.frame?.functionName, "timedCallback")
            try await wait("caller scope loaded") {
                debugger.properties.keys.contains { $0.hasPrefix("scope:") }
            }
            XCTAssertEqual(debugger.inlineScopes, top)
            XCTAssertEqual(debugger.inlineGeneration, generation)
            debugger.step("resume")
            try await wait("resume clears inline values") { debugger.pause == nil && debugger.inlineScopes.isEmpty }
            await session.disconnect().value
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    func testConditionalBreakpointScopeWatchLogpointAndContinueToHere() async throws {
        let (server, page, session) = try await open()
        defer { UserDefaults.standard.removeObject(forKey: DeveloperDebugger.watchesKey) }
        let debugger = session.debugger
        let url = server.url("/app.js").absoluteString
        do {
            // A conditional breakpoint pauses only when its condition holds.
            debugger.setBreakpoint(url: url, line: 2, kind: .conditional, expression: "n === 3")
            try await wait("conditional breakpoint set") { debugger.breakpoints.first?.protocolID != nil }
            XCTAssertEqual(session.breakpoints, [], "no file is open in the editor")
            try await trigger(page, "run(1)")
            try await stayUnpaused(debugger)
            try await assertResults(page, "2")

            try await trigger(page, "run(3)")
            try await wait("pause on the conditional breakpoint") { debugger.pause != nil }
            let pause = try XCTUnwrap(debugger.pause)
            XCTAssertEqual(pause.reason, "Breakpoint")
            XCTAssertEqual(pause.message, "Paused on breakpoint")
            let frame = try XCTUnwrap(debugger.frame)
            XCTAssertEqual(frame.functionName, "compute")
            XCTAssertEqual(frame.line, 1)
            XCTAssertTrue(DeveloperDebugger.sameScript(frame.url, url), frame.url)
            XCTAssertEqual(debugger.executionLine(for: url), 2)

            // Scope: Local is open and holds the argument; Global is listed.
            let titles = frame.scopes.map(\.title)
            XCTAssertEqual(titles.first, "Local", "\(titles)")
            XCTAssertTrue(titles.contains("Global"), "\(titles)")
            let local = try XCTUnwrap(frame.scopes.first { $0.kind == .local })
            try await wait("local variables") {
                debugger.properties["scope:\(local.id)"]?.contains { $0.name == "n" && $0.value?.display == "3" } == true
            }
            XCTAssertEqual(debugger.properties["scope:\(local.id)"]?.first?.name, "this")
            // The global scope's objects expand on demand.
            let global = try XCTUnwrap(frame.scopes.first { $0.kind == .global })
            debugger.toggleExpanded("scope:\(global.id)", objectID: nil)
            try await wait("global variables") {
                debugger.properties["scope:\(global.id)"]?.contains { $0.name == "results" } == true
            }
            let resultsArray = try XCTUnwrap(debugger.properties["scope:\(global.id)"]?.first { $0.name == "results" }?.value)
            XCTAssertTrue(resultsArray.expandable)
            debugger.toggleExpanded("scope:\(global.id)/results", objectID: resultsArray.objectID)
            try await wait("array elements") {
                debugger.properties[resultsArray.objectID ?? ""]?.contains { $0.name == "0" && $0.value?.display == "2" } == true
            }

            // Watch expressions evaluate in the selected frame.
            debugger.addWatch("n * 10")
            try await wait("watch value") { debugger.watches.first?.value?.display == "30" }

            // Continue to here pauses again further down.
            debugger.continueToHere(url: url, line: 4)
            try await wait("pause at line 4") { debugger.frame?.line == 3 }

            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            try await assertResults(page, "2,6")
            // Not paused, the watch has no `n` to see.
            try await wait("watch unavailable") {
                debugger.watches.first?.evaluated == true && debugger.watches.first?.value == nil
            }

            // A logpoint logs and never pauses.
            let conditional = try XCTUnwrap(debugger.breakpoints.first)
            debugger.setBreakpointEnabled(conditional.id, false)
            debugger.setBreakpoint(url: url, line: 4, kind: .logpoint, expression: "`logged ${doubled}`")
            try await wait("logpoint set") { debugger.breakpoints.last?.protocolID != nil }
            try await trigger(page, "run(3); run(5)")
            try await wait("logpoint message") {
                session.console.contains { $0.text == "logged 6" } && session.console.contains { $0.text == "logged 10" }
            }
            try await stayUnpaused(debugger)
            try await assertResults(page, "2,6,6,10")

            // Re-enabled, the condition holds again; deactivated, nothing pauses.
            debugger.setBreakpointsActive(false)
            debugger.setBreakpointEnabled(conditional.id, true)
            try await wait("re-enabled") { debugger.breakpoints.first?.protocolID != nil }
            try await trigger(page, "run(3)")
            try await stayUnpaused(debugger)
            debugger.setBreakpointsActive(true)
            await debugger.settled()
            try await trigger(page, "run(3)")
            try await wait("pause after reactivating") { debugger.pause?.reason == "Breakpoint" }
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }

            debugger.removeBreakpoints()
            await debugger.settled()
            XCTAssertTrue(debugger.breakpoints.isEmpty)
            try await trigger(page, "run(3)")
            try await stayUnpaused(debugger)
            await session.disconnect().value
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    func testExceptionsAndXHREventAndDOMBreakpoints() async throws {
        let (_, page, session) = try await open()
        let debugger = session.debugger
        do {
            // Uncaught only: a caught exception runs on, an uncaught one pauses.
            debugger.setPauseOnExceptions(uncaught: true, caught: false)
            await debugger.settled()
            XCTAssertEqual(debugger.exceptionState, "uncaught")
            try await trigger(page, "setTimeout(catcher)")
            try await stayUnpaused(debugger)
            try await trigger(page, "setTimeout(thrower)")
            try await wait("pause on uncaught exception") { debugger.pause?.reason == "exception" }
            XCTAssertEqual(debugger.pause?.message, "Paused on exception")
            XCTAssertTrue(debugger.pause?.errorLike == true)
            XCTAssertTrue(debugger.pause?.detail?.contains("boom") == true, debugger.pause?.detail ?? "")
            XCTAssertEqual(debugger.frame?.functionName, "thrower")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }

            debugger.setPauseOnExceptions(uncaught: true, caught: true)
            await debugger.settled()
            XCTAssertEqual(debugger.exceptionState, "all")
            try await trigger(page, "setTimeout(catcher)")
            try await wait("pause on caught exception") { debugger.pause?.reason == "exception" }
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            debugger.setPauseOnExceptions(uncaught: false, caught: false)

            // XHR/fetch: URL contains.
            debugger.addURLBreakpoint("sample")
            await debugger.settled()
            try await trigger(page, "setTimeout(() => fetch('/other'))")
            try await stayUnpaused(debugger)
            try await trigger(page, "setTimeout(() => fetch('/sample'))")
            try await wait("pause on fetch") { debugger.pause?.reason == "URL" }
            XCTAssertEqual(debugger.pause?.message, "Paused on XHR or fetch")
            XCTAssertTrue(debugger.pause?.detail?.contains("/sample") == true, debugger.pause?.detail ?? "")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            debugger.removeURLBreakpoint(try XCTUnwrap(debugger.urlBreakpoints.first).id)

            // Event listener breakpoint: Mouse › click.
            let click = try XCTUnwrap(DeveloperDebugger.EventBreakpoint.categories
                .first { $0.name == "Mouse" }?.items.first { $0.eventName == "click" })
            debugger.setEventBreakpoint(click, true)
            await debugger.settled()
            try await trigger(page, "setTimeout(() => document.body.click())")
            try await wait("pause on click listener") { debugger.pause?.reason == "Listener" }
            XCTAssertEqual(debugger.pause?.message, "Paused on event listener")
            XCTAssertEqual(debugger.pause?.detail, "click")
            XCTAssertEqual(debugger.frame?.functionName, "onClick")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            debugger.setEventBreakpoint(click, false)

            // DOM breakpoint: subtree modifications on <body>.
            let body = try XCTUnwrap(session.nodes.values.first { $0.name == "body" })
            debugger.toggleDOMBreakpoint(node: body.id, type: .subtreeModified)
            await debugger.settled()
            XCTAssertEqual(debugger.domBreakpoints.first?.label, "body")
            try await trigger(page, "setTimeout(() => document.body.append(document.createElement('p')))")
            try await wait("pause on subtree modification") { debugger.pause?.reason == "DOM" }
            XCTAssertEqual(debugger.pause?.message, "Paused on subtree modifications")
            XCTAssertEqual(debugger.pause?.detail, "body")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            debugger.toggleDOMBreakpoint(node: body.id, type: .subtreeModified)
            await debugger.settled()
            XCTAssertTrue(debugger.domBreakpoints.isEmpty)
            try await trigger(page, "setTimeout(() => document.body.append(document.createElement('p')))")
            try await stayUnpaused(debugger)
            await session.disconnect().value
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    /// Chromium's Event Listener Breakpoints categories, in its order, with
    /// the instrumentation rows WebKit lacks listed but not checkable.
    func testEventBreakpointCategoriesFollowChromium() {
        let categories = DeveloperDebugger.EventBreakpoint.categories
        XCTAssertEqual(categories.map(\.name), [
            "Ad auction worklet", "Animation", "Canvas", "Clipboard", "Control", "Device", "DOM mutation", "Drag / drop",
            "Geolocation", "Keyboard", "Load", "Media", "Mouse", "Notification", "Parse", "Picture-in-picture",
            "Pointer", "Script", "Timer", "Touch", "WebAudio", "Window", "Worker", "XHR",
        ])
        let timer = categories.first { $0.name == "Timer" }!.items
        XCTAssertEqual(timer.map(\.title), ["setTimeout", "clearTimeout", "setTimeout fired",
                                            "setInterval", "clearInterval", "setInterval fired"])
        XCTAssertEqual(timer.filter(\.available).map(\.type), ["timeout", "interval"])
        XCTAssertTrue(categories.first { $0.name == "Canvas" }!.items.allSatisfy { !$0.available })
        XCTAssertTrue(categories.first { $0.name == "Mouse" }!.items.allSatisfy(\.available))
    }

    // MARK: Helpers

    private var server: LocalPageServer?
    // The session holds its tab weakly and closes once it is gone.
    private var tab: Tab?

    private func open() async throws -> (LocalPageServer, WKWebView, DeveloperToolsSession) {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: DeveloperDebugger.watchesKey)
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Debugger fixture</title>
                <h1 id="target">Fixture</h1>
                <script src="/app.js"></script>
                """),
            "/app.js": .init(type: "text/javascript", body: Self.script),
            "/sample": .init(type: "text/plain", body: "sample"),
            "/other": .init(type: "text/plain", body: "other"),
        ])
        self.server = server
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Debugger fixture" }
        let tab = Tab(shy: true)
        self.tab = tab
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await wait("inspector to load the DOM") {
            session.ready && session.nodes.values.contains { $0.name == "body" }
        }
        return (server, page, session)
    }

    /// Runs page script that schedules work, so a pause can't block the call.
    private func trigger(_ page: WKWebView, _ script: String) async throws {
        _ = try await page.evaluateJavaScript(script + "; 0")
    }

    private func results(_ page: WKWebView) async throws -> String {
        try await page.evaluateJavaScript("window.results.join(',')") as? String ?? ""
    }

    private func stayUnpaused(_ debugger: DeveloperDebugger) async throws {
        for _ in 0..<7 {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(debugger.pause, "paused unexpectedly: \(debugger.pause?.message ?? "")")
        }
    }

    private func assertResults(_ page: WKWebView, _ expected: String, file: StaticString = #filePath,
                               line: UInt = #line) async throws {
        let value = try await results(page)
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeveloperDebuggerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}
