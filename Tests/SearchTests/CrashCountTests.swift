import XCTest
@testable import Search

/// A page whose process keeps dying is made again twice a minute at most,
/// then left to say so: the rule tabs and the side panel share.
final class CrashCountTests: XCTestCase {
    func testTwoReloadsAMinuteThenGivesUp() {
        var count = CrashCount()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(count.another(at: start))
        XCTAssertTrue(count.another(at: start.addingTimeInterval(5)))
        XCTAssertFalse(count.gaveUp)
        XCTAssertFalse(count.another(at: start.addingTimeInterval(10)), "a third death within the minute is not met with a reload")
        XCTAssertTrue(count.gaveUp)
    }

    func testOldDeathsStopCounting() {
        var count = CrashCount()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(count.another(at: start))
        XCTAssertTrue(count.another(at: start.addingTimeInterval(30)))
        XCTAssertTrue(count.another(at: start.addingTimeInterval(61)), "the first is more than a minute old")
        XCTAssertFalse(count.another(at: start.addingTimeInterval(62)))
    }
}
