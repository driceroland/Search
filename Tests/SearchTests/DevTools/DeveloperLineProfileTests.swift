import XCTest
@testable import Search

/// Sources' line-level profile, as Chrome's gutter shows it after a
/// Performance recording: sampled self time by line, plain, pretty-printed
/// and source-mapped.
final class DeveloperLineProfileTests: XCTestCase {
    private let app = "https://x.test/app.js"

    private func sample(_ time: Double, _ frames: [(url: String, line: Int, column: Int)]) -> [String: Any] {
        ["timestamp": time, "stackFrames": frames.map { ["name": "f", "url": $0.url, "line": $0.line, "column": $0.column] }]
    }

    func testSamplesAddTheirTimeToTheInnermostFrameWithAPlace() {
        let profile = DeveloperLineProfile([
            sample(1.004, [(app, 3, 5), (app, 9, 1)]),
            sample(1.000, [("", 0, 0), (app, 3, 1)]),   // a built-in: its caller's line
            sample(1.010, [(app, 7, 1)]),
        ])
        // Halfway to each neighbour, 0.5 ms at the recording's ends.
        XCTAssertEqual(profile.times[app]?[SourceBreakpoint(line: 3, column: 0)] ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(profile.times[app]?[SourceBreakpoint(line: 3, column: 4)] ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(profile.times[app]?[SourceBreakpoint(line: 7, column: 0)] ?? 0, 3.5, accuracy: 0.0001)
        let lines = profile.lines(of: app, original: nil) { line, _ in line }
        XCTAssertEqual(lines[3] ?? 0, 7.5, accuracy: 0.0001)
        XCTAssertEqual(Set(lines.keys), [3, 7])
        XCTAssertEqual(DeveloperLineProfile.label(7.5), "7.5 ms")
    }

    func testAGapLongerThanTheCapCountsTenMillisecondsEachWay() {
        let profile = DeveloperLineProfile([sample(0, [(app, 1, 1)]), sample(5, [(app, 2, 1)])])
        XCTAssertEqual(profile.lines(of: app, original: nil) { line, _ in line }[1] ?? 0, 10.5, accuracy: 0.0001)
        XCTAssertTrue(DeveloperLineProfile([sample(0, [("", 0, 0)])]).isEmpty)
    }

    func testPrettyPrintedLinesSplitOneMinifiedLineByColumn() {
        let profile = DeveloperLineProfile([sample(0, [(app, 1, 1)]), sample(0.002, [(app, 1, 41)])])
        // The shown line for an original line and column, as a pretty-printed document gives it.
        let lines = profile.lines(of: app + "?v=2", original: nil) { _, column in column < 40 ? 1 : 6 }
        XCTAssertEqual(Set(lines.keys), [1, 6])
    }

    func testAnAuthoredFileGetsItsCompiledScriptsTimeThroughTheMap() {
        let bundle = "https://x.test/bundle.js", authored = "webpack:///src/main.ts"
        let profile = DeveloperLineProfile([sample(0, [(bundle, 10, 3)]), sample(0.002, [(bundle, 20, 1)])])
        let original: (String, Int, Int) -> DeveloperSourceMap.Original? = { url, line, column in
            XCTAssertEqual(url, bundle)
            return line == 9 && column == 2 ? .init(url: authored, line: 4, column: 0, name: nil)
                : .init(url: "webpack:///src/other.ts", line: 0, column: 0, name: nil)
        }
        let lines = profile.lines(of: authored, original: original) { line, _ in line }
        XCTAssertEqual(Array(lines.keys), [5])
        XCTAssertEqual(lines[5] ?? 0, 1.5, accuracy: 0.0001)
        // Without a map, an authored file has none of it.
        XCTAssertTrue(profile.lines(of: authored, original: nil) { line, _ in line }.isEmpty)
    }
}
