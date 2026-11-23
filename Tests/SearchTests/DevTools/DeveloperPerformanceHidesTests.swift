import XCTest
@testable import Search

/// The flame chart's context menu hides: Hide function, Hide children,
/// Hide repeating children, Reset children and Reset trace, and what
/// Call tree and Bottom-up make of them.
final class DeveloperPerformanceHidesTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    /// A 100 ms timer running f (10–90 ms), which calls g (20–60), which
    /// calls f again (30–50), which calls h (35–45); f then calls h (70–80).
    /// Ids, in start order: 0 timer, 1 f, 2 g, 3 f, 4 h, 5 h.
    static var tree: [DeveloperToolsSession.Timing] {
        func frame(_ name: String, _ start: Double, _ end: Double, _ depth: Int) -> Timing {
            Timing(type: "JavaScriptFrame", start: start / 1_000, end: end / 1_000, depth: depth, data: ["name": name])
        }
        return [
            Timing(type: "TimerFire", start: 0, end: 0.100),
            frame("f", 10, 90, 1),
            frame("g", 20, 60, 2),
            frame("f", 30, 50, 3),
            frame("h", 35, 45, 4),
            frame("h", 70, 80, 2),
        ]
    }

    private func makeProfile() -> DeveloperPerformanceProfile { DeveloperPerformanceProfile(Self.tree) }

    func testTheSyntheticTreeLaysOutAsExpected() {
        let profile = makeProfile()
        XCTAssertEqual(profile.events.map(\.title), ["Timer fired", "f", "g", "f", "h", "h"])
        XCTAssertEqual(profile.events.map(\.parent), [nil, 0, 1, 2, 3, 1])
        XCTAssertEqual(profile.shown.map(\.row), [0, 1, 2, 3, 4, 2])
        XCTAssertEqual(profile.shownRows, 5)
        XCTAssertTrue(profile.hides.isEmpty)
    }

    func testHideFunctionMergesEveryEntryOfItIntoItsParent() {
        var profile = makeProfile()
        profile.hideFunction(2)
        XCTAssertEqual(profile.shown.map(\.isHidden), [false, false, true, false, false, false])
        XCTAssertEqual(profile.shown[3].parent, 1, "g's callee now hangs from f")
        XCTAssertEqual(profile.shown.map(\.row), [0, 1, -1, 2, 3, 2])
        XCTAssertEqual(profile.shownRows, 4)
        XCTAssertTrue(profile.shown[1].hidesChildren)
        XCTAssertFalse(profile.shown[0].hidesChildren)
        // f's 80 ms less the 20 ms f and the 10 ms h now beneath it.
        XCTAssertEqual(profile.shown[1].selfTime, 50, accuracy: 0.0001)
        XCTAssertEqual(profile.events[1].selfTime, 30, accuracy: 0.0001, "the records themselves are unchanged")
        XCTAssertEqual(profile.event(at: 40, row: 2)?.id, 3)

        var both = makeProfile()
        both.hideFunction(1)
        XCTAssertEqual(both.shown.map(\.isHidden), [false, true, false, true, false, false], "every f, wherever it is")
        XCTAssertEqual(both.shown[2].parent, 0)
        XCTAssertEqual(both.shown[4].parent, 2)
        XCTAssertEqual(both.shown[5].row, 1)
        // The timer's 100 ms less g's 40 and the later h's 10.
        XCTAssertEqual(both.shown[0].selfTime, 50, accuracy: 0.0001)
    }

    func testHideChildrenCollapsesEverythingBeneath() {
        var profile = makeProfile()
        XCTAssertTrue(profile.canHideChildren(1))
        XCTAssertFalse(profile.canHideChildren(4), "a leaf has none")
        profile.hideChildren(1)
        XCTAssertEqual(profile.shown.map(\.isHidden), [false, false, true, true, true, true])
        XCTAssertTrue(profile.shown[1].children.isEmpty)
        XCTAssertTrue(profile.shown[1].hidesChildren)
        XCTAssertEqual(profile.shown[1].selfTime, 80, accuracy: 0.0001)
        XCTAssertEqual(profile.shownRows, 2)
        XCTAssertFalse(profile.canHideChildren(1))
        XCTAssertNil(profile.event(at: 40, row: 2))
    }

    func testHideRepeatingChildrenMergesOnlyTheSameFunction() {
        var profile = makeProfile()
        XCTAssertTrue(profile.canHideRepeatingChildren(1))
        XCTAssertFalse(profile.canHideRepeatingChildren(2), "g doesn't call g")
        profile.hideRepeatingChildren(1)
        XCTAssertEqual(profile.shown.map(\.isHidden), [false, false, false, true, false, false])
        XCTAssertEqual(profile.shown[4].parent, 2)
        XCTAssertEqual(profile.shown[4].row, 3)
        XCTAssertTrue(profile.shown[2].hidesChildren)
        XCTAssertEqual(profile.shown[2].selfTime, 30, accuracy: 0.0001, "g's 40 ms less h's 10")
        XCTAssertFalse(profile.canHideRepeatingChildren(1))
    }

    func testResetChildrenUndoesHidesBeneathAnEntryOnly() {
        var profile = makeProfile()
        profile.hideChildren(1)
        XCTAssertTrue(profile.canResetChildren(1))
        profile.resetChildren(1)
        XCTAssertTrue(profile.hides.isEmpty)
        XCTAssertFalse(profile.shown.contains { $0.isHidden })

        // A hidden function comes back beneath the entry reset, not elsewhere.
        profile.hideFunction(4)
        XCTAssertEqual(profile.shown.map(\.isHidden), [false, false, false, false, true, true])
        profile.resetChildren(2)
        XCTAssertEqual(profile.shown.map(\.isHidden), [false, false, false, false, false, true])
        XCTAssertEqual(profile.shown[4].row, 4)
        XCTAssertFalse(profile.canResetChildren(2))
        XCTAssertTrue(profile.canResetChildren(1))
    }

    func testResetTraceUndoesEverything() {
        var profile = makeProfile()
        profile.hideFunction(2)
        profile.hideChildren(5)
        profile.hideRepeatingChildren(1)
        let hidden = profile
        profile.resetTrace()
        XCTAssertTrue(profile.hides.isEmpty)
        XCTAssertEqual(profile.shown, profile.events)
        XCTAssertEqual(profile.shownRows, profile.rows)
        XCTAssertNotEqual(profile, hidden, "a hide is a change the panel redraws for")
    }

    func testANewRecordingStartsWithNoHides() {
        var profile = makeProfile()
        profile.hideChildren(0)
        let fresh = DeveloperPerformanceProfile(Self.tree)
        XCTAssertTrue(fresh.hides.isEmpty)
        XCTAssertFalse(fresh.shown.contains { $0.isHidden })
    }

    // MARK: Aggregation after hides

    func testCallTreeAndBottomUpFollowTheHides() throws {
        var profile = makeProfile()
        profile.hideFunction(2)
        let tree = profile.callTree(in: profile.bounds)
        let timer = try XCTUnwrap(tree.first)
        XCTAssertEqual(timer.children.map(\.activity), ["f"])
        let f = try XCTUnwrap(timer.children.first)
        XCTAssertEqual(f.selfTime, 50, accuracy: 0.0001)
        XCTAssertEqual(f.children.map(\.activity), ["f", "h"])
        XCTAssertFalse(tree.contains { $0.activity == "g" })

        profile.resetTrace()
        profile.hideChildren(1)
        let bottom = profile.bottomUp(in: profile.bounds)
        XCTAssertEqual(bottom.map(\.activity), ["f", "Timer fired"])
        XCTAssertEqual(bottom[0].selfTime, 80, accuracy: 0.0001)
        XCTAssertEqual(bottom[1].selfTime, 20, accuracy: 0.0001)
    }
}
