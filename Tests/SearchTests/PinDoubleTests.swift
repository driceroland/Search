import XCTest
@testable import Search

/// A double-click on a pin's square (idea 1216), decided at its second
/// press: the first press makes a pin you weren't on the one on screen,
/// and the square is drawn anew, so a tap counting to two never saw two.
@available(macOS 14, *)
final class PinDoubleTests: XCTestCase {
    func testFromAnotherSquareAWanderedPinGoesHome() {
        XCTAssertTrue(PinDouble.goesHome(clicks: 2, live: true, opened: true, wandered: true))
    }

    func testFromAnotherSquareAPinAtHomeIsOnlyPicked() {
        XCTAssertFalse(PinDouble.goesHome(clicks: 2, live: true, opened: true, wandered: false))
    }

    func testOnTheSquareYouAreOnItGoesHomeOrToItsLetter() {
        // goHome itself picks: home when wandered, the letter when at home.
        XCTAssertTrue(PinDouble.goesHome(clicks: 2, live: true, opened: false, wandered: true))
        XCTAssertTrue(PinDouble.goesHome(clicks: 2, live: true, opened: false, wandered: false))
    }

    func testOnlyADoubleClick() {
        XCTAssertFalse(PinDouble.goesHome(clicks: 1, live: true, opened: false, wandered: true))
        XCTAssertFalse(PinDouble.goesHome(clicks: 3, live: true, opened: false, wandered: true))
        XCTAssertFalse(PinDouble.goesHome(clicks: 2, live: false, opened: false, wandered: true))
    }

    @MainActor
    func testAppKitsClickCountIsReadFromThePress() {
        TabClick.forget()
        _ = TabClick.watching
        XCTAssertEqual(TabClick.clicks, 1)
        for count in [1, 2] {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                           eventNumber: 0, clickCount: count, pressure: 1)!
            NSApp.sendEvent(event)
            XCTAssertEqual(TabClick.clicks, count)
        }
        TabClick.forget()
    }
}
