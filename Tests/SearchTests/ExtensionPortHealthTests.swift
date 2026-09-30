import JavaScriptCore
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class ExtensionPortHealthTests: XCTestCase {
    private func context() throws -> JSContext {
        let script = ExtensionShims.script
        let start = try XCTUnwrap(script.range(of: "// A worker can answer new connections"))
        let end = try XCTUnwrap(script.range(of: "if (inContent) {", range: start.upperBound..<script.endIndex))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        const document = {}, inContent = true;
        let clock = 100000, nextTimer = 0;
        Date.now = () => clock;
        const timers = new Map();
        const setTimeout = (f) => { timers.set(++nextTimer, f); return nextTimer; };
        const clearTimeout = (id) => timers.delete(id);
        const expire = () => { const jobs = [...timers.values()]; timers.clear(); jobs.forEach(f => f()); };
        const event = () => {
          const listeners = new Set();
          return { listeners, addListener: f => listeners.add(f), removeListener: f => listeners.delete(f),
            hasListener: f => listeners.has(f), hasListeners: () => listeners.size > 0,
            emit: (...args) => [...listeners].forEach(f => f(...args)) };
        };
        const put = (object, key, value) => object[key] = value;
        const ports = [];
        const runtime = { id: "fixture", onConnect: event(), connect: (...args) => {
          const port = { name: "UI_PORT", args, sent: [], closed: false, onMessage: event(), onDisconnect: event(),
            postMessage(message) { this.sent.push(message); },
            disconnect() { this.closed = true; this.onDisconnect.emit(this); } };
          ports.push(port); return port;
        } };
        (() => {
          \#(script[start.lowerBound..<end.lowerBound])
          if (inContent) return;
          throw new Error("content script reached extension-only APIs");
        })();
        const ack = (port) => {
          const check = port.sent.at(-1).__searchPortCheck;
          port.onMessage.emit({ __searchPortCheck: { token: check.token, reply: true } });
        };
        const port = runtime.connect({ name: "UI_PORT" });
        let replies = 0, disconnects = 0;
        port.onMessage.addListener(() => replies++);
        port.onDisconnect.addListener(() => disconnects++);
        """#)
        XCTAssertNil(js.exception?.toString())
        return js
    }

    func testIdleContentPortReconnectsWithoutReplayingDeliveredRequests() throws {
        let js = try context()
        js.evaluateScript("port.postMessage({ type: 'FIRST' }); ack(ports[0]); clock += 6000; port.postMessage({ type: 'SECOND' }); port.postMessage({ type: 'THIRD' });")
        XCTAssertEqual(js.evaluateScript("ports[0].sent.filter(x => x.type).length")?.toInt32(), 1)
        js.evaluateScript("expire(); ack(ports[1]);")
        XCTAssertNil(js.exception?.toString())
        XCTAssertEqual(js.evaluateScript("ports.length")?.toInt32(), 2)
        XCTAssertEqual(js.evaluateScript("ports[1].sent.filter(x => x.type).map(x => x.type).join(',')")?.toString(), "SECOND,THIRD")
        XCTAssertEqual(js.evaluateScript("disconnects")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("replies")?.toInt32(), 0, "private acknowledgements must not reach extension listeners")
        js.evaluateScript("ports[1].onMessage.emit({ type: 'ANSWER' });")
        XCTAssertEqual(js.evaluateScript("replies")?.toInt32(), 1)
    }

    func testUnavailableReceiverDisconnectsOnceAndClearsPendingMessages() throws {
        let js = try context()
        js.evaluateScript("port.postMessage({ type: 'QUESTION' }); expire(); expire(); expire();")
        XCTAssertEqual(js.evaluateScript("disconnects")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("ports.flatMap(p => p.sent).filter(x => x.type).length")?.toInt32(), 0)
        js.evaluateScript("try { port.postMessage({}); } catch(e) { var failure = e.message; }")
        XCTAssertEqual(js.evaluateScript("failure")?.toString(), "Attempting to use a disconnected port object")
    }


    func testQueuedMessageIsSnapshottedAndExplicitCloseDoesNotNotifyCaller() throws {
        let js = try context()
        js.evaluateScript("const question = { type: 'ORIGINAL' }; port.postMessage(question); question.type = 'CHANGED'; ack(ports[0]);")
        XCTAssertEqual(js.evaluateScript("ports[0].sent[1].type")?.toString(), "ORIGINAL")
        js.evaluateScript("clock += 6000; port.postMessage({ type: 'UNSENT' }); port.disconnect(); expire();")
        XCTAssertEqual(js.evaluateScript("ports.length")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("disconnects")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("ports[0].sent.filter(x => x.type).length")?.toInt32(), 1)
    }

    func testReceiverFiltersHealthMessagesAndExternalConnectionsStayNative() throws {
        let js = try context()
        js.evaluateScript(#"""
        let received = [], incoming;
        const listener = p => { incoming = p; p.onMessage.addListener(m => received.push(m)); };
        runtime.onConnect.addListener(listener);
        const receiver = runtime.connect("another-extension");
        const nativeMessages = receiver.onMessage;
        runtime.onConnect.emit(receiver);
        nativeMessages.emit({ __searchPortCheck: { token: "probe", reply: false } });
        nativeMessages.emit({ type: "REAL" });
        """#)
        XCTAssertNil(js.exception?.toString())
        XCTAssertEqual(js.evaluateScript("received.length")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("ports[1].sent[0].__searchPortCheck.reply")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("runtime.onConnect.hasListener(listener)")?.toBool(), true)
        js.evaluateScript("runtime.onConnect.removeListener(listener);")
        XCTAssertEqual(js.evaluateScript("runtime.onConnect.hasListener(listener)")?.toBool(), false)
        XCTAssertEqual(js.evaluateScript("incoming === ports[1]")?.toBool(), true)
    }
}
