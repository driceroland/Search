import AppKit
import WebKit
import XCTest
@testable import Search

/// The Recorder panel and the Issues drawer tool against real pages and
/// WebKit's real inspector. The Recorder records through a real tab of a
/// Browser, so the tab's own user scripts are swapped at each navigation
/// as they are in the app (Tab.arm), and the page hears trusted presses:
/// mouse events handed to the page view itself, and typing through the
/// editor (execCommand's input events are the browser's own). Replay and
/// the exports go through the model's own paths. Issues reads what WebKit
/// says about a page's Content Security Policy, a response's Set-Cookie
/// and the page's form fields. Pages come from a loopback server with
/// inline content; nothing leaves the machine.
@MainActor
final class DeveloperRecorderIssuesLiveTests: XCTestCase {
    // MARK: Recorder: recording

    /// A trusted-click counter, so a press handed to the page view can be
    /// waited for.
    private static let clickCounter = """
        <script>
        window.perchClicks = 0;
        addEventListener("click", (event) => { if (event.isTrusted) perchClicks++; }, true);
        </script>
        """

    func testRecordingCapturesClicksTypingAndANavigationAndKeepsRecordingOnTheNextPage() async throws {
        let live = try await openTab([
            "/first": .init(type: "text/html", body: """
                <!doctype html><title>Recorder first</title>
                <style>body { margin: 20px; } button, input, a { display: block; margin: 12px 0; font-size: 16px; }</style>
                <button id="go" onclick="document.getElementById('out').textContent = 'went'">Go</button>
                <label for="name">Your name</label>
                <input id="name" type="text">
                <a id="next" href="/second">Next page</a>
                <p id="out"></p>
                \(Self.clickCounter)
                """),
            "/second": .init(type: "text/html", body: """
                <!doctype html><title>Recorder second</title>
                <style>body { margin: 20px; } button { font-size: 16px; }</style>
                <button id="again">Again</button>
                \(Self.clickCounter)
                """),
        ], path: "/first", title: "Recorder first")
        defer { live.window.close() }
        let web = live.page
        let model = DeveloperRecorderModel.model(for: live.session)
        let firstURL = live.server.url("/first").absoluteString
        let secondURL = live.server.url("/second").absoluteString
        var made: UUID?
        do {
            model.startRecording(title: "Live flow", types: Set(DeveloperRecorderSelectorType.allCases), attribute: "")
            let id = try XCTUnwrap(model.recordingID, "recording didn't start: \(model.problem ?? "no problem given")")
            made = id
            func steps() -> [DeveloperRecorderStep] { model.store.recording(id)?.steps ?? [] }
            let state = { Self.describe(steps()) + "; at \(web.url?.absoluteString ?? "nil")" }

            try await waitForRecorder(in: web, "the recorder in the first page", state: state)
            try await wait("the opening steps, with the page's load", state: state) {
                let all = steps()
                return all.count == 2 && all[1].assertedEvents.first?.title == "Recorder first"
            }

            // A click on the button, by the mouse.
            try await press("#go", in: web)
            try await wait("the click on #go", state: state) {
                steps().contains { $0.kind == .click && $0.selectors.contains(["#go"]) }
            }

            // Typing: each keystroke is an input event, folded into one change.
            let typed = try await page(web, """
                const field = document.getElementById("name");
                field.focus();
                for (const letter of "Perch") document.execCommand("insertText", false, letter);
                return field.value;
                """) as? String
            XCTAssertEqual(typed, "Perch")
            try await wait("the change with the final value", state: state) {
                steps().last?.kind == .change && steps().last?.value == "Perch"
            }

            // The link, which navigates: its click asserts the navigation.
            try await press("#next", in: web, navigates: true)
            try await wait("the second page", seconds: 15, state: state) {
                web.url?.path() == "/second" && web.title == "Recorder second" && !web.isLoading
            }
            try await wait("the navigation, on the link's click", state: state) {
                steps().contains { $0.kind == .click && $0.selectors.contains(["#next"]) && $0.assertsNavigation }
            }

            // The recorder came along to the next page (its user script
            // went back in after the tab's own were swapped), and records.
            try await waitForRecorder(in: web, "the recorder in the second page", state: state)
            try await press("#again", in: web)
            try await wait("the click on the second page", state: state) {
                steps().contains { $0.kind == .click && $0.selectors.contains(["#again"]) }
            }
            model.stopRecording()
            XCTAssertNil(model.recordingID)

            let all = steps()
            XCTAssertEqual(all.map(\.type), ["setViewport", "navigate", "click", "change", "click", "click"], Self.describe(all))
            guard all.count == 6 else { throw Failure("unexpected steps: " + Self.describe(all)) }

            let viewport = all[0]
            XCTAssertEqual(viewport["width"]?.number, Double(web.bounds.width))
            XCTAssertEqual(viewport["height"]?.number, Double(web.bounds.height))

            let navigate = all[1]
            XCTAssertEqual(navigate.url, firstURL)
            XCTAssertEqual(navigate.assertedEvents, [DeveloperRecorderAssertedEvent(url: firstURL, title: "Recorder first")])

            let go = all[2]
            XCTAssertTrue(go.selectors.contains(["#go"]), "\(go.selectors)")
            XCTAssertTrue(go.selectors.contains { $0.first?.hasPrefix("aria/Go") == true }, "\(go.selectors)")
            XCTAssertTrue(go.selectors.contains(["xpath///*[@id=\"go\"]"]), "\(go.selectors)")
            XCTAssertEqual(go.target, "main")
            XCTAssertNotNil(go.offsetX)
            XCTAssertNotNil(go.offsetY)
            XCTAssertFalse(go.assertsNavigation)

            let change = all[3]
            XCTAssertEqual(change.value, "Perch")
            XCTAssertTrue(change.selectors.contains(["#name"]), "\(change.selectors)")
            XCTAssertTrue(change.selectors.contains { $0.first?.hasPrefix("aria/Your name") == true }, "\(change.selectors)")
            XCTAssertEqual(all.filter { $0.kind == .change }.count, 1, "typing is one change")

            let next = all[4]
            XCTAssertTrue(next.selectors.contains(["#next"]), "\(next.selectors)")
            XCTAssertEqual(next.assertedEvents, [DeveloperRecorderAssertedEvent(url: secondURL, title: "Recorder second")])

            let again = all[5]
            XCTAssertTrue(again.selectors.contains(["#again"]), "\(again.selectors)")
            XCTAssertFalse(again.assertsNavigation)

            // MARK: Recorder: export

            let recording = try XCTUnwrap(model.store.recording(id))
            let json = DeveloperRecorderModel.ExportFormat.json.text(recording)
            let back = try DeveloperRecording(data: Data(json.utf8))
            XCTAssertEqual(back.title, "Live flow")
            XCTAssertEqual(back.steps.map(\.json), recording.steps.map(\.json))
            XCTAssertEqual(back.steps.map(\.type), recording.steps.map(\.type))
            XCTAssertEqual(back.exportedJSON, json, "a re-export is the same text")
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual((parsed["steps"] as? [[String: Any]])?.compactMap { $0["type"] as? String }, recording.steps.map(\.type))

            let script = DeveloperRecorderModel.ExportFormat.puppeteer.text(recording)
            XCTAssertTrue(script.contains("targetPage.locator('#go')"), script)
            XCTAssertTrue(script.contains("targetPage.locator('::-p-aria(Go)')")
                          || script.contains("targetPage.locator('::-p-aria(Go[role=\\\"button\\\"])')"), script)
            XCTAssertTrue(script.contains("targetPage.locator('#name')"), script)
            XCTAssertTrue(script.contains(".fill('Perch');"), script)
            XCTAssertTrue(script.contains("targetPage.locator('#next')"), script)
            XCTAssertTrue(script.contains("promises.push(targetPage.waitForNavigation());"), script)
            XCTAssertTrue(script.contains("await targetPage.goto('\(firstURL)');"), script)
            XCTAssertTrue(script.contains(".click({"), script)

            let replayScript = DeveloperRecorderModel.ExportFormat.replay.text(recording)
            XCTAssertTrue(replayScript.contains("await runner.runStep("), replayScript)
            XCTAssertTrue(replayScript.contains("'#again'"), replayScript)
        } catch {
            model.stopRecording()
            if let made { model.store.remove(made) }
            await finish(live)
            throw error
        }
        if let made { model.store.remove(made) }
        await finish(live)
    }

