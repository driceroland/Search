import AppKit
import WebKit
import XCTest
@testable import Search

/// A page WebKit's full-screen window has, without going full screen: that
/// takes a Space of its own on the display, which a test must not do.
private final class LentPage: WKWebView {
    var lent: WKWebView.FullscreenState = .notInFullscreen {
        willSet { willChangeValue(forKey: "fullscreenState") }
        didSet { didChangeValue(forKey: "fullscreenState") }
    }
    override var fullscreenState: WKWebView.FullscreenState { lent }
}

/// Found by its name, as WebKit's own is (see StageView.isPlaceholder).
private final class FakeFullScreenPlaceholderView: NSView {}

/// In front or not, without taking the keys from whatever is really in front.
private final class TestWindow: NSWindow {
    var key = true
    override var isKeyWindow: Bool { key }
}

@MainActor
final class StageFullScreenTests: XCTestCase {
    private var ended = 0
    private var chromeBack = 0

    override class func setUp() {
        setenv("SEARCH_PROBE", "stage-full-screen-\(getpid())", 1)
        super.setUp()
    }

    private func page() -> LentPage {
        LentPage(frame: .zero, configuration: WKWebViewConfiguration())
    }

    private func stage() -> (StageView, TestWindow) {
        _ = NSApplication.shared
        let stage = StageView(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        stage.endFullScreen = { [weak self] _ in self?.ended += 1 }
        stage.chromeBack = { [weak self] _ in self?.chromeBack += 1 }
        let window = TestWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1000, height: 500),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFrontRegardless()
        return (stage, window)
    }

    /// What is put off until the layout is over.
    private func turn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// The tab left for another while its video stays full screen, then
    /// chosen again in this window: the other tab's page goes, the column
    /// comes back, full screen is asked to end, and the page returns at the
    /// stage's size with the keys when WebKit lets it go.
    func testATabFullScreenElsewhereChosenAgainComesHome() {
        let (stage, host) = stage()
        defer { host.close() }
        let other = page()
        stage.show(other)
        XCTAssertTrue(other.superview === stage)

        // WebKit's own window, with no placeholder left on this stage.
        let elsewhere = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen

        stage.show(video)
        XCTAssertNil(other.superview, "the last tab's page stayed on the stage")
        turn()
        XCTAssertEqual(chromeBack, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(video.superview === elsewhere, "taken from WebKit before it let go")

        video.lent = .exitingFullscreen
        XCTAssertTrue(video.superview === elsewhere)

        video.removeFromSuperview()
        host.makeFirstResponder(nil)
        video.lent = .notInFullscreen
        XCTAssertTrue(video.superview === stage)
        XCTAssertEqual(video.frame, stage.bounds)
        XCTAssertTrue(host.firstResponder === video, "came home without the keys")
    }

    /// Full screen that doesn't end: the column is back all the same, so
    /// the window is never left without a way out.
    func testAFullScreenThatDoesNotEndStillGivesTheColumnBack() {
        let (stage, host) = stage()
        defer { host.close() }
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen

        stage.show(video)
        turn()
        XCTAssertEqual(chromeBack, 1)
        XCTAssertTrue(video.superview === elsewhere)
    }

    /// Landing on the tab from the video's own Space, by a link it opened or
    /// a popup closing itself: the video goes on, and comes home when left.
    func testChosenFromTheVideosOwnSpaceTheVideoGoesOn() {
        let (stage, host) = stage()
        defer { host.close() }
        host.key = false
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen

        stage.show(video)
        turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 1)

        video.lent = .exitingFullscreen
        video.removeFromSuperview()
        video.lent = .notInFullscreen
        XCTAssertTrue(video.superview === stage)
    }

    /// Chosen while still on its way in: asked again once it is there, when
    /// the page has a full-screen element to leave.
    func testChosenOnItsWayInIsAskedAgainOnceThere() {
        let (stage, host) = stage()
        defer { host.close() }
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .enteringFullscreen

        stage.show(video)
        turn()
        XCTAssertEqual(ended, 1)
        video.lent = .inFullscreen
        turn()
        XCTAssertEqual(ended, 2)
        XCTAssertEqual(chromeBack, 2)
    }

    /// The ordinary full screen: a placeholder is on the stage, and only the
    /// page's own way out ends it, even when the stage is told to show it
    /// again.
    func testAPageWithItsPlaceholderHereIsLeftFullScreen() {
        let (stage, host) = stage()
        defer { host.close() }
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen
        let placeholder = FakeFullScreenPlaceholderView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        stage.addSubview(placeholder)

        stage.show(video)
        stage.frame.size.width = 900
        stage.layoutSubtreeIfNeeded()
        turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 0)
        XCTAssertTrue(placeholder.superview === stage)
        XCTAssertEqual(placeholder.frame, stage.bounds)
    }

    /// On its way in, still on the stage: nothing is stranded yet.
    func testAPageStillOnTheStageIsLeftAlone() {
        let (stage, host) = stage()
        defer { host.close() }
        let video = page()
        stage.addSubview(video)
        video.lent = .enteringFullscreen

        stage.show(video)
        turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 0)
        XCTAssertTrue(video.superview === stage)
    }
}
