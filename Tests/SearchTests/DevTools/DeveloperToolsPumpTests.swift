import XCTest
@testable import Search

@MainActor
final class DeveloperToolsPumpTests: XCTestCase {
    func testPumpDrainsQuicklyWhileBusyAndBacksOffToAboutASecondWhenIdle() {
        // Busy, or only a few idle drains: the old 220 ms pace.
        for idle in 0...4 {
            XCTAssertEqual(DeveloperToolsSession.pumpInterval(afterIdleDrains: idle), 220)
        }
        // Then a slice longer per idle drain, never shorter than before.
        var previous = 220
        for idle in 5...40 {
            let interval = DeveloperToolsSession.pumpInterval(afterIdleDrains: idle)
            XCTAssertGreaterThanOrEqual(interval, previous)
            XCTAssertLessThanOrEqual(interval - previous, DeveloperToolsSession.pumpSlice)
            XCTAssertEqual(interval % DeveloperToolsSession.pumpSlice, 0)
            previous = interval
        }
        XCTAssertEqual(DeveloperToolsSession.pumpInterval(afterIdleDrains: 5), 330)
        XCTAssertEqual(previous, 990)
    }

    func testShownHighlightTellsTheSameHoverFromAnother() {
        XCTAssertEqual(ShownHighlight.node(4, .chrome), .node(4, .chrome))
        XCTAssertNotEqual(ShownHighlight.node(4, .chrome), .node(5, .chrome))
        XCTAssertNotEqual(ShownHighlight.node(4, .chrome), .node(4, .only(.margin)))
        XCTAssertNotEqual(ShownHighlight.hidden, .unknown)
    }
}
