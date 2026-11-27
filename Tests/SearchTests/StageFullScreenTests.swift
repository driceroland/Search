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
        TestWorld.enter()
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

    /// What is put off until the layout is over (DispatchQueue.main.async).
    /// Awaited, not a run loop turned by hand: the test's body runs as a
    /// block on the main queue, and the blocks it waits for queue behind it
    /// however long the run loop is turned (see WakeLatencyTests.spin).
    private func turn() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// The tab left for another while its video stays full screen, then
    /// chosen again in this window: the other tab's page goes, the column
    /// comes back, full screen is asked to end, and the page returns at the
    /// stage's size with the keys when WebKit lets it go.
    func testATabFullScreenElsewhereChosenAgainComesHome() async {
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
        await turn()
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
    func testAFullScreenThatDoesNotEndStillGivesTheColumnBack() async {
        let (stage, host) = stage()
        defer { host.close() }
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen

        stage.show(video)
        await turn()
        XCTAssertEqual(chromeBack, 1)
        XCTAssertTrue(video.superview === elsewhere)
    }

    /// Landing on the tab from the video's own Space, by a link it opened or
    /// a popup closing itself: the video goes on, and comes home when left.
    func testChosenFromTheVideosOwnSpaceTheVideoGoesOn() async {
        let (stage, host) = stage()
        defer { host.close() }
        host.key = false
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .inFullscreen

        stage.show(video)
        await turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 1)

        video.lent = .exitingFullscreen
        video.removeFromSuperview()
        video.lent = .notInFullscreen
        XCTAssertTrue(video.superview === stage)
    }

    /// Chosen while still on its way in: asked again once it is there, when
    /// the page has a full-screen element to leave.
    func testChosenOnItsWayInIsAskedAgainOnceThere() async {
        let (stage, host) = stage()
        defer { host.close() }
        let elsewhere = NSView()
        let video = page()
        elsewhere.addSubview(video)
        video.lent = .enteringFullscreen

        stage.show(video)
        await turn()
        XCTAssertEqual(ended, 1)
        video.lent = .inFullscreen
        await turn()
        XCTAssertEqual(ended, 2)
        XCTAssertEqual(chromeBack, 2)
    }

    /// The ordinary full screen: a placeholder is on the stage, and only the
    /// page's own way out ends it, even when the stage is told to show it
    /// again.
    func testAPageWithItsPlaceholderHereIsLeftFullScreen() async {
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
        await turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 0)
        XCTAssertTrue(placeholder.superview === stage)
        XCTAssertEqual(placeholder.frame, stage.bounds)
    }

    /// WebKit coming out of full screen: the page goes back where its
    /// placeholder is, if it is anywhere, and the placeholder goes.
    private func comeOut(_ video: LentPage, placeholder: NSView) {
        video.lent = .exitingFullscreen
        video.removeFromSuperview()
        if let home = placeholder.superview {
            video.frame = placeholder.frame
            home.addSubview(video, positioned: .above, relativeTo: placeholder)
        }
        placeholder.removeFromSuperview()
        video.lent = .notInFullscreen
    }

    /// A video full screen, its placeholder on the stage, as WebKit leaves it.
    private func fullScreen(on stage: StageView) -> (LentPage, NSView, NSView) {
        let video = page()
        stage.show(video)
        let elsewhere = NSView(frame: stage.bounds)
        let placeholder = FakeFullScreenPlaceholderView(frame: stage.bounds)
        stage.addSubview(placeholder, positioned: .above, relativeTo: video)
        elsewhere.addSubview(video)
        video.lent = .inFullscreen
        return (video, placeholder, elsewhere)
    }

    /// Another tab shown while the video is full screen, and the video's
    /// full screen ended as ⌃Tab and ⌘1–⌘9 end it (idea 936): its
    /// placeholder stays under the tab in front, so WebKit has somewhere to
    /// bring the page back to; once back, it is put away as any tab
    /// behind, and chosen again it is the page, at the stage's size.
    func testAVideoLeftForAnotherTabComesBackToItsPlaceholder() {
        let (stage, host) = stage()
        defer { host.close() }
        let (video, placeholder, _) = fullScreen(on: stage)
        let other = page()
        stage.show(other)
        stage.layoutSubtreeIfNeeded()
        XCTAssertTrue(placeholder.superview === stage, "the placeholder went with the tab left")
        XCTAssertTrue(stage.subviews.last === other, "the tab shown isn't in front")

        comeOut(video, placeholder: placeholder)
        XCTAssertTrue(video.superview === stage, "WebKit had nowhere to bring the page back to")
        XCTAssertTrue(stage.subviews.last === other)
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        XCTAssertNil(video.superview, "home behind the other tab, and never put away")

        stage.show(video)
        XCTAssertTrue(video.superview === stage)
        XCTAssertNil(other.superview)
        XCTAssertEqual(video.frame, stage.bounds)
        XCTAssertFalse(stage.subviews.contains { $0 is FakeFullScreenPlaceholderView })
        XCTAssertEqual(ended, 0)
    }

    /// The tab whose video is still full screen, left for another and
    /// chosen again in this window: not its placeholder alone, white where
    /// the video was (idea 936), but full screen asked to end, the column
    /// back, and the page home at the stage's size with the keys.
    func testAVideoStillFullScreenChosenAgainComesHome() async {
        let (stage, host) = stage()
        defer { host.close() }
        let (video, placeholder, _) = fullScreen(on: stage)
        let other = page()
        stage.show(other)
        stage.layoutSubtreeIfNeeded()

        stage.show(video)
        await turn()
        XCTAssertEqual(ended, 1, "full screen was never asked to end")
        XCTAssertEqual(chromeBack, 1)
        XCTAssertNil(other.superview, "the last tab's page stayed on the stage")

        host.makeFirstResponder(nil)
        comeOut(video, placeholder: placeholder)
        XCTAssertTrue(video.superview === stage)
        XCTAssertEqual(video.frame, stage.bounds)
        XCTAssertEqual(stage.subviews.filter { !($0 is FakeFullScreenPlaceholderView) }.count, 1)
        XCTAssertTrue(host.firstResponder === video, "came home without the keys")
    }

    /// The same with Settings › Keep the window in use during full screen.
    func testAVideoStillFullScreenChosenAgainComesHomeKeepingTheWindow() async {
        let was = Shared.prefs.keepsWindow
        Shared.prefs.keepsWindow = true
        defer { Shared.prefs.keepsWindow = was }
        await testAVideoStillFullScreenChosenAgainComesHome()
    }

    /// Chosen again from the video's own Space, by a link it opened: the
    /// video goes on, and comes home to its placeholder when it ends.
    func testAVideoLeftAndChosenFromItsOwnSpaceGoesOn() async {
        let (stage, host) = stage()
        defer { host.close() }
        let (video, placeholder, _) = fullScreen(on: stage)
        stage.show(page())
        stage.layoutSubtreeIfNeeded()
        host.key = false
        stage.show(video)
        await turn()
        XCTAssertEqual(ended, 0)
        comeOut(video, placeholder: placeholder)
        XCTAssertTrue(video.superview === stage)
        XCTAssertEqual(video.frame, stage.bounds)
    }

    /// On its way in, still on the stage: nothing is stranded yet.
    func testAPageStillOnTheStageIsLeftAlone() async {
        let (stage, host) = stage()
        defer { host.close() }
        let video = page()
        stage.addSubview(video)
        video.lent = .enteringFullscreen

        stage.show(video)
        await turn()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(chromeBack, 0)
        XCTAssertTrue(video.superview === stage)
    }
}
