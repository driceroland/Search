import CoreGraphics
import XCTest
@testable import Search

final class DeveloperStyleAngleTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(DeveloperAngle("45deg"), DeveloperAngle(value: 45, unit: .deg))
        XCTAssertEqual(DeveloperAngle("-1.5rad"), DeveloperAngle(value: -1.5, unit: .rad))
        XCTAssertEqual(DeveloperAngle("100grad"), DeveloperAngle(value: 100, unit: .grad))
        XCTAssertEqual(DeveloperAngle(".25turn"), DeveloperAngle(value: 0.25, unit: .turn))
        XCTAssertEqual(DeveloperAngle("90DEG"), DeveloperAngle(value: 90, unit: .deg))
        XCTAssertNil(DeveloperAngle("45"))
        XCTAssertNil(DeveloperAngle("deg"))
        XCTAssertNil(DeveloperAngle("45px"))
    }

    func testFormattingKeepsTheUnit() {
        XCTAssertEqual(DeveloperAngle(value: 45, unit: .deg).css, "45deg")
        XCTAssertEqual(DeveloperAngle(value: 0.5, unit: .turn).css, "0.5turn")
        XCTAssertEqual(DeveloperAngle(value: -1.2345, unit: .rad).css, "-1.2345rad")
    }

    func testUnitConversion() {
        XCTAssertEqual(DeveloperAngle(value: 0.5, unit: .turn).degrees, 180, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle(value: 100, unit: .grad).degrees, 90, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle(value: .pi, unit: .rad).degrees, 180, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle(value: 90, unit: .deg).converted(to: .turn).value, 0.25, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle(value: 90, unit: .deg).converted(to: .grad).value, 100, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle(value: 180, unit: .deg).converted(to: .rad).value, .pi, accuracy: 1e-9)
    }

    func testRoundingByUnit() {
        XCTAssertEqual(DeveloperAngle(value: 44.6, unit: .deg).roundedByUnit().value, 45)
        XCTAssertEqual(DeveloperAngle(value: 1.234567, unit: .rad).roundedByUnit().value, 1.2346, accuracy: 1e-12)
        XCTAssertEqual(DeveloperAngle(value: 0.256, unit: .turn).roundedByUnit().value, 0.26, accuracy: 1e-12)
    }

    func testSnapping() {
        XCTAssertEqual(DeveloperAngle.snap(7), 0)
        XCTAssertEqual(DeveloperAngle.snap(8), 15)
        XCTAssertEqual(DeveloperAngle.snap(352), 345)
        XCTAssertEqual(DeveloperAngle.snap(358), 0)
        XCTAssertEqual(DeveloperAngle.snap(-20), 345)
        XCTAssertEqual(DeveloperAngle.normalized(-90), 270)
        XCTAssertEqual(DeveloperAngle.normalized(720), 0)
    }

    func testTheDialKeepsTheUnitAndSnapsWithShift() {
        let turn = DeveloperAngle(value: 0.1, unit: .turn)
        XCTAssertEqual(turn.dialed(to: 90, snapping: false), DeveloperAngle(value: 0.25, unit: .turn))
        let degrees = DeveloperAngle(value: 10, unit: .deg)
        XCTAssertEqual(degrees.dialed(to: 52.4, snapping: false), DeveloperAngle(value: 52, unit: .deg))
        XCTAssertEqual(degrees.dialed(to: 52.4, snapping: true), DeveloperAngle(value: 45, unit: .deg))
        let radians = DeveloperAngle(value: 1, unit: .rad).dialed(to: 180, snapping: false)
        XCTAssertEqual(radians.unit, .rad)
        XCTAssertEqual(radians.value, 3.1416, accuracy: 1e-12)
    }

    func testPointsOnTheDial() {
        let center = CGPoint(x: 50, y: 50)
        XCTAssertEqual(DeveloperAngle.degrees(at: CGPoint(x: 50, y: 0), center: center), 0, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle.degrees(at: CGPoint(x: 100, y: 50), center: center), 90, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle.degrees(at: CGPoint(x: 50, y: 100), center: center), 180, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle.degrees(at: CGPoint(x: 0, y: 50), center: center), 270, accuracy: 1e-9)
        XCTAssertEqual(DeveloperAngle.degrees(at: center, center: center), 0)
    }

    func testArrowKeysStepByOneDegreeOrTenWithShift() {
        XCTAssertEqual(DeveloperAngle(value: 45, unit: .deg).stepped(up: true, shift: false), DeveloperAngle(value: 46, unit: .deg))
        XCTAssertEqual(DeveloperAngle(value: 45, unit: .deg).stepped(up: false, shift: true), DeveloperAngle(value: 35, unit: .deg))
        let turn = DeveloperAngle(value: 0.25, unit: .turn).stepped(up: true, shift: true)
        XCTAssertEqual(turn.unit, .turn)
        XCTAssertEqual(turn.value, 0.2778, accuracy: 1e-12)
        let grad = DeveloperAngle(value: 100, unit: .grad).stepped(up: true, shift: false)
        XCTAssertEqual(grad.value, 101.11, accuracy: 1e-9)
    }

    func testAnglesInAValue() {
        let value = "linear-gradient(45deg, red, blue), conic-gradient(from .5turn, red, blue)"
        let found = DeveloperAngle.matches(in: value)
        XCTAssertEqual(found.map { $0.angle }, [DeveloperAngle(value: 45, unit: .deg), DeveloperAngle(value: 0.5, unit: .turn)])
        XCTAssertEqual(DeveloperAngle.replacing(1, in: value, with: DeveloperAngle(value: 0.75, unit: .turn)),
                       "linear-gradient(45deg, red, blue), conic-gradient(from 0.75turn, red, blue)")
        XCTAssertEqual(DeveloperAngle.matches(in: "rotate(-1.5rad) skew(10grad)").map { $0.angle.css }, ["-1.5rad", "10grad"])
        XCTAssertEqual(DeveloperAngle.matches(in: "hue-rotate(90deg)").count, 1)
        // Not angles: lengths, and units inside words.
        XCTAssertTrue(DeveloperAngle.matches(in: "translate(10px, 2em) var(--x10deg)").isEmpty)
        XCTAssertEqual(DeveloperAngle.replacing(3, in: "rotate(5deg)", with: DeveloperAngle(value: 1, unit: .deg)), "rotate(5deg)")
    }
}
