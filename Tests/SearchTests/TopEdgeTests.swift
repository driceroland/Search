import AppKit
import WebKit
import XCTest
@testable import Search

/// The top of the window: what the menu bar's reveal in full screen pushes
/// the bars down by (idea 926), and the band along the top of a page leaving
/// what the page has to press there to the page (idea 928).
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

    // MARK: DragStrip over a page

    private func band() -> (NSView, DragStrip.Strip) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let strip = DragStrip.Strip(frame: NSRect(x: 0, y: 588, width: 800, height: 12))
        strip.overPage = true
        root.addSubview(strip)
        return (root, strip)
    }

    func testTheBandIsTheWindowsOverEmptyPage() {
        let (root, strip) = band()
        XCTAssertTrue(root.hitTest(NSPoint(x: 600, y: 594)) === strip)
    }

    /// Where the page said it has a field, the press goes to the page.
    func testTheBandLeavesTheFieldToThePage() {
        let (root, strip) = band()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 592))
        root.addSubview(web, positioned: .below, relativeTo: strip)
        strip.passing = [NSRect(x: 0, y: 560, width: 360, height: 40)]
        XCTAssertTrue(root.hitTest(NSPoint(x: 120, y: 594)) === strip, "without the page's answer kept, still the window's")
        strip.page = web
        let over = root.hitTest(NSPoint(x: 120, y: 590))
        XCTAssertTrue(over.map { $0 === web || $0.isDescendant(of: web) } ?? false, "over the field the press is the page's")
        XCTAssertTrue(root.hitTest(NSPoint(x: 600, y: 594)) === strip, "beside it, still the window's")
        web.isHidden = true
        XCTAssertTrue(root.hitTest(NSPoint(x: 120, y: 590)) === strip, "a page no longer shown takes nothing")
    }

    /// A band that isn't over a page (the column's, the strip's) never
    /// keeps a page's answer.
    func testOnlyOverAPage() {
        let (_, strip) = band()
        strip.passing = [NSRect(x: 0, y: 560, width: 360, height: 40)]
        strip.overPage = false
        XCTAssertTrue(strip.passing.isEmpty)
    }

    func testThePagesScriptParses() throws {
        let script = PageUnder.script(x: 10, y: 5)
        XCTAssertTrue(script.contains("elementFromPoint(x, y)"))
        XCTAssertTrue(script.contains("/\\S/.test"), "the text test's pattern reaches the page unescaped")
        XCTAssertTrue(script.hasSuffix("})(10.0, 5.0)"))
    }
}
