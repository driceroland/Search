import XCTest
@testable import Search

/// How long a tab waits to sleep with Settings › General › Save power in Low
/// Power Mode on, off, and overridden by the bench.
@MainActor
final class SleepPowerTests: XCTestCase {
    private let keys = [Motion.lightKey, SleepPace.key, "sleep.after"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = Store.settings.object(forKey: key)
            Store.settings.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            Store.settings.set(saved[key] ?? nil, forKey: key)
        }
        Motion.testLowPower = nil
        super.tearDown()
    }

    private func waits(switchOn: Bool, lowPower: Bool) -> [SleepPace: TimeInterval] {
        Store.settings.set(switchOn, forKey: Motion.lightKey)
        Motion.testLowPower = lowPower
        var waits: [SleepPace: TimeInterval] = [:]
        for pace in SleepPace.allCases {
            Store.settings.set(pace.rawValue, forKey: SleepPace.key)
            waits[pace] = Browser.sleepAfter
        }
        return waits
    }

    func testSwitchOffLeavesTheWaitAlone() {
        for (pace, wait) in waits(switchOn: false, lowPower: true) {
            XCTAssertEqual(wait, pace.wait, "\(pace)")
        }
    }

    func testOutOfLowPowerModeLeavesTheWaitAlone() {
        for (pace, wait) in waits(switchOn: true, lowPower: false) {
            XCTAssertEqual(wait, pace.wait, "\(pace)")
        }
    }

    func testLowPowerModeCapsLaterAndNormalAtSooner() {
        let waits = waits(switchOn: true, lowPower: true)
        XCTAssertEqual(waits[.later], 600)
        XCTAssertEqual(waits[.normal], 600)
    }

    func testSoonerStaysTenMinutes() {
        XCTAssertEqual(waits(switchOn: true, lowPower: true)[.sooner], 600)
    }

    func testTheBenchStillWins() {
        Store.settings.set(42.0, forKey: "sleep.after")
        for (_, wait) in waits(switchOn: true, lowPower: true) {
            XCTAssertEqual(wait, 42)
        }
    }
}
