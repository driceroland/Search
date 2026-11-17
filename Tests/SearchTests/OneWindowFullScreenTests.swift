import AppKit
import XCTest
@testable import Search

/// Profiles in one window, in full screen (idea 670): a window ordered out
/// in full screen keeps its full-screen space, so a profile switch must
/// never order one out while it is still in full screen. Played here with
/// stand-in windows whose full screen turns at once, as macOS's would
/// after its animation; nothing reaches the screen.
@MainActor
final class OneWindowFullScreenTests: XCTestCase {
    /// A window whose full screen is a flag, told about as macOS tells.
    final class Stand: NSWindow {
        var full = false
        var shown = false
        var outWhileFull = false
        var turns: [Bool] = []
        /// Holds the end of a turn back, as a slow animation would.
        var holding = false
        private var held: (() -> Void)?

        convenience init(_ shown: Bool, full: Bool = false) {
            self.init(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            self.shown = shown
            self.full = full
            isReleasedWhenClosed = false
        }
        override var styleMask: NSWindow.StyleMask {
            get { full ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
            set { super.styleMask = newValue.subtracting(.fullScreen) }
        }
        override var isVisible: Bool { shown }
        override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
        override func orderFront(_ sender: Any?) { shown = true }
        override func order(_ place: NSWindow.OrderingMode, relativeTo other: Int) { shown = place != .out }
        override func orderOut(_ sender: Any?) {
            if full { outWhileFull = true }
            shown = false
        }
        override func toggleFullScreen(_ sender: Any?) {
            full.toggle()
            turns.append(full)
            let name = full ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
            let post = { NotificationCenter.default.post(name: name, object: self) }
            if holding { held = post } else { post() }
        }
        func finish() {
            let run = held
            held = nil
            run?()
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testFromFullScreenTheOneLeavingComesOutFirst() {
        let old = Stand(true, full: true), next = Stand(false)
        OneWindow.swap(next, over: old, leaving: { true }, coming: { true })
        XCTAssertEqual(old.turns, [false], "the one leaving came out of full screen")
        XCTAssertFalse(old.shown, "and went out of sight")
        XCTAssertFalse(old.outWhileFull, "never ordered out in full screen")
        XCTAssertEqual(next.turns, [true], "the one coming went into full screen")
        XCTAssertTrue(next.shown && next.full)
    }

    func testTheOneLeavingWaitsForItsTurnToEnd() {
        let old = Stand(true, full: true), next = Stand(false)
        old.holding = true
        OneWindow.swap(next, over: old, leaving: { true }, coming: { true })
        XCTAssertTrue(old.shown, "still on screen while it comes out")
        XCTAssertFalse(next.shown, "the next waits")
        old.finish()
        XCTAssertFalse(old.shown)
        XCTAssertFalse(old.outWhileFull)
        XCTAssertTrue(next.full && next.shown)
    }

    func testSwitchedBackMidwayLeavesItOnScreen() {
        let old = Stand(true, full: true), next = Stand(false)
        old.holding = true
        var back = false
        OneWindow.swap(next, over: old, leaving: { !back }, coming: { !back })
        back = true
        old.finish()
        XCTAssertTrue(old.shown, "the one you came back to stays")
        XCTAssertFalse(next.shown, "the other never came")
        XCTAssertTrue(next.turns.isEmpty)
    }

    func testAThirdSwitchMidwayOnlyPutsItAway() {
        let old = Stand(true, full: true), next = Stand(false)
        old.holding = true
        var third = false
        OneWindow.swap(next, over: old, leaving: { true }, coming: { !third })
        third = true
        old.finish()
        XCTAssertFalse(old.shown)
        XCTAssertFalse(old.outWhileFull)
        XCTAssertFalse(next.shown, "the window passed over never comes")
    }

    func testOutOfFullScreenItIsStraightOver() {
        let old = Stand(true), next = Stand(false)
        OneWindow.swap(next, over: old, leaving: { true }, coming: { true })
        XCTAssertTrue(old.turns.isEmpty && next.turns.isEmpty, "no full screen involved")
        XCTAssertFalse(old.shown)
        XCTAssertTrue(next.shown)
        XCTAssertEqual(next.frame, old.frame, "at the same place")
    }

    func testAWindowLeftInFullScreenComesOutWhenItReturns() {
        // Tucked in full screen by a build from before idea 670.
        let old = Stand(true), next = Stand(false, full: true)
        OneWindow.swap(next, over: old, leaving: { true }, coming: { true })
        XCTAssertEqual(next.turns, [false])
        XCTAssertTrue(next.shown && !next.full)
        XCTAssertFalse(old.shown)
        XCTAssertFalse(old.outWhileFull || next.outWhileFull)
    }
}