    // MARK: Recorder: replay

    func testReplayRunsEachStepAndStopsAtTheFirstThatFails() async throws {
        let formPage = """
            <!doctype html><title>Replay form</title>
            <input id="name" type="text" aria-label="Name">
            <button id="apply" onclick="document.title = 'Applied ' + document.getElementById('name').value">Apply</button>
            """
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Replay start</title><p>start</p>"),
            "/form": .init(type: "text/html", body: formPage),
        ], path: "/start", title: "Replay start")
        defer { live.window.close() }
        let web = live.page
        let model = DeveloperRecorderModel.model(for: live.session)
        let formURL = live.server.url("/form").absoluteString
        var added: [UUID] = []
        do {
            // As Chrome's Recorder exports a recording.
            let good = try DeveloperRecording(data: Data(#"""
                {
                  "title": "Apply a name",
                  "steps": [
                    { "type": "setViewport", "width": 800, "height": 600, "deviceScaleFactor": 1,
                      "isMobile": false, "hasTouch": false, "isLandscape": false },
                    { "type": "navigate", "url": "\#(formURL)",
                      "assertedEvents": [ { "type": "navigation", "url": "\#(formURL)", "title": "Replay form" } ] },
                    { "type": "change", "value": "Perch", "selectors": [ [ "aria/Name" ], [ "#name" ] ], "target": "main" },
                    { "type": "click", "target": "main", "selectors": [ [ "aria/Apply" ], [ "#apply" ] ],
                      "offsetY": 5, "offsetX": 10 }
                  ]
                }
                """#.utf8))
            model.store.add(good)
            added.append(good.id)
            model.speed = .normal
            model.replay(good.id)
            XCTAssertTrue(model.replaying)
            func statuses(_ recording: DeveloperRecording) -> [DeveloperRecorderModel.Status] {
                recording.steps.map { model.status[$0.id] ?? .pending }
            }
            func title() async throws -> String? {
                try await page(web, "return document.title;") as? String
            }
            try await wait("the replay", seconds: 30, state: {
                "statuses \(statuses(good)), problem \(model.problem ?? "none"), title \(web.title ?? "nil")"
            }) { !model.replaying }
            XCTAssertNil(model.problem)
            XCTAssertEqual(statuses(good), Array(repeating: DeveloperRecorderModel.Status.done, count: 4))
            XCTAssertEqual(web.url?.absoluteString, formURL)
            let applied = try await title()
            XCTAssertEqual(applied, "Applied Perch")
            let value = try await page(web, "return document.getElementById('name').value;") as? String
            XCTAssertEqual(value, "Perch")

            // A selector that finds nothing: the step fails, and the one
            // after it never runs.
            _ = try await page(web, "document.title = 'Replay form'; return true;")
            let bad = try DeveloperRecording(data: Data(#"""
                {
                  "title": "Missing element",
                  "steps": [
                    { "type": "change", "value": "Nope", "selectors": [ [ "#name" ] ], "target": "main" },
                    { "type": "click", "target": "main", "selectors": [ [ "#missing" ] ], "offsetY": 1, "offsetX": 1,
                      "timeout": 1000 },
                    { "type": "click", "target": "main", "selectors": [ [ "#apply" ] ], "offsetY": 5, "offsetX": 10 }
                  ]
                }
                """#.utf8))
            model.store.add(bad)
            added.append(bad.id)
            model.replay(bad.id)
            try await wait("the failing replay", seconds: 20, state: {
                "statuses \(statuses(bad)), problem \(model.problem ?? "none")"
            }) { !model.replaying }
            let after = statuses(bad)
            XCTAssertEqual(after.first, .done)
            if after.count > 1, case .failed(let message) = after[1] {
                XCTAssertTrue(message.contains("#missing"), message)
            } else {
                XCTFail("step 2 should have failed: \(after)")
            }
            XCTAssertEqual(after.last, .pending, "the step after the failure never ran")
            let problem = try XCTUnwrap(model.problem)
            XCTAssertTrue(problem.hasPrefix("Step 2"), problem)
            let unchanged = try await title()
            XCTAssertEqual(unchanged, "Replay form", "#apply wasn't clicked")
            let changed = try await page(web, "return document.getElementById('name').value;") as? String
            XCTAssertEqual(changed, "Nope")
        } catch {
            model.cancelReplay()
            added.forEach(model.store.remove)
            await finish(live)
            throw error
        }
        added.forEach(model.store.remove)
        await finish(live)
    }

    // MARK: Issues: Content Security Policy

    func testInlineScriptBlockedByCSPIsAnIssueWithItsDirectiveAndSource() async throws {
        let html = """
            <!doctype html><title>CSP fixture</title>
            <p>csp</p>
            <script>window.perchInline = true;</script>
            """
        let live = try await openPage([
            "/csp": .init(type: "text/html", body: html, headers: ["Content-Security-Policy: script-src 'self'"]),
        ])
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperIssuesModel.model(for: session)
        let url = live.server.url("/csp").absoluteString
        do {
            try await navigate(live, to: "/csp", title: "CSP fixture")
            try await wait("the CSP issue", seconds: 15, state: {
                "groups \(Self.describe(model.groups)), console \(session.console.map(\.text).suffix(6))"
            }) {
                model.groups.contains { $0.code == .cspInline }
            }
            let ran = try await page(live.page, "return window.perchInline === true;") as? Bool
            XCTAssertEqual(ran, false, "the inline script was blocked")

            let group = try XCTUnwrap(model.groups.first { $0.code == .cspInline })
            XCTAssertEqual(group.count, 1)
            XCTAssertEqual(group.kind, .pageError)
            XCTAssertEqual(group.category, .contentSecurityPolicy)
            let directive = try XCTUnwrap(group.resources(.directive).first)
            XCTAssertEqual(directive.label, "script-src")
            XCTAssertEqual(directive.detail, "blocked: inline")
            XCTAssertTrue(group.resources(.request).isEmpty)
            let source = try XCTUnwrap(group.resources(.source).first, "\(group.resources)")
            XCTAssertEqual(source.url, url)
            XCTAssertEqual(source.line, 3, "the <script>'s line")
            XCTAssertEqual(source.label, ConsoleFormat.location(url, line: 3))
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Issues: mixed content

    func testMixedContent() throws {
        // A mixed content issue needs an https page with an http
        // subresource; the loopback fixture server speaks only http, and
        // loopback addresses are trustworthy origins besides.
        throw XCTSkip("LocalPageServer serves http only; mixed content needs an https page")
    }

    // MARK: Issues: cookies

    func testSameSiteNoneWithoutSecureIsACookieIssue() async throws {
        let live = try await openPage([
            "/cookie": .init(type: "text/html", body: "<!doctype html><title>Cookie fixture</title><p>cookie</p>",
                             headers: ["Set-Cookie: perchSameSite=1; SameSite=None; Path=/"]),
        ])
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperIssuesModel.model(for: session)
        let url = live.server.url("/cookie").absoluteString
        do {
            // The frontend's ear on Network.responseReceived is set up on
            // the model's first look; the response must come after it.
            try await waitAsync("the frontend's Set-Cookie listener") {
                (try? await session.evaluateInFrontend("return !!globalThis.perchIssues;")) as? Bool == true
            }
            try await navigate(live, to: "/cookie", title: "Cookie fixture")
            try await wait("the cookie issue", seconds: 15, state: {
                "groups \(Self.describe(model.groups)), hidden \(model.hidden), requests \(session.requests.map(\.url))"
            }) {
                model.groups.contains { $0.code == .cookieSameSiteNoneInsecure }
            }
            let group = try XCTUnwrap(model.groups.first { $0.code == .cookieSameSiteNoneInsecure })
            XCTAssertEqual(group.count, 1)
            XCTAssertEqual(group.kind, .breakingChange)
            XCTAssertEqual(group.category, .cookie)
            let cookie = try XCTUnwrap(group.resources(.cookie).first)
            XCTAssertEqual(cookie.label, "perchSameSite")
            XCTAssertEqual(cookie.detail, "127.0.0.1/")
            let request = try XCTUnwrap(group.resources(.request).first)
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.detail, "SameSite=None without Secure")
            XCTAssertNotNil(request.requestID, "linked to the Network panel's request")
            XCTAssertEqual(model.hidden, 0, "a first-party cookie isn't hidden")
            XCTAssertFalse(model.groups.contains { $0.code == .cookieThirdPartyBlocked })
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Issues: forms

    private static let formsPage = """
        <!doctype html><title>Forms fixture</title>
        <form>
        <input type="text">
        <label for="nowhere">Nowhere</label>
        <label for="pw">Password</label>
        <input type="password" id="pw">
        </form>
        """

    func testFormIssuesCountTheirElementsAndRevealARealNode() async throws {
        let live = try await openPage(["/forms": .init(type: "text/html", body: Self.formsPage)])
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperIssuesModel.model(for: session)
        let codes: [DeveloperIssueCode] = [.formEmptyIdAndName, .formInputWithNoLabel, .formLabelForNonExistingId,
                                           .formAutocompleteMissing]
        do {
            try await navigate(live, to: "/forms", title: "Forms fixture")
            try await wait("the form issues", seconds: 15, state: {
                "groups \(Self.describe(model.groups)), problem \(model.problem ?? "none")"
            }) {
                codes.allSatisfy { code in model.groups.contains { $0.code == code } }
            }
            XCTAssertNil(model.problem)
            XCTAssertEqual(Set(model.groups.map(\.code)), Set(codes), Self.describe(model.groups))
            for code in codes {
                let group = try XCTUnwrap(model.groups.first { $0.code == code })
                XCTAssertEqual(group.count, 1, "\(code)")
                XCTAssertEqual(group.resources(.element).count, 1, "\(code)")
                XCTAssertEqual(group.category, .generic, "\(code)")
            }
            func element(_ code: DeveloperIssueCode) throws -> DeveloperAffectedResource {
                try XCTUnwrap(model.groups.first { $0.code == code }?.resources(.element).first)
            }
            XCTAssertEqual(try element(.formEmptyIdAndName).label, "input[type=text]")
            XCTAssertEqual(try element(.formInputWithNoLabel).label, "input[type=text]")
            XCTAssertEqual(try element(.formLabelForNonExistingId).label, "label")
            XCTAssertEqual(try element(.formLabelForNonExistingId).detail, "for=nowhere")
            XCTAssertEqual(try element(.formAutocompleteMissing).label, "input#pw[type=password]")
            XCTAssertEqual(try element(.formAutocompleteMissing).detail, "type=password")

            // Revealing the label selects its node in Elements.
            let label = try XCTUnwrap(try element(.formLabelForNonExistingId).element)
            XCTAssertTrue(model.canReveal(label))
            model.reveal(label)
            try await wait("the label, selected in Elements", seconds: 15, state: {
                let node = session.selectedNode.flatMap { session.nodes[$0] }
                return "selected \(session.selectedNode.map(String.init) ?? "nil") \(node?.display ?? "nil"), panel \(session.panel)"
            }) {
                guard let id = session.selectedNode, let node = session.nodes[id] else { return false }
                return node.name.lowercased() == "label" && node.attributes.contains("nowhere")
            }
            XCTAssertEqual(session.panel, .elements)
            let selected = try XCTUnwrap(session.selectedNode)
            let resolved = try await session.command("DOM.resolveNode", ["nodeId": selected], targetID: session.domTargetID)
            let objectID = try XCTUnwrap((resolved["object"] as? [String: Any])?["objectId"] as? String, "\(resolved)")
            let reply = try await session.command("Runtime.callFunctionOn", [
                "objectId": objectID, "functionDeclaration": "function() { return this.htmlFor + '|' + this.textContent; }",
                "returnByValue": true,
            ], targetID: session.domTargetID)
            XCTAssertEqual((reply["result"] as? [String: Any])?["value"] as? String, "nowhere|Nowhere")
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Issues: counts and navigation

    func testBadgeCountsTheVisibleIssuesAndNavigationClearsThem() async throws {
        let live = try await openPage(["/forms": .init(type: "text/html", body: Self.formsPage)])
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperIssuesModel.model(for: session)
        let saved = session.preserveConsoleLog
        defer { session.preserveConsoleLog = saved }
        do {
            session.preserveConsoleLog = false
            try await navigate(live, to: "/forms", title: "Forms fixture")
            try await wait("the form issues", seconds: 15, state: { "groups \(Self.describe(model.groups))" }) {
                model.groups.count >= 4
            }
            // The badge's total, its counters and the pane's rows agree.
            let rows = model.groups.reduce(0) { $0 + $1.count }
            XCTAssertEqual(model.total, rows)
            XCTAssertEqual(model.counts.values.reduce(0, +), rows)
            XCTAssertEqual(model.counts[.improvement], 3, "\(model.counts)")
            XCTAssertEqual(model.counts[.pageError], 1, "\(model.counts)")
            for (byKind, byCategory) in [(true, false), (false, true), (true, true), (false, false)] {
                let sections = DeveloperIssueRules.sections(model.groups, byKind: byKind, byCategory: byCategory)
                XCTAssertEqual(sections.reduce(0) { $0 + $1.count }, rows, "byKind \(byKind), byCategory \(byCategory)")
            }
            XCTAssertEqual(model.hidden, 0)

            // Preserve log off: the next page starts with none.
            try await navigate(live, to: "/start", title: "Issues start")
            try await wait("the issues to clear", seconds: 12, state: { "groups \(Self.describe(model.groups))" }) {
                model.groups.isEmpty && model.total == 0
            }
            // And the empty page's own scan finds none to bring back.
            try await Task.sleep(for: .milliseconds(3_500))
            XCTAssertEqual(model.total, 0, Self.describe(model.groups))
            XCTAssertTrue(model.counts.isEmpty)

            // Preserve log on: the old page's issues stay, without their elements.
            session.preserveConsoleLog = true
            try await navigate(live, to: "/forms", title: "Forms fixture")
            try await wait("the form issues again", seconds: 15, state: { "groups \(Self.describe(model.groups))" }) {
                model.groups.count >= 4
            }
            let before = model.total
            try await navigate(live, to: "/start", title: "Issues start")
            try await Task.sleep(for: .milliseconds(1_500))
            try await wait("the preserved issues", seconds: 8, state: { "before \(before), groups \(Self.describe(model.groups))" }) {
                model.total == before
            }
            XCTAssertTrue(model.groups.flatMap { $0.resources(.element) }.allSatisfy { $0.element == nil })
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Support

    private struct Live {
        let server: LocalPageServer
        let page: WKWebView
        let window: NSWindow
        let tab: Tab
        let session: DeveloperToolsSession
        let browser: Browser?
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A bare page view on `/start`, in an on-screen borderless window off
    /// to the side (a page in no window now and then stops answering the
    /// inspector), with a DevTools session attached and ready. The test
    /// then navigates, so what the tool hears comes after it's listening.
    private func openPage(_ pages: [String: LocalPageServer.Page]) async throws -> Live {
        _ = NSApplication.shared
        var all = pages
        all["/start"] = .init(type: "text/html", body: "<!doctype html><title>Issues start</title><p>start</p>")
        let server = try LocalPageServer(all)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = Self.window(for: page)
        page.load(URLRequest(url: server.url("/start")))
        do {
            try await wait("page to load") { page.title == "Issues start" }
        } catch {
            window.close()
            throw error
        }
        return try await attach(server: server, page: page, window: window, tab: Tab(shy: true), browser: nil)
    }

    /// A private tab of a real Browser, its page in the same kind of
    /// window, at `path`, with a DevTools session on it: the Recorder's
    /// user script lives alongside the tab's own, which Browser swaps in
    /// at each navigation.
    private func openTab(_ pages: [String: LocalPageServer.Page], path: String, title: String) async throws -> Live {
        _ = NSApplication.shared
        let server = try LocalPageServer(pages)
        let browser = Browser(record: WindowRecord())
        browser.newShyTab()
        guard let tab = browser.active, tab.shy else {
            browser.closeAll()
            throw Failure("no private tab")
        }
        let page: WKWebView = tab.web
        let window = Self.window(for: page)
        tab.go(to: server.url(path))
        do {
            try await wait("page to load") { page.title == title && !page.isLoading }
        } catch {
            browser.closeAll()
            window.close()
            throw error
        }
        return try await attach(server: server, page: page, window: window, tab: tab, browser: browser)
    }

    private static func window(for page: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        return window
    }

    private func attach(server: LocalPageServer, page: WKWebView, window: NSWindow, tab: Tab,
                        browser: Browser?) async throws -> Live {
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        watched = session
        let live = Live(server: server, page: page, window: window, tab: tab, session: session, browser: browser)
        do {
            try await wait("inspector") { session.ready }
        } catch {
            await finish(live)
            live.window.close()
            throw error
        }
        return live
    }

    private func finish(_ live: Live) async {
        await DeveloperTestSupport.finish(live.session, page: live.page, keeping: live.tab, live.server, live.browser as Any)
        live.browser?.closeAll()
    }

    private func navigate(_ live: Live, to path: String, title: String) async throws {
        live.page.load(URLRequest(url: live.server.url(path)))
        try await wait("\(path) to load", seconds: 15) {
            live.page.url?.path() == path && live.page.title == title && !live.page.isLoading
        }
    }

    private func page(_ page: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    /// Until the recording script is up in the page shown, in the recorder's world.
    private func waitForRecorder(in web: WKWebView, _ action: String, state: @escaping () -> String) async throws {
        try await waitAsync(action, state: state) {
            let up = try? await web.callAsyncJavaScript("return !!window[Symbol.for('perch.recorder')];", arguments: [:],
                                                         in: nil, contentWorld: DeveloperRecorderModel.world)
            return up as? Bool == true
        }
    }

    /// A press of the mouse on the element, as a person's: mouse down and
    /// up handed to the page view, which WebKit turns into the page's
    /// trusted pointerdown, mousedown, mouseup and click (detail 1).
    /// Waits for the page to count the click, or, for a link, to start going.
    private func press(_ selector: String, in web: WKWebView, navigates: Bool = false) async throws {
        let found = try await page(web, """
            const el = document.querySelector(selector);
            if (!el) return null;
            el.scrollIntoView({ block: "center" });
            const rect = el.getBoundingClientRect();
            return [rect.left + Math.min(10, rect.width / 2), rect.top + rect.height / 2, window.perchClicks || 0];
            """, ["selector": selector]) as? [Double]
        let point = try XCTUnwrap(found, "\(selector) on the page")
        let window = try XCTUnwrap(web.window)
        let local = NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1])
        let location = web.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            eventNumber += 1
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
        }
        let before = Int(point[2])
        let address = web.url
        let moved = try event(.mouseMoved)
        let down = try event(.leftMouseDown)
        web.mouseMoved(with: moved)
        web.mouseDown(with: down)
        try await Task.sleep(for: .milliseconds(60))
        let up = try event(.leftMouseUp)
        web.mouseUp(with: up)
        if navigates {
            try await wait("\(selector)'s navigation to begin", state: { "at \(web.url?.absoluteString ?? "nil")" }) {
                web.isLoading || web.url != address
            }
            return
        }
        try await waitAsync("the page to hear the click on \(selector)") {
            let clicks = try? await self.page(web, "return window.perchClicks || 0;") as? Int
            return (clicks ?? 0) > before
        }
    }

    private var eventNumber = 0

    private static func describe(_ steps: [DeveloperRecorderStep]) -> String {
        steps.map { step in
            var text = step.type
            if let first = step.selectors.first { text += " " + first.joined(separator: ">>>") }
            if let value = step.value { text += " =\(value)" }
            if let url = step.url { text += " " + url }
            if !step.assertedEvents.isEmpty { text += " -> " + step.assertedEvents.map { $0.url ?? "?" }.joined(separator: ",") }
            return text
        }.joined(separator: " | ")
    }

    private static func describe(_ groups: [DeveloperIssueGroup]) -> String {
        groups.map { "\($0.code)×\($0.count) [\($0.resources.map { "\($0.kind):\($0.label)" }.joined(separator: ", "))]" }
            .joined(separator: "; ")
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperRecorderIssuesLiveTests", state: { [watched] in
            var parts: [String] = []
            if let watched {
                parts.append("ready \(watched.ready), message \(watched.message ?? "none")")
            }
            if let state { parts.append(state()) }
            return parts.joined(separator: "; ")
        }, until: condition)
    }

    /// As `wait`, for a condition that has to ask the page.
    private func waitAsync(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                           until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if await condition() { return }
        try await wait(action, seconds: 0, state: state) { false }
    }
}
