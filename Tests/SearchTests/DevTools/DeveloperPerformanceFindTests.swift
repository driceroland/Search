import XCTest
@testable import Search

/// Performance › Find (⌘F): which entries match, and stepping through them.
final class DeveloperPerformanceFindTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Find = DeveloperPerformanceFind

    private var profile: DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([
            Timing(type: "EventDispatch", start: 0, end: 0.010, data: ["type": "click"]),
            Timing(type: "FunctionCall", start: 0.001, end: 0.008, depth: 1,
                   data: ["scriptName": "https://example.com/app.js"]),
            Timing(type: "Layout", start: 0.002, end: 0.004, depth: 2),
            Timing(type: "Layout", start: 0.020, end: 0.022),
            Timing(type: "Paint", start: 0.030, end: 0.031),
        ])
    }

    func testMatchesNamesIgnoringCase() {
        let events = profile.shown
        let layouts = Find.matches("layout", in: events)
        XCTAssertEqual(layouts.count, 2)
        XCTAssertTrue(layouts.allSatisfy { events[$0].type == "Layout" })
        XCTAssertEqual(layouts, layouts.sorted(), "in time order")
        XCTAssertEqual(Find.matches("CLICK", in: events).map { events[$0].type }, ["EventDispatch"])
    }

    func testMatchesURLs() {
        let events = profile.shown
        XCTAssertEqual(Find.matches("app.js", in: events).map { events[$0].type }, ["FunctionCall"])
        XCTAssertEqual(Find.matches("example.com", in: events).map { events[$0].type }, ["FunctionCall"])
    }

    func testEmptyOrUnmatchedQueriesFindNothing() {
        XCTAssertEqual(Find.matches("", in: profile.shown), [])
        XCTAssertEqual(Find.matches("   ", in: profile.shown), [])
        XCTAssertEqual(Find.matches("no such entry", in: profile.shown), [])
    }

    func testHiddenEntriesAreLeftOut() {
        var profile = profile
        guard let call = profile.shown.first(where: { $0.type == "FunctionCall" })?.id else {
            return XCTFail("no function call")
        }
        profile.hideChildren(call)
        let layouts = Find.matches("layout", in: profile.shown)
        XCTAssertEqual(layouts.count, 1, "the nested layout merged into its parent")
    }

    func testSteppingGoesRoundTheEnds() {
        XCTAssertNil(Find.step(nil, count: 0, backwards: false))
        XCTAssertEqual(Find.step(nil, count: 3, backwards: false), 0)
        XCTAssertEqual(Find.step(nil, count: 3, backwards: true), 2)
        XCTAssertEqual(Find.step(0, count: 3, backwards: false), 1)
        XCTAssertEqual(Find.step(2, count: 3, backwards: false), 0)
        XCTAssertEqual(Find.step(0, count: 3, backwards: true), 2)
        XCTAssertEqual(Find.step(7, count: 3, backwards: false), 0, "a stale index starts over")
    }

    func testStatusReadsAsChromes() {
        XCTAssertEqual(Find.status(nil, count: 0), "No matches")
        XCTAssertEqual(Find.status(0, count: 12), "1 of 12")
        XCTAssertEqual(Find.status(nil, count: 4), "0 of 4")
    }
}
