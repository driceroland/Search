import XCTest
@testable import Search

/// The Performance panel's pure logic: recording records, laying them out
/// as a flame chart, the Summary, Bottom-up, Call tree and Event log totals,
/// and the zoom, pan and range-selection maths.
final class DeveloperPerformanceTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    /// A 10 ms timer whose 6 ms function call lays out for 2 ms, then a
    /// separate 4 ms paint at 20 ms. Times are in seconds, as WebKit sends them.
    private var sample: [Timing] {
        [
            Timing(type: "TimerFire", start: 1.000, end: 1.010, data: ["timerId": "3"]),
            Timing(type: "FunctionCall", start: 1.001, end: 1.007, depth: 1,
                   data: ["scriptName": "https://example.com/app.js", "scriptLine": "12"], stack: ["tick — app.js:12"]),
            Timing(type: "Layout", start: 1.002, end: 1.004, depth: 2),
            Timing(type: "Paint", start: 1.020, end: 1.024),
        ]
    }

    // MARK: Recording

    @MainActor
    func testAddTimingsKeepsNestedRecordsWithDepthDataAndStack() {
        let raw: [String: Any] = [
            "type": "EventDispatch", "startTime": 2.0, "endTime": 2.5, "data": ["type": "click"],
            "stackTrace": [["functionName": "", "url": "https://example.com/a/main.js", "lineNumber": 10]] as [[String: Any]],
            "children": [
                ["type": "FunctionCall", "startTime": 2.1, "endTime": 2.2] as [String: Any],
                ["type": "TimeStamp", "startTime": 2.3, "data": ["message": "here"]] as [String: Any],
                // No start: skipped, but what it holds is kept.
                ["type": "Unknown",
                 "children": [["type": "Layout", "startTime": 2.35, "endTime": 2.4] as [String: Any]]] as [String: Any],
            ] as [[String: Any]],
        ]
        var result: [Timing] = []
        DeveloperToolsSession.addTimings(raw, to: &result)
        XCTAssertEqual(result.map(\.type), ["EventDispatch", "FunctionCall", "TimeStamp", "Layout"])
        XCTAssertEqual(result.map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(result[0].data["type"], "click")
        XCTAssertEqual(result[0].stack, ["(anonymous) — main.js:10"])
        XCTAssertEqual(result[0].milliseconds, 500, accuracy: 0.001)
        XCTAssertEqual(result[2].end, result[2].start, "an instant has no length")
        XCTAssertEqual(result[2].data["message"], "here")
    }

    // MARK: Layout

    func testRecordsStackByTimeWithSelfTimes() throws {
        let profile = DeveloperPerformanceProfile(sample)
        XCTAssertEqual(profile.events.map(\.type), ["TimerFire", "FunctionCall", "Layout", "Paint"])
        XCTAssertEqual(profile.events.map(\.row), [0, 1, 2, 0])
        XCTAssertEqual(profile.events.map(\.parent), [nil, 0, 1, nil])
        XCTAssertEqual(profile.rows, 3)
        XCTAssertEqual(profile.duration, 24, accuracy: 0.0001)
        XCTAssertEqual(profile.events[0].selfTime, 4, accuracy: 0.0001)
        XCTAssertEqual(profile.events[1].selfTime, 4, accuracy: 0.0001)
        XCTAssertEqual(profile.events[2].selfTime, 2, accuracy: 0.0001)
        XCTAssertEqual(profile.events[1].title, "Function call")
        XCTAssertEqual(profile.events[1].detail, "app.js:12")
        XCTAssertEqual(profile.events[1].category, .scripting)
        XCTAssertEqual(profile.events[2].category, .rendering)
        XCTAssertEqual(profile.events[3].category, .painting)
    }

    func testRecordsThatStartTogetherPutTheLongerOneOnTop() {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "Layout", start: 0, end: 0.001),
            Timing(type: "RenderingFrame", start: 0, end: 0.005),
        ])
        XCTAssertEqual(profile.events.map(\.type), ["RenderingFrame", "Layout"])
        XCTAssertEqual(profile.events.map(\.row), [0, 1])
    }

    func testTitlesAreChromes() {
        XCTAssertEqual(DeveloperPerformanceEvent.title("EventDispatch", data: ["type": "click"]), "Event: click")
        XCTAssertEqual(DeveloperPerformanceEvent.title("RecalculateStyles", data: [:]), "Recalculate style")
        XCTAssertEqual(DeveloperPerformanceEvent.title("SomethingNew", data: [:]), "Something new")
        XCTAssertEqual(DeveloperPerformanceCategory.of("SomethingNew"), .system)
    }

    // MARK: Tabs

    func testSummaryTotalsSelfTimeByCategoryWithIdle() {
        let profile = DeveloperPerformanceProfile(sample)
        let whole = profile.summary(in: profile.bounds)
        XCTAssertEqual(whole.categories[.scripting] ?? 0, 8, accuracy: 0.0001)
        XCTAssertEqual(whole.categories[.rendering] ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(whole.categories[.painting] ?? 0, 4, accuracy: 0.0001)
        XCTAssertEqual(whole.idle, 10, accuracy: 0.0001)
        // Only the first 3 ms: 1 ms of timer, 1 of function call, 1 of layout.
        let part = profile.summary(in: 0...3)
        XCTAssertEqual(part.categories[.scripting] ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(part.categories[.rendering] ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(part.categories[.painting])
    }

    func testCallTreeNestsAndBottomUpLeadsBackToCallers() throws {
        let profile = DeveloperPerformanceProfile(sample)
        let tree = profile.callTree(in: profile.bounds)
        XCTAssertEqual(tree.map(\.activity), ["Timer fired", "Paint"])
        let timer = try XCTUnwrap(tree.first)
        XCTAssertEqual(timer.totalTime, 10, accuracy: 0.0001)
        XCTAssertEqual(timer.selfTime, 4, accuracy: 0.0001)
        XCTAssertEqual(timer.children.map(\.activity), ["Function call — app.js:12"])
        XCTAssertEqual(timer.children.first?.children.map(\.activity), ["Layout"])

        let bottom = profile.bottomUp(in: profile.bounds)
        XCTAssertEqual(bottom.first?.selfTime ?? 0, 4, accuracy: 0.0001)
        let layout = try XCTUnwrap(bottom.first { $0.activity == "Layout" })
        XCTAssertEqual(layout.selfTime, 2, accuracy: 0.0001)
        XCTAssertEqual(layout.children.map(\.activity), ["Function call — app.js:12"])
        XCTAssertEqual(layout.children.first?.children.map(\.activity), ["Timer fired"])
        XCTAssertNil(layout.children.first?.children.first?.outline)
    }

    func testBottomUpCountsNestedRecordsOfOneActivityOnce() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "FunctionCall", start: 0, end: 0.010),
            Timing(type: "FunctionCall", start: 0.002, end: 0.004, depth: 1),
        ])
        let call = try XCTUnwrap(profile.bottomUp(in: profile.bounds).first)
        XCTAssertEqual(call.totalTime, 10, accuracy: 0.0001)
        XCTAssertEqual(call.selfTime, 10, accuracy: 0.0001)
    }

    func testEventLogFiltersByRangeTextAndDuration() {
        let profile = DeveloperPerformanceProfile(sample)
        XCTAssertEqual(profile.log(in: profile.bounds).map(\.type), ["TimerFire", "FunctionCall", "Layout", "Paint"])
        XCTAssertEqual(profile.log(in: 15...30).map(\.type), ["Paint"])
        XCTAssertEqual(profile.log(in: profile.bounds, filter: "app.js").map(\.type), ["FunctionCall"])
        XCTAssertEqual(profile.log(in: profile.bounds, minimum: 5).map(\.type), ["TimerFire", "FunctionCall"])
    }

    func testHitTestingFindsTheRecordOnARowWithTolerance() {
        let profile = DeveloperPerformanceProfile(sample)
        XCTAssertEqual(profile.event(at: 5, row: 0)?.type, "TimerFire")
        XCTAssertEqual(profile.event(at: 3, row: 2)?.type, "Layout")
        XCTAssertNil(profile.event(at: 15, row: 0))
        XCTAssertEqual(profile.event(at: 19.5, row: 0, tolerance: 1)?.type, "Paint")
        XCTAssertNil(profile.event(at: 3, row: 5))
    }

    func testOverviewActivityIsBusyWhereRecordsRan() {
        let profile = DeveloperPerformanceProfile(sample)
        let buckets = profile.activity(buckets: 24)
        XCTAssertEqual(buckets.count, 24)
        let busy = buckets[0].values.reduce(0, +)
        XCTAssertEqual(busy, 1, accuracy: 0.0001)
        XCTAssertTrue(buckets[15].isEmpty)
        XCTAssertEqual(buckets[21][.painting] ?? 0, 1, accuracy: 0.0001)
    }

    // MARK: Zoom, pan and range selection

    func testZoomKeepsTheAnchorInPlaceAndStaysInBounds() {
        let window = DeveloperFlameWindow(lower: 0, upper: 100)
        let zoomed = window.zoomed(by: 2, around: 25, in: 0...100)
        XCTAssertEqual(zoomed.lower, 12.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.upper, 62.5, accuracy: 0.0001)
        XCTAssertEqual(window.zoomed(by: 0.5, around: 50, in: 0...100), window, "never wider than the recording")
        let tiny = window.zoomed(by: 1e9, around: 50, in: 0...100)
        XCTAssertEqual(tiny.upper - tiny.lower, DeveloperFlameWindow.least, accuracy: 1e-9)
        XCTAssertEqual(DeveloperFlameWindow(lower: 80, upper: 100).zoomed(by: 0.5, around: 100, in: 0...100),
                       DeveloperFlameWindow(lower: 60, upper: 100))
    }

    func testPanningStopsAtTheEnds() {
        let window = DeveloperFlameWindow(lower: 10, upper: 30)
        XCTAssertEqual(window.panned(by: 5, in: 0...100), DeveloperFlameWindow(lower: 15, upper: 35))
        XCTAssertEqual(window.panned(by: -50, in: 0...100), DeveloperFlameWindow(lower: 0, upper: 20))
        XCTAssertEqual(window.panned(by: 500, in: 0...100), DeveloperFlameWindow(lower: 80, upper: 100))
        XCTAssertEqual(window.x(20, width: 200), 100, accuracy: 0.0001)
        XCTAssertEqual(window.time(atX: 50, width: 200), 15, accuracy: 0.0001)
    }

    func testOverviewDragChoosesResizesAndSlides() {
        let original = DeveloperFlameWindow(lower: 20, upper: 40)
        XCTAssertEqual(DeveloperOverviewDrag.grab(atX: 21, lowerX: 20, upperX: 40), .lower)
        XCTAssertEqual(DeveloperOverviewDrag.grab(atX: 43, lowerX: 20, upperX: 40), .upper)
        XCTAssertEqual(DeveloperOverviewDrag.grab(atX: 30, lowerX: 20, upperX: 40), .slide)
        XCTAssertEqual(DeveloperOverviewDrag.grab(atX: 80, lowerX: 20, upperX: 40), .choose)

        XCTAssertEqual(DeveloperOverviewDrag.window(.choose, original: original, from: 70, to: 50, bounds: 0...100),
                       DeveloperFlameWindow(lower: 50, upper: 70))
        XCTAssertEqual(DeveloperOverviewDrag.window(.choose, original: original, from: 70, to: 150, bounds: 0...100),
                       DeveloperFlameWindow(lower: 70, upper: 100))
        XCTAssertEqual(DeveloperOverviewDrag.window(.choose, original: original, from: 70, to: 70, bounds: 0...100),
                       original, "a click chooses nothing")
        XCTAssertEqual(DeveloperOverviewDrag.window(.lower, original: original, from: 20, to: 5, bounds: 0...100),
                       DeveloperFlameWindow(lower: 5, upper: 40))
        let pinched = DeveloperOverviewDrag.window(.lower, original: original, from: 20, to: 60, bounds: 0...100)
        XCTAssertEqual(pinched.upper - pinched.lower, DeveloperFlameWindow.least, accuracy: 1e-9)
        XCTAssertEqual(DeveloperOverviewDrag.window(.upper, original: original, from: 40, to: 90, bounds: 0...100),
                       DeveloperFlameWindow(lower: 20, upper: 90))
        XCTAssertEqual(DeveloperOverviewDrag.window(.slide, original: original, from: 30, to: 95, bounds: 0...100),
                       DeveloperFlameWindow(lower: 80, upper: 100))
    }

    func testRulerStepsAndLabels() {
        XCTAssertEqual(DeveloperPerformanceRuler.step(span: 1_000, width: 800), 100)
        XCTAssertEqual(DeveloperPerformanceRuler.step(span: 1_000, width: 500), 200)
        XCTAssertEqual(DeveloperPerformanceRuler.step(span: 1_000, width: 300), 500)
        XCTAssertEqual(DeveloperPerformanceRuler.ticks(in: .init(lower: 50, upper: 450), width: 320), [100, 200, 300, 400])
        XCTAssertEqual(DeveloperPerformanceRuler.label(850), "850 ms")
        XCTAssertEqual(DeveloperPerformanceRuler.label(1_250), "1.25 s")
        XCTAssertEqual(DeveloperPerformanceRuler.label(2.5), "2.5 ms")
        XCTAssertEqual(DeveloperPerformanceRuler.label(0.12), "120 µs")
        XCTAssertEqual(DeveloperPerformanceRuler.label(0), "0 ms")
    }
}
