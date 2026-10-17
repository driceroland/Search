import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class TabActivityTests: XCTestCase {
    private var browser: Browser!
    private var page: Tab!

    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-activity-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.sleepsTabs = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = Tab(configuration: configuration)
        page.setAddressOptimistically(URL(string: "https://example.test")!)
        browser.insert(page, at: browser.tabs.count)
    }

    override func tearDown() {
        browser.closeAll()
        browser.prefs.sleepsTabs = true
        browser = nil
        page = nil
    }

    private func reason() async -> String {
        await withCheckedContinuation { continuation in
            browser.activityReason(for: page) { continuation.resume(returning: $0) }
        }
    }

    private func script(_ text: String) async {
        await withCheckedContinuation { continuation in
            page.web.evaluateInSearch(text) { _ in continuation.resume() }
        }
    }

    func testUnloadedAndSleepingPagesAreNeverWoken() async {
        let unloaded = await reason()
        XCTAssertEqual(unloaded, "Not loaded")
        XCTAssertNil(page.built)
        page.restore(url: URL(string: "https://example.test")!, title: "Restored")
        let sleeping = await reason()
        XCTAssertEqual(sleeping, "Sleeping")
        XCTAssertNil(page.built)
    }

    func testReasonsReuseSleepPolicyAndDistinguishUnknownForms() async {
        await script("window.__officeForms = {unsaved: () => true}")
        let touched = page.touched
        let dirty = await reason()
        XCTAssertEqual(dirty, "Holding unsaved input")
        await script("window.__officeForms.unsaved = () => false")
        let waiting = await reason()
        XCTAssertEqual(waiting, "Waiting for sleep delay")
        XCTAssertEqual(page.touched, touched)
        page.touch(at: .distantPast)
        let eligible = await reason()
        XCTAssertEqual(eligible, "Eligible to sleep")
        await script("delete window.__officeForms")
        let unavailable = await reason()
        XCTAssertEqual(unavailable, "Form state unavailable")
        browser.prefs.sleepsTabs = false
        let disabled = await reason()
        XCTAssertEqual(disabled, "Automatic sleeping is off")
        browser.select(page)
        let visible = await reason()
        XCTAssertEqual(visible, browser.awake(because: page))
    }

    func testNavigationDuringFormCheckDiscardsTheAnswer() async {
        await script("window.__officeForms = {unsaved: () => true}")
        let answer = await withCheckedContinuation { continuation in
            browser.activityReason(for: page) { continuation.resume(returning: $0) }
            page.setAddressOptimistically(URL(string: "https://changed.test")!)
        }
        XCTAssertEqual(answer, "Changed — refresh")
    }

    func testClosePanelDoesNotCloseATab() {
        let count = browser.tabs.count
        browser.activityShowing = true
        XCTAssertTrue(browser.closePanel())
        XCTAssertFalse(browser.activityShowing)
        XCTAssertEqual(browser.tabs.count, count)
    }
}
