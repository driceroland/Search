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
        let helper = try XCTUnwrap(context.evaluateScript(ExtensionDebuggerPage.source + "('t')"))
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
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "chan"))
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
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "chan"))
        context.evaluateScript("console.log('again')")
        XCTAssertEqual(context.evaluateScript("posted.length").toInt32(), 2)
    }

    func testSensorStaysQuietWithoutItsChannel() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.evaluateScript("var window = this;")
        context.evaluateScript(ExtensionDebuggerSensor.source(channel: "none"))
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
}
