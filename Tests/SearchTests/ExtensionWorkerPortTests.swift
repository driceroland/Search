import JavaScriptCore
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
    func testCancellationDoesNotAdvanceNativeGeneration() {
        let recovery = ExtensionWorkerRecovery()
        var value: Int?
        recovery.observe("first", generation: 0, token: "closing-page") { value = $0 }
        recovery.cancel("first", token: "closing-page")
        XCTAssertEqual(value, 0)
        XCTAssertEqual(recovery.generation(for: "first"), 0)
    }

    private func drain(_ js: JSContext) {
        for _ in 0..<40 { js.evaluateScript("void 0") }
        XCTAssertNil(js.exception?.toString())
    }
}
