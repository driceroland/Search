import JavaScriptCore
import XCTest
@testable import Search

/// The parts of chrome.debugger that need no window: what may be debugged,
/// the protocol's errors and keys, and the helper that runs inside a page.
@available(macOS 15.4, *)
@MainActor
final class ExtensionDebuggerTests: XCTestCase {
    func testOnlyWebPagesMayBeDebugged() throws {
        for address in ["https://example.com/", "http://localhost:3000/", "about:blank"] {
            XCTAssertTrue(ExtensionDebugger.mayDebug(try XCTUnwrap(URL(string: address))), address)
        }
        for address in ["file:///etc/hosts", "search://settings", "chrome-extension://abc/page.html",
                        "safari-web-extension://abc/page.html", "about:config", "data:text/html,hi"] {
            XCTAssertFalse(ExtensionDebugger.mayDebug(try XCTUnwrap(URL(string: address))), address)
        }
    }

    func testFailuresReadLikeChromes() throws {
        XCTAssertEqual(ExtensionDebugger.Failure.missing("Foo.bar").errorDescription,
                       #"{"code":-32601,"message":"'Foo.bar' wasn't found"}"#)
        XCTAssertEqual(ExtensionDebugger.Failure.server("No").errorDescription, #"{"code":-32000,"message":"No"}"#)
        XCTAssertEqual(ExtensionDebugger.Failure.invalid("x").code, -32602)
    }

    func testModifierBitsAreChromes() {
        XCTAssertEqual(ExtensionDebugger.modifiers(0), [])
        XCTAssertEqual(ExtensionDebugger.modifiers(1 | 2 | 4 | 8), [.option, .control, .command, .shift])
        XCTAssertEqual(ExtensionDebugger.modifiers(8), .shift)
    }

    func testKeysFindTheirCodes() {
        XCTAssertEqual(ExtensionDebugger.keyCode(key: "a", text: nil)?.code, 0)
        XCTAssertEqual(ExtensionDebugger.keyCode(key: "Enter", text: nil)?.code, 36)
        XCTAssertEqual(ExtensionDebugger.keyCode(key: "x", text: "X")?.characters, "X")
        XCTAssertNil(ExtensionDebugger.keyCode(key: "NoSuchKey", text: nil))
    }

    func testPageHelperAnswersLikeRuntime() throws {
        let context = try XCTUnwrap(JSContext())
        // The helper looks at DOM classes; a bare engine has none.
        context.evaluateScript("class Node {}; class Element extends Node {}")
        let helper = try XCTUnwrap(context.evaluateScript(ExtensionDebuggerPage.source(key: "k") + "('t')"))
        context.setObject(helper, forKeyedSubscript: "cdp" as NSString)

        func answer(_ script: String) throws -> [String: Any] {
            context.evaluateScript("var out; (async () => { out = await \(script); })();")
            // The helper's work is async; a promise settles on the next turns.
            for _ in 0..<5 where context.objectForKeyedSubscript("out").isUndefined { context.evaluateScript("0") }
            let text = try XCTUnwrap(context.objectForKeyedSubscript("out").toString())
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        let value = try answer("cdp.finish(() => ({a: [1, 'b']}), {returnByValue: true})")
        let result = try XCTUnwrap(value["result"] as? [String: Any])
        XCTAssertEqual(result["type"] as? String, "object")
        XCTAssertEqual(try XCTUnwrap(result["value"] as? [String: Any])["a"] as? NSArray, [1, "b"])

        let thrown = try answer("cdp.finish(() => { throw new Error('boom') }, {})")
        XCTAssertNotNil(thrown["exceptionDetails"] ?? (thrown["result"] as? [String: Any])?["exceptionDetails"])

        let missing = try answer("cdp.run('resolveNode', {objectId: 'nope'})")
        XCTAssertNotNil(missing["error"])
    }

    func testFetchIsAcceptedOnlyForFinishedDocuments() {
        let documents: [String: Any] = ["urlPattern": "*", "resourceType": "Document", "requestStage": "Response"]
        XCTAssertTrue(ExtensionDebugger.onlyFinishedDocuments([documents]))
        XCTAssertTrue(ExtensionDebugger.onlyFinishedDocuments([]))
        XCTAssertFalse(ExtensionDebugger.onlyFinishedDocuments([["urlPattern": "*"]]))
        XCTAssertFalse(ExtensionDebugger.onlyFinishedDocuments([documents, ["urlPattern": "*", "requestStage": "Request"]]))
    }

    func testCookiesAreSentWhereTheirDomainPathAndSchemeAllow() throws {
        func cookie(_ domain: String, path: String = "/", secure: Bool = false) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "a", .value: "1", .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }
        XCTAssertTrue(ExtensionDebugger.cookie(try cookie("example.com"), sentTo: try url("https://example.com/x")))
        XCTAssertFalse(ExtensionDebugger.cookie(try cookie("example.com"), sentTo: try url("https://www.example.com/")))
        XCTAssertTrue(ExtensionDebugger.cookie(try cookie(".example.com"), sentTo: try url("https://www.example.com/")))
        XCTAssertTrue(ExtensionDebugger.cookie(try cookie(".example.com"), sentTo: try url("https://example.com/")))
        XCTAssertFalse(ExtensionDebugger.cookie(try cookie(".example.com"), sentTo: try url("https://badexample.com/")))
        XCTAssertTrue(ExtensionDebugger.cookie(try cookie("example.com", path: "/app"), sentTo: try url("https://example.com/app/page")))
        XCTAssertFalse(ExtensionDebugger.cookie(try cookie("example.com", path: "/app"), sentTo: try url("https://example.com/apple")))
        XCTAssertFalse(ExtensionDebugger.cookie(try cookie("example.com", secure: true), sentTo: try url("http://example.com/")))
        XCTAssertTrue(ExtensionDebugger.cookie(try cookie("example.com", secure: true), sentTo: try url("https://example.com/")))

        let json = ExtensionDebugger.json(try cookie("example.com", secure: true))
        XCTAssertEqual(json["name"] as? String, "a")
        XCTAssertEqual(json["secure"] as? Bool, true)
        XCTAssertEqual(json["session"] as? Bool, true)
        XCTAssertEqual((json["expires"] as? NSNumber)?.doubleValue, -1)
    }

    func testLiteralsAreJavaScriptStrings() throws {
        let context = try XCTUnwrap(JSContext())
        for text in ["plain", "quo\"te", "back\\slash", "line\nbreak", "</script>", "é ✓", "a/b"] {
            let value = context.evaluateScript(ExtensionDebuggerSensor.literal(text))
            XCTAssertEqual(value?.toString(), text)
        }
    }

    func testSensorReportsConsoleCallsAndErrorsToItsChannel() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        // A bare engine has no page; just enough of one for the sensor to start.
        context.evaluateScript("""
            var window = this, posted = [], listeners = {};
            class Node {} ; class Element extends Node {}
            window.webkit = { messageHandlers: { chan: { postMessage(m) { posted.push(m); } } } };
            var console = { log() {} , error() {} };
            window.addEventListener = (type, fn) => { listeners[type] = fn; };
            var document = { readyState: "loading", baseURI: "https://example.com/" };
            var location = { href: "https://example.com/" };
            var performance = { timeOrigin: 1, getEntriesByType: () => [] };
            window.fetch = () => Promise.resolve({});
            class XMLHttpRequest { open() {} send() {} addEventListener() {} }
            class ErrorEvent {}
            """)
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "chan", key: "k"))
        XCTAssertNil(failure)

