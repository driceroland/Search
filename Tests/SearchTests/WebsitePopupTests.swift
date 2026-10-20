import AppKit
import XCTest
import WebKit
@testable import Search

@MainActor
final class WebsitePopupTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "website-popup-\(getpid())", 1)
        super.setUp()
    }

    func testRequestedSizeStaysUsableAndOnTheOpenersScreen() {
        let screen = NSRect(x: -1280, y: 40, width: 1280, height: 760)
        XCTAssertEqual(Browsers.popupFrame(width: 400, height: 500, on: screen),
                       NSRect(x: -840, y: 170, width: 400, height: 500))
        XCTAssertEqual(Browsers.popupFrame(width: 100_000, height: 100_000, on: screen), screen)
        let tiny = Browsers.popupFrame(width: -1, height: 0, on: screen)
        XCTAssertEqual(tiny.size, NSSize(width: 200, height: 150))
        let missing = Browsers.popupFrame(width: .nan, height: nil, on: screen)
        XCTAssertEqual(missing.size, NSSize(width: 480, height: 600))
        XCTAssertTrue(screen.contains(missing))
    }

    func testClosingPopupDeniesItsPendingCaptureExactlyOnce() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let popup = Browser(record: WindowRecord(), websitePopup: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = CaptureRelay(browser: popup)
        configuration.userContentController.add(relay, name: "fixtureCapture")
        let tab = Tab(shy: true, configuration: configuration)
        popup.prepare(tab)
        popup.showRow([tab], active: tab.id)
        tab.web.loadHTMLString("<script>window.webkit.messageHandlers.fixtureCapture.postMessage(true)</script>",
                               baseURL: URL(string: "https://popup.invalid"))
        for _ in 0..<100 where popup.asking == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(popup.asking?.wants, "microphone")
        XCTAssertTrue(relay.decisions.isEmpty)
        popup.closeAll()
        popup.closeAll()
        XCTAssertEqual(relay.decisions, [.deny], "window teardown must settle the callback without waiting for the click guard")
        XCTAssertNil(popup.asking)
        configuration.userContentController.removeScriptMessageHandler(forName: "fixtureCapture")
    }

    func testLocationAndNotificationQuestionsUseThePopupAndCancel() async throws {
        for kind in ["location", "notifications"] {
            let popup = Browser(record: WindowRecord(), websitePopup: true)
            let notifications = popup.prefs.siteNotifications
            popup.prefs.siteNotifications = true
            defer { popup.prefs.siteNotifications = notifications }
            let configuration = Web.configuration(space: popup.spaceID)
            let relay = CaptureRelay(browser: popup)
            configuration.userContentController.add(relay, name: "fixtureCapture")
            let tab = Tab(configuration: configuration)
            popup.prepare(tab)
            popup.showRow([tab], active: tab.id)
            tab.web.loadHTMLString("<script>window.webkit.messageHandlers.fixtureCapture.postMessage('\(kind)')</script>",
                                  baseURL: URL(string: "https://popup.invalid"))
            for _ in 0..<100 where popup.asking == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(popup.asking?.wants, kind)
            popup.cancelCapture()
            XCTAssertEqual(relay.decisions, [.deny])
            popup.closeAll()
            configuration.userContentController.removeScriptMessageHandler(forName: "fixtureCapture")
        }
    }

    func testWebsitePopupDoesNotRestoreOrWritePinsAndSessions() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let popup = Browser(record: WindowRecord(), websitePopup: true)
        XCTAssertTrue(popup.isPopup)
        XCTAssertNil(popup.extensionPopup)
        XCTAssertTrue(popup.tabs.isEmpty, "a popup must not construct a blank page or restore pins")
        XCTAssertTrue(popup.parkedTabs.isEmpty, "a popup must not warm other Spaces")
        let oldPins = Pins.defs(popup.spaceID)
        let pins = [PinDef(id: UUID(), letter: "P", home: "https://pin.invalid", title: "Pin", name: nil)]
        Pins.set(popup.spaceID, pins, from: popup)
        defer { Pins.set(popup.spaceID, oldPins, from: popup) }
        let before = popup.record.rows
        popup.writeSession(now: true)
        popup.pinsChanged(in: popup.spaceID)
        XCTAssertEqual(Pins.defs(popup.spaceID), pins, "opening a popup must not erase a Space's pins")
        XCTAssertEqual(popup.record.rows.count, before.count)
        XCTAssertTrue(popup.tabs.isEmpty, "pin changes must not add hidden tabs")
        Browsers.register(popup)
        XCTAssertFalse(Browsers.saved.contains { $0 === popup })
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }
}

@MainActor
private final class CaptureRelay: NSObject, WKScriptMessageHandler {
    weak var browser: Browser?
    var decisions: [WKPermissionDecision] = []
    init(browser: Browser) { self.browser = browser }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web = message.webView else { return }
        let origin = message.frameInfo.securityOrigin
        if message.body as? String == "location" {
            browser?.askedForLocation(web, origin: origin, frame: message.frameInfo) { [weak self] in self?.decisions.append($0) }
        } else if message.body as? String == "notifications" {
            browser?.askedForNotifications(web, origin: origin) { [weak self] in self?.decisions.append($0 ? .grant : .deny) }
        } else {
            browser?.askedForCapture(web, origin: origin, frame: message.frameInfo,
                                     type: .microphone) { [weak self] in self?.decisions.append($0) }
        }
    }
}
