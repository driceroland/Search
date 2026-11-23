import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › Ignore list, as Chrome has it: the /node_modules/ rule on by
/// default, source maps' ignoreList, anonymous scripts, and custom rules.
@MainActor
final class DeveloperIgnoreListTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Self.clearSettings()
    }

    override func tearDown() {
        Self.clearSettings()
        super.tearDown()
    }

    private static func clearSettings() {
        for key in [DeveloperDebugger.ignorePatternsKey, DeveloperDebugger.ignoreThirdPartyKey, DeveloperDebugger.ignoreAnonymousKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Source maps

    /// a.js at line 0 column 0, b.js from column 10, c.js on line 1.
    private static func map(_ extra: String) throws -> DeveloperSourceMap {
        try DeveloperSourceMap(text: """
            {"version": 3, "sources": ["a.js", "b.js", "c.js"], "names": [],
             "mappings": "AAAA,UCAA;ACAA"\(extra)}
            """, mapURL: "http://x.test/js/app.js.map", scriptURL: "http://x.test/js/app.js")
    }

    func testIgnoreListIsReadFromEitherKey() throws {
        let standard = try Self.map(#", "ignoreList": [1]"#)
        XCTAssertEqual(standard.ignoredSources, [1])
        XCTAssertEqual(standard.ignoredSourceURLs, [standard.sources[1]])
        XCTAssertTrue(standard.ignoredSourceURLs[0].hasSuffix("/js/b.js"))

        let google = try Self.map(#", "x_google_ignoreList": [0, 2, 9]"#)
        XCTAssertEqual(google.ignoredSources, [0, 2], "an index past the sources is dropped")
        XCTAssertTrue(try Self.map("").ignoredSources.isEmpty)
    }

    func testIgnoreListOfAnIndexMapSectionKeepsItsSources() throws {
        let map = try DeveloperSourceMap(text: """
            {"version": 3, "sections": [
              {"offset": {"line": 0, "column": 0}, "map": {"version": 3, "sources": ["app.js"], "mappings": "AAAA"}},
              {"offset": {"line": 5, "column": 0}, "map": {"version": 3, "sources": ["vendor.js"], "ignoreList": [0], "mappings": "AAAA"}}
            ]}
            """, mapURL: nil, scriptURL: "http://x.test/bundle.js")
        XCTAssertEqual(map.ignoredSourceURLs.count, 1)
        XCTAssertTrue(map.ignoredSourceURLs[0].hasSuffix("vendor.js"))
    }

    func testGeneratedRangesCoverTheIgnoredSources() throws {
        let map = try Self.map("")
        XCTAssertEqual(map.generatedRanges(of: [1]), [[0, 10, 1, 0]])
        // An inline script: moved to where it starts in its document.
        XCTAssertEqual(map.generatedRanges(of: [1], line: 5, column: 3), [[5, 13, 6, 0]])
        let end = Int(Int32.max)
        XCTAssertEqual(map.generatedRanges(of: [2]), [[1, 0, end, end]])
        XCTAssertEqual(map.generatedRanges(of: [0, 1]), [[0, 0, 1, 0]])
        XCTAssertTrue(map.generatedRanges(of: []).isEmpty)
    }

    // MARK: Rules

    func testDefaultRuleAndCustomRules() {
        let debugger = DeveloperDebugger()
        XCTAssertEqual(debugger.ignorePatterns, [.init(pattern: DeveloperDebugger.defaultIgnorePattern, enabled: true)])
        XCTAssertTrue(debugger.ignoreThirdParty)
        XCTAssertFalse(debugger.ignoreAnonymous)
        XCTAssertTrue(debugger.isIgnored("http://x.test/node_modules/react/index.js"))
        XCTAssertTrue(debugger.isIgnored("webpack://app/./bower_components/jquery.js"))
        XCTAssertFalse(debugger.isIgnored("http://x.test/src/app.js"))
        XCTAssertFalse(debugger.isListed("http://x.test/node_modules/react/index.js"))

        XCTAssertFalse(debugger.addIgnorePattern("("), "not a regular expression")
        XCTAssertFalse(debugger.addIgnorePattern(DeveloperDebugger.defaultIgnorePattern), "already there")
        XCTAssertTrue(debugger.addIgnorePattern("framework\\.js$"))
        XCTAssertTrue(debugger.isIgnored("http://x.test/lib/framework.js"))
        XCTAssertTrue(debugger.replaceIgnorePattern("framework\\.js$", with: "vendor\\.js$"))
        XCTAssertFalse(debugger.isIgnored("http://x.test/lib/framework.js"))
        XCTAssertTrue(debugger.isIgnored("http://x.test/lib/vendor.js"))

        // The default is an ordinary entry: it can be turned off.
        debugger.setIgnorePattern(DeveloperDebugger.defaultIgnorePattern, enabled: false)
        XCTAssertFalse(debugger.isIgnored("http://x.test/node_modules/react/index.js"))
        debugger.ignoreAnonymous = true
        debugger.ignoreThirdParty = false

        // Kept across sessions.
        let again = DeveloperDebugger()
        XCTAssertEqual(again.ignorePatterns.map(\.pattern), [DeveloperDebugger.defaultIgnorePattern, "vendor\\.js$"])
        XCTAssertEqual(again.ignorePatterns.map(\.enabled), [false, true])
        XCTAssertTrue(again.ignoreAnonymous)
        XCTAssertFalse(again.ignoreThirdParty)
        again.removeIgnorePattern("vendor\\.js$")
        XCTAssertEqual(DeveloperDebugger().ignorePatterns.map(\.pattern), [DeveloperDebugger.defaultIgnorePattern])
    }

    // MARK: Live

    /// Step into on a call to a node_modules function steps over it: the
    /// default rule reached WebKit's blackboxing.
    func testStepIntoSkipsAScriptMatchedByTheDefaultRule() async throws {
        let (_, page, session) = try await open()
        let debugger = session.debugger
        do {
            await debugger.settled()
            let url = try XCTUnwrap(server?.url("/app.js").absoluteString)
            XCTAssertTrue(debugger.isIgnored(try XCTUnwrap(server?.url("/node_modules/lib/lib.js").absoluteString)))
            // Line 3 is `helper();`.
            debugger.setBreakpoint(url: url, line: 3, kind: .regular)
            try await wait("breakpoint set") { debugger.breakpoints.first?.protocolID != nil }
            try await trigger(page, "go()")
            try await wait("paused at the call") { debugger.pause?.reason == "Breakpoint" }
            XCTAssertEqual(debugger.pause?.frames.first?.functionName, "caller")
            debugger.step("stepInto")
            try await wait("stepped past the ignored call") {
                guard let top = debugger.pause?.frames.first else { return false }
                return top.functionName != "caller" || top.line != 2
            }
            let top = try XCTUnwrap(debugger.pause?.frames.first)
            XCTAssertEqual(top.functionName, "caller", "step into went into the ignore-listed helper")
            XCTAssertEqual(top.line, 3)
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            let results = try await page.evaluateJavaScript("window.results.join(',')") as? String
            XCTAssertEqual(results, "helper,after")
            await DeveloperTestSupport.finish(session, page: page)
        } catch {
            await DeveloperTestSupport.finish(session, page: page)
            throw error
        }
    }

    /// With anonymous scripts ignored, `debugger` in eval'd code doesn't stop.
    func testAnonymousScriptsAreNotPausedInWhenIgnored() async throws {
        let (_, page, session) = try await open()
        let debugger = session.debugger
        do {
            debugger.ignoreAnonymous = true
            try await trigger(page, #"setTimeout(() => eval("debugger; window.results.push('eval')"), 0)"#)
            // Paused there, the eval'd push would never run.
            for _ in 0..<40 {
                // While WebKit is stopped there, before Perch resumes it,
                // the page can't run a script: try again.
                if (try? await page.evaluateJavaScript("window.results.join(',')") as? String) == "eval" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let results = try await page.evaluateJavaScript("window.results.join(',')") as? String
            XCTAssertEqual(results, "eval")
            XCTAssertNil(debugger.pause)
            await DeveloperTestSupport.finish(session, page: page)
        } catch {
            await DeveloperTestSupport.finish(session, page: page)
            throw error
        }
    }

    // MARK: Helpers

    private static let library = """
        function helper() {
            window.results.push("helper");
            return 1;
        }
        """

    private static let app = """
        window.results = [];
        function caller() {
            helper();
            window.results.push("after");
        }
        window.go = () => setTimeout(caller, 0);
        """

    private var server: LocalPageServer?
    // The session holds its tab weakly and closes once it is gone.
    private var tab: Tab?

    private func open() async throws -> (LocalPageServer, WKWebView, DeveloperToolsSession) {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Ignore list fixture</title>
                <script src="/node_modules/lib/lib.js"></script>
                <script src="/app.js"></script>
                """),
            "/node_modules/lib/lib.js": .init(type: "text/javascript", body: Self.library),
            "/app.js": .init(type: "text/javascript", body: Self.app),
        ])
        self.server = server
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Ignore list fixture" }
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

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeveloperIgnoreListTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}
