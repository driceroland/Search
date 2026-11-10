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
}
