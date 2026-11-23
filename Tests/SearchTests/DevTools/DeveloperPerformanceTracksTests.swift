import XCTest
@testable import Search

/// A recording's page tracks: the page's own timings moved onto the
/// timeline's clock, and the Timings, Interactions and Frames tracks and
/// long tasks the profile finds in it.
final class DeveloperPerformanceTracksTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing

    func testPageTimingsLineUpWithTheTimelineByTheSyncStamp() throws {
        var record = [
            Timing(type: "RecordingBounds", start: 10, end: 12),
            Timing(type: "TimeStamp", start: 10.5, end: 10.5, data: ["message": "perch-sync 2000"]),
            Timing(type: "TimeStamp", start: 10.7, end: 10.7, data: ["message": "the page's own"]),
        ]
        let page: [String: Any] = ["now": 2_000, "entries": [
            ["kind": "mark", "name": "start", "start": 2_100, "end": 2_100],
            ["kind": "measure", "name": "work", "start": 1_900, "end": 2_300],
            // Before the recording began: left out.
            ["kind": "FCP", "name": "First Contentful Paint", "start": 1_000, "end": 1_000],
            ["kind": "LCP", "name": "Largest Contentful Paint", "start": 2_400, "end": 2_400],
        ]]
        DeveloperPerformancePageTimings.merge(page, into: &record, bounds: 10...12)

        XCTAssertFalse(record.contains { $0.data["message"]?.hasPrefix("perch-sync") == true }, "the sync stamp stays in the recording")
        XCTAssertTrue(record.contains { $0.data["message"] == "the page's own" })
        let timings = record.filter { $0.type == "PageTiming" }
        XCTAssertEqual(timings.map { $0.data["kind"] }, ["mark", "measure", "LCP"])
        let mark = try XCTUnwrap(timings.first { $0.data["name"] == "start" })
        XCTAssertEqual(mark.start, 10.6, accuracy: 1e-9)
        let measure = try XCTUnwrap(timings.first { $0.data["name"] == "work" })
        XCTAssertEqual(measure.start, 10.4, accuracy: 1e-9)
        XCTAssertEqual(measure.end, 10.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(timings.last).start, 10.9, accuracy: 1e-9)
    }

    func testWithoutTheStampThePageAnsweredAtTheRecordingsEnd() throws {
        var record = [Timing(type: "RecordingBounds", start: 10, end: 12)]
        DeveloperPerformancePageTimings.merge(["now": 3_000, "entries": [
            ["kind": "mark", "name": "late", "start": 2_500],
            // A measure begun before the recording is cut at its start.
            ["kind": "measure", "name": "long", "start": 0, "end": 2_900],
        ]], into: &record, bounds: 10...12)
        let mark = try XCTUnwrap(record.first { $0.data["name"] == "late" })
        XCTAssertEqual(mark.start, 11.5, accuracy: 1e-9)
        let measure = try XCTUnwrap(record.first { $0.data["name"] == "long" })
        XCTAssertEqual(measure.start, 10, accuracy: 1e-9)
        XCTAssertEqual(measure.end, 11.9, accuracy: 1e-9)
    }

    func testProfileFindsTimingsInteractionsFramesAndLongTasks() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 1),
            Timing(type: "RenderingFrame", start: 0.1, end: 0.116),
            Timing(type: "EventDispatch", start: 0.2, end: 0.45, data: ["type": "click"]),
            // An event sent from the click's handler is part of it.
            Timing(type: "EventDispatch", start: 0.21, end: 0.22, depth: 1, data: ["type": "mousedown"]),
            Timing(type: "EventDispatch", start: 0.46, end: 0.47, data: ["type": "mousemove"]),
            Timing(type: "FunctionCall", start: 0.5, end: 0.58),
            Timing(type: "FunctionCall", start: 0.6, end: 0.61),
            Timing(type: "PageTiming", start: 0.02, end: 0.02, data: ["kind": "mark", "name": "go"]),
            Timing(type: "PageTiming", start: 0.05, end: 0.3, data: ["kind": "measure", "name": "work"]),
            Timing(type: "PageTiming", start: 0.1, end: 0.2, data: ["kind": "measure", "name": "inner"]),
            Timing(type: "PageTiming", start: 0.03, end: 0.03, data: ["kind": "FCP", "name": "First Contentful Paint"]),
            Timing(type: "PageTiming", start: 0.04, end: 0.04, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
            Timing(type: "PageTiming", start: 0.09, end: 0.09, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
        ])
        XCTAssertFalse(profile.events.contains { $0.type == "PageTiming" }, "page timings aren't flame chart records")

        XCTAssertEqual(profile.markers.map(\.kind), ["FCP", "LCP"])
        XCTAssertEqual(try XCTUnwrap(profile.markers.last).start, 90, accuracy: 1e-6, "LCP is the last candidate")
        XCTAssertEqual(profile.pageTimings.map(\.name), ["go", "work", "inner"])
        XCTAssertEqual(profile.pageTimings.map(\.row), [0, 0, 1])
        XCTAssertEqual(profile.timingRows, 2)

        XCTAssertEqual(profile.interactions.map(\.type), ["click"])
        let click = try XCTUnwrap(profile.interactions.first)
        XCTAssertEqual(profile.events[click.event].type, "EventDispatch")
        XCTAssertEqual(click.duration, 250, accuracy: 1e-6)

        XCTAssertEqual(profile.frames.map { profile.events[$0].type }, ["RenderingFrame"])
        let long = profile.longTasks.map { profile.events[$0] }
        XCTAssertEqual(long.map(\.type), ["EventDispatch", "FunctionCall"])
        XCTAssertTrue(long.allSatisfy { $0.parent == nil && $0.duration > DeveloperPerformanceProfile.longTask })
    }

    func testInteractionsSplitIntoInputDelayProcessingAndPresentation() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 2),
            // The click's handlers waited on a timer already running: the input delay.
            Timing(type: "TimerFire", start: 0.1, end: 0.25),
            Timing(type: "EventDispatch", start: 0.18, end: 0.24, depth: 1, data: ["type": "click"]),
            Timing(type: "Layout", start: 0.26, end: 0.27),
            // The first paint after the handlers ends the presentation delay.
            Timing(type: "Paint", start: 0.28, end: 0.29),
            Timing(type: "Paint", start: 0.4, end: 0.41),
            // Without a paint, the frame after the handlers does.
            Timing(type: "EventDispatch", start: 1.0, end: 1.05, data: ["type": "keydown"]),
            Timing(type: "RenderingFrame", start: 1.06, end: 1.08),
        ])
        XCTAssertEqual(profile.interactions.map(\.type), ["click", "keydown"])
        let click = profile.interactions[0]
        XCTAssertEqual(profile.events[click.event].type, "EventDispatch")
        XCTAssertEqual(click.start, 100, accuracy: 1e-6)
        XCTAssertEqual(click.inputDelay, 80, accuracy: 1e-6)
        XCTAssertEqual(click.processingDuration, 60, accuracy: 1e-6)
        XCTAssertEqual(click.presentationDelay, 50, accuracy: 1e-6)
        XCTAssertEqual(click.duration, 190, accuracy: 1e-6)

        let key = profile.interactions[1]
        XCTAssertEqual(key.inputDelay, 0, accuracy: 1e-6)
        XCTAssertEqual(key.processingDuration, 50, accuracy: 1e-6)
        XCTAssertEqual(key.presentationDelay, 30, accuracy: 1e-6)
    }

    func testAnInteractionWithNothingPaintedAfterItIsItsHandlers() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 3),
            Timing(type: "EventDispatch", start: 0.5, end: 0.6, data: ["type": "pointerdown"]),
            // Over a second later: another frame's paint, not this one's.
            Timing(type: "Paint", start: 1.7, end: 1.71),
        ])
        let down = try XCTUnwrap(profile.interactions.first)
        XCTAssertEqual(down.inputDelay, 0, accuracy: 1e-6)
        XCTAssertEqual(down.presentationDelay, 0, accuracy: 1e-6)
        XCTAssertEqual(down.duration, 100, accuracy: 1e-6)

        // Phases outside the interaction are kept inside it.
        let odd = DeveloperPerformanceProfile.Interaction(event: 0, type: "click", start: 10, end: 20,
                                                          processingStart: 5, processingEnd: 30)
        XCTAssertEqual(odd.inputDelay, 0)
        XCTAssertEqual(odd.processingDuration, 10)
        XCTAssertEqual(odd.presentationDelay, 0)
    }

    func testChromeMilestonesAndMarksOpenAsTimings() throws {
        let trace: [[String: Any]] = [
            ["name": "thread_name", "ph": "M", "pid": 1, "tid": 1, "args": ["name": "CrRendererMain"]],
            ["name": "RunTask", "ph": "X", "pid": 1, "tid": 1, "ts": 1_000, "dur": 60_000, "cat": "devtools.timeline"],
            ["name": "firstContentfulPaint", "ph": "I", "pid": 1, "tid": 1, "ts": 20_000, "cat": "loading"],
            ["name": "MarkLoad", "ph": "I", "pid": 1, "tid": 1, "ts": 40_000, "cat": "devtools.timeline"],
            ["name": "ready", "ph": "R", "pid": 1, "tid": 1, "ts": 30_000, "cat": "blink.user_timing"],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["traceEvents": trace])
        let profile = DeveloperPerformanceProfile(try DeveloperPerformanceTrace.timings(from: data))
        XCTAssertEqual(profile.markers.map(\.kind), ["FCP", "L"])
        XCTAssertEqual(profile.pageTimings.map(\.name), ["ready"])
        XCTAssertEqual(profile.events.map(\.title), ["Run task"])

        // Saved and opened again, they're kept.
        let saved = try DeveloperPerformanceTrace.export(try DeveloperPerformanceTrace.timings(from: data))
        let again = DeveloperPerformanceProfile(try DeveloperPerformanceTrace.timings(from: saved))
        XCTAssertEqual(again.markers.map(\.kind), ["FCP", "L"])
        XCTAssertEqual(again.pageTimings.map(\.name), ["ready"])
    }

    // MARK: Layout shifts

    func testPageShiftsBecomeLayoutShiftRecords() throws {
        var record = [
            Timing(type: "RecordingBounds", start: 10, end: 12),
            Timing(type: "TimeStamp", start: 11, end: 11, data: ["message": "perch-sync 5000"]),
        ]
        DeveloperPerformancePageTimings.merge(["shifts": [
            ["index": 7, "time": 4_500, "value": 0.042, "nodes": ["h1#title", "p.intro"]],
            // Before the recording.
            ["index": 6, "time": 3_000, "value": 0.2, "nodes": []],
        ]], into: &record, bounds: 10...12)
        let shifts = record.filter { $0.type == "LayoutShift" }
        XCTAssertEqual(shifts.count, 1)
        let shift = try XCTUnwrap(shifts.first)
        XCTAssertEqual(shift.start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(shift.data["index"], "7")
        XCTAssertEqual(shift.data["nodes"], "h1#title\np.intro")
        XCTAssertEqual(Double(shift.data["score"] ?? ""), 0.042)
    }

    func testLayoutShiftsClusterAsChromeClustersThem() throws {
        var timings = [Timing(type: "RecordingBounds", start: 0, end: 10)]
        func shift(_ at: Double, _ score: String, _ extra: [String: String] = [:]) {
            timings.append(Timing(type: "LayoutShift", start: at, end: at, data: extra.merging(["score": score]) { $1 }))
        }
        shift(0.1, "0.05", ["index": "3", "nodes": "div#a\np.b"])
        shift(0.6, "0.02")
        // Over a second after the last: a new cluster.
        for at in [2.0, 2.9, 3.8, 4.7, 5.6, 6.5] { shift(at, "0.01") }
        // Under a second after the last, but five seconds after the cluster began: another.
        shift(7.4, "0.1")
        shift(9.5, "not a score")
        let profile = DeveloperPerformanceProfile(timings)

        XCTAssertFalse(profile.events.contains { $0.type == "LayoutShift" })
        XCTAssertEqual(profile.layoutShifts.count, 9)
        let first = try XCTUnwrap(profile.layoutShifts.first)
        XCTAssertEqual(first.time, 100, accuracy: 1e-6)
        XCTAssertEqual(first.index, 3)
        XCTAssertEqual(first.nodes, ["div#a", "p.b"])
        XCTAssertNil(profile.layoutShifts[1].index)

        XCTAssertEqual(profile.shiftClusters.map(\.shifts), [0..<2, 2..<8, 8..<9])
        XCTAssertEqual(profile.shiftClusters[0].score, 0.07, accuracy: 1e-9)
        XCTAssertEqual(profile.shiftClusters[1].start, 2_000, accuracy: 1e-6)
        XCTAssertEqual(profile.shiftClusters[1].end, 6_500, accuracy: 1e-6)
        XCTAssertEqual(profile.cluster(of: 1)?.score ?? 0, 0.07, accuracy: 1e-9)
        XCTAssertEqual(profile.cluster(of: 8)?.shifts, 8..<9)
    }
}
