import XCTest
@testable import Search

/// A pinned square carried across the grid (Side.swift): the cell it lands
/// in and how far it sits from it, on rows of different lengths.
final class PinCarriedTests: XCTestCase {
    // Three squares on the first row, two wider ones on the second.
    private let cells = [
        CGRect(x: 0, y: 0, width: 60, height: 40), CGRect(x: 66, y: 0, width: 60, height: 40),
        CGRect(x: 132, y: 0, width: 60, height: 40),
        CGRect(x: 0, y: 46, width: 93, height: 40), CGRect(x: 99, y: 46, width: 93, height: 40),
    ]

    func testStaysInItsCellUntilNearerAnother() {
        XCTAssertEqual(PinCarried.target(travel: .zero, from: 0, cells: cells), 0)
        XCTAssertEqual(PinCarried.target(travel: CGSize(width: 30, height: 0), from: 0, cells: cells), 0)
        XCTAssertEqual(PinCarried.target(travel: CGSize(width: 40, height: 0), from: 0, cells: cells), 1)
    }

    func testDownIntoAWiderRowLandsByCentre() {
        // From the third square straight down: nearest is the second wide cell.
        XCTAssertEqual(PinCarried.target(travel: CGSize(width: 0, height: 46), from: 2, cells: cells), 4)
        XCTAssertEqual(PinCarried.target(travel: CGSize(width: -120, height: 46), from: 2, cells: cells), 3)
    }

    func testHeldSquareStaysUnderTheHandAfterMoving() {
        let travel = CGSize(width: 70, height: 3)
        // Before it changes cell, the offset is the travel itself.
        XCTAssertEqual(PinCarried.offset(travel: travel, from: 0, index: 0, cells: cells), travel)
        // Once it is in the next cell, only what is left over.
        let after = PinCarried.offset(travel: travel, from: 0, index: 1, cells: cells)
        XCTAssertEqual(after.width, 4, accuracy: 0.001)
        XCTAssertEqual(after.height, 3, accuracy: 0.001)
        XCTAssertEqual(PinCarried.offset(travel: travel, from: 9, index: 0, cells: cells), .zero)
    }
}
