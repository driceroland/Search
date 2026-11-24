import AppKit
import WebKit
import XCTest
@testable import Search

/// Source maps, Layers, CSS overview and header overrides against a real
/// page and WebKit's real inspector: each checks what the tool's own model
/// makes of what the protocol says (a map fetched and read, a pause and a
/// breakpoint moved through it, the layer tree and its compositing reasons,
/// the overview's capture, a response answered with a `.headers` rule).
/// Pages come from a loopback server with inline content; nothing leaves
/// the machine.
@MainActor
final class DeveloperNewToolsLive2Tests: XCTestCase {
    // MARK: AI assistance's run-JavaScript tool

    func testAIScriptRunsInThePageOnlyOnceApproved() async throws {
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>AI run fixture</title><p id=p>x</p>"),
            "/next": .init(type: "text/html", body: "<!doctype html><title>Next page</title>"),
        ], title: "AI run fixture")
        defer { live.window.close() }
        let assistance = live.session.aiAssistance
        defer { assistance.stop() }
        assistance.beginResponseForTesting()

        func pending() -> DeveloperAIAssistance.Message? {
            assistance.messages.last { $0.script?.state == .pending }
        }

        // Declined: shown, never run.
        let declined = Task { await assistance.requestRun("window.ran = 1; document.title") }
        try await wait("script card") { pending() != nil }
        XCTAssertTrue(assistance.awaitingApproval)
        assistance.decide(try XCTUnwrap(pending()).id, run: false)
        let declinedAnswer = await declined.value
        XCTAssertEqual(declinedAnswer, DeveloperAIAssistance.declined)
        XCTAssertEqual(assistance.messages.last?.script?.state, .declined)
        let ranAfterDecline = try await page(live.page, "return window.ran ?? null")
        XCTAssertTrue(ranAfterDecline is NSNull || ranAfterDecline == nil)

        // Approved: runs, with top-level await, its value read back.
        let approved = Task { await assistance.requestRun("await Promise.resolve(1);\n({title: document.title, text: document.getElementById('p').textContent})") }
        try await wait("second card") { pending() != nil }
        assistance.decide(try XCTUnwrap(pending()).id, run: true)
        let answer = await approved.value
        XCTAssertEqual(answer, #"Result: {"text":"x","title":"AI run fixture"}"#)
        XCTAssertEqual(assistance.messages.last?.script?.state, .ran)

        // Thrown: reported as such.
        let thrown = Task { await assistance.requestRun("nope.nope") }
        try await wait("third card") { pending() != nil }
        assistance.decide(try XCTUnwrap(pending()).id, run: true)
        let thrownAnswer = await thrown.value
        XCTAssertTrue(thrownAnswer.hasPrefix("The code threw: ReferenceError"), thrownAnswer)
        XCTAssertEqual(assistance.messages.last?.script?.state, .threw)

        // Stop: what waits is declined.
        let stopped = Task { await assistance.requestRun("window.ran = 2") }
        try await wait("fourth card") { pending() != nil }
        assistance.stop()
        let stoppedAnswer = await stopped.value
        XCTAssertEqual(stoppedAnswer, DeveloperAIAssistance.declined)
        XCTAssertFalse(assistance.awaitingApproval)
        let ranAfterStop = try await page(live.page, "return window.ran ?? null")
        XCTAssertTrue(ranAfterStop is NSNull || ranAfterStop == nil)
        // Stopped, a late call is turned away without a card.
        let late = await assistance.requestRun("window.ran = 3")
        XCTAssertEqual(late, DeveloperAIAssistance.declined)
        XCTAssertNil(pending())

        // Navigation cancels approval for the previous document.
        assistance.beginResponseForTesting()
        let navigating = Task { await assistance.requestRun("window.ran = 4") }
        try await wait("script card before navigation") { pending() != nil }
        let card = try XCTUnwrap(pending())
        live.page.load(URLRequest(url: live.server.url("/next")))
        try await wait("navigation to cancel the card") { live.page.title == "Next page" && !assistance.awaitingApproval }
        assistance.decide(card.id, run: true)
        let navigationAnswer = await navigating.value
        XCTAssertEqual(navigationAnswer, DeveloperAIAssistance.declined)
        let ranAfterNavigation = try await page(live.page, "return window.ran ?? null")
        XCTAssertTrue(ranAfterNavigation is NSNull || ranAfterNavigation == nil)
        await live.finish()
    }

    // MARK: Source maps

    // 0-based lines, as the protocol and the map count them.
    private static let bundle = """
        /* bundle.js: compiled */
        (function () {
        "use strict";
        function greet(name) {
        debugger;
        window.greeted = "hi " + name;
        return window.greeted;
        }
        window.greet = greet;
        })();
        //# sourceMappingURL=bundle.js.map
        """

    private static let appTS = """
        // src/app.ts, the authored file (perch-authored-marker)
        export function greet(name: string): string {
            debugger;
            window.greeted = "hi " + name;
            return window.greeted;
        }
        (window as any).greet = greet;
        """

    /// bundle.js line → app.ts line (both 0-based), at the columns where
    /// each statement starts.
    private static let bundleSegments: [Segment] = [
        Segment(line: 3, column: 0, originalLine: 1, originalColumn: 0),
        Segment(line: 4, column: 0, originalLine: 2, originalColumn: 4),
        Segment(line: 5, column: 0, originalLine: 3, originalColumn: 4),
        Segment(line: 6, column: 0, originalLine: 4, originalColumn: 4),
        Segment(line: 7, column: 0, originalLine: 5, originalColumn: 0),
        Segment(line: 8, column: 0, originalLine: 6, originalColumn: 0),
    ]

    func testSourceMapLoadsAndMovesThePauseAndBreakpointsToTheAuthoredFile() async throws {
        let map = try Self.mapJSON(file: "bundle.js", source: "src/app.ts", content: Self.appTS,
                                   segments: Self.bundleSegments)
        let live = try await open([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Source map fixture</title>
                <p>source maps</p>
                <script src="/bundle.js"></script>
                """),
            "/bundle.js": .init(type: "text/javascript", body: Self.bundle),
            "/bundle.js.map": .init(type: "application/json", body: map),
        ], title: "Source map fixture")
        defer { live.window.close() }
        let session = live.session
        let maps = session.sourceMaps
        let debugger = session.debugger
        let bundleURL = live.server.url("/bundle.js").absoluteString
        let appURL = live.server.url("/src/app.ts").absoluteString
        do {
            // Sources reads the page's files; the frontend has the script's
            // sourceMappingURL from before DevTools listened.
            session.select(.sources)
            try await wait("the map of bundle.js", seconds: 15, state: {
                "resources \(session.resources.map(\.url)), authored \(maps.authoredResources.map(\.url)),"
                    + " requests \(live.server.requests)"
            }) {
                maps.isAuthored(appURL)
            }
            XCTAssertTrue(live.server.requests.contains("/bundle.js.map"), "\(live.server.requests)")
            XCTAssertEqual(maps.authoredResources.map(\.url), [appURL])
            XCTAssertEqual(maps.authoredResources.first?.type, DeveloperSourceMaps.authoredType)
            XCTAssertTrue(maps.isAuthoredScript(appURL))
            XCTAssertEqual(maps.authoredCount(for: bundleURL), 1)
            XCTAssertTrue(DeveloperDebugger.sameScript(maps.compiledFile(for: appURL) ?? "", bundleURL),
                          maps.compiledFile(for: appURL) ?? "nil")
            let content = await maps.content(of: appURL)
            XCTAssertEqual(content, Self.appTS)

            // The lookups both ways.
            XCTAssertEqual(maps.original(url: bundleURL, line: 4, column: 0),
                           DeveloperSourceMap.Original(url: appURL, line: 2, column: 4, name: nil))
            let generated = try XCTUnwrap(maps.generated(url: appURL, line: 3))
            XCTAssertTrue(DeveloperDebugger.sameScript(generated.url, bundleURL), generated.url)
            XCTAssertEqual(generated.line, 5)
            XCTAssertEqual(generated.column, 0)
            XCTAssertEqual(maps.linked(url: bundleURL, line: 6, column: 1).url, appURL)
            XCTAssertEqual(maps.linked(url: bundleURL, line: 6, column: 1).line, 4)

            // The navigator: top › 127.0.0.1:port › src › app.ts, in the page's own origin's node, as Chrome.
            let authored = try XCTUnwrap(maps.authoredResources.first)
            let nodes = SourceTree.build(session.resources, frames: session.resourceFrames, authored: maps.authoredResources)
            let origin = "127.0.0.1:\(live.server.port)"
            let top = try XCTUnwrap(nodes.first)
            XCTAssertEqual(top.name, "top")
            XCTAssertEqual(SourceTree.ancestors(of: authored.id, in: nodes),
                           [top.id, top.id + "|o:" + origin, "authored|o:" + origin + "/src"])
            XCTAssertEqual(top.children.filter { $0.name == origin }.count, 1)
            XCTAssertEqual(top.children.first?.id, top.id + "|o:" + origin)
            let folder = try XCTUnwrap(top.children.first?.children.first)
            XCTAssertEqual(folder.name, "src")
            XCTAssertEqual(folder.children.map(\.name), ["app.ts"])
            XCTAssertEqual(folder.children.first?.kind, .file(authored))

            // Sources › Search finds the authored file's own text (a comment
            // the bundle doesn't have), and its result opens that file.
            let search = DeveloperSourcesSearchModel.of(session)
            search.query = "perch-authored-marker"
            search.matchCase = false
            search.regex = false
            search.search()
            try await wait("the search", state: { "status \(search.status ?? "nil"), results \(search.results.map(\.resource.url))" }) {
                !search.searching && search.status != nil
            }
            XCTAssertEqual(search.results.map(\.resource.url), [appURL], search.status ?? "")
            let result = try XCTUnwrap(search.results.first)
            XCTAssertEqual(result.resource.type, DeveloperSourceMaps.authoredType)
            XCTAssertEqual(result.matches.map(\.line), [1])
            let firstLine = Self.appTS.components(separatedBy: "\n")[0] as NSString
            XCTAssertEqual(result.matches.first?.column, firstLine.range(of: "perch-authored-marker").location + 1)
            XCTAssertEqual(search.status, "Search finished. Found 1 matching line in 1 file.")
            // The result row's action.
            let match = try XCTUnwrap(result.matches.first)
            session.revealSource(url: result.resource.url, line: match.line, column: match.column)
            XCTAssertEqual(session.sourceReveal?.url, appURL)
            XCTAssertEqual(session.sourceReveal?.line, 1)
            XCTAssertEqual(session.sourceReveal?.column, match.column)
            try await wait("app.ts in the editor", state: {
                "open \(session.sourceResource?.url ?? "nil"), text \(session.source?.prefix(60) ?? "nil")"
            }) {
                session.sourceResource?.url == appURL && session.source == Self.appTS
            }
            XCTAssertEqual(session.sourceResource?.type, DeveloperSourceMaps.authoredType)

            // A real pause on `debugger;` in the bundle shows where it is in app.ts.
            _ = try? await session.command("Debugger.setPauseOnDebuggerStatements", ["enabled": true])
            try await trigger(live.page, "setTimeout(() => greet('x'), 0)")
            try await wait("the pause on debugger;", seconds: 10, state: { Self.describe(debugger) }) {
                debugger.frame != nil
            }
            let frame = try XCTUnwrap(debugger.frame)
            XCTAssertEqual(frame.functionName, "greet")
            XCTAssertTrue(DeveloperDebugger.sameScript(frame.url, bundleURL), frame.url)
            XCTAssertEqual(frame.line, 4)
            XCTAssertEqual(frame.original?.url, appURL)
            XCTAssertEqual(frame.original?.line, 2)
            XCTAssertEqual(frame.location, "app.ts:3")
            XCTAssertEqual(frame.generatedLocation, "bundle.js:5")
            XCTAssertEqual(debugger.executionLine(for: appURL), 3)
            XCTAssertEqual(debugger.revealed?.url, appURL)
            XCTAssertEqual(debugger.revealed?.line, 3)

            // A breakpoint set in app.ts goes on the bundle's line 6 (1-based)
            // and the page stops there.
            debugger.setBreakpoint(url: appURL, line: 4, kind: .regular, expression: "")
            try await wait("the breakpoint to resolve", state: { Self.describe(debugger) }) {
                debugger.breakpoints.first?.resolved == true
            }
            XCTAssertEqual(debugger.breakpoints.first?.url, appURL)
            XCTAssertEqual(debugger.breakpoints.first?.line, 4)
            XCTAssertEqual(debugger.lines(in: appURL), [4])
            debugger.step("resume")
            try await wait("the pause on the app.ts breakpoint", seconds: 10, state: { Self.describe(debugger) }) {
                debugger.pause?.reason == "Breakpoint" && debugger.frame?.line == 5
            }
            let stopped = try XCTUnwrap(debugger.frame)
            XCTAssertEqual(debugger.pausedBreakpoint?.url, appURL)
            XCTAssertEqual(stopped.original?.url, appURL)
            XCTAssertEqual(stopped.original?.line, 3)
            XCTAssertEqual(stopped.location, "app.ts:4")
            XCTAssertEqual(debugger.executionLine(for: appURL), 4)
            debugger.step("resume")
            try await wait("resume", state: { Self.describe(debugger) }) { debugger.pause == nil }
            let greeted = try await page(live.page, "return window.greeted;") as? String
            XCTAssertEqual(greeted, "hi x")
            debugger.removeBreakpoints()
            await debugger.settled()
        } catch {
            if debugger.pause != nil { debugger.step("resume") }
            await live.finish()
            throw error
        }
        await live.finish()
    }

    func testInlineDataURLSourceMapOfAScriptAddedLater() async throws {
        // 0-based lines.
        let inlineTS = """
            // src/inline.ts (perch-inline-marker)

            export function twice(n: number): number {
                return n * 2;
            }
            (window as any).twice = twice;
            """
        let map = try Self.mapJSON(file: "inline.js", source: "src/inline.ts", content: inlineTS, segments: [
            Segment(line: 1, column: 0, originalLine: 2, originalColumn: 0),
            Segment(line: 2, column: 0, originalLine: 3, originalColumn: 4),
            Segment(line: 3, column: 0, originalLine: 4, originalColumn: 0),
            Segment(line: 4, column: 0, originalLine: 5, originalColumn: 0),
        ])
        let script = """
            (function () {
            function twice(n) {
            return n * 2;
            }
            window.twice = twice;
            })();
            //# sourceMappingURL=data:application/json;charset=utf-8;base64,\(Data(map.utf8).base64EncodedString())
            """
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>Inline map fixture</title><p>inline</p>"),
            "/inline.js": .init(type: "text/javascript", body: script),
        ], title: "Inline map fixture")
        defer { live.window.close() }
        let session = live.session
        let maps = session.sourceMaps
        let debugger = session.debugger
        let scriptURL = live.server.url("/inline.js").absoluteString
        // Relative to the script: a data: map has no address of its own.
        let inlineURL = live.server.url("/src/inline.ts").absoluteString
        do {
            session.select(.sources)
            try await wait("the page's files") { !session.resources.isEmpty }
            // Parsed while DevTools listens: Debugger.scriptParsed brings the map.
            _ = try await page(live.page, """
                const element = document.createElement("script");
                element.src = "/inline.js";
                await new Promise((resolve, reject) => {
                    element.onload = resolve;
                    element.onerror = reject;
                    document.head.append(element);
                });
                return typeof window.twice;
                """)
            try await wait("the inline map", seconds: 15, state: {
                "authored \(maps.authoredResources.map(\.url)), resources \(session.resources.map(\.url))"
            }) {
                maps.isAuthored(inlineURL)
            }
            XCTAssertEqual(maps.authoredResources.map(\.url), [inlineURL])
            XCTAssertTrue(DeveloperDebugger.sameScript(maps.compiledFile(for: inlineURL) ?? "", scriptURL),
                          maps.compiledFile(for: inlineURL) ?? "nil")
            XCTAssertFalse(live.server.requests.contains { $0.hasSuffix(".map") || $0.hasPrefix("/src/") },
                           "\(live.server.requests)")
            let content = await maps.content(of: inlineURL)
            XCTAssertEqual(content, inlineTS)
            XCTAssertEqual(maps.original(url: scriptURL, line: 2, column: 0),
                           DeveloperSourceMap.Original(url: inlineURL, line: 3, column: 4, name: nil))
            XCTAssertEqual(maps.original(url: scriptURL, line: 2, column: 9)?.line, 3)
            XCTAssertNil(maps.original(url: scriptURL, line: 0, column: 0), "the wrapper has no authored place")
            let returnLine = try XCTUnwrap(maps.generated(url: inlineURL, line: 3))
            XCTAssertEqual(returnLine.line, 2)
            XCTAssertEqual(returnLine.column, 0)
            // A blank authored line moves on to the next one with code.
            XCTAssertEqual(maps.generated(url: inlineURL, line: 1)?.line, 1)

            // A breakpoint in inline.ts stops the page on the script's line.
            debugger.setBreakpoint(url: inlineURL, line: 4, kind: .regular, expression: "")
            try await wait("the breakpoint to resolve", state: { Self.describe(debugger) }) {
                debugger.breakpoints.first?.resolved == true
            }
            try await trigger(live.page, "setTimeout(() => { window.doubled = twice(21); }, 0)")
            try await wait("the pause in inline.ts", seconds: 10, state: { Self.describe(debugger) }) {
                debugger.pause?.reason == "Breakpoint"
            }
            let frame = try XCTUnwrap(debugger.frame)
            XCTAssertEqual(frame.functionName, "twice")
            XCTAssertEqual(frame.line, 2)
            XCTAssertEqual(frame.original?.url, inlineURL)
            XCTAssertEqual(frame.original?.line, 3)
            XCTAssertEqual(frame.location, "inline.ts:4")
            debugger.step("resume")
            try await wait("resume", state: { Self.describe(debugger) }) { debugger.pause == nil }
            let doubled = try await page(live.page, "return window.doubled;") as? Int
            XCTAssertEqual(doubled, 42)
            debugger.removeBreakpoints()
            await debugger.settled()
        } catch {
            if debugger.pause != nil { debugger.step("resume") }
            await live.finish()
            throw error
        }
        await live.finish()
    }

    // MARK: Layers

    func testLayersListsThePromotedElementsAndWhy() async throws {
        let live = try await open(["/": .init(type: "text/html", body: """
            <!doctype html><title>Layers fixture</title>
            <style>
            #will { will-change: transform; width: 160px; height: 40px; background: rgb(200, 220, 255); }
            #lifted { transform: translateZ(0); width: 160px; height: 40px; background: rgb(255, 220, 200); }
            </style>
            <div id="will">will-change</div>
            <div id="lifted">translateZ</div>
            """)], title: "Layers fixture")
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperLayers.model(for: session)
        func layer(_ label: String) -> DeveloperLayer? { model.layers.first { model.label($0) == label } }
        do {
            try await wait("the document") { session.root != nil }
            model.start()
            try await wait("the two promoted layers", seconds: 15, state: {
                "layers \(model.layers.map { model.label($0) }), problem \(model.problem ?? "none"), loaded \(model.loaded)"
            }) {
                layer("div#will") != nil && layer("div#lifted") != nil
            }
            XCTAssertNil(model.problem)
            XCTAssertGreaterThanOrEqual(model.layers.count, 2)
            let will = try XCTUnwrap(layer("div#will"))
            let lifted = try XCTUnwrap(layer("div#lifted"))
            XCTAssertNotEqual(will.id, lifted.id)
            XCTAssertGreaterThan(will.nodeId, 0)
            XCTAssertEqual(will.bounds.width, 160, accuracy: 0.5)
            XCTAssertEqual(will.bounds.height, 40, accuracy: 0.5)
            XCTAssertEqual(lifted.bounds.width, 160, accuracy: 0.5)
            XCTAssertGreaterThan(lifted.bounds.y, will.bounds.y)

            // Each one's node is the element it names.
            let resolved = try await session.command("DOM.resolveNode", ["nodeId": will.nodeId], targetID: session.domTargetID)
            let objectID = try XCTUnwrap((resolved["object"] as? [String: Any])?["objectId"] as? String, "\(resolved)")
            let reply = try await session.command("Runtime.callFunctionOn", [
                "objectId": objectID, "functionDeclaration": "function() { return this.id; }", "returnByValue": true,
            ], targetID: session.domTargetID)
            XCTAssertEqual((reply["result"] as? [String: Any])?["value"] as? String, "will")

            // Why each was given a layer.
            let willChange = try XCTUnwrap(DeveloperLayerReasons.known.first { $0.key == "willChange" }?.label)
            let transform3D = try XCTUnwrap(DeveloperLayerReasons.known.first { $0.key == "transform3D" }?.label)
            model.selection = will.id
            try await wait("the will-change layer's reasons", state: { "reasons \(model.reasons)" }) {
                model.reasons[will.id] != nil
            }
            XCTAssertTrue(model.reasons[will.id]?.contains(willChange) == true, "\(model.reasons[will.id] ?? [])")
            model.selection = lifted.id
            try await wait("the translateZ layer's reasons", state: { "reasons \(model.reasons)" }) {
                model.reasons[lifted.id] != nil
            }
            XCTAssertTrue(model.reasons[lifted.id]?.contains(transform3D) == true, "\(model.reasons[lifted.id] ?? [])")
            XCTAssertEqual(model.selectedLayer?.id, lifted.id)
            model.stop()
        } catch {
            model.stop()
            await live.finish()
            throw error
        }
        await live.finish()
    }

    // MARK: CSS overview

    func testCSSOverviewCountsTheColoursFontsAndFindsTheIssues() async throws {
        let live = try await open(["/": .init(type: "text/html", body: """
            <!doctype html><html><head><title>CSS overview fixture</title>
            <style>
            body { margin: 0; background-color: rgb(255, 255, 255); color: rgb(17, 17, 17); font-family: Helvetica; font-size: 16px; }
            h1 { font-family: Georgia; font-size: 32px; color: rgb(0, 0, 128); }
            .low { color: rgb(200, 200, 200); }
            .nudged { top: 5px; }
            @media (max-width: 600px) { .low { color: rgb(190, 190, 190); } }
            </style></head>
            <body><h1>Heading</h1><p>Readable text</p><p class="low">Faint text</p><div class="nudged">Static with top</div></body></html>
            """)], title: "CSS overview fixture")
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperCSSOverviewModel.model(for: session)
        do {
            model.capture()
            try await wait("the capture", seconds: 15, state: { "problem \(model.problem ?? "none")" }) {
                !model.capturing && (model.report != nil || model.problem != nil)
            }
            XCTAssertNil(model.problem)
            let report = try XCTUnwrap(model.report)
            XCTAssertFalse(model.stale)
            XCTAssertEqual(model.capturedAddress, live.server.url("/"))

            // html, head, title, style, body, h1, p, p.low, div.nudged.
            XCTAssertEqual(report.elements.map(\.label),
                           ["html", "head", "title", "style", "body", "h1", "p", "p.low", "div.nudged"])
            XCTAssertEqual(report.summary.elements, 9)
            XCTAssertFalse(report.summary.truncated)
            XCTAssertEqual(report.summary.inlineSheets, 1)
            XCTAssertEqual(report.summary.externalSheets, 0)
            XCTAssertEqual(report.summary.unreadableSheets, 0)
            // body, h1, .low, .nudged, and .low inside @media.
            XCTAssertEqual(report.summary.styleRules, 5)
            XCTAssertEqual(report.summary.selectors.type, 2)
            XCTAssertEqual(report.summary.selectors.classes, 3)
            XCTAssertEqual(report.summary.selectors.id, 0)
            XCTAssertEqual(report.summary.selectors.nonSimple, 0)
            XCTAssertEqual(report.summary.mediaQueries, 1)
            XCTAssertEqual(report.media, [DeveloperCSSOverview.MediaQuery(text: "(max-width: 600px)", count: 1)])

            // Colours: the body's background; text in its own colour on h1,
            // both paragraphs and the div.
            XCTAssertEqual(report.colors.background.map(\.key), ["#ffffff"])
            XCTAssertEqual(report.colors.text.map(\.key), ["#111111", "#000080", "#c8c8c8"])
            XCTAssertEqual(report.colors.text.map(\.count), [2, 1, 1])
            XCTAssertTrue(report.colors.border.isEmpty, "\(report.colors.border.map(\.key))")
            XCTAssertTrue(report.colors.fill.isEmpty)
            XCTAssertEqual(report.colors.unique, 4)

            // Fonts: Helvetica on three, Georgia on the heading.
            XCTAssertEqual(report.fonts.map(\.family), ["Helvetica", "Georgia"])
            XCTAssertEqual(report.fonts.first?.uses.map(\.size), ["16px"])
            XCTAssertEqual(report.fonts.first?.count, 3)
            XCTAssertEqual(report.fonts.last?.uses.map(\.size), ["32px"])
            XCTAssertEqual(report.fonts.last?.count, 1)

            // The faint paragraph, below AA on white.
            let low = try XCTUnwrap(report.elements.firstIndex { $0.label == "p.low" })
            XCTAssertEqual(report.contrast.count, 1, "\(report.contrast)")
            let issue = try XCTUnwrap(report.contrast.first)
            XCTAssertEqual(issue.text.hex, "#c8c8c8")
            XCTAssertEqual(issue.background.hex, "#ffffff")
            XCTAssertEqual(issue.elements, [low])
            XCTAssertEqual(issue.threshold, 4.5)
            XCTAssertEqual(issue.ratio, 1.67, accuracy: 0.01)

            // top: 5px on a statically positioned div.
            let nudged = try XCTUnwrap(report.elements.firstIndex { $0.label == "div.nudged" })
            XCTAssertEqual(report.unused.count, 1, "\(report.unused)")
            let unused = try XCTUnwrap(report.unused.first)
            XCTAssertEqual(unused.property, "top")
            XCTAssertEqual(unused.values, ["5px"])
            XCTAssertEqual(unused.elements, [nudged])
            XCTAssertEqual(unused.reason, "The position: static property prevents top from having an effect. Try setting position to something other than static.")
        } catch {
            await live.finish()
            throw error
        }
        model.clear()
        await live.finish()
    }

    // MARK: Header overrides

    /// Network conditions' Accepted Content-Encodings: requests go out
    /// offering only the chosen encodings, and back to the browser's own.
    func testAcceptedContentEncodingsReachTheServer() async throws {
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>Encodings fixture</title><p>encodings</p>"),
            "/data.txt": .init(type: "text/plain", body: "plain body"),
        ], title: "Encodings fixture")
        defer { live.window.close() }
        let tools = live.session.networkTools
        defer { tools.acceptedEncodings = nil }
        try await live.run {
            live.session.select(.network)
            let fetch = """
                const response = await fetch("/data.txt", {cache: "no-store"});
                return await response.text();
                """
            _ = try await page(live.page, fetch)
            let browsers = live.server.header("Accept-Encoding", of: "/data.txt")
            XCTAssertNotNil(browsers)
            XCTAssertNotEqual(browsers, "gzip")

            tools.acceptedEncodings = [.gzip]
            try await wait("the encodings rule", state: { "active \(tools.blockingActive)" }) { tools.blockingActive }
            let body = try await page(live.page, fetch) as? String
            XCTAssertEqual(body, "plain body")
            XCTAssertEqual(live.server.header("Accept-Encoding", of: "/data.txt"), "gzip")

            // Network throttling's latency still holds a request whose encodings are rewritten.
            live.session.setNetwork(.fast4G)
            try await wait("Fast 4G") { live.session.throttle == .fast4G }
            let timed = #"const t = performance.now(); await (await fetch("/data.txt", {cache: "no-store"})).text(); return performance.now() - t;"#
            let heldValue = try await page(live.page, timed)
            let held = try XCTUnwrap(heldValue as? Double)
            XCTAssertGreaterThanOrEqual(held, DeveloperToolsSession.NetworkCondition.fast4G.latency - 5)
            XCTAssertEqual(live.server.header("Accept-Encoding", of: "/data.txt"), "gzip")
            live.session.setNetwork(.unrestricted)
            try await wait("no throttling") { live.session.throttle == .unrestricted }

            tools.acceptedEncodings = []
            try await Task.sleep(for: .milliseconds(300))
            _ = try await page(live.page, fetch)
            XCTAssertEqual(live.server.header("Accept-Encoding", of: "/data.txt"), "identity")

            tools.acceptedEncodings = nil
            try await wait("the rule taken out", state: { "active \(tools.blockingActive)" }) { !tools.blockingActive }
            _ = try await page(live.page, fetch)
            XCTAssertEqual(live.server.header("Accept-Encoding", of: "/data.txt"), browsers)
        }
    }

    /// Rendering's Disable WebP image format, as Chrome does it: image
    /// requests stop offering WebP, and a WebP response fails to decode.
    func testDisablingWebPDropsItFromAcceptAndFailsWebPImages() async throws {
        // A 1×1 lossless WebP.
        let webp = try XCTUnwrap(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="))
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>WebP fixture</title><p>images</p>"),
            "/pic.webp": .init(type: "image/webp", body: "", bytes: webp),
        ], title: "WebP fixture")
        defer { live.window.close() }
        let tools = live.session.networkTools
        defer { tools.disabledImageFormats = [] }
        var load = 0
        func image() async throws -> String? {
            load += 1
            return try await page(live.page, """
                return await new Promise((done) => {
                    const image = new Image();
                    image.onload = () => done("loaded " + image.naturalWidth);
                    image.onerror = () => done("failed");
                    image.src = "/pic.webp?\(load)";
                });
                """) as? String
        }
        try await live.run {
            live.session.select(.network)
            let first = try await image()
            XCTAssertEqual(first, "loaded 1")
            let accept = try XCTUnwrap(live.server.header("Accept", of: "/pic.webp"))
            XCTAssertTrue(accept.contains("image/webp"), accept)

            tools.disabledImageFormats = [.webp]
            try await wait("the rule", state: { "active \(tools.blockingActive)" }) { tools.blockingActive }
            try await Task.sleep(for: .milliseconds(300))
            let disabled = try await image()
            XCTAssertEqual(disabled, "failed")
            let without = try XCTUnwrap(live.server.header("Accept", of: "/pic.webp"))
            XCTAssertFalse(without.contains("image/webp"), without)
            XCTAssertTrue(without.contains("image/"), without)

            tools.disabledImageFormats = []
            try await wait("the rule taken out", state: { "active \(tools.blockingActive)" }) { !tools.blockingActive }
            try await Task.sleep(for: .milliseconds(300))
            let again = try await image()
            XCTAssertEqual(again, "loaded 1")
        }
    }

    /// Headers › General has the request's referrer policy, as Chrome's
    /// does, from the request itself rather than only a header.
    func testRequestsCarryTheirReferrerPolicy() async throws {
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>Referrer policy fixture</title><p>policy</p>"),
            "/data.txt": .init(type: "text/plain", body: "data"),
        ], title: "Referrer policy fixture")
        defer { live.window.close() }
        let session = live.session
        let dataURL = live.server.url("/data.txt").absoluteString
        try await live.run {
            session.select(.network)
            _ = try await page(live.page, """
                await fetch("/data.txt", {cache: "no-store", referrerPolicy: "no-referrer"});
                return true;
                """)
            try await wait("the data.txt row", state: { "rows \(session.requests.map(\.url))" }) {
                session.requests.contains { $0.url == dataURL && $0.ended != nil }
            }
            let row = try XCTUnwrap(session.requests.last { $0.url == dataURL })
            let fetched = await session.requestDetails(row.id)
            let details = try XCTUnwrap(fetched)
            XCTAssertEqual(details.referrerPolicy, "no-referrer")
        }
    }

    func testHeaderOverridesAddAHeaderAndKeepTheBody() async throws {
        let live = try await open([
            "/": .init(type: "text/html", body: "<!doctype html><title>Header overrides fixture</title><p>headers</p>"),
            "/data.txt": .init(type: "text/plain", body: "perch original body"),
        ], title: "Header overrides fixture")
        defer { live.window.close() }
        let session = live.session
        let overrides = DeveloperLocalOverrides.shared
        let tools = session.networkTools
        let dataURL = live.server.url("/data.txt").absoluteString

        // The folder and switches live in the standard defaults: put them back after.
        let keys = ["DeveloperLocalOverridesFolder", "DeveloperLocalOverridesEnabled", "DeveloperLocalOverridesDisabledFiles"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let savedFolder = overrides.folder
        let savedEnabled = overrides.enabled
        // Symlinks resolved (/var is /private/var), so the folder's walk
        // sees the same paths it was given.
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("perch-header-overrides-\(UUID().uuidString)", isDirectory: true)
        defer {
            overrides.enabled = savedEnabled
            overrides.setFolder(savedFolder)
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: folder)
        }
        try await live.run {
            let host = DeveloperLocalOverrides.escape("127.0.0.1:\(live.server.port)")
            let place = folder.appendingPathComponent(host, isDirectory: true)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try Data("""
                [{"applyTo": "data.txt", "headers": [{"name": "X-Perch-Test", "value": "yes"}]}]
                """.utf8).write(to: place.appendingPathComponent(DeveloperHeaderOverrides.fileName))
            XCTAssertEqual(DeveloperLocalOverrides.headersPath(for: dataURL)?.path, host + "/.headers")

            session.select(.network)
            overrides.enabled = true
            overrides.setFolder(folder)
            XCTAssertEqual(overrides.files.map(\.path), [host + "/.headers"])
            XCTAssertTrue(overrides.headerErrors.isEmpty, "\(overrides.headerErrors)")
            XCTAssertEqual(overrides.headerOverrides(for: dataURL), [.init(name: "X-Perch-Test", value: "yes")])
            XCTAssertTrue(overrides.headerOverrides(for: live.server.url("/").absoluteString).isEmpty)
            XCTAssertEqual(overrides.ruleHeaders(for: dataURL), [.init(name: "X-Perch-Test", value: "yes")])
            try await wait("the rules handed to the network bridge", state: { "status \(overrides.status ?? "nil")" }) {
                overrides.status?.contains("headers from 1 .headers file") == true
            }
            XCTAssertFalse(overrides.status?.contains("can’t") == true, overrides.status ?? "")
            XCTAssertFalse(overrides.status?.contains("unavailable") == true, overrides.status ?? "")

            // The page's own fetch: the body as served, the header added.
            let answer = try await page(live.page, """
                const response = await fetch("/data.txt", {cache: "no-store"});
                return [response.status, await response.text(), response.headers.get("X-Perch-Test"),
                        response.headers.get("Content-Type")];
                """) as? [Any]
            let values = try XCTUnwrap(answer)
            XCTAssertEqual(values.count, 4)
            XCTAssertEqual(values.first as? Int, 200)
            XCTAssertEqual(values.dropFirst().first as? String, "perch original body")
            XCTAssertEqual(values.dropFirst(2).first as? String, "yes")
            XCTAssertEqual((values.last as? String)?.hasPrefix("text/plain"), true, "\(values)")

            // The Network row has it among its response headers.
            try await wait("the data.txt row", state: {
                "rows \(session.requests.map { "\($0.url) \($0.status ?? -1) \($0.ended == nil ? "open" : "done")" })"
            }) {
                session.requests.contains { $0.url == dataURL && $0.ended != nil && $0.status == 200 }
            }
            let row = try XCTUnwrap(session.requests.last { $0.url == dataURL && $0.ended != nil })
            let fetched = await session.requestDetails(row.id)
            let details = try XCTUnwrap(fetched)
            let headers = details.responseHeaders.map { "\($0.name): \($0.value)" }
            XCTAssertTrue(details.responseHeaders.contains {
                $0.name.caseInsensitiveCompare("X-Perch-Test") == .orderedSame && $0.value == "yes"
            }, "\(headers)")
            XCTAssertTrue(details.responseHeaders.contains {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame && $0.value.hasPrefix("text/plain")
            }, "\(headers)")
            XCTAssertEqual(details.status, 200)
            if let body = details.body, !details.base64Encoded { XCTAssertEqual(body, "perch original body") }

            // The list marks it served with overrides, and only it.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, tools.extras[row.id]?.overridden != true {
                await tools.poll()
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(tools.extras[row.id]?.overridden == true, "extras \(String(describing: tools.extras[row.id]))")
            XCTAssertTrue(tools.extras[row.id]?.servedWithOverrides == true)
            let document = session.requests.filter { $0.url == live.server.url("/").absoluteString }
            XCTAssertFalse(document.contains { tools.extras[$0.id]?.overridden == true })
        }
    }

    // MARK: Support

    struct Segment {
        let line: Int
        let column: Int
        let originalLine: Int
        let originalColumn: Int
    }

    /// A Source Map v3 for one source, its mappings encoded here from the
    /// segments (in order of line, then column).
    static func mapJSON(file: String, source: String, content: String, segments: [Segment]) throws -> String {
        let json: [String: Any] = [
            "version": 3, "file": file, "sources": [source], "sourcesContent": [content], "names": [String](),
            "mappings": mappings(segments),
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func mappings(_ segments: [Segment]) -> String {
        var lines = [[String]](repeating: [], count: (segments.map(\.line).max() ?? -1) + 1)
        var lastColumn: [Int: Int] = [:]
        var originalLine = 0, originalColumn = 0
        for segment in segments {
            let column = segment.column - (lastColumn[segment.line] ?? 0)
            lastColumn[segment.line] = segment.column
            lines[segment.line].append(vlq(column) + vlq(0) + vlq(segment.originalLine - originalLine)
                                       + vlq(segment.originalColumn - originalColumn))
            originalLine = segment.originalLine
            originalColumn = segment.originalColumn
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: ";")
    }

    static func vlq(_ value: Int) -> String {
        let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var rest = value < 0 ? ((-value) << 1) | 1 : value << 1
        var out = ""
        repeat {
            var digit = rest & 31
            rest >>= 5
            if rest > 0 { digit |= 32 }
            out.append(digits[digit])
        } while rest > 0
        return out
    }

    private static func describe(_ debugger: DeveloperDebugger) -> String {
        let frame = debugger.frame.map { frame -> String in
            let place = frame.original.map { "\($0.url):\($0.line)" } ?? "unmapped"
            return "\(frame.functionName) \(frame.url):\(frame.line):\(frame.column) → \(place)"
        }
        let breakpoints = debugger.breakpoints.map { "\($0.url):\($0.line) id \($0.protocolID ?? "nil") resolved \($0.resolved)" }
        return "pause \(debugger.pause?.reason ?? "none"), frame \(frame ?? "none"), breakpoints \(breakpoints)"
    }

    private typealias Live = DeveloperLivePage

    private func open(_ pages: [String: LocalPageServer.Page], title: String) async throws -> Live {
        try await Live.open(pages, title: title, opened: { watched = $0 }, wait: { try await wait($0, until: $1) })
    }

    private func page(_ page: WKWebView, _ body: String) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Runs page script that schedules work, so a pause can't block the call.
    private func trigger(_ page: WKWebView, _ script: String) async throws {
        _ = try await page.evaluateJavaScript(script + "; 0")
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperNewToolsLive2Tests", state: { [watched] in
            var parts: [String] = []
            if let watched {
                parts.append("ready \(watched.ready), message \(watched.message ?? "none")")
            }
            if let state { parts.append(state()) }
            return parts.joined(separator: "; ")
        }, until: condition)
    }
}
