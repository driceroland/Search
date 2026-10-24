import XCTest
@testable import Search

/// What the browser saves while the Mac is in Low Power Mode (see LowPower.swift).
@MainActor
final class LowPowerTests: XCTestCase {
    private var mode = FastPages.never
    private var follows = true

    override func setUp() async throws {
        mode = FrameRate.mode
        follows = LowPower.follows
        Store.settings.removeObject(forKey: "sleep.after")
    }

    override func tearDown() async throws {
        LowPower.testing = nil
        LowPower.follows = follows
        FrameRate.mode = mode
        Store.settings.removeObject(forKey: SleepPace.key)
    }

    func testPagesKeepTo60InLowPowerMode() {
        FrameRate.mode = .always
        LowPower.testing = false
        XCTAssertTrue(FrameRate.fast)
        LowPower.testing = true
        XCTAssertFalse(FrameRate.fast)
        LowPower.testing = false
        XCTAssertTrue(FrameRate.fast, "back to 120 once Low Power Mode is off")
    }

    func testTurnedOffInSettingsPagesStayFast() {
        FrameRate.mode = .always
        LowPower.follows = false
        LowPower.testing = true
        XCTAssertFalse(LowPower.on)
        XCTAssertTrue(FrameRate.fast)
    }

    func testTabsSleepSoonerInLowPowerMode() {
        Store.settings.set(SleepPace.later.rawValue, forKey: SleepPace.key)
        LowPower.testing = false
        XCTAssertEqual(Browser.sleepAfter, SleepPace.later.wait)
        LowPower.testing = true
        XCTAssertEqual(Browser.sleepAfter, SleepPace.sooner.wait)
    }

    func testAPaceAlreadySoonerIsLeftAlone() {
        Store.settings.set(SleepPace.sooner.rawValue, forKey: SleepPace.key)
        LowPower.testing = true
        XCTAssertEqual(Browser.sleepAfter, SleepPace.sooner.wait)
    }

    func testTheBenchsOwnWaitStillWins() {
        Store.settings.set(42.0, forKey: "sleep.after")
        LowPower.testing = true
        XCTAssertEqual(Browser.sleepAfter, 42)
        Store.settings.removeObject(forKey: "sleep.after")
    }
}
