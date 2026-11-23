import XCTest
@testable import Search

final class DeveloperSliderTests: XCTestCase {
    func testTicksShowOnlyWhenFew() {
        XCTAssertTrue(DeveloperSlider.showsTicks(range: 100...900, step: 100))   // font weight: 8 stops
        XCTAssertFalse(DeveloperSlider.showsTicks(range: 0...72, step: 1))       // font size in px
        XCTAssertFalse(DeveloperSlider.showsTicks(range: -10...10, step: 0.1))   // letter spacing
        XCTAssertFalse(DeveloperSlider.showsTicks(range: 0...1, step: nil))      // continuous
        XCTAssertTrue(DeveloperSlider.showsTicks(range: 0...10, step: 1))
        XCTAssertFalse(DeveloperSlider.showsTicks(range: 0...11, step: 1))
    }

    func testSnapsToStepsWithinRange() {
        XCTAssertEqual(DeveloperSlider.snap(17.6, range: 0...72, step: 1), 18)
        XCTAssertEqual(DeveloperSlider.snap(420, range: 100...900, step: 100), 400)
        XCTAssertEqual(DeveloperSlider.snap(99, range: 0...72, step: 1), 72)
        XCTAssertEqual(DeveloperSlider.snap(0.37, range: 0...1, step: nil), 0.37)
    }
}
