import XCTest
@testable import Search

/// Performance › Save profile and Load profile: Chrome's trace event
/// format written and read back, Chrome's own traces, and WebKit's records.
final class DeveloperPerformanceTraceTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing
    private typealias Trace = DeveloperPerformanceTrace

    private var sample: [Timing] {
        [
            Timing(type: "TimerFire", start: 1.000, end: 1.010, data: ["timerId": "3"]),
            Timing(type: "FunctionCall", start: 1.001, end: 1.007, depth: 1,
                   data: ["scriptName": "https://example.com/app.js", "scriptLine": "12"], stack: ["tick — app.js:12"]),
            Timing(type: "RecalculateStyles", start: 1.002, end: 1.004, depth: 2),
            Timing(type: "TimeStamp", start: 1.020, end: 1.020, data: ["message": "007 here"]),
        ]
    }

    private func events(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testSavedProfileIsAChromeTraceArrayOfCompleteEvents() throws {
        let saved = try events(Trace.export(sample, url: "https://example.com/"))
        let complete = saved.filter { $0["ph"] as? String == "X" }
        XCTAssertEqual(complete.count, 4)
        XCTAssertEqual(complete.map { $0["name"] as? String }, ["TimerFire", "FunctionCall", "UpdateLayoutTree", "TimeStamp"],
                       "WebKit's names are Chrome's where they differ")
        let call = complete[1]
        XCTAssertEqual(call["cat"] as? String, "devtools.timeline")
        XCTAssertEqual(try XCTUnwrap(call["ts"] as? Double), 1_001_000, accuracy: 0.01, "microseconds")
        XCTAssertEqual(try XCTUnwrap(call["dur"] as? Double), 6_000, accuracy: 0.01)
        XCTAssertEqual(call["pid"] as? Int, 1)
        XCTAssertEqual(call["tid"] as? Int, 1)
        let data = try XCTUnwrap((call["args"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["scriptLine"] as? Int, 12, "whole numbers are written as numbers, as Chrome writes them")
        let thread = saved.first { $0["name"] as? String == "thread_name" }
        XCTAssertEqual((thread?["args"] as? [String: Any])?["name"] as? String, "CrRendererMain")
        XCTAssertTrue(saved.contains { $0["name"] as? String == "TracingStartedInBrowser" })
    }

    func testSavedProfileLoadsBackAsRecorded() throws {
        let loaded = try Trace.timings(from: Trace.export(sample))
        XCTAssertEqual(loaded.count, sample.count, "Chrome's bookkeeping events aren't records")
        for (back, original) in zip(loaded, sample) {
            XCTAssertEqual(back.type, original.type)
            XCTAssertEqual(back.start, original.start, accuracy: 1e-9)
            XCTAssertEqual(back.end, original.end, accuracy: 1e-9)
            XCTAssertEqual(back.depth, original.depth)
            XCTAssertEqual(back.data, original.data)
            XCTAssertEqual(back.stack, original.stack)
        }
        let profile = DeveloperPerformanceProfile(loaded)
        XCTAssertEqual(profile.events.map(\.row), [0, 1, 2, 0])
        XCTAssertEqual(profile.duration, 20, accuracy: 0.0001)
    }

    func testAnnotationsRoundTripWithTheirLabelsAndTimeRanges() throws {
        let range = DeveloperPerformanceAnnotation(label: "Rendering hot path", range: 2...6)
        let instant = DeveloperPerformanceAnnotation(label: "User action", range: 18...18)
        let data = try Trace.export(sample, annotations: [range, instant])
        let loaded = try Trace.recording(from: data)
        XCTAssertEqual(loaded.annotations.count, 2)
        // Times go to microseconds and back, so they match within rounding.
        for (back, original) in zip(loaded.annotations, [range, instant]) {
            XCTAssertEqual(back.id, original.id)
            XCTAssertEqual(back.label, original.label)
            XCTAssertEqual(back.range.lowerBound, original.range.lowerBound, accuracy: 1e-6)
            XCTAssertEqual(back.range.upperBound, original.range.upperBound, accuracy: 1e-6)
        }
        XCTAssertEqual(loaded.timings.map(\.type), sample.map(\.type))
        XCTAssertEqual(DeveloperPerformanceProfile(loaded.timings).events.count, sample.count)
    }

    func testTraceSavedWithoutAnnotationsStillLoads() throws {
        let loaded = try Trace.recording(from: Trace.export(sample, url: "https://example.com/"))
        XCTAssertEqual(loaded.annotations, [])
        XCTAssertEqual(loaded.timings.map(\.type), sample.map(\.type))
        XCTAssertEqual(DeveloperPerformanceProfile(loaded.timings).events.count, sample.count)
    }

    func testChromeTraceKeepsTheRenderersMainThread() throws {
        let trace: [String: Any] = ["traceEvents": [
            ["name": "thread_name", "ph": "M", "pid": 7, "tid": 1, "args": ["name": "CrBrowserMain"]],
            ["name": "thread_name", "ph": "M", "pid": 9, "tid": 4, "args": ["name": "CrRendererMain"]],
            ["name": "RunTask", "ph": "X", "pid": 7, "tid": 1, "ts": 10, "dur": 5],
            ["name": "RunTask", "ph": "X", "pid": 9, "tid": 4, "ts": 1_000, "dur": 3_000],
            ["name": "UpdateLayoutTree", "ph": "B", "pid": 9, "tid": 4, "ts": 1_500],
            ["name": "UpdateLayoutTree", "ph": "E", "pid": 9, "tid": 4, "ts": 2_000],
            ["name": "TimeStamp", "ph": "I", "pid": 9, "tid": 4, "ts": 3_500, "args": ["data": ["message": "mark"]]],
            ["name": "ProfileChunk", "ph": "P", "pid": 9, "tid": 4, "ts": 3_600],
        ] as [[String: Any]]]
        let loaded = try Trace.timings(from: JSONSerialization.data(withJSONObject: trace))
        XCTAssertEqual(loaded.map(\.type), ["RunTask", "RecalculateStyles", "TimeStamp"])
        XCTAssertEqual(loaded[1].start, 0.0015, accuracy: 1e-12)
        XCTAssertEqual(loaded[1].end, 0.002, accuracy: 1e-12)
        XCTAssertEqual(loaded[2].end, loaded[2].start, "an instant has no length")
        XCTAssertEqual(loaded[2].data["message"], "mark")
        let profile = DeveloperPerformanceProfile(loaded)
        XCTAssertEqual(profile.events.map(\.parent), [nil, 0, 0])
    }

    func testWebKitRecordsLoadAsRecorded() throws {
        let records: [[String: Any]] = [
            ["type": "EventDispatch", "startTime": 2.0, "endTime": 2.5, "data": ["type": "click"],
             "children": [["type": "FunctionCall", "startTime": 2.1, "endTime": 2.2] as [String: Any]]],
        ]
        let loaded = try Trace.timings(from: JSONSerialization.data(withJSONObject: ["records": records]))
        XCTAssertEqual(loaded.map(\.type), ["EventDispatch", "FunctionCall"])
        XCTAssertEqual(loaded.map(\.depth), [0, 1])
        XCTAssertEqual(loaded[0].data["type"], "click")
    }

    func testFilesThatArentProfilesAreRefused() {
        XCTAssertThrowsError(try Trace.timings(from: Data("not json".utf8))) {
            XCTAssertEqual($0 as? Trace.Failure, .unreadable)
        }
        XCTAssertThrowsError(try Trace.timings(from: Data(#"{"name": "x"}"#.utf8))) {
            XCTAssertEqual($0 as? Trace.Failure, .unreadable)
        }
        XCTAssertThrowsError(try Trace.timings(from: Data(#"[{"name": "thread_name", "ph": "M", "ts": 0}]"#.utf8))) {
            XCTAssertEqual($0 as? Trace.Failure, .empty)
        }
    }

    func testFileNameIsChromes() {
        let parts = DateComponents(year: 2026, month: 11, day: 22, hour: 15, minute: 30, second: 5)
        let date = Calendar.current.date(from: parts) ?? Date()
        XCTAssertEqual(Trace.fileName(at: date), "Trace-20261122T153005.json")
    }
}
