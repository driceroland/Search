import XCTest
@testable import Search

/// Performance's Animations track: WebKit's Animation.trackingUpdate
/// states read into bars, and the Animations drawer's animations when
/// WebKit has no Animation instrument.
final class DeveloperPerformanceAnimationsTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    private func update(_ id: String, _ state: String, at time: Double, name: String? = nil,
                        property: String? = nil) -> [String: Any] {
        var raw: [String: Any] = ["timestamp": time, "trackingAnimationId": id, "animationState": state]
        if let name { raw["animationName"] = name }
        if let property { raw["transitionProperty"] = property }
        return raw
    }

    func testStatesBecomeBarsFromFirstStateToDone() throws {
        let bars = DeveloperPerformanceAnimationTrack.timings([
            update("1", "ready", at: 10.1, name: "spin"),
            update("1", "delayed", at: 10.1, name: "spin"),
            update("2", "active", at: 10.2, property: "opacity"),
            update("1", "active", at: 10.3, name: "spin"),
            update("2", "done", at: 10.5, property: "opacity"),
            update("1", "canceled", at: 10.8, name: "spin"),
        ], bounds: 10...11)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.type), ["AnimationBar", "AnimationBar"])
        let spin = bars[0], fade = bars[1]
        XCTAssertEqual(spin.data["name"], "spin")
        XCTAssertEqual(spin.data["kind"], "CSS animation")
        XCTAssertEqual(spin.data["state"], "canceled")
        XCTAssertEqual(spin.start, 10.1, accuracy: 1e-9)
        XCTAssertEqual(spin.end, 10.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(spin.data["activeOffset"].flatMap { Double($0) }), 200, accuracy: 1e-6)
        XCTAssertEqual(fade.data["name"], "opacity")
        XCTAssertEqual(fade.data["kind"], "CSS transition")
        XCTAssertEqual(fade.data["state"], "done")
        XCTAssertEqual(fade.end - fade.start, 0.3, accuracy: 1e-9)
    }

    func testRunningAnimationsEndWithTheRecordingAndEarlierOnesStartWithIt() {
        let bars = DeveloperPerformanceAnimationTrack.timings([
            update("a", "done", at: 10.2, name: "intro"),
            update("b", "active", at: 10.4, name: "pulse"),
            update("c", "active", at: 9.0, name: "old"),
            update("c", "done", at: 9.5, name: "old"),
        ], bounds: 10...11)
        XCTAssertEqual(bars.map { $0.data["name"] }, ["intro", "pulse"], "one wholly before the recording is left out")
        XCTAssertEqual(bars[0].start, 10)
        XCTAssertEqual(bars[1].end, 11)
        XCTAssertEqual(bars[1].data["state"], "active")
    }

    func testARestartedAnimationGetsASecondBar() {
        let bars = DeveloperPerformanceAnimationTrack.timings([
            update("1", "active", at: 10.1, name: "spin"),
            update("1", "done", at: 10.2, name: "spin"),
            update("1", "active", at: 10.4, name: "spin"),
            update("1", "done", at: 10.6, name: "spin"),
        ], bounds: 10...11)
        XCTAssertEqual(bars.count, 2)
    }

    func testTheProfileStacksBarsIntoRows() {
        let bars = DeveloperPerformanceAnimationTrack.timings([
            update("1", "active", at: 0.1, name: "a"),
            update("2", "active", at: 0.2, name: "b"),
            update("1", "done", at: 0.5, name: "a"),
            update("3", "active", at: 0.6, name: "c"),
            update("2", "done", at: 0.7, name: "b"),
            update("3", "done", at: 0.9, name: "c"),
        ], bounds: 0...1)
        let profile = DeveloperPerformanceProfile([Timing(type: "RecordingBounds", start: 0, end: 1)] + bars)
        XCTAssertEqual(profile.animations.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(profile.animations.map(\.row), [0, 1, 0])
        XCTAssertEqual(profile.animationRows, 2)
        XCTAssertEqual(profile.animations[0].start, 100, accuracy: 1e-6)
        XCTAssertEqual(profile.animations[0].duration, 400, accuracy: 1e-6)
        XCTAssertTrue(profile.events.isEmpty, "bars stay out of the flame chart")
    }

    func testTheDrawersAnimationsAreTimedFromTheirEffects() {
        var spin = DeveloperAnimation(id: "x", name: "spin", kind: .cssAnimation,
                                      effect: DeveloperAnimationEffect(startDelay: 100, iterationCount: 2, iterationDuration: 150),
                                      arrival: 1_000_000 - 800)
        spin.node = 7
        let endless = DeveloperAnimation(id: "y", name: nil, kind: .cssTransition,
                                         effect: DeveloperAnimationEffect(iterationCount: .infinity, iterationDuration: 100),
                                         arrival: 1_000_000 - 200)
        let early = DeveloperAnimation(id: "z", arrival: 1_000_000 - 5_000)
        let bars = DeveloperPerformanceAnimationTrack.timings(fromDrawer: [endless, spin, early], stopped: 1_000_000,
                                                              bounds: 10...11)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].data["name"], "spin")
        XCTAssertEqual(bars[0].start, 10.2, accuracy: 1e-9)
        XCTAssertEqual(bars[0].end, 10.6, accuracy: 1e-9, "100 ms delay then two 150 ms iterations")
        XCTAssertEqual(bars[0].data["node"], "7")
        XCTAssertEqual(bars[1].data["kind"], "CSS transition")
        XCTAssertEqual(bars[1].data["name"], "transition")
        XCTAssertEqual(bars[1].end, 11, "an endless one runs to the recording's end")
        XCTAssertEqual(bars[1].data["state"], "active")
    }

    func testACappedRecordingKeepsBarsWithinTheirBudget() {
        var records = (0..<(DeveloperToolsSession.timelineLimit + 1)).map {
            Timing(type: "Layout", start: Double($0), end: Double($0))
        }
        records += (0..<(DeveloperPerformanceAnimationTrack.limit + 5)).map {
            Timing(type: "AnimationBar", start: Double($0), end: Double($0) + 1, data: ["name": "a"])
        }
        let capped = DeveloperToolsSession.cappedTimeline(records)
        XCTAssertEqual(capped.filter { $0.type == "AnimationBar" }.count, DeveloperPerformanceAnimationTrack.limit)
    }
}
