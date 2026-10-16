import JavaScriptCore
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class ExtensionPortTests: XCTestCase {
    func testContentMessagesStayPlainAndOwnPageMessagesStayNumbered() throws {
        let script = ExtensionShims.script
        let start = try XCTUnwrap(script.range(of: "if (runtime && typeof runtime.connect === \"function\" && runtime.onConnect) {"))
        let end = try XCTUnwrap(script.range(of: "// Members of namespaces WebKit has.", range: start.upperBound..<script.endIndex))
        let ports = String(script[start.lowerBound..<end.lowerBound])
        for content in [true, false] {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript(#"""
            const inContent = \#(content), own = "webkit-extension://test/";
            const put = (target, key, value) => { target[key] = value; };
            const untabbed = (sender) => sender;
            const makeEvent = () => {
              const listeners = new Set();
              return { addListener: f => listeners.add(f), removeListener: f => listeners.delete(f),
                       hasListener: f => listeners.has(f), fire: m => [...listeners].forEach(f => f(m)) };
            };
            let sent;
            const runtime = { id: "test", getURL: () => own,
                              connect: () => ({ postMessage: m => { sent = m; }, onMessage: makeEvent() }),
                              onConnect: makeEvent() };
            \#(ports)
            runtime.connect().postMessage({ question: "hello" });
            """#)
            XCTAssertNil(js.exception?.toString())
            XCTAssertEqual(js.evaluateScript("sent.question === 'hello'")?.toBool(), content)
            XCTAssertEqual(js.evaluateScript("Array.isArray(sent.__searchPort)")?.toBool(), !content)
            js.evaluateScript(#"""
            let received = [];
            runtime.onConnect.addListener(p => p.onMessage.addListener(m => received.push(m)));
            const incoming = { sender: { url: inContent ? "https://example.com/" : "webkit-extension://test" },
                               postMessage: () => {}, onMessage: makeEvent() };
            runtime.onConnect.fire(incoming);
            incoming.onMessage.fire(sent);
            incoming.onMessage.fire(sent);
            """#)
            XCTAssertNil(js.exception?.toString())
            XCTAssertEqual(js.evaluateScript("received[0].question")?.toString(), "hello")
            XCTAssertEqual(js.evaluateScript("received.length")?.toInt32(), content ? 2 : 1)
            js.evaluateScript("runtime.connect('another-extension').postMessage({ external: true });")
            XCTAssertEqual(js.evaluateScript("sent.external")?.toBool(), true)
        }
    }
}
