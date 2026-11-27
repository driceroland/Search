import AppKit
import XCTest
@testable import Search

/// A mouse's wheel over the tabs, read as steps between spaces (SpaceWheel.swift):
/// each notch of a notched wheel one step, in the way it was turned, however
/// quickly they come and however big the Mac makes them; a wheel smoothed by
/// its driver one step every `smooth` points; a trackpad not a wheel at all.
final class SpaceWheelTests: XCTestCase {
    /// Feeds (along, time) pairs and answers the steps that came of them.
    private func run(_ events: [(CGFloat, TimeInterval)], notched: Bool) -> [Int] {
        var wheel = WheelSteps()
        return events.map { wheel.feed($0.0, notched: notched, at: $0.1) }.filter { $0 != 0 }
    }

    /// `count` events of `along` each, `every` seconds apart from `start`.
    private func turn(_ along: CGFloat, count: Int, every: TimeInterval, from start: TimeInterval = 100) -> [(CGFloat, TimeInterval)] {
        (0..<count).map { (along, start + Double($0) * every) }
    }

    // MARK: a notched wheel (line deltas, no phase)

    func testEachNotchIsOneStepTurnedSteadily() {
        // Turned steadily, a notch every 0.1 s: before, one space and then
        // nothing until the wheel paused 0.3 s.
        XCTAssertEqual(run(turn(-1, count: 5, every: 0.1), notched: true), [1, 1, 1, 1, 1])
        XCTAssertEqual(run(turn(1, count: 3, every: 0.15), notched: true), [-1, -1, -1])
    }

    func testAcceleratedNotchesStillOneStepEach() {
        // The Mac makes a quick spin's notches bigger, not more of them.
        let fast: [(CGFloat, TimeInterval)] = [(-1, 0), (-3, 0.06), (-7.5, 0.12), (-12, 0.18)]
        XCTAssertEqual(run(fast, notched: true), [1, 1, 1, 1])
        // A tenth of a line is still a notch.
        XCTAssertEqual(run([(-0.1, 0), (-0.1, 0.2)], notched: true), [1, 1])
    }

    func testTurningBackStepsBackAtOnce() {
        let there: [(CGFloat, TimeInterval)] = [(-1, 0), (-1, 0.1), (1, 0.2), (1, 0.3)]
        XCTAssertEqual(run(there, notched: true), [1, 1, -1, -1])
    }

    func testAFlickedFreeWheelIsPaced() {
        // 40 notches in 0.4 s (a free-spinning wheel flicked): at most one
        // step every `pace`, all one way.
        let steps = run(turn(-1, count: 40, every: 0.01), notched: true)
        XCTAssertTrue(steps.allSatisfy { $0 == 1 })
        XCTAssertLessThanOrEqual(steps.count, Int(0.4 / WheelSteps.pace) + 1)
        XCTAssertGreaterThanOrEqual(steps.count, 8)
    }

    func testOneNotchAfterARestIsOneStep() {
        XCTAssertEqual(run([(-1, 0), (-1, 5), (-1, 10)], notched: true), [1, 1, 1])
    }

    // MARK: a wheel smoothed by its driver (points, no phase)

    func testSmoothedNotchIsOneStep() {
        // One notch as six 6-point steps 8 ms apart: 36 points, one step.
        XCTAssertEqual(run(turn(-6, count: 6, every: 0.008), notched: false), [1])
        // Three of them in a row: three steps, the same way.
        XCTAssertEqual(run(turn(-6, count: 18, every: 0.008), notched: false), [1, 1, 1])
        XCTAssertEqual(run(turn(6, count: 18, every: 0.008), notched: false), [-1, -1, -1])
    }

    func testSmoothedNudgeShortOfANotchIsNothing() {
        XCTAssertEqual(run(turn(-4, count: 5, every: 0.008), notched: false), [])
        // Short of a notch, a pause, short again: a pause starts afresh.
        let twice = turn(-4, count: 5, every: 0.008) + turn(-4, count: 5, every: 0.008, from: 101)
        XCTAssertEqual(run(twice, notched: false), [])
    }

    func testSmoothedBigStepIsStillOneStep() {
        // One event of 200 points (a driver's catch-up): one step, not six.
        XCTAssertEqual(run([(-200, 0)], notched: false), [1])
    }

    func testSmoothedWobbleTheOtherWayStartsAfresh() {
        let wobble: [(CGFloat, TimeInterval)] = [(-20, 0), (2, 0.01), (-20, 0.02), (-20, 0.03)]
        // 20 points, then back: dropped; 40 points after that: one step.
        XCTAssertEqual(run(wobble, notched: false), [1])
    }

    // MARK: which events are a wheel's

    func testTrackpadIsNotAWheel() {
        XCTAssertFalse(WheelSteps.isWheel(precise: true, phase: .began, momentum: []))
        XCTAssertFalse(WheelSteps.isWheel(precise: true, phase: .changed, momentum: []))
        XCTAssertFalse(WheelSteps.isWheel(precise: true, phase: .ended, momentum: []))
        XCTAssertFalse(WheelSteps.isWheel(precise: true, phase: .mayBegin, momentum: []))
        // The glide after a stroke, and after a smoothed wheel's: not a step.
        XCTAssertFalse(WheelSteps.isWheel(precise: true, phase: [], momentum: .changed))
        XCTAssertTrue(WheelSteps.isWheel(precise: false, phase: [], momentum: []))
        XCTAssertTrue(WheelSteps.isWheel(precise: true, phase: [], momentum: []))
    }

    func testTrackpadEventsMadeAsTheMacSendsThem() throws {
        func event(units: CGScrollEventUnit, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: 0, wheel2: -3, wheel3: 0))
            if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        func wheel(_ e: NSEvent) -> Bool { WheelSteps.isWheel(precise: e.hasPreciseScrollingDeltas, phase: e.phase, momentum: e.momentumPhase) }
        XCTAssertTrue(wheel(try event(units: .line)), "a notched wheel")
        XCTAssertTrue(wheel(try event(units: .pixel)), "a smoothed wheel: points, no phase")
        XCTAssertFalse(wheel(try event(units: .pixel, phase: 1)), "a trackpad stroke beginning")
        XCTAssertFalse(wheel(try event(units: .pixel, phase: 2)), "a trackpad stroke moving")
        XCTAssertFalse(wheel(try event(units: .pixel, momentum: 2)), "a stroke's glide")
    }
}
