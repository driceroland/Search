import JavaScriptCore
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class ExtensionWorkerPortTests: XCTestCase {
    func testRealShimEntryCoversContentScriptsAndExtensionPages() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        for content in [true, false] {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
            js.evaluateScript("const fixture = recoveryFixture(\(content)); Object.assign(globalThis, fixture.root); window = globalThis; top = globalThis;")
            // Execute the whole shim: slicing after the content-script return
            // would falsely claim that the content path is covered (#506).
            js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
            XCTAssertNil(js.exception?.toString())
            js.evaluateScript("const port = chrome.runtime.connect(); let count = 0; port.onDisconnect.addListener(() => count++); port.postMessage({ question: 'hello' });")
            drain(js)
            XCTAssertEqual(js.evaluateScript("fixture.subscriptions.length")?.toInt32(), 1)
            XCTAssertEqual(js.evaluateScript("count")?.toInt32(), 0)
            js.evaluateScript("fixture.subscriptions[0].resolve(1);")
            drain(js)
            XCTAssertEqual(js.evaluateScript("count")?.toInt32(), 1, "content: \(content)")
            js.evaluateScript("port.nativeDisconnect.fire(port);")
            XCTAssertEqual(js.evaluateScript("count")?.toInt32(), 1)
            XCTAssertEqual(js.evaluateScript("fixture.nativePorts.length")?.toInt32(), 1, "No automatic reconnect")
            XCTAssertEqual(js.evaluateScript("port.posts.length")?.toInt32(), 1, "No replay")
            XCTAssertNil(js.exception?.toString())
        }
    }

    func testContentScriptsGetChromeReasonAndPlatformEnums() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
        js.evaluateScript("const fixture = recoveryFixture(true); Object.assign(globalThis, fixture.root); window = globalThis; top = globalThis;")
        js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
        XCTAssertNil(js.exception?.toString())
        // A content script's own code runs after the early return, so read the
        // constants then, not merely once the whole shim has finished.
        js.evaluateScript("globalThis.reasonAtStartup = chrome.runtime.OnInstalledReason.INSTALL;")
        XCTAssertEqual(js.evaluateScript("reasonAtStartup")?.toString(), "install")
        XCTAssertEqual(js.evaluateScript("chrome.runtime.OnInstalledReason.INSTALL")?.toString(), "install")
        XCTAssertEqual(js.evaluateScript("chrome.runtime.OnRestartRequiredReason.OS_UPDATE")?.toString(), "os_update")
        XCTAssertEqual(js.evaluateScript("chrome.runtime.PlatformArch.ARM64")?.toString(), "arm64")
        XCTAssertEqual(js.evaluateScript("chrome.runtime.PlatformOs.MAC")?.toString(), "mac")
        XCTAssertEqual(js.evaluateScript("chrome.runtime.RequestUpdateCheckStatus.NO_UPDATE")?.toString(), "no_update")
    }

    func testCookieChangesWithoutACookieAreNotGivenToListeners() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
        js.evaluateScript("""
        const fixture = recoveryFixture(false);
        Object.assign(globalThis, fixture.root);
        window = globalThis; top = globalThis;
        const listeners = [];
        chrome.cookies = { onChanged: { addListener: (f) => listeners.push(f), removeListener: (f) => { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
                                   hasListener: (f) => listeners.includes(f), fire: (...args) => listeners.forEach((f) => f(...args)) } };
        """)
        js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
        XCTAssertNil(js.exception?.toString())
        js.evaluateScript("""
        globalThis.seen = [];
        const listener = (change) => seen.push(change.cookie.name);
        chrome.cookies.onChanged.addListener(listener);
        chrome.cookies.onChanged.addListener(listener);
        chrome.cookies.onChanged.fire(undefined);
        chrome.cookies.onChanged.fire({});
        chrome.cookies.onChanged.fire({ cookie: { name: "session" }, cause: "explicit" });
        """)
        XCTAssertNil(js.exception?.toString())
        XCTAssertEqual(js.evaluateScript("seen.length")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("seen[0]")?.toString(), "session")
        XCTAssertTrue(js.evaluateScript("chrome.cookies.onChanged.hasListener(listener)")?.toBool() == true)
        js.evaluateScript("chrome.cookies.onChanged.removeListener(listener)")
        XCTAssertFalse(js.evaluateScript("chrome.cookies.onChanged.hasListener(listener)")?.toBool() ?? true)
        js.evaluateScript("chrome.cookies.onChanged.fire({ cookie: { name: 'after' }, cause: 'explicit' });")
        XCTAssertEqual(js.evaluateScript("seen.length")?.toInt32(), 1)
    }

    @MainActor
    func testNativeGenerationCatchesLateSubscribersAndIsolatesExtensions() async {
        let recovery = ExtensionWorkerRecovery()
        XCTAssertEqual(recovery.generation(for: "first"), 0)
        recovery.restarted("first")
        let late = await recovery.observe("first", generation: 0, token: "old-page")
        XCTAssertEqual(late, 1)
        XCTAssertEqual(recovery.generation(for: "second"), 0)
        recovery.restarted("first")
        let twice = await recovery.observe("first", generation: 1, token: "old-page")
        XCTAssertEqual(twice, 2)
    }

    @MainActor
    func testObserverLimitIsPerExtensionAndCancellationReleasesCapacity() {
        let recovery = ExtensionWorkerRecovery()
        var retired = 0, rejected = 0, replacement = 0, other = 0
        for index in 0..<ExtensionWorkerRecovery.observerLimit {
            recovery.observe("first", generation: 0, token: "port-\(index)", lifetime: nil) { _ in retired += 1 }
        }
        recovery.observe("first", generation: 0, token: "overflow", lifetime: nil) {
            XCTAssertNil($0); rejected += 1
        }
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(retired, 0, "Overflow must not evict working ports")
        recovery.observe("second", generation: 0, token: "other", lifetime: nil) { _ in other += 1 }
        XCTAssertEqual(other, 0, "Another extension has its own capacity")
        recovery.observe("first", generation: 0, token: "port-0", lifetime: nil) { _ in replacement += 1 }
        XCTAssertEqual(retired, 1, "Replacing a token at capacity must remain possible")
        XCTAssertEqual(replacement, 0)
        recovery.cancel("first", token: "port-1")
        XCTAssertEqual(retired, 2)
        recovery.observe("first", generation: 0, token: "new", lifetime: nil) { _ in replacement += 1 }
        XCTAssertEqual(replacement, 0)
        recovery.restarted("first")
        XCTAssertEqual(retired, ExtensionWorkerRecovery.observerLimit)
        XCTAssertEqual(replacement, 2)
        XCTAssertEqual(rejected, 1, "A rejected observer is never queued")
        XCTAssertEqual(other, 0)
        recovery.unregister("second")
        XCTAssertEqual(other, 1)
    }

    @MainActor
    func testCancellationDoesNotAdvanceNativeGeneration() {
        let recovery = ExtensionWorkerRecovery()
        var value: Int?, replies = 0
        recovery.observe("first", generation: 0, token: "closing-page", lifetime: nil) { value = $0; replies += 1 }
        recovery.cancel("first", token: "closing-page")
        XCTAssertNil(value)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(recovery.generation(for: "first"), 0)
    }

    @MainActor
    func testWorkerOnlyWakeRetiresOldPortsButKeepsTheConnectionWakingIt() {
        let recovery = ExtensionWorkerRecovery(), oldWorker = UUID(), freshWorker = UUID()
        var old: [Int?] = [], waking: [Int?] = []
        recovery.observe("first", generation: 0, token: "old-port", lifetime: oldWorker) { old.append($0) }
        recovery.observe("first", generation: 0, token: "new-port", lifetime: nil) { waking.append($0) }
        recovery.createdWorker("first", lifetime: freshWorker)
        XCTAssertEqual(old, [0])
        XCTAssertTrue(waking.isEmpty)
        XCTAssertEqual(recovery.generation(for: "first"), 0)
        recovery.createdWorker("first", lifetime: freshWorker)
        XCTAssertEqual(old, [0], "A repeated creation report is not another restart")
        XCTAssertTrue(waking.isEmpty)
        recovery.createdWorker("first", lifetime: UUID())
        XCTAssertEqual(waking, [0], "The fresh port retires only on the following worker")
    }

    @MainActor
    func testReloadingSameContextRetiresPortsWithoutStalingCachedShims() {
        let recovery = ExtensionWorkerRecovery()
        var old: [Int?] = [], fresh: [Int?] = []
        recovery.observe("first", generation: 0, token: "old", lifetime: UUID()) { old.append($0) }
        recovery.restarted("first", replacingContext: false)
        XCTAssertEqual(old, [0])
        XCTAssertEqual(recovery.generation(for: "first"), 0)
        recovery.observe("first", generation: 0, token: "fresh", lifetime: nil) { fresh.append($0) }
        recovery.createdWorker("first", lifetime: UUID())
        XCTAssertTrue(fresh.isEmpty)
        recovery.cancel("first", token: "fresh")
    }

    @MainActor
    func testUnregisterCancelsPendingObserversWithoutClaimingRestart() {
        let recovery = ExtensionWorkerRecovery()
        recovery.restarted("first")
        var replies: [Int?] = [], other: [Int?] = []
        recovery.observe("first", generation: 1, token: "pending", lifetime: nil) { replies.append($0) }
        recovery.observe("second", generation: 0, token: "pending", lifetime: nil) { other.append($0) }
        recovery.unregister("first")
        XCTAssertEqual(replies.count, 1)
        XCTAssertNil(replies[0])
        recovery.createdWorker("first", lifetime: UUID())
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(recovery.generation(for: "first"), 1, "Cleanup must preserve a previous context generation")
        XCTAssertTrue(other.isEmpty, "Another extension's subscriptions are retained")
        recovery.cancel("second", token: "pending")
        XCTAssertEqual(other.count, 1)
    }

    @MainActor
    func testLiveFixtureParsesWithoutWebKitErrors() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/extension")
        let fixture = try await WKWebExtension(resourceBaseURL: folder)
        XCTAssertTrue(fixture.errors.isEmpty, "The live fixture must not create WebKit manifest errors")
    }

    private func drain(_ js: JSContext) {
        for _ in 0..<40 { js.evaluateScript("void 0") }
        XCTAssertNil(js.exception?.toString())
    }
}
