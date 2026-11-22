import AppKit
import XCTest
@testable import Search

/// The top of the window: what the menu bar's reveal in full screen pushes
/// the bars down by (idea 926).
@MainActor
final class TopEdgeTests: XCTestCase {
    // MARK: FullScreenReveal.inset

    func testNothingOutsideFullScreen() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: false, shown: true, revealAmount: 1, contentTop: 1000, barBottom: 937), 0)
    }

    func testNothingWhileTheTitleBarIsAway() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: false, revealAmount: 1, contentTop: 1000, barBottom: 937), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 0, contentTop: 1000, barBottom: 937), 0)
        // Parked above the screen's top, out of sight.
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: nil, contentTop: 1000, barBottom: 1000), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: nil, contentTop: 1000, barBottom: 1060), 0)
    }

    /// The menu bar and the buttons' bar together, 37 and 26 points: the
    /// bars move down by all of it, not by the title bar's part alone.
    func testExactlyWhatCameDown() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 1000, barBottom: 937), 63)
    }

    /// Half way through the slide, half way down.
    func testFollowsTheSlide() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 0.5, contentTop: 1000, barBottom: 968.4), 32)
    }

    /// Room macOS already left at the top (the content moved down with the
    /// reveal) is not counted again: the gap the 1.0.17 strip showed.
    func testNeverTwice() {
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 937, barBottom: 937), 0)
        XCTAssertEqual(FullScreenReveal.inset(fullScreen: true, shown: true, revealAmount: 1, contentTop: 950, barBottom: 937), 13)
    }
}
