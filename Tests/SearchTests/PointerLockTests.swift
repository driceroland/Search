import XCTest
@testable import Search

/// Who may have the pointer (PointerLock, #1305). The whole path, a click
/// in a page asking and Escape letting go, is Tests/pointer_lock.py.
@available(macOS 14, *)
final class PointerLockTests: XCTestCase {
    func testOnlyTheFrontTabRightAfterInputAndNeverAnAgent() {
        XCTAssertNil(PointerLock.refusal(agent: false, front: true, input: true))
        XCTAssertEqual(PointerLock.refusal(agent: true, front: true, input: true), "agent")
        XCTAssertEqual(PointerLock.refusal(agent: false, front: false, input: true), "not in front")
        XCTAssertEqual(PointerLock.refusal(agent: false, front: true, input: false), "no gesture")
    }

    func testInputCountsForFiveSecondsWithoutBeingSpent() {
        var input = PopupGesture()
        XCTAssertFalse(input.recent(now: 10))
        input.record(origin: "https://game.test:443", kind: "click", now: 10)
        XCTAssertTrue(input.recent(now: 11))
        // Asking for the pointer leaves the click its one window.
        XCTAssertTrue(input.take(origin: "https://game.test:443", now: 11))
        XCTAssertTrue(input.recent(now: 14.9))
        XCTAssertFalse(input.recent(now: 15.1))
        input.record(origin: "https://game.test:443", kind: "input", now: 20)
        input.clear()
        XCTAssertFalse(input.recent(now: 20.1))
    }
}
