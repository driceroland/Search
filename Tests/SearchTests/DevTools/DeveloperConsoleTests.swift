import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperConsoleTests: XCTestCase {
    func testConsoleMessagesKeepTheirArgumentsTablesGroupsAndStacks() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Console fixture</title>
                <body id="page-body">
                <script>
                window.sample = {name: "perch", list: [1, 2, 3], nested: {deep: true}};
                window.collection = new Map([["key", 1]]);
                function greet(name) { return "hi " + name; }
                function logAll() {
                    console.log("plain %s and %d", "text", 42.7, sample);
                    console.log("%cstyled", "color: red; font-weight: bold");
                    console.table([{a: 1, b: "x"}, {a: 2, b: "y"}]);
                    console.group("outer");
                    console.log("inside");
                    console.groupEnd();
                    console.error("boom");
                    for (let i = 0; i < 3; i++) console.log("again");
                    console.log(collection);
                    console.log(document.body);
                    console.log("done");
                }
                class Bird {}
                window.bird = new Bird();
                </script>
                """),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // In a window that is on screen, as a tab's page is: a page in no
        // window now and then stops answering the inspector until something
        // else wakes it, and a command waits with it.
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Console fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        watched = session
        do {
            try await wait("inspector") { session.ready }
            session.select(.console)
            _ = try await page.callAsyncJavaScript("logAll(); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await wait("all messages") { session.console.contains { $0.text == "done" } }
            let lines = session.console

            // Format specifiers and the arguments after them.
            let plain = try XCTUnwrap(lines.first { $0.text.hasPrefix("plain") })
            let parameters = try XCTUnwrap(plain.details?.parameters)
            XCTAssertEqual(parameters.count, 4)
            let segments = ConsoleFormat.segments(parameters)
            XCTAssertTrue(ConsoleFormat.plain(segments).hasPrefix("plain text and 42 "), ConsoleFormat.plain(segments))
            guard case .object(let sample, _) = try XCTUnwrap(segments.last) else { return XCTFail("object argument") }
            XCTAssertTrue(sample.expandable)
            XCTAssertEqual(ConsoleFormat.inline(sample), "{name: 'perch', list: Array(3), nested: {deep: true}}")

            // %c styles the text that follows it.
            let styled = try XCTUnwrap(lines.first { $0.text.contains("styled") })
            let styledSegments = ConsoleFormat.segments(try XCTUnwrap(styled.details?.parameters))
            guard case .text("styled", let style) = try XCTUnwrap(styledSegments.first) else { return XCTFail("styled text") }
            XCTAssertEqual(style.color, ConsoleColor(red: 1, green: 0, blue: 0))
            XCTAssertTrue(style.bold)

            // console.table reads its rows from the preview.
            let tableLine = try XCTUnwrap(lines.first { $0.details?.type == "table" })
            let table = try XCTUnwrap(ConsoleTable(try XCTUnwrap(tableLine.details?.parameters.first)))
            XCTAssertEqual(table.columns, ["a", "b"])
            XCTAssertEqual(table.rows.map(\.index), ["0", "1"])
            XCTAssertEqual(table.rows.last?.cells["b"]?.text, "'y'")

            // Groups indent and collapse what they hold.
            let rows = ConsoleLayout.rows(lines, levels: ConsoleLevel.defaults, filter: "", toggled: [])
            let header = try XCTUnwrap(rows.first { $0.opensGroup })
            XCTAssertEqual(header.line.text, "outer")
            XCTAssertEqual(rows.first { $0.line.text == "inside" }?.depth, 1)
            let collapsed = ConsoleLayout.rows(lines, levels: ConsoleLevel.defaults, filter: "", toggled: [header.line.id])
            XCTAssertFalse(collapsed.contains { $0.line.text == "inside" })
            XCTAssertTrue(ConsoleLayout.rows(lines, levels: [.errors], filter: "", toggled: []).allSatisfy { $0.line.level == "error" })

            // console.error carries the stack that led to it.
            let error = try XCTUnwrap(lines.first { $0.text == "boom" })
            XCTAssertEqual(error.level, "error")
            let frame = try XCTUnwrap(error.details?.stackTrace.first)
            XCTAssertEqual(frame.functionName, "logAll")
            XCTAssertEqual(URL(string: frame.url)?.path, "/")
            XCTAssertEqual(frame.lineNumber, 14)

            // Repeated messages fold into one with a count.
            try await wait("repeat count") { session.console.first { $0.text == "again" }?.repeatCount == 3 }
            XCTAssertEqual(session.console.filter { $0.text == "again" }.count, 1)

            // An object opens into its properties, then [[Prototype]].
            session.loadConsoleProperties(sample, targetID: plain.details?.targetID)
            let sampleID = try XCTUnwrap(sample.objectId)
            try await wait("object properties") { session.consoleStore.properties[sampleID] != nil }
            let properties = try XCTUnwrap(session.consoleStore.properties[sampleID])
            XCTAssertEqual(Array(properties.map(\.name).prefix(3)), ["name", "list", "nested"])
            XCTAssertEqual(properties.last?.name, "[[Prototype]]")
            XCTAssertEqual(properties.first?.value?.value, .string("perch"))
            let list = try XCTUnwrap(properties.first { $0.name == "list" }?.value)
            XCTAssertEqual(ConsoleFormat.inline(list), "(3) [1, 2, 3]")

            // A Map shows its entries.
            let mapLine = try XCTUnwrap(session.console.first { $0.details?.parameters.first?.subtype == "map" })
            let map = try XCTUnwrap(mapLine.details?.parameters.first)
            XCTAssertEqual(ConsoleFormat.inline(map), "Map(1) {'key' => 1}")
            session.loadConsoleProperties(map, targetID: mapLine.details?.targetID)
            try await wait("map entries") { session.consoleStore.properties[map.objectId ?? ""] != nil }
            let entries = session.consoleStore.properties[map.objectId ?? ""]?.first { $0.name == "[[Entries]]" }?.entries
            XCTAssertEqual(entries?.first?.key?.value, .string("key"))

            // A node reveals itself in Elements, and becomes $0.
            let nodeLine = try XCTUnwrap(session.console.first { $0.details?.parameters.first?.subtype == "node" })
            let node = try XCTUnwrap(nodeLine.details?.parameters.first)
            session.revealConsoleNode(node, targetID: nodeLine.details?.targetID)
            try await wait("revealed node") {
                session.panel == .elements && session.selectedNode.flatMap { session.nodes[$0]?.name } == "body"
            }
            session.select(.console)
            session.evaluate("$0.id")
            try await wait("$0") { session.console.contains { $0.level == "result" && $0.text == "'page-body'" } }

            // Results stay expandable, and $_ follows them.
            session.evaluate("6 * 7")
            try await wait("result") { session.console.contains { $0.level == "result" && $0.text == "42" } }
            session.evaluate("$_ + 1")
            try await wait("$_") { session.console.contains { $0.level == "result" && $0.text == "43" } }
            session.evaluate("sample")
            try await wait("object result") {
                session.console.last?.level == "result" && session.console.last?.details?.parameters.first?.objectId != nil
            }
            let result = try XCTUnwrap(session.console.last?.details?.parameters.first)
            session.loadConsoleProperties(result, targetID: nil)
            try await wait("result properties") { session.consoleStore.properties[result.objectId ?? ""]?.isEmpty == false }
            session.evaluate("{answer: 42}")
            try await wait("object literal") { session.console.last?.text == "{answer: 42}" }
            session.evaluate("missing.value")
            try await wait("thrown") { session.console.last?.level == "error" && session.console.last?.text.hasPrefix("Uncaught") == true }

            // The eager preview only reads; a call gets none.
            let eager = await session.consoleEagerPreview("sample.list.length")
            XCTAssertEqual(eager?.value, .number(3))
            let arithmetic = await session.consoleEagerPreview("(2 + 3) * 4")
            XCTAssertEqual(arithmetic?.value, .number(20))
            let call = await session.consoleEagerPreview("logAll()")
            XCTAssertNil(call)
            let count = session.console.count
            let getter = await session.consoleEagerPreview("document.title")
            XCTAssertEqual(getter?.value, .string("Console fixture"))
            XCTAssertEqual(session.console.count, count, "eager evaluation logs nothing")

            // Completions for a property and for a global.
            let member = await session.consoleCompletions("sample.na")
            XCTAssertEqual(member.prefix, "na")
            XCTAssertEqual(member.names.first, "name")
            let global = await session.consoleCompletions("docu")
            XCTAssertTrue(global.names.contains("document"))

            // $1 is the node picked before $0, as in Chrome.
            let html = try XCTUnwrap(session.nodes.values.first { $0.name.lowercased() == "html" && $0.type == 1 }?.id)
            session.selectNode(html)
            session.evaluate("$1.id + ' ' + $0.tagName")
            try await wait("$1") { session.console.contains { $0.level == "result" && $0.text == "'page-body HTML'" } }

            // Store as global variable makes temp1 and logs it.
            session.storeConsoleObjectAsGlobal(sample, targetID: plain.details?.targetID)
            try await wait("temp1") { session.console.contains { $0.level == "command" && $0.text == "temp1" } }
            let stored = try await page.callAsyncJavaScript("return window.temp1 === window.sample;", arguments: [:],
                                                            in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(stored, true)

            // queryObjects() is WebKit's queryInstances().
            session.evaluate("queryObjects(Bird).length")
            try await wait("queryObjects") { session.console.last?.level == "result" && session.console.last?.text == "1" }

            // monitor() logs each call in Chrome's words, unmonitor() stops it.
            session.evaluate("monitor(greet)")
            try await wait("monitor") { session.console.last?.level == "result" && session.console.last?.text == "undefined" }
            _ = try await page.callAsyncJavaScript("greet('perch'); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await wait("monitored call") { session.console.contains { $0.text == "function greet called with arguments: perch" } }
            session.evaluate("unmonitor(greet)")
            try await wait("unmonitor") { session.console.last?.level == "result" }
            _ = try await page.callAsyncJavaScript("greet('again'); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertFalse(session.console.contains { $0.text.contains("with arguments: again") })

            // A live expression shows its current value.
            session.consoleStore.liveExpressions = [ConsoleLiveExpression(expression: "sample.list.length")]
            await session.refreshLiveExpressions()
            XCTAssertEqual(session.consoleStore.liveExpressions.first?.result, "3")
            session.consoleStore.liveExpressions = []

            // Log XMLHttpRequests: a verbose line when a fetch finishes.
            let saved = session.consoleStore.settings
            session.consoleStore.settings.logXMLHttpRequests = true
            _ = try await page.callAsyncJavaScript("await fetch('/?xhr'); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await wait("XHR log") {
                session.console.contains { $0.level == "debug" && $0.text.hasPrefix("Fetch finished loading: GET \"") }
            }
            session.consoleStore.settings = saved

            // console.clear() from the page.
            _ = try await page.callAsyncJavaScript("console.clear(); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await wait("cleared") { session.console.contains { $0.details?.type == "clear" } }
            XCTAssertFalse(session.console.contains { $0.text == "done" })
            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    func testFormatSpecifiersAndPreviews() {
        let format = ConsoleRemoteObject(type: "string", value: .string("%s is %d%% done, %.1f left %o %c!"))
        let arguments = [
            format,
            ConsoleRemoteObject(type: "string", value: .string("job")),
            ConsoleRemoteObject(type: "number", value: .number(99.9)),
            ConsoleRemoteObject(type: "number", value: .number(0.25)),
            ConsoleRemoteObject(type: "object", objectId: "1", preview: ConsoleObjectPreview(type: "object", properties: [
                .init(name: "a", type: "number", value: "1"),
            ])),
            ConsoleRemoteObject(type: "string", value: .string("color: #0f0; background: rgb(0, 0, 255)")),
            ConsoleRemoteObject(type: "string", value: .string("extra")),
        ]
        let segments = ConsoleFormat.segments(arguments)
        XCTAssertEqual(ConsoleFormat.plain(segments), "job is 99% done, 0.2 left {a: 1} ! extra")
        guard case .text("!", let style) = segments[segments.count - 3] else { return XCTFail("styled run") }
        XCTAssertEqual(style.color, ConsoleColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(style.background, ConsoleColor(red: 0, green: 0, blue: 1))

        // A directive without an argument is left as written.
        XCTAssertEqual(ConsoleFormat.plain(ConsoleFormat.segments([ConsoleRemoteObject(type: "string", value: .string("%s and %d"))])),
                       "%s and %d")
        XCTAssertEqual(ConsoleFormat.function("function greet(name) { return name }"), "ƒ greet(name)")
        XCTAssertEqual(ConsoleFormat.function("(a, b) => a + b"), "ƒ (a, b)")
        let set = ConsoleObjectPreview(type: "object", subtype: "set", size: 2, entries: [
            .init(key: nil, value: ConsoleObjectPreview(type: "number", description: "1")),
            .init(key: nil, value: ConsoleObjectPreview(type: "string", description: "b")),
        ])
        XCTAssertEqual(ConsoleFormat.inline(set, className: "Set"), "Set(2) {1, 'b'}")
        XCTAssertEqual(ConsoleLevel.label(ConsoleLevel.defaults), "Default levels")
        XCTAssertEqual(ConsoleLevel.label([.errors]), "Errors only")
        XCTAssertEqual(ConsoleLevel.label(Set(ConsoleLevel.allCases)), "All levels")
    }

    func testFiltersSidebarAndSimilarMessages() {
        typealias Line = DeveloperToolsSession.ConsoleLine
        func log(_ level: String, _ text: String, url: String? = nil, source: String = "console-api", count: Int = 1) -> Line {
            Line(level: level, text: text, url: url, line: url == nil ? nil : 3, repeatCount: count,
                 details: ConsoleMessageDetails(source: source, type: "log"))
        }
        let lines = [
            log("log", "hello", url: "https://a.test/app.js"),
            log("error", "failed", url: "https://cdn.test/lib.js"),
            log("log", "hello", url: "https://a.test/app.js", count: 2),
            log("warning", "Origin x is not allowed by Access-Control-Allow-Origin.", source: "network"),
            log("debug", "detail", url: "https://a.test/app.js"),
        ]
        let all = Set(ConsoleLevel.allCases)
        func texts(_ rows: [ConsoleRow]) -> [String] { rows.map(\.line.text) }

        // Chrome's filter syntax.
        XCTAssertEqual(texts(ConsoleLayout.rows(lines, levels: all, filter: "-url:cdn.test hello", toggled: [])), ["hello"])
        XCTAssertEqual(texts(ConsoleLayout.rows(lines, levels: all, filter: "/^fail/", toggled: [])), ["failed"])
        XCTAssertEqual(texts(ConsoleLayout.rows(lines, levels: all, filter: "-hello -detail", toggled: [])).count, 2)

        // Group similar messages folds the later "hello" into the first.
        let grouped = ConsoleLayout.rows(lines, levels: all, filter: "", toggled: [])
        XCTAssertEqual(grouped.first?.count, 3)
        XCTAssertEqual(grouped.filter { $0.line.text == "hello" }.count, 1)
        var settings = ConsoleSettings()
        settings.groupSimilar = false
        let separate = ConsoleLayout.rows(lines, levels: all, filter: "", toggled: [], settings: settings)
        XCTAssertEqual(separate.filter { $0.line.text == "hello" }.count, 3)
        XCTAssertEqual(Set(separate.map(\.id)).count, separate.count)

        // Network messages off hides network-sourced messages.
        settings = ConsoleSettings()
        settings.networkMessages = false
        XCTAssertFalse(texts(ConsoleLayout.rows(lines, levels: all, filter: "", toggled: [], settings: settings)).contains { $0.hasPrefix("Origin") })

        // The sidebar counts and filters, and overrides the levels menu.
        let tally = ConsoleSidebarFilter.tally(lines)
        XCTAssertEqual(tally[.messages]?.count, 6)
        XCTAssertEqual(tally[.user]?.count, 5)
        XCTAssertEqual(tally[.errors]?.count, 1)
        XCTAssertEqual(tally[.verbose]?.count, 1)
        XCTAssertEqual(ConsoleSidebarGroup.errors.title(1), "1 error")
        XCTAssertEqual(ConsoleSidebarGroup.warnings.title(0), "No warnings")
        XCTAssertEqual(tally[.messages]?.files.first?.url, "https://a.test/app.js")
        let verbose = ConsoleLayout.rows(lines, levels: ConsoleLevel.defaults, filter: "", toggled: [],
                                         sidebar: ConsoleSidebarFilter(group: .verbose))
        XCTAssertEqual(texts(verbose), ["detail"])
        let file = ConsoleLayout.rows(lines, levels: all, filter: "", toggled: [],
                                      sidebar: ConsoleSidebarFilter(group: .messages, url: "https://cdn.test/lib.js"))
        XCTAssertEqual(texts(file), ["failed"])
    }

    func testIncompleteInputKeepsEditing() {
        XCTAssertTrue(ConsoleInput.isIncomplete("function f() {"))
        XCTAssertTrue(ConsoleInput.isIncomplete("[1, 2,"))
        XCTAssertTrue(ConsoleInput.isIncomplete("`multi"))
        XCTAssertFalse(ConsoleInput.isIncomplete("f('{')"))
        XCTAssertFalse(ConsoleInput.isIncomplete("1 + 1 // (comment"))
        XCTAssertFalse(ConsoleInput.isIncomplete("({a: 1})"))
    }

    /// debug(fn) pauses the function's next call where it starts, as in
    /// Chrome; undebug(fn) lets it run again.
    func testDebugPausesTheFunctionsNextCallAndUndebugStopsIt() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Debug fixture</title>
                <script>
                window.calls = 0;
                function greet(name) {
                    window.calls++;
                    return "hi " + name;
                }
                window.later = () => setTimeout(() => greet("perch"), 0);
                </script>
                """),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Debug fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        watched = session
        let debugger = session.debugger
        do {
            try await wait("inspector") { session.ready }
            session.select(.console)
            session.evaluate("debug(greet)")
            try await wait("debug") { session.console.last?.level == "result" && session.console.last?.text == "undefined" }
            // Called from a timer, so the page isn't held waiting on this test.
            _ = try await page.callAsyncJavaScript("later(); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await wait("paused in greet") { debugger.pause != nil }
            XCTAssertEqual(debugger.pause?.frames.first?.functionName, "greet")
            debugger.step("resume")
            try await wait("resume") { debugger.pause == nil }
            let first = try await page.callAsyncJavaScript("return window.calls;", arguments: [:], in: nil, contentWorld: .page) as? Int
            XCTAssertEqual(first, 1)

            session.evaluate("undebug(greet)")
            try await wait("undebug") { session.console.last?.level == "result" }
            _ = try await page.callAsyncJavaScript("later(); return true;", arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertNil(debugger.pause, "greet runs without pausing after undebug()")
            let second = try await page.callAsyncJavaScript("return window.calls;", arguments: [:], in: nil, contentWorld: .page) as? Int
            XCTAssertEqual(second, 2)

            // A value that isn't a function is refused.
            let before = session.console.count
            session.evaluate("debug(42)")
            try await wait("refused") { session.console.dropFirst(before).contains { $0.level == "error" } }
            XCTAssertNil(debugger.pause)
            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            if debugger.pause != nil { debugger.step("resume") }
            await session.disconnect().value
            throw error
        }
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: 8, in: "DeveloperConsoleTests", state: { [watched] in
            guard let watched else { return "" }
            let last = watched.console.suffix(4).map { "\($0.level): \($0.text.prefix(60))" }.joined(separator: " | ")
            return "ready \(watched.ready), message \(watched.message ?? "none"), last: \(last)"
        }, until: condition)
    }
}
