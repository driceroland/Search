import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › General › The floating video: Search's window unless picture
/// in picture is chosen, and the choice kept (idea 376). Entering picture
/// in picture puts a system window on screen, so that part is by eye.
@MainActor
final class NativePiPTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testSearchsWindowUnlessChosen() {
        let saved = Store.settings.object(forKey: "float.style")
        defer { Store.settings.set(saved, forKey: "float.style") }
        Store.settings.removeObject(forKey: "float.style")
        XCTAssertEqual(Preferences().floatStyle, .search)
        let prefs = Preferences()
        prefs.floatStyle = .system
        XCTAssertEqual(Preferences().floatStyle, .system)
        Store.settings.set("nonsense", forKey: "float.style")
        XCTAssertEqual(Preferences().floatStyle, .search)
    }

    func testScriptsAskOnlyForPictureInPicture() {
        let on = NativePiP.script(toggle: false)
        XCTAssertTrue(on.contains("var toggle = false"))
        XCTAssertTrue(NativePiP.script(toggle: true).contains("var toggle = true"))
        XCTAssertTrue(on.contains("webkitSetPresentationMode('picture-in-picture')"))
        XCTAssertFalse(on.contains("fullscreen"))
        XCTAssertTrue(NativePiP.off.contains("webkitSetPresentationMode('inline')"))
        XCTAssertTrue(MediaKeys.watch.contains("webkitPresentationMode === 'picture-in-picture'"))
    }

    func testWebKitPiPDelegateTracksStateKeepsTabAwakeAndExcludesPlayer() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let video = Tab(configuration: config)
        video.setAddressOptimistically(URL(string: "https://video.example/watch")!)
        let other = Tab(configuration: config)
        other.setAddressOptimistically(URL(string: "https://other.example/")!)
        let web = video.web
        _ = other.web
        browser.showRow([video, other], active: other.id)
        video.touch(at: .distantPast)

        // Quiet background tab with no PiP may sleep and close.
        XCTAssertNil(browser.awake(because: video))
        XCTAssertNil(browser.stays(because: video))

        // WebKit reports PiP started (e.g. from the page's own PiP button):
        // tab stays awake even when paused (noisy == false) and doesn't show in sidebar player.
        let prevOcclusion = NativePiP.occlusionDetectionEnabled(web)
        browser.webView(web, hasVideoInPictureInPictureDidChange: true)
        XCTAssertTrue(video.inPictureInPicture)
        XCTAssertTrue(web.inPictureInPicture)
        // Started by the page, not by Search: never `pictured`, so coming
        // back to the tab leaves it where the person put it.
        XCTAssertNil(browser.pictured)
        XCTAssertTrue(browser.hasPictureInPicture)
        // The tab itself left out, as when Search's own script answers "in"
        // after WebKit already reported it (finishSpaceFloat).
        XCTAssertFalse(browser.hasPictureInPicture(besides: video))
        XCTAssertTrue(browser.hasPictureInPicture(besides: other))
        XCTAssertEqual(browser.awake(because: video), "its video is out")
        XCTAssertEqual(browser.stays(because: video), "its video is out")
        if prevOcclusion {
            XCTAssertFalse(NativePiP.occlusionDetectionEnabled(web))
        }

        // Sidebar player excludes tabs in macOS PiP so its pause cannot suspend media playback.
        let oldShowsPlayer = browser.prefs.showsPlayer
        let oldSidebar = browser.prefs.sidebar
        defer {
            browser.prefs.showsPlayer = oldShowsPlayer
            browser.prefs.sidebar = oldSidebar
        }
        browser.prefs.showsPlayer = true
        browser.prefs.sidebar = true
        browser.heard(video, noisy: true, stilled: false)
        XCTAssertNil(browser.player)

        // WebKit reports PiP ended (e.g. user closed PiP with X):
        // state, pictured, occlusion detection, and sleep eligibility all clean up.
        browser.webView(web, hasVideoInPictureInPictureDidChange: false)
        XCTAssertFalse(video.inPictureInPicture)
        XCTAssertFalse(web.inPictureInPicture)
        XCTAssertNil(browser.pictured)
        XCTAssertFalse(browser.hasPictureInPicture)
        XCTAssertNil(browser.awake(because: video))
        XCTAssertEqual(NativePiP.occlusionDetectionEnabled(web), prevOcclusion)
    }

    private func paint(_ views: PageView...) async {
        for view in views { view.showFirstFrame() }
        for _ in 0..<100 where views.contains(where: \.unpainted) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testStageViewHoldsBackgroundPiPPageUnseenUntilPiPEnds() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let stage = StageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = stage

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let video = Tab(configuration: config)
        let other = Tab(configuration: config)
        defer {
            video.close()
            other.close()
        }
        let videoWeb = video.web
        let otherWeb = other.web

        // Start on video tab, enter PiP, then switch to other tab.
        stage.show(videoWeb)
        await paint(videoWeb, otherWeb)
        XCTAssertTrue(videoWeb.superview === stage)
        XCTAssertEqual(videoWeb.alphaValue, 1)

        video.setPictureInPicture(true)
        stage.show(otherWeb)

        // Video page stays attached to the window unseen so WebKit doesn't throttle/suspend it.
        XCTAssertTrue(videoWeb.superview === stage)
        XCTAssertEqual(videoWeb.alphaValue, 0)
        XCTAssertTrue(stage.holdsPictureInPicture(videoWeb))
        XCTAssertTrue(otherWeb.superview === stage)
        XCTAssertEqual(otherWeb.alphaValue, 1)

        // Hit testing reaches the active tab, never the held PiP page.
        let hit = stage.hitTest(NSPoint(x: 320, y: 180))
        XCTAssertTrue(hit != nil && (hit === otherWeb || hit!.isDescendant(of: otherWeb)))
        XCTAssertFalse(hit === videoWeb || (hit?.isDescendant(of: videoWeb) == true))

        // Exiting PiP immediately detaches the background view.
        video.setPictureInPicture(false)
        XCTAssertNil(videoWeb.superview)
        XCTAssertFalse(stage.holdsPictureInPicture(videoWeb))
    }

    func testStageViewLetGoTransitionsPartingPiPViewToHeld() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let stage = StageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = stage

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let video = Tab(configuration: config)
        let other = Tab(configuration: config)
        defer {
            video.close()
            other.close()
        }
        let videoWeb = video.web
        let otherWeb = other.web

        // Simulates Browser.select switching tabs while Browser.picture evaluates JS.
        stage.show(videoWeb)
        await paint(videoWeb, otherWeb)
        stage.keep(videoWeb)
        stage.show(otherWeb)
        XCTAssertTrue(videoWeb.superview === stage)
        XCTAssertEqual(videoWeb.alphaValue, 0)

        // Script returns "in" -> expectPictureInPicture() before letGo().
        video.expectPictureInPicture()
        stage.letGo(videoWeb)
        XCTAssertTrue(videoWeb.superview === stage)
        XCTAssertEqual(videoWeb.alphaValue, 0)
        XCTAssertTrue(stage.holdsPictureInPicture(videoWeb))

        // Returning to the video tab restores visibility.
        stage.show(videoWeb)
        XCTAssertEqual(videoWeb.alphaValue, 1)
        XCTAssertFalse(stage.holdsPictureInPicture(videoWeb))
    }

    func testPausedPiPTabDoesNotHushOrSleepAndProcessTerminationClearsPiP() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let video = Tab(configuration: config)
        video.setAddressOptimistically(URL(string: "https://video.example/watch")!)
        let other = Tab(configuration: config)
        let web = video.web
        _ = other.web
        browser.showRow([video, other], active: other.id)

        browser.webView(web, hasVideoInPictureInPictureDidChange: true)
        XCTAssertTrue(video.inPictureInPicture)
        XCTAssertTrue(browser.hasPictureInPicture)

        // Simulating WebContent process termination clears stale PiP state.
        browser.webViewWebContentProcessDidTerminate(web)
        XCTAssertFalse(video.inPictureInPicture)
        XCTAssertNil(browser.pictured)
        XCTAssertFalse(browser.hasPictureInPicture)
    }
}
