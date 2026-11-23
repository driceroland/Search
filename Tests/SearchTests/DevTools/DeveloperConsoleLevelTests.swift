import XCTest
@testable import Search

/// WebKit makes console.count's and console.time's lines Debug; Chrome
/// shows them at Info, under the default levels. console.debug stays
/// Verbose.
final class DeveloperConsoleLevelTests: XCTestCase {
    func testCountAndTimingLinesAreInfoAndDebugStaysVerbose() {
        let count: [String: Any] = ["source": "console-api", "level": "debug", "type": "log", "text": "default: 1"]
        XCTAssertEqual(DeveloperToolsSession.consoleLevel(count), "info")
        let timing: [String: Any] = ["source": "console-api", "level": "debug", "type": "timing", "text": "t: 1ms",
                                     "parameters": [["type": "string", "value": "t: 1ms"]]]
        XCTAssertEqual(DeveloperToolsSession.consoleLevel(timing), "info")
        let debug: [String: Any] = ["source": "console-api", "level": "debug", "type": "log", "text": "a: 1",
                                    "parameters": [["type": "string", "value": "a: 1"]]]
        XCTAssertEqual(DeveloperToolsSession.consoleLevel(debug), "debug")
        XCTAssertEqual(ConsoleLevel(DeveloperToolsSession.consoleLevel(debug)), .verbose)
        let network: [String: Any] = ["source": "network", "level": "debug", "type": "log", "text": "x"]
        XCTAssertEqual(DeveloperToolsSession.consoleLevel(network), "debug")
        XCTAssertEqual(DeveloperToolsSession.consoleLevel(["level": "error"]), "error")
    }

    private func jsError(_ text: String, stack: Bool) -> DeveloperToolsSession.ConsoleLine {
        var raw: [String: Any] = ["source": "javascript", "level": "error", "type": "log", "text": text]
        if stack { raw["stackTrace"] = [["functionName": "f", "url": "https://a.test/app.js", "lineNumber": 3, "columnNumber": 1]] }
        return DeveloperToolsSession.ConsoleLine(level: "error", text: text,
                                                 details: ConsoleMessageDetails(message: raw, targetID: nil))
    }

    /// Chrome's wording for JavaScript errors: Uncaught for exceptions,
    /// Uncaught (in promise) for rejections, none for WebKit's notices.
    func testUncaughtOnlyForExceptionsAndRejections() {
        XCTAssertEqual(ConsoleRowContent.uncaught(jsError("TypeError: x is undefined", stack: false)),
                       "Uncaught TypeError: x is undefined")
        XCTAssertEqual(ConsoleRowContent.uncaught(jsError("Error: boom", stack: false)), "Uncaught Error: boom")
        XCTAssertEqual(ConsoleRowContent.uncaught(jsError("5", stack: true)), "Uncaught 5")
        XCTAssertEqual(ConsoleRowContent.uncaught(jsError("Unhandled Promise Rejection: Error: no", stack: false)),
                       "Uncaught (in promise) Error: no")
        let notice = "Fetch API cannot load https://example.com/ due to access control checks."
        XCTAssertEqual(ConsoleRowContent.uncaught(jsError(notice, stack: false)), notice)
    }
}

/// Chrome links code with no address as VM<script id>.
final class DeveloperConsoleVMLinkTests: XCTestCase {
    func testAnonymousScriptNamesRoundTrip() {
        XCTAssertEqual(DeveloperToolsSession.anonymousScriptURL("25"), "VM25")
        XCTAssertEqual(DeveloperToolsSession.anonymousScriptID("VM25"), "25")
        XCTAssertNil(DeveloperToolsSession.anonymousScriptID("VM"))
        XCTAssertNil(DeveloperToolsSession.anonymousScriptID("VMware.js"))
        XCTAssertNil(DeveloperToolsSession.anonymousScriptID("https://a.test/VM25"))
        let frame = ConsoleCallFrame(["functionName": "boom", "url": "", "lineNumber": 2, "columnNumber": 3, "scriptId": "25"])
        XCTAssertEqual(frame.scriptID, "25")
    }
}
