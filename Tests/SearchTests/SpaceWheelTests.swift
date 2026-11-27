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

    // MARK: a tablet pen's pan (Wacom, side button set to Pan/Scroll, idea 1391)

    /// A scroll event as a tablet's driver posts one: lines, or points with
    /// no phase; `inverted` with macOS's natural scrolling on for it.
    private func panEvent(dx: Int32, points: Bool, inverted: Bool) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: points ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        if points { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        if inverted { cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 137)), value: 1) }
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.isDirectionInvertedFromDevice, inverted)
        return event
    }

    /// The step a run of the same event brings, read as SpaceSwipe reads it.
    private func steps(_ event: NSEvent, pen: Bool, sidebar: Bool = true, count: Int = 12, every: TimeInterval = 0.016) -> [Int] {
        let along = WheelSteps.along(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, sidebar: sidebar, pen: pen)
        var wheel = WheelSteps()
        return (0..<count).map { wheel.feed(along, notched: !event.hasPreciseScrollingDeltas, pen: pen, at: 100 + Double($0) * every) }.filter { $0 != 0 }
    }

    func testPenPanMovesSpacesTheWayThePageMoves() throws {
        // The page carried left (deltas below zero, as a page scrolls by
        // them) brings the next space, as two fingers moved left do; carried
        // right, the one before. Natural scrolling on or off for the pen:
        // the deltas already say which way the page goes.
        for inverted in [false, true] {
            for points in [false, true] {
                let left = try panEvent(dx: -6, points: points, inverted: inverted)
                let right = try panEvent(dx: 6, points: points, inverted: inverted)
                XCTAssertEqual(steps(left, pen: true), [1], "page left: next space (inverted \(inverted), points \(points))")
                XCTAssertEqual(steps(right, pen: true), [-1], "page right: the space before (inverted \(inverted), points \(points))")
            }
        }
    }

    func testPenPanIsOneSpaceADrag() {
        // A long drag of the pen: one space, not one an event.
        var wheel = WheelSteps()
        let drag = (0..<60).map { wheel.feed(-2, notched: true, pen: true, at: 100 + Double($0) * 0.016) }.filter { $0 != 0 }
        XCTAssertEqual(drag, [1])
        // Rested, then dragged again: the next one.
        XCTAssertEqual(wheel.feed(-2, notched: true, pen: true, at: 103), 1)
        // A smoothed pan short of `smooth` points: nothing yet.
        var nudge = WheelSteps()
        XCTAssertEqual(nudge.feed(-10, notched: false, pen: true, at: 100), 0)
        XCTAssertEqual(nudge.feed(-25, notched: false, pen: true, at: 100.02), 1)
    }

    func testMouseWheelsKeepTheirWay() throws {
        // A mouse's sideways wheel, notched or smoothed, stays as #1646 has
        // it: the other way round to the page.
        let notch = try panEvent(dx: -1, points: false, inverted: false)
        XCTAssertEqual(WheelSteps.along(dx: notch.scrollingDeltaX, dy: 0, sidebar: true, pen: false), 1)
        XCTAssertEqual(run([(1, 100)], notched: true), [-1])
        // The bar across the top: up or down as sent, for both.
        XCTAssertEqual(WheelSteps.along(dx: 0, dy: -1, sidebar: false, pen: false), -1)
        XCTAssertEqual(WheelSteps.along(dx: 0, dy: -1, sidebar: false, pen: true), -1)
        // More up or down than sideways in the column: the tabs scroll.
        XCTAssertEqual(WheelSteps.along(dx: 2, dy: 5, sidebar: true, pen: true), 0)
        XCTAssertEqual(WheelSteps.along(dx: 2, dy: 5, sidebar: true, pen: false), 0)
    }

    @MainActor
    func testPenKnownFromTheTabletAndItsDriver() throws {
        XCTAssertTrue(PenPan.isTabletDriver("WacomTabletDriver"))
        XCTAssertTrue(PenPan.isTabletDriver("TabletDriver"))
        XCTAssertFalse(PenPan.isTabletDriver("logioptionsplus_agent"))
        XCTAssertFalse(PenPan.isTabletDriver(""))
        XCTAssertFalse(PenPan.fromTabletDriver(pid: getpid()))
        XCTAssertFalse(PenPan.fromTabletDriver(pid: 0))
        XCTAssertTrue(PenPan.isTablet(subtype: .tabletPoint))
        XCTAssertFalse(PenPan.isTablet(subtype: .mouseEvent))
        let saved = PenPan.near
        defer { PenPan.near = saved }
        // The pen near: the scroll events are its pan; a plain wheel's not.
        let event = try panEvent(dx: -1, points: false, inverted: true)
        PenPan.near = true
        XCTAssertTrue(PenPan.isPen(event))
        PenPan.near = false
        XCTAssertFalse(PenPan.isPen(event))
        // The mouse moved by a mouse: the pen is not what's scrolling.
        PenPan.near = true
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        PenPan.note(moved)
        XCTAssertFalse(PenPan.near)
    }
}
