import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Settings › Appearance › Reduce animations (Motion.instant): off unless
/// turned on, kept, and with it on nothing in Search's interface moves.
@MainActor
final class ReduceAnimationsTests: XCTestCase {
    private var saved: Any?

    override class func setUp() {
        setenv("SEARCH_PROBE", "reduce-animations-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        saved = Store.settings.object(forKey: Motion.instantKey)
        Store.settings.removeObject(forKey: Motion.instantKey)
        Motion.instant = false
        // Whatever the Mac running the tests has chosen.
        Motion.testReduceMotion = false
    }

    override func tearDown() {
        Store.settings.set(saved, forKey: Motion.instantKey)
        Motion.instant = false
        Motion.testReduceMotion = nil
        Motion.testLowPower = nil
        super.tearDown()
    }

    func testOffUnlessTurnedOn() {
        XCTAssertFalse(Preferences().instantMotion)
        XCTAssertFalse(Motion.instant)
    }

    func testTheSwitchIsKeptAndReadAgainAtLaunch() {
        Preferences().instantMotion = true
        XCTAssertTrue(Motion.instant)
        XCTAssertTrue(Store.settings.bool(forKey: Motion.instantKey))
        Motion.instant = false
        XCTAssertTrue(Preferences().instantMotion)
        XCTAssertTrue(Motion.instant)
        Preferences().instantMotion = false
        XCTAssertFalse(Motion.instant)
    }

    /// ⌘1–⌘9's highlight moves on glide and quick, a space on its own
    /// ease-out behind Motion.reduced, a page's first frame on seconds.
    func testOnEveryTransitionIsImmediate() {
        Motion.instant = true
        XCTAssertTrue(Motion.reduced)
        XCTAssertNil(Motion.glide)
        XCTAssertNil(Motion.settle)
        XCTAssertNil(Motion.quick)
        XCTAssertNil(Motion.folding(out: true))
        XCTAssertNil(Motion.folding(out: false))
        XCTAssertNil(Motion.timed(.easeOut(duration: 0.2)))
        XCTAssertEqual(Motion.seconds(0.12), 0)
        // Low Power Mode's short ease-out is still a movement.
        Motion.testLowPower = true
        Store.settings.set(true, forKey: Motion.lightKey)
        defer { Store.settings.removeObject(forKey: Motion.lightKey) }
        XCTAssertNil(Motion.glide)
        XCTAssertNil(Motion.settle)
    }

    func testOffEverythingMovesAsBefore() {
        XCTAssertFalse(Motion.reduced)
        XCTAssertNotNil(Motion.glide)
        XCTAssertNotNil(Motion.settle)
        XCTAssertNotNil(Motion.quick)
        XCTAssertNotNil(Motion.folding(out: true))
        XCTAssertNotNil(Motion.timed(.easeOut(duration: 0.2)))
        XCTAssertEqual(Motion.seconds(0.12), 0.12)
    }

    /// Reduce Motion alone keeps its fades; Reduce animations takes those too.
    func testReduceMotionAloneKeepsItsFades() {
        Motion.testReduceMotion = true
        XCTAssertTrue(Motion.reduced)
        XCTAssertNil(Motion.glide)
        XCTAssertEqual(Motion.seconds(0.12), 0.12)
        Motion.instant = true
        XCTAssertEqual(Motion.seconds(0.12), 0)
    }
}
