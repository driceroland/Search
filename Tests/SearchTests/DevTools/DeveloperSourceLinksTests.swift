import XCTest
@testable import Search

/// Locations outside Sources as Chrome links them: stacks with their
/// ignore-listed frames behind "Show N more frames", and the script places
/// Performance records and stacks carry for their links.
final class DeveloperSourceLinksTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    private func frame(_ name: String, _ url: String = "https://x.test/app.js", async: Bool = false) -> ConsoleCallFrame {
        ConsoleCallFrame(functionName: name, url: async ? "" : url, lineNumber: 1, columnNumber: 1, asyncBoundary: async)
    }

    private func ignored(_ frame: ConsoleCallFrame) -> Bool { frame.url.contains("/node_modules/") }

    // MARK: Ignore list

    func testIgnoreListedFramesAreHiddenAndCounted() {
        let lib = "https://x.test/node_modules/react/index.js"
        let frames = [frame("a"), frame("dispatch", lib), frame("render", lib), frame("main")]
        let result = DeveloperIgnoredFrames.filter(frames, isBoundary: { $0.asyncBoundary }, isIgnored: ignored)
        XCTAssertEqual(result.frames.map(\.functionName), ["a", "main"])
        XCTAssertEqual(result.hidden, 2)
    }

    func testAStackWithNothingOrEverythingIgnoredShowsInFull() {
        let lib = "https://x.test/node_modules/lib.js"
        let none = [frame("a"), frame("b")]
        XCTAssertEqual(DeveloperIgnoredFrames.filter(none, isIgnored: ignored).frames, none)
        XCTAssertEqual(DeveloperIgnoredFrames.filter(none, isIgnored: ignored).hidden, 0)
        let all = [frame("x", lib), frame("y", lib)]
        let result = DeveloperIgnoredFrames.filter(all, isIgnored: ignored)
        XCTAssertEqual(result.frames, all, "Chrome shows an all-ignored stack rather than an empty one")
        XCTAssertEqual(result.hidden, 0)
    }

    func testAsyncBoundariesShowOnlyBetweenShownFrames() {
        let lib = "https://x.test/node_modules/lib.js"
        let frames = [frame("lib1", lib), frame("", async: true), frame("a"), frame("", async: true),
                      frame("lib2", lib), frame("", async: true), frame("b"), frame("", async: true), frame("lib3", lib)]
        let result = DeveloperIgnoredFrames.filter(frames, isBoundary: { $0.asyncBoundary }, isIgnored: ignored)
        XCTAssertEqual(result.frames.map { $0.asyncBoundary ? "--" : $0.functionName }, ["a", "--", "b"],
                       "no boundary leads, trails, or doubles up")
        XCTAssertEqual(result.hidden, 3, "boundaries aren't frames")
    }

    func testToggleTitleReadsAsChrome() {
        XCTAssertEqual(DeveloperIgnoredFrames.toggleTitle(hidden: 1, showing: false), "Show 1 more frame")
        XCTAssertEqual(DeveloperIgnoredFrames.toggleTitle(hidden: 4, showing: false), "Show 4 more frames")
        XCTAssertEqual(DeveloperIgnoredFrames.toggleTitle(hidden: 4, showing: true), "Show less")
    }

    func testNativeFramesHaveNoSource() {
        XCTAssertTrue(frame("a").hasSource)
        XCTAssertFalse(frame("fetch", "[native code]").hasSource)
        XCTAssertFalse(frame("", async: true).hasSource)
    }

    // MARK: Performance

    func testPerformanceRecordsNameTheirScriptPlace() {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "FunctionCall", start: 1, end: 1.01,
                   data: ["scriptName": "https://x.test/bundle.js", "scriptLine": "12", "scriptColumn": "40"]),
            Timing(type: "EvaluateScript", start: 1.02, end: 1.03, data: ["url": "https://x.test/a.js", "lineNumber": "3"]),
            Timing(type: "Layout", start: 1.04, end: 1.05),
            Timing(type: "FunctionCall", start: 1.06, end: 1.07, data: ["scriptName": ""]),
        ])
        let sources = profile.events.map(\.source)
        XCTAssertEqual(sources[0]?.url, "https://x.test/bundle.js")
        XCTAssertEqual(sources[0]?.line, 12)
        XCTAssertEqual(sources[0]?.column, 40)
        XCTAssertEqual(sources[1]?.url, "https://x.test/a.js")
        XCTAssertEqual(sources[1]?.line, 3)
        XCTAssertNil(sources[1]?.column)
        XCTAssertNil(sources[2], "a layout has no script")
        XCTAssertNil(sources[3], "nor a call with no address")
    }

    func testRecordStacksKeepTheirFullAddressesThroughATrace() throws {
        let raw: [String: Any] = [
            "type": "TimerFire", "startTime": 2.0, "endTime": 2.5,
            "stackTrace": [["functionName": "tick", "url": "https://x.test/js/bundle.js", "lineNumber": 7,
                            "columnNumber": 30, "scriptId": "9"]] as [[String: Any]],
        ]
        var result: [Timing] = []
        DeveloperToolsSession.addTimings(raw, to: &result)
        let frames = try XCTUnwrap(result.first?.frames)
        XCTAssertEqual(frames.map(\.url), ["https://x.test/js/bundle.js"])
        XCTAssertEqual(frames.first?.lineNumber, 7)
        XCTAssertEqual(frames.first?.columnNumber, 30)

        let back = try DeveloperPerformanceTrace.timings(from: DeveloperPerformanceTrace.export(result))
        XCTAssertEqual(back.first?.frames, frames, "a saved profile's stacks link as the recording's did")
        XCTAssertEqual(back.first?.stack, result.first?.stack)
        XCTAssertEqual(DeveloperPerformanceProfile(back).events.first?.frames, frames)
    }

    func testCallTreeRowsKnowARecordOfTheirActivity() {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "TimerFire", start: 1.000, end: 1.010),
            Timing(type: "FunctionCall", start: 1.001, end: 1.007, depth: 1,
                   data: ["scriptName": "https://x.test/app.js", "scriptLine": "12"]),
        ])
        let tree = profile.callTree(in: profile.bounds)
        let call = tree.first?.children.first
        XCTAssertEqual(call?.event.flatMap { profile.shown[$0].source?.url }, "https://x.test/app.js")
        let bottomUp = profile.bottomUp(in: profile.bounds)
        let row = bottomUp.first { $0.activity.hasPrefix("Function call") }
        XCTAssertEqual(row?.event.flatMap { profile.shown[$0].source?.line }, 12)
    }
}
