import AppKit
import WebKit
import XCTest
@testable import Search

/// Pins in a space you aren't in sleep after the usual wait, except a pin
/// whose site may send notifications; pins in the space on screen stay
/// awake as before (#569). In a test world of its own, nothing shown.
@available(macOS 14, *)
@MainActor
final class PinSleepTests: XCTestCase {
    private var browser: Browser!
    private let site = "https://pinned.example"
    private var notifying: String { SiteNotifications.key(site) }

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.siteNotifications = true
        Store.settings.removeObject(forKey: notifying)
    }

    override func tearDown() {
        Store.settings.removeObject(forKey: notifying)
        browser.parked = [:]
        browser.closeAll()
        browser = nil
    }

    /// A pinned tab with its page made, last looked at long ago.
    private func pin(_ url: String) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        _ = tab.web
        tab.pin = "P"
        tab.touch(at: .distantPast)
        return tab
    }

    private func park(_ tabs: [Tab]) {
        browser.parked[UUID()] = Parked(tabs: tabs, active: nil)
    }

    func testPinInTheSpaceOnScreenStaysAwake() {
        let here = pin(site)
        browser.prepare(here)
        browser.insert(here, at: browser.tabs.count)
        XCTAssertEqual(browser.awake(because: here), "pinned")
    }

    func testPinInAnotherSpaceMaySleep() {
        let away = pin(site)
        park([away])
        XCTAssertNil(browser.awake(because: away), "Nothing should keep a parked pin awake")
    }

    func testPinWhoseSiteMayNotifyStaysAwake() {
        let away = pin(site + "/inbox")
        park([away])
        Store.settings.set(true, forKey: notifying)
        XCTAssertTrue(browser.mayNotify(away))
        XCTAssertNotNil(browser.awake(because: away))
        // Answered no, or notifications off in Settings: it may sleep.
        Store.settings.set(false, forKey: notifying)
        XCTAssertNil(browser.awake(because: away))
        Store.settings.set(true, forKey: notifying)
        browser.prefs.siteNotifications = false
        XCTAssertFalse(browser.mayNotify(away))
        XCTAssertNil(browser.awake(because: away))
    }

    func testAnotherSitesPermissionDoesNotCount() {
        Store.settings.set(true, forKey: notifying)
        let other = pin("https://elsewhere.example")
        park([other])
        XCTAssertNil(browser.awake(because: other))
        let port = pin("https://pinned.example:8443")
        park([port])
        XCTAssertNil(browser.awake(because: port), "Another port is another origin")
    }

    func testParkedPinStillKeptAwakeByWhatItIsDoing() {
        let away = pin(site)
        away.noisy = true
        park([away])
        XCTAssertEqual(browser.awake(because: away), "playing sound")
    }

    func testAParkedPinGoesToSleep() async throws {
        let away = pin(site)
        _ = away.web
        park([away])
        let said = await withCheckedContinuation { continuation in
            browser.sleep(away) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(said, "asleep")
        XCTAssertTrue(away.asleep)
    }
}
