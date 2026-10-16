import XCTest
@testable import Search

/// What each choice in Settings › Tabs › How soon tabs sleep waits for.
final class SleepPaceTests: XCTestCase {
    func testSoonerWaitsLess() {
        let paces: [SleepPace] = [.later, .normal, .sooner]
        for (slower, faster) in zip(paces, paces.dropFirst()) {
            XCTAssertGreaterThan(slower.wait, faster.wait)
        }
    }

    func testNormalIsTheHalfHourThereWasBefore() {
        XCTAssertEqual(SleepPace.normal.wait, 30 * 60)
    }
}