        context.evaluateScript("console.log('hi', 1)")
        XCTAssertNil(failure)
        let posted = try XCTUnwrap(context.evaluateScript("posted").toArray() as? [[String: Any]])
        let console = try XCTUnwrap(posted.first)
        XCTAssertEqual(console["k"] as? String, "console")
        XCTAssertEqual(console["type"] as? String, "log")
        let arguments = try XCTUnwrap(console["args"] as? [[String: Any]])
        XCTAssertEqual(arguments.first?["value"] as? String, "hi")
        XCTAssertEqual(arguments.last?["value"] as? Int, 1)

        // Run twice, the page is watched once.
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "chan", key: "k"))
        context.evaluateScript("console.log('again')")
        XCTAssertEqual(context.evaluateScript("posted.length").toInt32(), 2)
    }

    func testSensorStaysQuietWithoutItsChannel() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.evaluateScript("var window = this;")
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "none", key: "k"))
        context.evaluateScript(ExtensionDebuggerSensor.binding(channel: "none", name: "bridge"))
        XCTAssertNil(failure)
        XCTAssertTrue(context.evaluateScript("typeof bridge").toString() == "undefined")
    }

    func testBindingPostsOnlyStrings() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.evaluateScript("var window = this, posted = []; window.webkit = { messageHandlers: { chan: { postMessage(m) { posted.push(m); } } } };")
        context.evaluateScript(ExtensionDebuggerSensor.binding(channel: "chan", name: "bridge"))
        XCTAssertNil(failure)
        context.evaluateScript("bridge('payload')")
        XCTAssertEqual(context.evaluateScript("posted[0].payload").toString(), "payload")
        XCTAssertEqual(context.evaluateScript("posted[0].name").toString(), "bridge")
        context.evaluateScript("try { bridge(42) } catch (e) { var refused = e instanceof TypeError }")
        XCTAssertEqual(context.evaluateScript("refused").toBool(), true)
        XCTAssertEqual(context.evaluateScript("posted.length").toInt32(), 1)
    }

    // MARK: where a session may stay

    func testASessionEndsWhereATabLeavesDebuggablePages() throws {
        let web = try XCTUnwrap(URL(string: "https://example.com/"))
        let file = try XCTUnwrap(URL(string: "file:///etc/hosts"))
        XCTAssertNil(ExtensionDebugger.detachReason(private: false, access: false, ownPage: false, addresses: [web, nil, web]))
        // History, a link or a redirect took the tab to a file.
        XCTAssertEqual(ExtensionDebugger.detachReason(private: false, access: false, ownPage: false, addresses: [web, file]), "target_closed")
        XCTAssertEqual(ExtensionDebugger.detachReason(private: false, access: false, ownPage: true, addresses: [web]), "target_closed")
        // A private tab, once its extension is shut out of them.
        XCTAssertNil(ExtensionDebugger.detachReason(private: true, access: true, ownPage: false, addresses: [web]))
        XCTAssertEqual(ExtensionDebugger.detachReason(private: true, access: false, ownPage: false, addresses: [web]), "canceled_by_user")
    }

    func testWorldsBelongToOneExtensionAndSession() {
        let a = ExtensionDebugger.worldName(extensionID: "ext-a", sessionID: "s1", name: "agent")
        XCTAssertNotEqual(a, ExtensionDebugger.worldName(extensionID: "ext-b", sessionID: "s1", name: "agent"))
        XCTAssertNotEqual(a, ExtensionDebugger.worldName(extensionID: "ext-a", sessionID: "s2", name: "agent"))
        XCTAssertEqual(a, ExtensionDebugger.worldName(extensionID: "ext-a", sessionID: "s1", name: "agent"))
    }

    func testLoadersAreCountedByDocumentsNotBySteps() throws {
        XCTAssertEqual(ExtensionDebugger.loaderID(frame: "f", 2), "f0002")
        let page = try XCTUnwrap(URL(string: "https://example.com/a?x=1"))
        XCTAssertTrue(ExtensionDebugger.sameDocument(page, try XCTUnwrap(URL(string: "https://example.com/a?x=1#top"))))
        XCTAssertTrue(ExtensionDebugger.sameDocument(try XCTUnwrap(URL(string: "https://example.com/a#one")), try XCTUnwrap(URL(string: "https://example.com/a#two"))))
        XCTAssertFalse(ExtensionDebugger.sameDocument(page, page), "a reload to the same address is a new document")
        XCTAssertFalse(ExtensionDebugger.sameDocument(page, try XCTUnwrap(URL(string: "https://example.com/b#top"))))
        XCTAssertFalse(ExtensionDebugger.sameDocument(nil, page))
    }

    // MARK: keys

    /// What a run of key events types and presses, as the plan says.
    private func run(_ events: [(type: String, key: String, text: String?)]) -> (typed: String, presses: [String]) {
        var typed = "", presses: [String] = []
        for event in events {
            guard let plan = ExtensionDebugger.keyPlan(type: event.type, key: event.key, text: event.text) else { continue }
            if let press = plan.event, press.down { typed += press.characters; presses.append("down") }
            if let press = plan.event, !press.down { presses.append("up") }
            if let text = plan.insert { typed += text }
        }
        return (typed, presses)
    }

    func testEachKeySequenceTypesACharacterOnce() {
        // Chrome's own: keyDown with text; rawKeyDown then char; either then keyUp.
        XCTAssertEqual(run([("keyDown", "Q", "Q"), ("keyUp", "Q", nil)]).typed, "Q")
        XCTAssertEqual(run([("rawKeyDown", "Q", nil), ("char", "Q", "Q"), ("keyUp", "Q", nil)]).typed, "Q")
        XCTAssertEqual(run([("rawKeyDown", "q", "q"), ("char", "q", "q"), ("keyUp", "q", nil)]).typed, "q")
        XCTAssertEqual(run([("keyDown", "9", "9"), ("keyUp", "9", nil), ("keyDown", " ", " "), ("keyUp", " ", nil)]).typed, "9 ")
        // A key with no place on the keyboard still types its text, once.
        XCTAssertEqual(run([("keyDown", "é", "é"), ("keyUp", "é", nil)]).typed, "é")
        XCTAssertEqual(run([("rawKeyDown", "é", nil), ("char", "é", "é"), ("keyUp", "é", nil)]).typed, "é")
        // Down with no text types nothing; a command key still acts.
        XCTAssertEqual(run([("keyDown", "a", nil), ("keyUp", "a", nil)]).typed, "")
        XCTAssertEqual(ExtensionDebugger.keyPlan(type: "rawKeyDown", key: "Backspace", text: nil)?.event?.characters, "\u{7f}")
        XCTAssertNil(ExtensionDebugger.keyPlan(type: "nonsense", key: "a", text: nil))
    }

    // MARK: what a page says

    func testNumbersFromAPageNeverTrap() {
        XCTAssertEqual(ExtensionDebugger.whole(1e100), 1_000_000_000)
        XCTAssertEqual(ExtensionDebugger.whole(-1e100), -1_000_000_000)
        XCTAssertEqual(ExtensionDebugger.whole(.nan), 0)
        XCTAssertEqual(ExtensionDebugger.whole(.infinity), 0)
        XCTAssertEqual(ExtensionDebugger.whole(12.9), 12)
        XCTAssertEqual(ExtensionDebugger.finite(NSNumber(value: 1e100)), 1e9)
        XCTAssertNil(ExtensionDebugger.finite(NSNumber(value: Double.nan)))
        XCTAssertNil(ExtensionDebugger.finite("12"))
        XCTAssertNil(ExtensionDebugger.finite(nil))
    }

    func testWhatAPagePostsCanAlwaysBeWrittenOut() throws {
        let posted: [String: Any] = ["k": "net", "status": Double.nan, "headers": ["a": [1, Double.infinity, "x", Date()]],
                                     "ok": true, "n": 2]
        let clean = try XCTUnwrap(ExtensionDebugger.plain(posted) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: clean)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(back["status"] is NSNull)
        XCTAssertEqual(back["ok"] as? Bool, true)
        XCTAssertEqual(back["n"] as? Int, 2)
        XCTAssertEqual((back["headers"] as? [String: Any])?["a"] as? NSArray, [1, NSNull(), "x", NSNull()])
    }

    func testAPageCannotSwapTheHelperOrFindItByAKnownName() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("class Node {}; class Element extends Node {}; 'use strict';")
        let source = ExtensionDebuggerPage.source(key: "shk3y")
        context.evaluateScript("var first = \(source)('t'); var second = \(source)('t');")
        XCTAssertEqual(context.evaluateScript("first === second").toBool(), true)
        // The page's own script, in the same world, swapping an operation or the helper.
        context.evaluateScript("try { first.ops.viewport = () => ({clientWidth: 1e100}); } catch (e) {}")
        context.evaluateScript("try { globalThis.shk3y = {}; } catch (e) {}")
        context.evaluateScript("try { Object.defineProperty(globalThis, 'shk3y', { value: {} }); } catch (e) {}")
        XCTAssertEqual(context.evaluateScript("globalThis.shk3y === first").toBool(), true)
        XCTAssertEqual(context.evaluateScript("typeof first.ops.viewport").toString(), "function")
        XCTAssertEqual(context.evaluateScript("Object.isFrozen(first) && Object.isFrozen(first.ops)").toBool(), true)
        // Another session's helper is another object.
        XCTAssertEqual(context.evaluateScript("\(ExtensionDebuggerPage.source(key: "other"))('t') !== first").toBool(), true)
        // Not under the name every earlier version used.
        XCTAssertEqual(context.evaluateScript("globalThis[Symbol.for('search.debugger')] === undefined").toBool(), true)
    }

    // MARK: bindings

    func testBindingsGoWhereTheyWereAskedAndNowhereElse() {
        typealias Binding = ExtensionDebugger.Binding
        let everywhere = Binding(name: "b", context: nil, contextName: nil)
        XCTAssertTrue(everywhere.applies(to: 1, named: ""))
        XCTAssertTrue(everywhere.applies(to: 2, named: "agent"))
        let one = Binding(name: "b", context: 2, contextName: nil)
        XCTAssertTrue(one.applies(to: 2, named: "agent"))
        XCTAssertFalse(one.applies(to: 1, named: ""))
        XCTAssertFalse(one.applies(to: 3, named: "agent"))
        let named = Binding(name: "b", context: nil, contextName: "agent")
        XCTAssertTrue(named.applies(to: 4, named: "agent"))
        XCTAssertFalse(named.applies(to: 4, named: "other"))
        XCTAssertFalse(named.applies(to: 1, named: "agent"), "the page's own context has no name to ask for")
    }

    // MARK: cookies, snapshots

    func testAnHTTPOnlyCookieStaysHTTPOnly() throws {
        let params: [String: Any] = ["name": "sid", "value": "1", "url": "https://example.com/", "httpOnly": true]
        let cookie = try XCTUnwrap(try ExtensionDebugger.cookie(from: params))
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertTrue(cookie.isSecure)
        XCTAssertFalse(try XCTUnwrap(try ExtensionDebugger.cookie(from: ["name": "a", "value": "b", "domain": "example.com"])).isHTTPOnly)
        XCTAssertThrowsError(try ExtensionDebugger.cookie(from: ["name": "a"]))
    }

    func testSnapshotsCarryTheirTextBoxes() throws {
        let context = try XCTUnwrap(JSContext())
        // A page of one paragraph: just enough for the snapshot to walk.
        context.evaluateScript("""
            class Node {}; class Element extends Node {}
            const rect = { left: 8, top: 10, width: 120, height: 18, right: 128, bottom: 28 };
            const text = Object.assign(new Node(), { nodeType: 3, nodeName: "#text", nodeValue: "hello", childNodes: [] });
            const para = Object.assign(new Element(), { nodeType: 1, nodeName: "P", localName: "p", nodeValue: null, childNodes: [text],
              attributes: [], hasAttribute: () => false, getClientRects: () => [rect], getBoundingClientRect: () => rect, shadowRoot: null });
            const html = Object.assign(new Element(), { nodeType: 1, nodeName: "HTML", localName: "html", nodeValue: null, childNodes: [para],
              attributes: [], hasAttribute: () => false, getClientRects: () => [rect], getBoundingClientRect: () => rect, shadowRoot: null,
              lang: "en", scrollWidth: 800, scrollHeight: 600 });
            var document = { nodeType: 9, nodeName: "#document", nodeValue: null, childNodes: [html], documentElement: html,
              URL: "https://example.com/", title: "t", baseURI: "https://example.com/", characterSet: "UTF-8",
              defaultView: { scrollX: 0, scrollY: 0 },
              createRange: () => ({ selectNodeContents() {}, getBoundingClientRect: () => rect, getClientRects: () => [rect] }) };
            para.parentNode = html; text.parentNode = para; html.parentNode = document;
            var scrollX = 0, scrollY = 0, getComputedStyle = () => ({ getPropertyValue: () => "" });
            """)
        let helper = try XCTUnwrap(context.evaluateScript(ExtensionDebuggerPage.source(key: "k") + "('t')"))
        context.setObject(helper, forKeyedSubscript: "cdp" as NSString)
        context.evaluateScript("var out; (async () => { out = await cdp.run('snapshot', {mainFrame: 'f', computedStyles: []}); })();")
        for _ in 0..<5 where context.objectForKeyedSubscript("out").isUndefined { context.evaluateScript("0") }
        let text = try XCTUnwrap(context.objectForKeyedSubscript("out").toString())
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], text)
        let document = try XCTUnwrap((result["documents"] as? [[String: Any]])?.first)
        let boxes = try XCTUnwrap(document["textBoxes"] as? [String: Any])
        for field in ["layoutIndex", "bounds", "start", "length"] {
            XCTAssertEqual((boxes[field] as? [Any])?.count, 1, field)
        }
        let layout = try XCTUnwrap(document["layout"] as? [String: Any])
        XCTAssertEqual((layout["nodeIndex"] as? [Any])?.count, 3)
        XCTAssertEqual((layout["text"] as? [Any])?.count, 3)
        XCTAssertEqual((layout["styles"] as? [Any])?.count, 3)
    }
}
