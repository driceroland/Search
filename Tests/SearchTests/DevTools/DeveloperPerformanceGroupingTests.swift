import XCTest
@testable import Search

/// Bottom-up and Call tree's grouping menu, Filter box (with Match case and
/// Use regular expression) and Bottom-up's heaviest stack.
final class DeveloperPerformanceGroupingTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    /// A 100 ms timer calling app.js (10–60 ms, frame F1), which lays out
    /// (20–30), then lib.js (70–90); a paint at 120–130 ms.
    /// Ids: 0 timer, 1 app.js, 2 layout, 3 lib.js, 4 paint.
    private var sample: [Timing] {
        [
            Timing(type: "TimerFire", start: 0, end: 0.100),
            Timing(type: "FunctionCall", start: 0.010, end: 0.060, depth: 1,
                   data: ["scriptName": "https://cdn.example.com/app.js", "scriptLine": "1", "frame": "F1"]),
            Timing(type: "Layout", start: 0.020, end: 0.030, depth: 2),
            Timing(type: "FunctionCall", start: 0.070, end: 0.090, depth: 1,
                   data: ["scriptName": "https://other.org/lib.js"]),
            Timing(type: "Paint", start: 0.120, end: 0.130),
        ]
    }

    // MARK: Grouping

    func testGroupingsOfferedAreThoseTheDataSupports() {
        XCTAssertEqual(DeveloperPerformanceProfile(sample).groupings, DeveloperPerformanceGrouping.allCases)
        XCTAssertEqual(DeveloperPerformanceProfile(DeveloperPerformanceHidesTests.tree).groupings,
                       [.none, .activity, .category])
    }

    func testEachGroupingKey() {
        let profile = DeveloperPerformanceProfile(sample)
        let none = DeveloperPerformanceGrouping.unattributed
        XCTAssertEqual(profile.groupKeys(.activity), ["Timer fired", "Function call", "Layout", "Function call", "Paint"])
        XCTAssertEqual(profile.groupKeys(.category), ["Scripting", "Scripting", "Rendering", "Scripting", "Painting"])
        XCTAssertEqual(profile.groupKeys(.url), [none, "https://cdn.example.com/app.js", "https://cdn.example.com/app.js",
                                                 "https://other.org/lib.js", none])
        XCTAssertEqual(profile.groupKeys(.subdomain), [none, "cdn.example.com", "cdn.example.com", "other.org", none])
        XCTAssertEqual(profile.groupKeys(.domain), [none, "example.com", "example.com", "other.org", none])
        XCTAssertEqual(profile.groupKeys(.frame), [none, "F1", "F1", none, none])
    }

    func testDomainsAreSites() {
        XCTAssertEqual(DeveloperPerformanceGrouping.domain(of: "a.b.example.com"), "example.com")
        XCTAssertEqual(DeveloperPerformanceGrouping.domain(of: "www.example.co.uk"), "example.co.uk")
        XCTAssertEqual(DeveloperPerformanceGrouping.domain(of: "example.com"), "example.com")
        XCTAssertEqual(DeveloperPerformanceGrouping.domain(of: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(DeveloperPerformanceGrouping.domain(of: "localhost"), "localhost")
    }

    func testCallTreeGroupedByCategoryHoldsTheTopLevelActivities() throws {
        let profile = DeveloperPerformanceProfile(sample)
        let tree = profile.callTree(in: profile.bounds, groupedBy: .category)
        XCTAssertEqual(tree.map(\.activity), ["Scripting", "Painting"])
        XCTAssertTrue(tree.allSatisfy(\.isGroup))
        let scripting = try XCTUnwrap(tree.first)
        XCTAssertEqual(scripting.totalTime, 100, accuracy: 0.0001)
        XCTAssertEqual(scripting.children.map(\.activity), ["Timer fired"])
        XCTAssertFalse(scripting.children[0].isGroup)
        XCTAssertEqual(profile.callTree(in: profile.bounds, groupedBy: .none).map(\.activity), ["Timer fired", "Paint"])
    }

    func testBottomUpGroupedByDomainCountsNestedRecordsOnce() throws {
        let profile = DeveloperPerformanceProfile(sample)
        let groups = profile.bottomUp(in: profile.bounds, groupedBy: .domain)
        XCTAssertEqual(groups.map(\.activity), ["example.com", DeveloperPerformanceGrouping.unattributed, "other.org"])
        let site = try XCTUnwrap(groups.first)
        XCTAssertEqual(site.selfTime, 50, accuracy: 0.0001)
        XCTAssertEqual(site.totalTime, 50, accuracy: 0.0001, "the layout is inside app.js's call")
        XCTAssertEqual(Set(site.children.map(\.activity)), ["Function call — app.js:1", "Layout"])
        XCTAssertEqual(groups[1].selfTime, 40, accuracy: 0.0001)
        XCTAssertEqual(groups[1].totalTime, 110, accuracy: 0.0001)
        XCTAssertEqual(profile.bottomUp(in: profile.bounds, groupedBy: .frame).first?.activity,
                       DeveloperPerformanceGrouping.unattributed)
    }

    // MARK: Filter

    func testFilterKeepsMatchingRowsAndTheirAncestors() throws {
        let profile = DeveloperPerformanceProfile(sample)
        let tree = profile.callTree(in: profile.bounds)
        let kept = DeveloperPerformanceTextFilter(text: "layout").apply(to: tree)
        XCTAssertEqual(kept.map(\.activity), ["Timer fired"])
        XCTAssertEqual(kept[0].children.map(\.activity), ["Function call — app.js:1"])
        XCTAssertEqual(kept[0].children[0].children.map(\.activity), ["Layout"])
        XCTAssertEqual(kept[0].totalTime, 100, accuracy: 0.0001, "times are the unfiltered ones")

        XCTAssertTrue(DeveloperPerformanceTextFilter(text: "layout", matchCase: true).apply(to: tree).isEmpty)
        XCTAssertEqual(DeveloperPerformanceTextFilter(text: "Layout", matchCase: true).apply(to: tree).count, 1)
        XCTAssertEqual(DeveloperPerformanceTextFilter().apply(to: tree), tree)
    }

    func testFilterWithARegularExpression() throws {
        let profile = DeveloperPerformanceProfile(sample)
        let tree = profile.callTree(in: profile.bounds)
        let calls = DeveloperPerformanceTextFilter(text: "^function call — (app|lib)", regex: true).apply(to: tree)
        XCTAssertEqual(calls.map(\.activity), ["Timer fired"])
        XCTAssertEqual(Set(calls[0].children.map(\.activity)), ["Function call — app.js:1", "Function call — lib.js"])
        XCTAssertTrue(calls[0].children.allSatisfy { $0.children.isEmpty }, "a row beneath that doesn't match goes")
        XCTAssertTrue(DeveloperPerformanceTextFilter(text: "^function", matchCase: true, regex: true).apply(to: tree).isEmpty)
        let broken = DeveloperPerformanceTextFilter(text: "(", regex: true)
        XCTAssertFalse(broken.isValid)
        XCTAssertEqual(broken.apply(to: tree), tree, "a broken expression filters nothing")
        XCTAssertEqual(DeveloperPerformanceTextFilter(text: "Pa.nt", regex: true).apply(to: tree).map(\.activity), ["Paint"])
    }

    // MARK: Heaviest stack

    func testHeaviestStackRunsThroughTheChosenRow() throws {
        let profile = DeveloperPerformanceProfile(DeveloperPerformanceHidesTests.tree)
        let bottom = profile.bottomUp(in: profile.bounds)
        let g = try XCTUnwrap(DeveloperPerformanceProfile.path(to: "/g", in: bottom))
        let stack = profile.heaviestStack(through: g, in: profile.bounds)
        XCTAssertEqual(stack.map(\.activity), ["Timer fired", "f", "g", "f", "h"])
        XCTAssertEqual(stack.map(\.isSelected), [false, false, true, false, false])
        XCTAssertEqual(stack[2].totalTime, 40, accuracy: 0.0001)
        XCTAssertEqual(stack[3].totalTime, 20, accuracy: 0.0001)

        // A caller's row: the stack goes up from it, then down the path.
        let caller = try XCTUnwrap(DeveloperPerformanceProfile.path(to: "/h/f", in: bottom))
        XCTAssertEqual(caller.map(\.activity), ["h", "f"])
        let up = profile.heaviestStack(through: caller, in: profile.bounds)
        XCTAssertEqual(up.first?.activity, "Timer fired")
        XCTAssertEqual(up.suffix(2).map(\.activity), ["f", "h"])
        XCTAssertEqual(up.filter(\.isSelected).map(\.activity), ["f"])
        XCTAssertEqual(up.last?.isSelected, false)

        XCTAssertNil(DeveloperPerformanceProfile.path(to: "/nothing", in: bottom))
        XCTAssertTrue(profile.heaviestStack(through: [], in: profile.bounds).isEmpty)
    }
}
