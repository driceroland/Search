import JavaScriptCore
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class ExtensionWorkerPortTests: XCTestCase {
    func testPortsDisconnectOnlyAfterWorkerRecoveryActuallyRestartsIt() throws {
        let script = ExtensionShims.script
        let start = try XCTUnwrap(script.range(of: "let checkWorker = () => {};"))
        let end = try XCTUnwrap(script.range(of: "gather(runtime && runtime.onMessage, true);", range: start.upperBound..<script.endIndex))
        let section = String(script[start.lowerBound..<end.lowerBound])
        for (reply, restarted, expected) in [("pong", true, 0), ("gone", false, 0), ("gone", true, 1)] {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript(#"""
            const hasWorker = true, inContent = true, __SEARCH_VERBOSE__ = false;
            const location = { pathname: "/fixture" }, document = {};
            Date.now = () => 100000;
            let timerDelays = [], pings = 0, disconnects = 0, posts = 0, revives = 0;
            const setTimeout = (f, delay) => { timerDelays.push(delay); if (delay === 1000) f(); return 1; };
            const put = (target, key, value) => { target[key] = value; };
            const tell = () => {}, relay = () => {}, withLastError = () => {};
            const event = () => {
              const listeners = new Set();
              return { listeners, addListener: f => listeners.add(f), removeListener: f => listeners.delete(f),
                       hasListener: f => listeners.has(f), hasListeners: () => listeners.size > 0 };
            };
            const native = (name) => { if (name === "background.revive") revives++; return Promise.resolve(\#(restarted)); };
            const prototype = { sendMessage: () => { pings++; return Promise.resolve(\#(reply == "pong" ? "\"pong\"" : "undefined")); } };
            const runtime = Object.assign(Object.create(prototype), {
              id: "test", connect: () => ({ onMessage: event(), onDisconnect: event(),
                                         postMessage: () => { posts++; }, disconnect: () => {} })
            });
            const chrome = { runtime };
            \#(section)
            const port = runtime.connect();
            port.onDisconnect.addListener(() => { disconnects++; });
            port.postMessage({ question: "hello" });
            """#)
            XCTAssertNil(js.exception?.toString())
            // Drain JavaScriptCore's promise jobs without real timer delays.
            for _ in 0..<20 { js.evaluateScript("void 0") }
            XCTAssertEqual(js.evaluateScript("disconnects")?.toInt32(), Int32(expected), reply)
            XCTAssertEqual(js.evaluateScript("posts")?.toInt32(), 1)
            XCTAssertEqual(js.evaluateScript("timerDelays.includes(10000)")?.toBool(), false)
            if reply == "pong" { XCTAssertEqual(js.evaluateScript("revives")?.toInt32(), 0) }
            if expected == 1 {
                js.evaluateScript("disconnectWorkerPorts();")
                XCTAssertEqual(js.evaluateScript("disconnects")?.toInt32(), 1)
                js.evaluateScript("try { port.postMessage({}); } catch(e) { var closedError = e.message; }")
                XCTAssertEqual(js.evaluateScript("closedError")?.toString(), "Attempting to use a disconnected port object")
            }
        }
    }
}
