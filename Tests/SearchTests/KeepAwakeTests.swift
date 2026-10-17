import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class KeepAwakeTests: XCTestCase {
    private var browser: Browser!

    override class func setUp() {
        setenv("SEARCH_PROBE", "keep-awake-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.keepsSitesAwake = false
        browser.prefs.awakeSites = []
    }

    override func tearDown() {
        browser.closeAll()
        browser.prefs.keepsSitesAwake = false
        browser.prefs.awakeSites = []
        browser.prefs.tabLife = .never
        browser = nil
    }

    private func tab(_ url: String, privateMode: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: privateMode, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    func testOptInExactHostsAndPersistence() {
        let page = tab("https://EXAMPLE.com:8443/path")
        browser.keepAwake(true, for: page)
        XCTAssertFalse(browser.keepsAwake(page))
        browser.prefs.keepsSitesAwake = true
        XCTAssertTrue(browser.keepsAwake(page))
        XCTAssertTrue(browser.keepsAwake(tab("http://example.com/other")))
        XCTAssertFalse(browser.keepsAwake(tab("https://sub.example.com")))
        XCTAssertFalse(browser.keepsAwake(tab("https://example.company")))
        XCTAssertFalse(browser.keepsAwake(tab("file:///example.com")))
        XCTAssertEqual(Preferences().awakeSites, ["example.com"])
        browser.prefs.keepsSitesAwake = false
        XCTAssertFalse(browser.keepsAwake(page))
        XCTAssertEqual(browser.prefs.awakeSites, ["example.com"])
        browser.keepAwake(false, for: page)
        XCTAssertTrue(Preferences().awakeSites.isEmpty)
    }

    func testPrivateChoicesNeverReadOrWriteNormalChoices() {
        browser.prefs.keepsSitesAwake = true
        browser.keepAwake(true, for: tab("https://example.com"))
        let privatePage = tab("https://example.com", privateMode: true)
        XCTAssertFalse(browser.keepsAwake(privatePage))
        browser.keepAwake(true, for: privatePage)
        XCTAssertTrue(browser.keepsAwake(privatePage))
        XCTAssertFalse(browser.keepsAwake(tab("https://example.com", privateMode: true)))
        privatePage.setAddressOptimistically(URL(string: "https://other.example")!)
        XCTAssertFalse(browser.keepsAwake(privatePage))
        browser.keepAwake(true, for: privatePage)
        XCTAssertEqual(Preferences().awakeSites, ["example.com"])
        XCTAssertNil(privatePage.built, "Checking an exception must not load a page")
    }

    func testExceptionAddedDuringFormCheckPreventsDiscard() async {
        browser.prefs.keepsSitesAwake = true
        let page = tab("https://example.com")
        browser.insert(page, at: browser.tabs.count)
        await withCheckedContinuation { continuation in
            page.web.evaluateInSearch("window.__officeForms = {unsaved: () => false}") { _ in continuation.resume() }
        }
        let reason = await withCheckedContinuation { continuation in
            browser.sleep(page) { continuation.resume(returning: $0) }
            browser.keepAwake(true, for: page)
        }
        XCTAssertEqual(reason, "kept awake for this site")
        XCTAssertNotNil(page.built)
    }

    func testExceptionPreventsSleepAndAutomaticClosureButNotManualClose() async throws {
        browser.prefs.keepsSitesAwake = true
        browser.prefs.tabLife = .halfDay
        let page = tab("https://example.com")
        _ = page.web
        page.touch(at: .distantPast)
        browser.prepare(page)
        browser.insert(page, at: browser.tabs.count)
        browser.keepAwake(true, for: page)
        XCTAssertEqual(browser.awake(because: page), "kept awake for this site")
        XCTAssertEqual(browser.stays(because: page), "kept awake for this site")
        browser.sleepIdle(within: 0)
        browser.closeLeftAlone()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(page.built)
        XCTAssertTrue(browser.tabs.contains { $0 === page })
        browser.keepAwake(false, for: page)
        XCTAssertNil(browser.busy(page))
        browser.keepAwake(true, for: page)
        browser.close(page)
        XCTAssertFalse(browser.tabs.contains { $0 === page })
    }
}
