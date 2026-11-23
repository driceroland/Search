import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperToolsTests: XCTestCase {
    func testBrowserConsoleUsesOptionalDevToolsAndDisablingClosesTheSession() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Optional DevTools fixture</title>"),
        ])
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = browser.open(server.url("/"), foreground: true)
        let page = try XCTUnwrap(tab.built)
        try await wait("fixture page") { tab.isWeb && page.title == "Optional DevTools fixture" }

        let prefs = browser.prefs
        let previous = prefs.devTools
        let stored = Store.settings.object(forKey: "developerTools.enabled")
        defer {
            prefs.devTools = previous
            Store.settings.set(stored, forKey: "developerTools.enabled")
        }
        let tools = DeveloperTools.shared
        prefs.devTools = true
        browser.showConsole()
        XCTAssertTrue(tools.session?.web === page)
        XCTAssertEqual(tools.session?.panel, .console)

        prefs.devTools = false
        XCTAssertNil(tools.session)
        XCTAssertFalse(browser.showDeveloperPanel(.console))
        await tools.close()?.value

        browser.newShyTab()
        let privateTab = try XCTUnwrap(browser.active)
        XCTAssertTrue(privateTab.shy)
        privateTab.go(to: server.url("/"))
        let privatePage = try XCTUnwrap(privateTab.built)
        try await wait("private fixture page") { privateTab.isWeb && privatePage.title == "Optional DevTools fixture" }
        prefs.devTools = true
        XCTAssertFalse(browser.showDeveloperPanel(.console))
        XCTAssertNil(tools.session)
    }

    func testInspectorCommandsAndNetworkConditionsStayWithTheAttachedPage() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Inspector fixture</title>
                <style>
                    body, h1 { margin: 0 }
                    h1 { color: rgb(18, 38, 58) }
                    h1:hover { color: rgb(54, 74, 94) }
                </style>
                <h1 id="pick-me">Fixture</h1>
                <script>document.getElementById("pick-me").addEventListener("click", function onPick() {}, {passive: true});</script>
                """),
            "/sample": .init(type: "text/plain", body: "sample"),
        ])
        let store = WKWebsiteDataStore.nonPersistent()
        let inspected = makePage(store: store, url: server.url("/"))
        let other = makePage(store: store, url: server.url("/"))
        try await wait("both pages to load") { inspected.title == "Inspector fixture" && other.title == "Inspector fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: inspected, after: nil)
        do {
            try await wait("inspector to load the DOM") { session.ready && session.root != nil }
            XCTAssertTrue(session.nodes.values.contains { $0.display == "<!DOCTYPE html>" })
            session.inspect(at: NSPoint(x: 22, y: 16))
            try await wait("picked element and matched styles") {
                guard let id = session.selectedNode, session.nodes[id]?.name == "h1" else { return false }
                return session.matchedStyles.contains {
                    $0.selector == "h1" && $0.properties.contains { $0.name == "color" }
                }
            }
            XCTAssertFalse(session.nativeInspectorVisible)
            let selected = try XCTUnwrap(session.selectedNode)
            session.force(.hover, on: true, for: selected)
            try await wait("forced hover style") {
                session.forcedStates[selected]?.contains(.hover) == true
                    && session.styles.contains { $0.name == "color" && $0.value == "rgb(54, 74, 94)" }
            }
            session.force(.hover, on: false, for: selected)
            try await wait("cleared hover style") {
                session.forcedStates[selected] == nil
                    && session.styles.contains { $0.name == "color" && $0.value == "rgb(18, 38, 58)" }
            }

            // element.style takes a new declaration, as typed in DevTools.
            let inline = try XCTUnwrap(session.matchedStyles.first { $0.inline })
            XCTAssertTrue(inline.editable, "element.style is editable")
            session.editRule(inline.id, properties: inline.properties
                + DeveloperToolsSession.declarations(from: "color: rgb(1, 2, 3); padding-left: 7px"))
            try await wait("inline style applied") {
                session.styles.contains { $0.name == "color" && $0.value == "rgb(1, 2, 3)" }
                    && session.styles.contains { $0.name == "padding-left" && $0.value == "7px" }
            }
            // Switched off, the declaration stays in the rule, and the
            // sheet's colour shows through again.
            let edited = try XCTUnwrap(session.matchedStyles.first { $0.inline })
            var off = edited.properties
            let colour = try XCTUnwrap(off.firstIndex { $0.name == "color" })
            off[colour].enabled = false
            session.editRule(edited.id, properties: off)
            try await wait("inline declaration switched off") {
                session.styles.contains { $0.name == "color" && $0.value == "rgb(18, 38, 58)" }
                    && session.matchedStyles.first { $0.inline }?.properties.contains { $0.name == "color" && !$0.enabled } == true
            }
            // A sheet's own rule edits the same way.
            let sheet = try XCTUnwrap(session.matchedStyles.first { $0.selector == "h1" && $0.editable })
            session.editRule(sheet.id, properties: sheet.properties.map {
                var property = $0
                if property.name == "color" { property.value = "rgb(9, 9, 9)" }
                return property
            })
            try await wait("sheet rule edited") { session.styles.contains { $0.name == "color" && $0.value == "rgb(9, 9, 9)" } }

            session.loadListeners()
            try await wait("event listeners") { session.listeners.contains { $0.type == "click" && $0.passive } }
            let click = try XCTUnwrap(session.listeners.first { $0.type == "click" })
            XCTAssertEqual(click.handler, "onPick")
            session.setListener(click.id, disabled: true)
            session.loadListeners()
            try await wait("listener disabled") { session.listeners.first { $0.id == click.id }?.disabled == true }

            session.select(.console)
            session.evaluate("7 * 6")
            try await wait("console to return 42") { session.console.contains { $0.level == "result" && $0.text == "42" } }

            session.select(.network)
            try await wait("request interception to become available") { session.requestInterception }
            let captured = try await fetch(in: inspected, suffix: "captured")
            XCTAssertTrue(captured)
            try await wait("completed request timing") {
                session.requests.contains {
                    URL(string: $0.url)?.path == "/sample" && $0.status == 200 && $0.time != nil
                }
            }
            let request = try XCTUnwrap(session.requests.first { URL(string: $0.url)?.path == "/sample" })
            XCTAssertNotNil(request.received)
            XCTAssertFalse(DeveloperNetworkTiming.segments(for: request).isEmpty)
            // The Headers, Payload and Response tabs: asked for when chosen.
            let details = await session.requestDetails(request.id)
            let shown = try XCTUnwrap(details, "request details")
            XCTAssertEqual(shown.bodyText, "sample")
            XCTAssertEqual(shown.status, 200)
            XCTAssertEqual(shown.queryParameters.first?.name, "captured")
            XCTAssertTrue(shown.responseHeaders.contains { $0.name.lowercased() == "content-type" })
            XCTAssertTrue(DeveloperRequestTab.available(for: request, details: shown).contains(.payload))
            session.setNetwork(.offline)
            try await wait("offline condition") { session.throttle == .offline }
            let offline = try await fetch(in: inspected, suffix: "offline")
            let unaffected = try await fetch(in: other, suffix: "other")
            XCTAssertFalse(offline)
            XCTAssertTrue(unaffected)
            await session.disconnect().value
            let restored = try await fetch(in: inspected, suffix: "restored")
            XCTAssertTrue(restored)
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    /// Elements as in Chrome DevTools: the cascade with inherited, pseudo and
    /// @media rules; copied paths; new rules and selectors; Edit as HTML,
    /// Delete and ⌘Z; Hide element.
    func testElementsEditingAndCascadeMatchChromeDevTools() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Elements fixture</title>
                <style>
                    body { color: rgb(10, 20, 30); margin: 0 }
                    #box { color: rgb(1, 1, 1); color: rgb(2, 2, 2) }
                    #box:hover { color: rgb(200, 0, 0) }
                    #box::before { content: "x"; color: rgb(5, 5, 5) }
                    @media (min-width: 1px) { .item { padding: 2px } }
                    main { & .item { outline-color: rgb(3, 3, 3) } }
                </style>
                <main id="main"><div id="box" class="item">Box</div><p class="para">One</p><p class="para">Two</p></main>
                """),
        ])
        let page = makePage(store: .nonPersistent(), url: server.url("/"))
        try await wait("page to load") { page.title == "Elements fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await wait("inspector to load the DOM") { session.ready && session.root != nil }
            // ⌘F: a selector finds the node and brings its ancestors into the tree.
            let found = await session.searchDOM("#box")
            let box = try XCTUnwrap(found.first, "search result")
            XCTAssertEqual(session.nodes[box]?.name, "div")
            let paragraphs = await session.searchDOM("p.para")
            XCTAssertEqual(paragraphs.count, 2)

            session.selectNode(box)
            try await wait("cascade with inherited and pseudo sections") {
                session.matchedStyles.contains { $0.section == "Inherited from body" && $0.selector.hasPrefix("body") }
                    && session.matchedStyles.contains { $0.section == "Pseudo ::before element" }
            }
            let own = try XCTUnwrap(session.matchedStyles.first { $0.selector == "#box" && $0.section == nil })
            let colours = own.properties.filter { $0.name == "color" }
            XCTAssertEqual(colours.map(\.overridden), [true, false], "the first colour in a rule loses to the second")
            XCTAssertTrue(own.location(document: page.url).hasPrefix("(index):"), own.location(document: page.url))
            let item = try XCTUnwrap(session.matchedStyles.first { $0.selector == ".item" })
            XCTAssertEqual(item.groupings, ["@media (min-width: 1px)"])
            // A nested rule is headed by its parent rule's selector, as in Chrome.
            let nested = try XCTUnwrap(session.matchedStyles.first { $0.groupings == ["main"] },
                                       session.matchedStyles.map { $0.selector + " " + $0.groupings.joined(separator: ",") }
                                           .joined(separator: "; "))
            XCTAssertTrue(nested.selector.hasSuffix(".item"), nested.selector)
            XCTAssertTrue(nested.properties.contains { $0.name == "outline-color" })
            let body = try XCTUnwrap(session.matchedStyles.first { $0.inherited && $0.selector.hasPrefix("body") })
            XCTAssertEqual(body.properties.first { $0.name == "color" }?.overridden, true, "the element's own colour wins")
            XCTAssertEqual(body.properties.first { $0.name == "margin" }?.inheritable, false)
            XCTAssertTrue(session.copiedStyles().contains("color: rgb(2, 2, 2);"))

            // Force :hover; the computed colour follows.
            session.force(.hover, on: true, for: box)
            try await wait("forced hover") { session.styles.contains { $0.name == "color" && $0.value == "rgb(200, 0, 0)" } }
            session.force(.hover, on: false, for: box)
            try await wait("hover cleared") { session.styles.contains { $0.name == "color" && $0.value == "rgb(2, 2, 2)" } }

            // Copy selector / JS path / XPath / full XPath, as Chromium computes them.
            let selector = try await session.copyText(.selector, of: box)
            XCTAssertEqual(selector, "#box")
            let xpath = try await session.copyText(.xpath, of: box)
            XCTAssertEqual(xpath, "//*[@id=\"box\"]")
            let full = try await session.copyText(.fullXPath, of: box)
            XCTAssertEqual(full, "/html/body/main/div")
            let second = paragraphs[1]
            let paragraphSelector = try await session.copyText(.selector, of: second)
            XCTAssertEqual(paragraphSelector, "#main > p:nth-child(3)")
            let jsPath = try await session.copyText(.jsPath, of: second)
            XCTAssertEqual(jsPath, "document.querySelector(\"#main > p:nth-child(3)\")")
            let paragraphXPath = try await session.copyText(.xpath, of: second)
            XCTAssertEqual(paragraphXPath, "//*[@id=\"main\"]/p[2]")

            // New style rule (+) in the inspector sheet, then edited.
            XCTAssertEqual(session.simpleSelector(box), "div#box")
            session.addRule(for: box)
            try await wait("new rule") { session.matchedStyles.contains { $0.selector == "div#box" && $0.editable } }
            let added = try XCTUnwrap(session.matchedStyles.first { $0.selector == "div#box" })
            session.editRule(added.id, properties: DeveloperToolsSession.declarations(from: "background-color: rgb(4, 5, 6)"))
            try await wait("new rule applies") {
                session.styles.contains { $0.name == "background-color" && $0.value == "rgb(4, 5, 6)" }
            }
            // A selector edited in place.
            let item2 = try XCTUnwrap(session.matchedStyles.first { $0.selector == ".item" })
            XCTAssertTrue(item2.selectorEditable)
            session.setSelector(item2.id, "#main .item")
            try await wait("selector edited") { session.matchedStyles.contains { $0.selector == "#main .item" } }

            // Edit as HTML replaces the node and selects the new one.
            let html = try await session.outerHTML(of: second)
            XCTAssertEqual(html, "<p class=\"para\">Two</p>")
            session.setOuterHTML(second, "<p class=\"para\" id=\"edited\">Edited</p>")
            try await wait("outerHTML set") {
                guard let id = session.selectedNode, let node = session.nodes[id] else { return false }
                return node.attributes.contains("edited")
            }
            let edited = try XCTUnwrap(session.selectedNode)
            let exists = try await page.evaluateJavaScript("!!document.getElementById('edited')") as? Bool
            XCTAssertEqual(exists, true)

            // Delete element, then ⌘Z brings it back.
            session.deleteNode(edited)
            try await wait("deleted") { session.nodes[edited] == nil }
            let gone = try await page.evaluateJavaScript("!document.getElementById('edited')") as? Bool
            XCTAssertEqual(gone, true)
            session.undo()
            for _ in 0..<40 {
                if try await page.evaluateJavaScript("!!document.getElementById('edited')") as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let restored = try await page.evaluateJavaScript("!!document.getElementById('edited')") as? Bool
            XCTAssertEqual(restored, true, "undo restores the deleted element")

            // Hide element (H): visibility hidden through DevTools' class.
            session.toggleHidden(box)
            try await wait("hidden") { session.elements.hidden.contains(box) }
            let visibility = try await page.evaluateJavaScript("getComputedStyle(document.getElementById('box')).visibility") as? String
            XCTAssertEqual(visibility, "hidden")
            session.toggleHidden(box)
            try await wait("shown") { !session.elements.hidden.contains(box) }

            // Text nodes show their text once the tree expands.
            if let main = session.nodes[box]?.parent, let node = session.nodes[main] {
                if !session.expanded.contains(main) { session.expand(node) }
            }
            session.expandRecursively(box)
            try await wait("text node") { session.nodes.values.contains { $0.type == 3 && $0.text == "Box" } }

            // Break on ▸ attribute modifications, through DOMDebugger.
            session.toggleBreakpoint(.attribute, on: box)
            try await wait("DOM breakpoint") { session.elements.breakpoints[box]?.contains(.attribute) == true }
            session.toggleBreakpoint(.attribute, on: box)
            try await wait("DOM breakpoint removed") { session.elements.breakpoints[box] == nil }

            // Properties and Accessibility panes.
            let properties = await session.properties(of: box)
            XCTAssertFalse(properties.isEmpty, "the node object has properties")
            let accessibility = await session.accessibility(of: box)
            XCTAssertEqual(accessibility.properties["exists"] as? Bool, true, String(describing: accessibility))

            let image = try await session.snapshot(box)
            XCTAssertNotNil(NSImage(data: image), "node screenshot is an image")
            withExtendedLifetime(tab) {}
            await session.disconnect().value
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    func testStylesEditorsPortChromiumFormatsAndCategories() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let formats = DeveloperColorFormats.options(for: red, original: "#ff0000").map(\.text)
        XCTAssertEqual(Array(formats.prefix(4)), ["red", "#f00", "rgb(255 0 0)", "hsl(0deg 100% 50%)"])
        XCTAssertTrue(formats.contains("hwb(0deg 0% 0%)"))
        XCTAssertTrue(formats.contains("oklch(0.63 0.26 29.23)"), formats.description)
        XCTAssertTrue(formats.contains { $0.hasPrefix("lch(54.29 106.84 40.8") }, formats.description)
        XCTAssertTrue(formats.contains("color(srgb 1 0 0)"))
        XCTAssertFalse(formats.contains("#ff0000"), "the current text isn't offered again")

        XCTAssertEqual(DeveloperComputedCategory.categories(of: "margin-top"), ["Layout"])
        XCTAssertEqual(DeveloperComputedCategory.categories(of: "--brand"), ["CSS Variables"])
        XCTAssertEqual(DeveloperComputedCategory.categories(of: "order"), ["Layout", "Grid", "Flex"])
        XCTAssertEqual(DeveloperComputedCategory.categories(of: "mask"), ["Other"])

        XCTAssertEqual(DeveloperEasing.points("ease-in"), [0.42, 0, 1, 1])
        XCTAssertEqual(DeveloperEasing.token(in: "opacity 1s cubic-bezier(0.4, 0, 0.2, 1)"), "cubic-bezier(0.4, 0, 0.2, 1)")
        XCTAssertEqual(DeveloperEasing.css([0.42, 0, 0.58, 1]), "ease-in-out")

        var shadow = DeveloperShadow("2px 3px 4px rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(shadow?.color, "rgba(0, 0, 0, 0.5)")
        shadow?.inset = true
        XCTAssertEqual(shadow?.css(spread: true), "inset 2px 3px 4px rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(developerSplitLayers("1px 1px red, 0 0 2px rgb(0, 0, 0)").count, 2)

        XCTAssertEqual(DeveloperElementsState.DOMBreakpoint.allCases.map(\.menuTitle),
                       ["subtree modifications", "attribute modifications", "node removal"])
        XCTAssertEqual(DeveloperToolsSession.PseudoState.chromium.map(\.rawValue),
                       ["active", "hover", "focus", "visited", "focus-within", "focus-visible"])
    }

    func testWaterfallUsesOneClockAndSkipsInvalidPhases() {
        var first = DeveloperToolsSession.Request(id: "1", url: "https://example.test/a", method: "GET",
                                                   type: "XHR", loader: nil, started: 12)
        first.sent = 12.1
        first.received = 12.4
        first.ended = 13
        var last = DeveloperToolsSession.Request(id: "2", url: "https://example.test/b", method: "GET",
                                                  type: "Script", loader: nil, started: 14)
        last.received = 13
        last.ended = 16
        let ruler = DeveloperNetworkTiming([first, last])
        XCTAssertEqual(ruler.fraction(13), 0.25, accuracy: 0.0001)
        XCTAssertEqual(ruler.fraction(14), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ruler.fraction(16), 1, accuracy: 0.0001)
        XCTAssertEqual(DeveloperNetworkTiming.segments(for: first).map(\.phase), [.beforeSend, .waiting, .receiving])
        XCTAssertEqual(DeveloperNetworkTiming.segments(for: last).map(\.phase), [.total])
        XCTAssertEqual(DeveloperRequestKind(first), .fetch)
        last.mimeType = "application/wasm"
        XCTAssertEqual(DeveloperRequestKind(last), .wasm)
    }

    private func makePage(store: WKWebsiteDataStore, url: URL) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        Web.inspector(configuration.preferences)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    private func fetch(in view: WKWebView, suffix: String) async throws -> Bool {
        let response = try await view.callAsyncJavaScript("""
            try {
                return (await fetch("/sample?" + suffix, {cache: "no-store"})).ok;
            } catch {
                return false;
            }
            """, arguments: ["suffix": suffix], in: nil, contentWorld: .page)
        return response as? Bool ?? false
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeveloperToolsTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}
