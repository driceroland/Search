import JavaScriptCore
import XCTest
@testable import Search

/// The shim's tab group and idle events (chrome.tabGroups.onCreated/
/// onRemoved/onUpdated, chrome.idle.onStateChanged) come from the browser,
/// over a native port, and from no timer: nothing listening, nothing open and
/// nothing scheduled, and not a call asking after groups or idleness.
@available(macOS 15.4, *)
final class ExtensionWatchShimTests: XCTestCase {
    /// The whole shim, as a page of the extension runs it, with a browser
    /// that answers the group calls from `groupList` and records every
    /// native port, native call and interval.
    private func page() throws -> JSContext {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
        js.evaluateScript(#"""
        const fixture = recoveryFixture(false);
        Object.assign(globalThis, fixture.root);
        window = globalThis; top = globalThis;
        globalThis.groupList = [{ id: 1, title: "Reading", collapsed: false, color: "grey" }];
        globalThis.ports = [];
        globalThis.intervals = [];
        globalThis.setInterval = (f, ms) => { intervals.push({ f, ms }); return intervals.length; };
        globalThis.clearInterval = () => {};
        chrome.runtime.connectNative = (name) => { const port = fixture.makePort(); port.name = name; ports.push(port); return port; };
        chrome.runtime.sendNativeMessage = (app, message) => {
          fixture.calls.push(message.api);
          if (message.api === "tabGroups.query") return Promise.resolve({ value: JSON.parse(JSON.stringify(groupList)) });
          if (message.api === "tabGroups.update") {
            const [id, props] = message.args;
            groupList = groupList.map((g) => g.id === id ? Object.assign({}, g, props) : g);
            return Promise.resolve({ value: groupList.find((g) => g.id === id) });
          }
          return Promise.resolve({ value: false });
        };
        globalThis.portsNamed = (name) => ports.filter((p) => p.name === name);
        globalThis.callsTo = (prefix) => fixture.calls.filter((c) => c.startsWith(prefix)).length;
        """#)
        js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
        XCTAssertNil(js.exception?.toString())
        return js
    }

    private func drain(_ js: JSContext) {
        for _ in 0..<40 { js.evaluateScript("void 0") }
        XCTAssertNil(js.exception?.toString())
    }

    func testNothingRunsForGroupsWhileNobodyListens() throws {
        let js = try page()
        drain(js)
        XCTAssertEqual(js.evaluateScript("ports.length")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("callsTo('tabGroups.')")?.toInt32(), 0)
    }

    func testGroupChangesReachAListenerFromTheBrowserWithoutATimer() throws {
        let js = try page()
        js.evaluateScript(#"""
        globalThis.seen = [];
        chrome.tabGroups.onCreated.addListener((g) => seen.push("created:" + g.title));
        chrome.tabGroups.onUpdated.addListener((g) => seen.push("updated:" + g.title));
        chrome.tabGroups.onRemoved.addListener((g) => seen.push("removed:" + g.title));
        """#)
        drain(js)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0, "no 3 s timer asking after groups")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.groups').length")?.toInt32(), 1, "one port, however many events")
        XCTAssertEqual(js.evaluateScript("JSON.stringify(portsNamed('search.groups')[0].posts[0])")?.toString(),
                       #"{"listen":true,"worker":false}"#)
        XCTAssertEqual(js.evaluateScript("callsTo('tabGroups.query')")?.toInt32(), 1, "the groups as they were, once")

        // The browser says the port has arrived, then answers the hello: the
        // groups are looked at again in case something changed before then.
        js.evaluateScript("portsNamed('search.groups')[0].onMessage.fire({ ready: true });")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.groups')[0].posts.length")?.toInt32(), 2, "the hello, again")
        js.evaluateScript("portsNamed('search.groups')[0].onMessage.fire({ listening: true });")
        js.evaluateScript("portsNamed('search.groups')[0].onMessage.fire({ listening: true });")
        drain(js)
        XCTAssertEqual(js.evaluateScript("callsTo('tabGroups.query')")?.toInt32(), 2, "an answer repeated is looked at once")
        XCTAssertEqual(js.evaluateScript("JSON.stringify(seen)")?.toString(), "[]", "nothing changed yet")

        // Search renames one group and makes another.
        js.evaluateScript(#"""
        groupList = [{ id: 1, title: "Later", collapsed: true, color: "grey" }, { id: 2, title: "Work", collapsed: false, color: "grey" }];
        portsNamed('search.groups')[0].onMessage.fire({ changed: true });
        """#)
        drain(js)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(seen)")?.toString(), #"["updated:Later","created:Work"]"#)

        // And removes one.
        js.evaluateScript("""
        seen.length = 0;
        groupList = [{ id: 2, title: "Work", collapsed: false, color: "grey" }];
        portsNamed('search.groups')[0].onMessage.fire({ changed: true });
        """)
        drain(js)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(seen)")?.toString(), #"["removed:Later"]"#)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0)
    }

    /// What a worker posts in a port's first moments can come back to its own
    /// listeners instead of reaching the browser (seen in a live probe): the
    /// hello, sent back, is not the browser's answer, and it goes on being said
    /// until the browser's own word comes.
    func testAHelloSentBackIsNoAnswerAndTheHelloGoesOnUntilAnswered() throws {
        let js = try page()
        js.evaluateScript(#"""
        chrome.tabGroups.onUpdated.addListener(() => {});
        chrome.idle.onStateChanged.addListener(() => {});
        globalThis.sayAgain = () => fixture.timers.slice(-1)[0].callback();
        globalThis.groupsPort = portsNamed('search.groups')[0];
        globalThis.idlePort = portsNamed('search.idle')[0];
        groupsPort.onMessage.fire({ listen: true, worker: false });
        idlePort.onMessage.fire({ listen: true, worker: false, every: 60 });
        """#)
        drain(js)
        XCTAssertEqual(js.evaluateScript("callsTo('tabGroups.query')")?.toInt32(), 1, "no reason to look again")
        js.evaluateScript("const before = idlePort.posts.length; sayAgain(); globalThis.grew = idlePort.posts.length - before;")
        XCTAssertEqual(js.evaluateScript("grew")?.toInt32(), 1, "still saying hello")
        // The browser's word, and the saying stops.
        js.evaluateScript("idlePort.onMessage.fire({ listening: true });")
        drain(js)
        js.evaluateScript("const after = idlePort.posts.length; sayAgain(); globalThis.grew = idlePort.posts.length - after;")
        XCTAssertEqual(js.evaluateScript("grew")?.toInt32(), 0, "answered, it stops")
    }

    func testAnExtensionsOwnGroupChangeIsToldAtOnce() throws {
        let js = try page()
        js.evaluateScript(#"""
        globalThis.seen = [];
        chrome.tabGroups.onUpdated.addListener((g) => seen.push(g.title));
        chrome.tabGroups.update(1, { title: "Mine" });
        """#)
        drain(js)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(seen)")?.toString(), #"["Mine"]"#)
    }

    func testTheGroupsPortClosesWithTheLastListener() throws {
        let js = try page()
        js.evaluateScript(#"""
        globalThis.first = () => {}; globalThis.second = () => {};
        chrome.tabGroups.onUpdated.addListener(first);
        chrome.tabGroups.onCreated.addListener(second);
        """#)
        drain(js)
        js.evaluateScript("chrome.tabGroups.onUpdated.removeListener(first);")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.groups')[0].disconnects")?.toInt32(), 0, "one still listens")
        js.evaluateScript("chrome.tabGroups.onCreated.removeListener(second);")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.groups')[0].disconnects")?.toInt32(), 1)
        // What the browser says after that is not looked at.
        let asked = js.evaluateScript("callsTo('tabGroups.query')")?.toInt32()
        js.evaluateScript("portsNamed('search.groups')[0].onMessage.fire({ changed: true });")
        drain(js)
        XCTAssertEqual(js.evaluateScript("callsTo('tabGroups.query')")?.toInt32(), asked)
        // A listener again opens a port again.
        js.evaluateScript("chrome.tabGroups.onRemoved.addListener(() => {});")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.groups').length")?.toInt32(), 2)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0)
    }

    func testNothingRunsForIdlenessWhileNobodyListens() throws {
        let js = try page()
        drain(js)
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle').length")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("callsTo('idle.')")?.toInt32(), 0)
    }

    func testIdleStatesComeFromTheBrowserWithoutAnIntervalOrACall() throws {
        let js = try page()
        js.evaluateScript(#"""
        globalThis.states = [];
        globalThis.listener = (s) => states.push(s);
        chrome.idle.onStateChanged.addListener(listener);
        chrome.idle.setDetectionInterval(30);
        """#)
        drain(js)
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0, "no 15 s timer")
        XCTAssertEqual(js.evaluateScript("callsTo('idle.')")?.toInt32(), 0, "nobody asks the browser")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle').length")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(portsNamed('search.idle')[0].posts[0])")?.toString(),
                       #"{"listen":true,"worker":false,"every":60}"#)

        // A new detection interval goes to the browser on the port already open.
        XCTAssertEqual(js.evaluateScript("JSON.stringify(portsNamed('search.idle')[0].posts.slice(-1)[0])")?.toString(),
                       #"{"listen":true,"worker":false,"every":30}"#)
        js.evaluateScript("chrome.idle.setDetectionInterval(5);")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle')[0].posts.slice(-1)[0].every")?.toInt32(), 15, "never under 15 s, as in Chrome")

        // The Mac goes quiet, locks, and is used again; one word repeated
        // is not told twice, and "active" as it began is not news.
        js.evaluateScript(#"""
        const port = portsNamed('search.idle')[0];
        port.onMessage.fire({ state: "active" });
        port.onMessage.fire({ state: "idle" });
        port.onMessage.fire({ state: "idle" });
        port.onMessage.fire({ state: "locked" });
        port.onMessage.fire({ state: "active" });
        """#)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(states)")?.toString(), #"["idle","locked","active"]"#)
    }

    func testTheIdlePortClosesWithTheLastListener() throws {
        let js = try page()
        js.evaluateScript(#"""
        globalThis.a = () => {}; globalThis.b = () => {};
        chrome.idle.onStateChanged.addListener(a);
        chrome.idle.onStateChanged.addListener(b);
        chrome.idle.onStateChanged.removeListener(a);
        """#)
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle')[0].disconnects")?.toInt32(), 0)
        js.evaluateScript("chrome.idle.onStateChanged.removeListener(b);")
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle')[0].disconnects")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("portsNamed('search.idle').length")?.toInt32(), 1, "one port for two listeners")
        XCTAssertEqual(js.evaluateScript("intervals.length")?.toInt32(), 0)
    }
}
