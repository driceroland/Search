import XCTest
@testable import Search

/// Idea 1021: with Buttons at the top on, the column draws the doors' row
/// twice (up top and, hidden, at the foot). Both puzzles were bound to the
/// window's one flag, so both hung a popover, and the hidden one closing let
/// go of the flag and shut the list just opened. Each copy now has its own
/// open state: only the copy in sight shows, opens or closes the list.
@available(macOS 14, *)
final class PuzzleListTests: XCTestCase {
    private final class Window {}
    private let window = Window()
    private let other = Window()
    private var key: ObjectIdentifier { ObjectIdentifier(window) }

    func testOnlyTheCopyInSightShowsTheList() {
        XCTAssertTrue(PuzzleList.open(owner: key, key: key, live: true))
        XCTAssertFalse(PuzzleList.open(owner: key, key: key, live: false), "the hidden copy hangs no second popover")
        XCTAssertFalse(PuzzleList.open(owner: nil, key: key, live: true))
        XCTAssertFalse(PuzzleList.open(owner: ObjectIdentifier(other), key: key, live: true), "another window's list")
    }

    func testTheHiddenCopyClosingLeavesTheListOpen() {
        let opened = PuzzleList.pressed(owner: nil, key: key, live: true)
        XCTAssertEqual(opened, key)
        // SwiftUI closes the hidden copy's popover: the flag stays.
        XCTAssertEqual(PuzzleList.closed(owner: opened, key: key, live: false), key)
        XCTAssertTrue(PuzzleList.open(owner: key, key: key, live: true), "the list in sight is still open")
        // A click outside the one in sight closes it.
        XCTAssertNil(PuzzleList.closed(owner: opened, key: key, live: true))
    }

    func testPressesAndOtherWindows() {
        XCTAssertNil(PuzzleList.pressed(owner: key, key: key, live: true), "a second press closes")
        XCTAssertNil(PuzzleList.pressed(owner: nil, key: key, live: false), "the hidden copy can't open it")
        XCTAssertEqual(PuzzleList.pressed(owner: key, key: key, live: false), key, "nor close it")
        let theirs = ObjectIdentifier(other)
        XCTAssertEqual(PuzzleList.pressed(owner: theirs, key: key, live: true), key, "this window's press takes the list")
        XCTAssertEqual(PuzzleList.closed(owner: theirs, key: key, live: true), theirs, "closing here leaves another window's list")
    }
}
