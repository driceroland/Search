import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search
import SearchPluginAPI

private typealias PageTab = Search.Tab

/// Developer Tools Full, headless, in a window that is never shown. Installed
/// from a local feed, each panel reads a real page from a loopback server:
/// Elements its tree and styles, Console a logged message and an
/// evaluation, Network its requests with headers, Sources its files and a
/// breakpoint, Application its local storage and cookies, Performance a
/// short recording, Memory a heap snapshot. A hostile page sees and reaches
/// nothing of it. With Lite installed too, the picker decides which one the
/// menus and ⌥⌘I use; each is removed with every file and setting.
///
/// Needs both packages built first: SEARCH_TEST_DEVTOOLS names the folder
/// `SEARCH_SIGN_IDENTITY=- ./build.sh release devtools` makes (build/devtools).
/// A package, once loaded, stays for the run: the tests are in order.
@MainActor
final class DevToolsFullTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var server: LocalPageServer!
    private var browser: Browser!
    private var window: NSWindow!
    private var tab: PageTab?
    private var scratch: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer(Self.pages)
        browser = Browser(record: WindowRecord())
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        scratch = TestWorld.home.appendingPathComponent("devtools-full-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DevToolsPackages.requireRelease = false
    }

    override func tearDown() async throws {
        if let tab { browser.close(tab) }
        server.stop()
        window.orderOut(nil)
        window.close()
        try? FileManager.default.removeItem(at: scratch)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "no window was shown")
        try await super.tearDown()
    }

    private var packages: DevToolsPackages { .shared }

    // MARK: - 1. Full: installed, every panel on a real page

    func test1FullInstallsAndEveryPanelReadsThePage() async throws {
        XCTAssertTrue(packages.installed.isEmpty)
        XCTAssertTrue(packages.takenKeys.isEmpty, "with nothing installed ⌥⌘I is Web Inspector's")
        let full = try XCTUnwrap(try localPackage("DevToolsFull")([:]))
        packages.offered = [full]
        packages.install("full")
        try await waitUntil(timeout: 60) { self.packages.states["full"] == .idle && self.packages.installed["full"] != nil }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: DevToolsPackages.folder.path).filter { $0.hasPrefix(".staging") }, [])
        XCTAssertEqual(packages.primary?.offer.menu.map(\.id), ["devtools", "console", "pick", "lighthouse", "recorder", "device"])
        XCTAssertEqual(Set(packages.takenKeys.keys), ["devtools", "console", "pick"], "⌥⌘I, ⌥⌘J and ⌥⌘C are Full's")
        XCTAssertTrue(DevToolsPackages.idle, "installed isn't loaded")

        let tab = try await open("/app")
        // ⌥⌘I, as the key's command runs it.
        browser.toggleInspector()
        XCTAssertFalse(DevToolsPackages.idle, "loaded on first use")
        let ready = try await perform("ready", [:], tab)
        XCTAssertEqual(ready["ready"] as? Bool, true, "the inspector connected: \(ready)")
        let state = try await perform("state", [:], tab)
        XCTAssertEqual(state["dock"] as? Bool, true, "docked beside the page")
        XCTAssertTrue(DevToolsPackages.busy(tab), "kept awake while open")

        // Elements: the known DOM, and the rule that styles #title.
        let styles = try await perform("elements.select", ["selector": "#title"], tab)
        let tree = try await perform("elements.tree", [:], tab)
        let nodes = try XCTUnwrap(tree["nodes"] as? [[String: Any]], "\(tree)")
        XCTAssertTrue(nodes.contains { ($0["name"] as? String)?.lowercased() == "h1" && ($0["attributes"] as? [String])?.contains("title") == true },
                      "the h1#title: \(nodes.prefix(12))")
        XCTAssertTrue(nodes.contains { ($0["name"] as? String)?.lowercased() == "ul" }, "the list")
        let rules = try XCTUnwrap(styles["rules"] as? [[String: Any]], "\(styles)")
        XCTAssertTrue(rules.contains { ($0["selector"] as? String) == "#title" && (($0["properties"] as? [String]) ?? []).contains("color: rgb(10, 20, 30)") },
                      "the stylesheet's rule: \(rules)")

        // Console: the page's message, and an evaluation.
        _ = try await tab.web.evaluateJavaScript("console.log('hello from the page'); true")
        let logged = try await perform("console.messages", ["contains": "hello from the page"], tab)
        XCTAssertTrue((logged["lines"] as? [[String: Any]] ?? []).contains { ($0["text"] as? String)?.contains("hello from the page") == true },
                      "\(logged)")
        let evaluated = try await perform("console.evaluate", ["expression": "6 * 7"], tab)
        XCTAssertTrue((evaluated["lines"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "42" }, "\(evaluated)")

        // Network: the page's requests, with headers both ways.
        tab.web.reload()
        try await waitUntil { !tab.web.isLoading }
        let network = try await perform("network.requests", ["contains": "/app.css"], tab)
        let requests = try XCTUnwrap(network["requests"] as? [[String: Any]], "\(network)")
        let css = try XCTUnwrap(requests.first { ($0["url"] as? String)?.hasSuffix("/app.css") == true }, "\(requests)")
        XCTAssertEqual(css["status"] as? Int, 200)
        let headers = try await perform("network.headers", ["id": css["id"] as? String ?? ""], tab)
        XCTAssertTrue((headers["response"] as? [[String]] ?? []).contains { $0.first?.lowercased() == "content-type" }, "\(headers)")
        XCTAssertFalse((headers["request"] as? [[String]] ?? []).isEmpty, "\(headers)")

        // Sources: the files, and a breakpoint the page stops at.
        let sources = try await perform("sources.list", [:], tab)
        let files = try XCTUnwrap(sources["files"] as? [String], "\(sources)")
        let script = server.url("/app.js").absoluteString
        XCTAssertTrue(files.contains(script), "\(files)")
        let stopped = try await perform("sources.breakpoint", ["url": script, "line": 2, "trigger": "setTimeout(() => compute(3), 0); true"], tab)
        XCTAssertEqual(stopped["breakpoints"] as? [Int], [2], "\(stopped)")
        XCTAssertEqual(stopped["paused"] as? Bool, true, "the page stopped at the breakpoint: \(stopped)")

        // Application: the page's local storage and its cookie.
        let local = try await perform("application.read", ["section": "Local storage"], tab)
        XCTAssertTrue((local["rows"] as? [[String]] ?? []).contains { $0.contains("flavour") && $0.contains("vanilla") }, "\(local)")
        let cookies = try await perform("application.read", ["section": "Cookies"], tab)
        XCTAssertTrue((cookies["rows"] as? [[String]] ?? []).contains { $0.contains("visit") && $0.contains("1") }, "\(cookies)")

        // Performance: a short recording has records.
        let recorded = try await perform("performance.record", ["milliseconds": 600, "during": "for (let i = 0; i < 1e5; i++) Math.sqrt(i); return true"], tab)
        XCTAssertGreaterThan(recorded["records"] as? Int ?? 0, 0, "\(recorded)")

        // Memory: a heap snapshot, counted.
        let heap = try await perform("memory.snapshot", [:], tab)
        XCTAssertGreaterThan(heap["nodes"] as? Int ?? 0, 1000, "\(heap)")

        // Closed: nothing of it is left on the tab.
        browser.toggleInspector()
        try await waitUntil { !DevToolsPackages.busy(tab) }
        XCTAssertTrue(DevToolsPackages.scripts(for: tab).isEmpty, "no scripts once closed")
        tab.web.reload()
        try await waitUntil { !tab.web.isLoading }
        let world = WKContentWorld.world(name: "Search Developer full")
        let left = try await tab.web.callAsyncJavaScript("return typeof window.__searchDeveloperLoad", arguments: [:], in: nil, contentWorld: world)
        XCTAssertEqual(left as? String, "undefined", "the load observer came out")
    }

    // MARK: - 2. A hostile page sees and reaches nothing

    func test2HostilePageSeesNothing() async throws {
        let tab = try await open("/hostile")
        _ = try await perform("open", ["item": "devtools"], tab)
        let ready = try await perform("ready", [:], tab)
        XCTAssertEqual(ready["ready"] as? Bool, true, "\(ready)")
        for panel in ["Elements", "Console", "Network", "Sources", "Application", "Performance", "Memory"] {
            _ = try await perform("select", ["panel": panel], tab)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let picked = try await perform("elements.select", ["selector": "#visible"], tab)
        XCTAssertNotNil(picked["node"], "Elements reads the page whatever it replaced on its side: \(picked)")
        _ = try await perform("console.messages", [:], tab)
        _ = try await perform("open", ["item": "device"], tab)
        _ = try await tab.web.evaluateJavaScript("window.attack(); true")
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let answer = try await tab.web.evaluateJavaScript("window.probe")
        let seen = try XCTUnwrap(answer as? [String: Any])
        let probe = "\(seen)"
        XCTAssertEqual(seen["webkit"] as? String, "undefined", "no window.webkit in the page's world: \(probe)")
        XCTAssertEqual(seen["globals"] as? [String], [], "no new globals: \(probe)")
        XCTAssertEqual(seen["symbols"] as? [String], [], "no symbols on window or document: \(probe)")
        XCTAssertEqual(seen["attributes"] as? [String], [], "nothing written on the root: \(probe)")
        XCTAssertEqual(seen["elements"] as? [String], [], "no element of the tools in the page: \(probe)")
        XCTAssertEqual(seen["posted"] as? String, "refused", "no handler to call: \(probe)")
        XCTAssertEqual(seen["patched"] as? [String], [], "the page's own functions untouched: \(probe)")
        _ = try await perform("close", [:], tab)
    }

    // MARK: - 3. Both packages: the picker decides; Remove each

    func test3BothInstalledPickerAndRemove() async throws {
        let full = try XCTUnwrap(try localPackage("DevToolsFull")([:]))
        let lite = try XCTUnwrap(try localPackage("DevToolsLite")([:]))
        packages.offered = [full, lite]
        if packages.installed["full"] == nil { packages.install("full") }
        packages.install("lite")
        try await waitUntil(timeout: 60) { self.packages.installed["full"] != nil && self.packages.installed["lite"] != nil
            && self.packages.states["lite"] == .idle }

        let tab = try await open("/app")
        // Nothing picked: the one installed last.
        packages.primaryID = nil
        XCTAssertEqual(packages.primary?.offer.id, "lite", "the most recently installed package")
        packages.primaryID = "full"
        XCTAssertEqual(packages.primary?.offer.id, "full", "a pick stays")
        XCTAssertEqual(Set(packages.takenKeys.keys), ["devtools", "console", "pick"])
        browser.toggleInspector()
        _ = try await perform("ready", [:], tab)
        XCTAssertTrue(try XCTUnwrap(packages.plugin("full")).isOpen(webView: tab.web))

        // Lite picked: Full's tools close, the keys are Web Inspector's again,
        // and the menu is Lite's.
        packages.primaryID = "lite"
        XCTAssertFalse(try XCTUnwrap(packages.plugin("full")).isOpen(webView: tab.web), "the other package's tools put away")
        XCTAssertTrue(packages.takenKeys.isEmpty, "⌥⌘I back to Web Inspector")
        XCTAssertEqual(packages.primary?.offer.menu.map(\.id), ["lighthouse", "recorder", "device"])
        packages.open("lighthouse", in: browser)
        XCTAssertTrue(try XCTUnwrap(packages.plugin("lite")).isOpen(webView: tab.web))
        packages.primaryID = "full"
        XCTAssertFalse(try XCTUnwrap(packages.plugin("lite")).isOpen(webView: tab.web))

        // A setting of Full's, in its own store and not Search's.
        _ = try await perform("dock", ["position": "left"], tab)
        let suite = DevToolsHostBridge.suite("full")
        XCTAssertNotNil(UserDefaults(suiteName: suite)?.object(forKey: "developerTools.dock"), "kept in the package's store")
        XCTAssertNil(Store.settings.object(forKey: "developerTools.dock"), "never in Search's")

        // Removed, each: its files and its settings go, nothing half there.
        packages.remove("full")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevToolsPackages.folder.appendingPathComponent("full").path))
        XCTAssertNil(UserDefaults(suiteName: suite)?.object(forKey: "developerTools.dock"), "its settings went too")
        XCTAssertEqual(packages.states["full"], .removedLoaded)
        XCTAssertEqual(packages.primary?.offer.id, "lite")
        packages.remove("lite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevToolsPackages.folder.appendingPathComponent("lite").path))
        XCTAssertNil(packages.primary, "no Developer menu")
        XCTAssertTrue(packages.takenKeys.isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: DevToolsPackages.folder.path)) ?? [], [],
                       "nothing half-installed")
        packages.offered = []
    }

    // MARK: - helpers

    /// A package build.sh made, and a feed entry for it at a file address.
    private func localPackage(_ product: String) throws -> ([String: Any]) -> DevToolsOffer? {
        guard let folder = ProcessInfo.processInfo.environment["SEARCH_TEST_DEVTOOLS"] else {
            throw XCTSkip("SEARCH_TEST_DEVTOOLS names no built package")
        }
        let built = URL(fileURLWithPath: folder)
        let data = try Data(contentsOf: built.appendingPathComponent("\(product).entry.json"))
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let zip = scratch.appendingPathComponent(try XCTUnwrap(entry["file"] as? String))
        if !FileManager.default.fileExists(atPath: zip.path) {
            try FileManager.default.copyItem(at: built.appendingPathComponent(zip.lastPathComponent), to: zip)
        }
        entry["file"] = nil
        entry["url"] = zip.absoluteString
        let base = entry
        return { changes in
            var json = base
            for (key, value) in changes { json[key] = value }
            return DevToolsOffer(json: json, link: { ($0 as? String).flatMap(URL.init(string:)) })
        }
    }

    private func perform(_ command: String, _ arguments: [String: Any], _ tab: PageTab) async throws -> [String: Any] {
        let plugin = try XCTUnwrap(packages.plugin("full"), "the package loads: \(String(describing: packages.states["full"]))")
        return await withCheckedContinuation { done in
            plugin.perform(command, arguments: arguments, webView: tab.web) { done.resume(returning: $0) }
        }
    }

    private func open(_ path: String) async throws -> PageTab {
        if let tab = self.tab { browser.close(tab) }
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        self.tab = tab
        window.contentView = tab.web
        tab.go(to: server.url(path))
        try await waitUntil { tab.committed == self.server.url(path) && !tab.loading && !tab.web.isLoading }
        return tab
    }

    private func waitUntil(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "no window was shown", file: file, line: line)
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out", file: file, line: line)
        throw CancellationError()
    }

    // MARK: - pages

    static let pages: [String: LocalPageServer.Page] = [
        "/app": .init(type: "text/html; charset=utf-8", body: """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>app</title>
            <link rel="stylesheet" href="/app.css"></head>
            <body><h1 id="title" class="big">Hello</h1><ul><li>one</li><li>two</li></ul>
            <script src="/app.js"></script>
            <script>localStorage.setItem("flavour", "vanilla"); document.cookie = "visit=1; path=/";
            console.log("hello from the page"); fetch("/data.json");</script></body></html>
            """),
        "/app.css": .init(type: "text/css", body: "#title { color: rgb(10, 20, 30); margin: 4px; }\n"),
        "/app.js": .init(type: "text/javascript", body: "function compute(n) {\n  const doubled = n * 2;\n  return doubled;\n}\n"),
        "/data.json": .init(type: "application/json", body: "{\"ok\":true}"),
        "/hostile": .init(type: "text/html", body: """
            <!doctype html><html lang="en"><title>hostile</title><body>
            <button id="visible">Press</button>
            <script>
            const before = new Set(Object.getOwnPropertyNames(window));
            const windowSymbols = Object.getOwnPropertySymbols(window).length;
            const documentSymbols = Object.getOwnPropertySymbols(document).length;
            const attributes = Array.from(document.documentElement.attributes).map((a) => a.name);
            const elements = document.getElementsByTagName("*").length;
            const natives = { timeStamp: console.timeStamp, addEventListener: EventTarget.prototype.addEventListener,
              fetch: window.fetch, open: XMLHttpRequest.prototype.open, WebSocket: window.WebSocket,
              getCurrentPosition: navigator.geolocation && navigator.geolocation.getCurrentPosition };
            window.probe = { webkit: typeof window.webkit, globals: [], symbols: [], attributes: [], elements: [], patched: [], posted: "refused" };
            Element.prototype.querySelectorAll = () => [];
            Array.from = Array.from;
            window.attack = () => {
              try { window.webkit.messageHandlers.searchDeveloper.postMessage({ kind: "step" }); window.probe.posted = "sent"; } catch (e) {}
            };
            setInterval(() => {
              if (typeof window.webkit !== "undefined") window.probe.webkit = typeof window.webkit;
              for (const name of Object.getOwnPropertyNames(window)) {
                if (!before.has(name) && !/^\\d+$/.test(name) && !/^temp\\d+$/.test(name) && name !== "probe" && name !== "attack" && !window.probe.globals.includes(name)) window.probe.globals.push(name);
              }
              if (Object.getOwnPropertySymbols(window).length !== windowSymbols || Object.getOwnPropertySymbols(document).length !== documentSymbols) window.probe.symbols = ["changed"];
              for (const a of document.documentElement.attributes) if (!attributes.includes(a.name) && !window.probe.attributes.includes(a.name)) window.probe.attributes.push(a.name);
              const now = document.getElementsByTagName("*");
              if (now.length !== elements) for (const e of now) if (/search|developer|overlay/i.test(e.localName) && !window.probe.elements.includes(e.localName)) window.probe.elements.push(e.localName);
              for (const [name, value] of Object.entries(natives)) {
                const current = { timeStamp: console.timeStamp, addEventListener: EventTarget.prototype.addEventListener,
                  fetch: window.fetch, open: XMLHttpRequest.prototype.open, WebSocket: window.WebSocket,
                  getCurrentPosition: navigator.geolocation && navigator.geolocation.getCurrentPosition }[name];
                if (current !== value && !window.probe.patched.includes(name)) window.probe.patched.push(name);
              }
            }, 50);
            </script></body></html>
            """),
    ]
}
