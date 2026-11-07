import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class ScreenPermissionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "screen-permission-\(getpid())", 1)
        super.setUp()
    }

    func testScreenWindowAndDenialNeverOpenPickerInTests() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        for choice in ["screen", "window", "no"] {
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            browser.shareScreen() // Clickjacking guard still applies.
            XCTAssertTrue(replies.isEmpty)
            try await Task.sleep(nanoseconds: 550_000_000)
            if choice == "screen" { browser.shareScreen() }
            else if choice == "window" { browser.shareWindow() }
            else { browser.denyShare() }
            browser.denyShare()
            XCTAssertEqual(replies, [0], choice)
            XCTAssertEqual(Browser.displayAnswered, choice == "screen" ? 1 : choice == "window" ? 2 : 0)
            XCTAssertNil(browser.asking)
        }
    }

    func testPendingScreenCannotBeReplacedByOtherPermissions() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        browser.prefs.siteNotifications = true
        XCTAssertFalse(tab.shy)
        XCTAssertTrue(tab.web.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(tab.web.url?.host, frame.securityOrigin.host)
        XCTAssertNil(SiteNotifications.choices["https://screen.example"])
        var screen: [Int] = []
        ask(browser, tab, frame) { screen.append($0) }
        for type: WKMediaCaptureType in [.camera, .microphone, .cameraAndMicrophone] {
            var reply: WKPermissionDecision?
            browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: type) { reply = $0 }
            XCTAssertEqual(reply, .deny)
            XCTAssertEqual(browser.asking?.wants, "screen")
        }
        var location: WKPermissionDecision?
        browser.askedForLocation(tab.web, origin: frame.securityOrigin, frame: frame) { location = $0 }
        XCTAssertEqual(location, .deny)
        var notification: Bool?
        browser.askedForNotifications(tab.web, origin: frame.securityOrigin) { notification = $0 }
        XCTAssertEqual(notification, false)
        var second: [Int] = []
        ask(browser, tab, frame) { second.append($0) }
        XCTAssertEqual(second, [0])
        XCTAssertTrue(screen.isEmpty)
        XCTAssertEqual(browser.asking?.wants, "screen")
        browser.cancelDisplay()
        browser.askedForNotifications(tab.web, origin: frame.securityOrigin) { notification = $0 }
        XCTAssertEqual(browser.asking?.wants, "notifications")
    }

    func testCameraCardRefusesScreenRequest() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .microphone) { _ in }
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        XCTAssertEqual(replies, [0])
        XCTAssertEqual(browser.asking?.wants, "microphone")
    }

    func testVisibleRequestEndsOnSwitchNavigationCloseAndWindowClose() async throws {
        for event in ["switch", "navigate", "close", "window", "crash", "replace", "discard"] {
            let (browser, tab, frame) = try await fixture()
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            switch event {
            case "switch": browser.newTab()
            case "navigate":
                tab.web.loadHTMLString("<p>A different document</p>", baseURL: URL(string: "https://screen.example/next"))
                try await Task.sleep(nanoseconds: 200_000_000)
            case "close": browser.close(tab)
            case "window": browser.closeAll()
            case "crash": browser.webViewWebContentProcessDidTerminate(tab.web)
            case "discard": tab.rest()
            default: browser.replace(tab, going: URL(string: "about:blank")!)
            }
            XCTAssertEqual(replies, [0], event)
            XCTAssertNil(browser.asking, event)
            browser.denyShare()
            browser.closeAll()
            XCTAssertEqual(replies, [0], "\(event) answers exactly once")
        }
    }

    func testBackgroundRequestWaitsForItsTabAndCancelsBeforePresentation() async throws {
        for event in ["select", "navigate", "close", "rapid-switch", "move"] {
            let (browser, tab, frame) = try await fixture()
            browser.newTab()
            let other = try XCTUnwrap(browser.active)
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            XCTAssertNil(browser.asking)
            switch event {
            case "select": browser.select(tab)
            case "navigate": tab.web.loadHTMLString("<p>Next</p>", baseURL: URL(string: "https://screen.example/next"))
            case "close": browser.close(tab)
            case "move":
                let destination = Browser(record: WindowRecord())
                browser.moveToWindow(tab, destination)
                destination.closeAll()
            default: browser.select(tab); browser.select(other)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            if event == "select" {
                XCTAssertEqual(browser.asking?.wants, "screen")
                XCTAssertTrue(replies.isEmpty)
            } else {
                XCTAssertEqual(replies, [0], event)
                XCTAssertNil(browser.asking, event)
                XCTAssertTrue(browser.heldDialogs[tab.id]?.isEmpty ?? true)
            }
            browser.closeAll()
            XCTAssertEqual(replies, [0], event)
        }
    }

    func testCameraCardEndsWhenItsTabIsLeftOrGoes() async throws {
        for event in ["switch", "navigate", "close"] {
            let (browser, tab, frame) = try await fixture()
            var replies: [WKPermissionDecision] = []
            browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .camera) { replies.append($0) }
            XCTAssertEqual(browser.asking?.wants, "camera", event)
            switch event {
            case "switch": browser.newTab()
            case "navigate":
                tab.web.loadHTMLString("<p>A different document</p>", baseURL: URL(string: "https://screen.example/next"))
                try await Task.sleep(nanoseconds: 200_000_000)
            default: browser.close(tab)
            }
            XCTAssertEqual(replies, [.deny], event)
            XCTAssertNil(browser.asking, event)
            try await Task.sleep(nanoseconds: 550_000_000)
            browser.allowCapture()
            browser.closeAll()
            XCTAssertEqual(replies, [.deny], "\(event) answers exactly once")
        }
    }

    func testHeldScreenQuestionLeavesTheTabInFrontFreeToAsk() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        browser.newTab()
        let other = try XCTUnwrap(browser.active)
        other.web.loadHTMLString("<p>Front</p>", baseURL: URL(string: "https://screen.example/front"))
        var screen: [Int] = []
        ask(browser, tab, frame) { screen.append($0) }
        XCTAssertNil(browser.asking)
        var camera: [WKPermissionDecision] = []
        browser.askedForCapture(other.web, origin: frame.securityOrigin, frame: frame, type: .camera) { camera.append($0) }
        XCTAssertEqual(browser.asking?.wants, "camera")
        XCTAssertTrue(camera.isEmpty)
        browser.select(tab)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(camera, [.deny])
        XCTAssertEqual(browser.asking?.wants, "screen")
        XCTAssertTrue(screen.isEmpty)
    }

    func testCompletionCanRequestAgainWithoutLosingTheNewCard() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        var first: [Int] = [], next: [Int] = []
        ask(browser, tab, frame) { decision in
            first.append(decision)
            self.ask(browser, tab, frame) { next.append($0) }
        }
        browser.cancelDisplay()
        XCTAssertEqual(first, [0])
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(browser.asking?.wants, "screen")
        browser.cancelDisplay()
        XCTAssertEqual(first, [0])
        XCTAssertEqual(next, [0])
    }

    func testUnknownPageCannotRaiseAWindowCard() async throws {
        let (browser, _, frame) = try await fixture()
        defer { browser.closeAll() }
        let web = WKWebView(frame: .zero)
        var replies: [Int] = []
        browser.askedToShareScreen(web, origin: frame.securityOrigin, frame: frame,
                                  systemAudio: false) { replies.append($0) }
        XCTAssertEqual(replies, [0])
        XCTAssertNil(browser.asking)
    }

    func testClosingTheLastWindowCancelsWithoutDiscardingItsTabs() async throws {
        let (browser, tab, frame) = try await fixture()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        browser.window = window
        Browsers.register(browser)
        defer { browser.closeAll(); browser.window = nil }
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        Browsers.closing(window)
        XCTAssertTrue(browser.shut)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        XCTAssertEqual(replies, [0])
        XCTAssertNil(browser.asking)
        XCTAssertFalse(window.isVisible)
    }

    func testPrivateRequestNeverRemembersAndSplitFocusCancels() async throws {
        let (browser, tab, frame) = try await fixture(shy: true)
        defer { browser.closeAll() }
        let before = Store.settings.dictionaryRepresentation().filter { $0.key.hasPrefix("capture.") } as NSDictionary
        for _ in 0..<2 {
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            XCTAssertEqual(browser.asking?.wants, "screen")
            try await Task.sleep(nanoseconds: 550_000_000)
            browser.shareWindow()
            XCTAssertEqual(replies, [0])
            XCTAssertEqual(Browser.displayAnswered, 2)
        }
        XCTAssertEqual(before, Store.settings.dictionaryRepresentation().filter { $0.key.hasPrefix("capture.") } as NSDictionary)
        browser.newTab()
        let other = try XCTUnwrap(browser.active)
        browser.prefs.splitView = true
        browser.pair(other, with: tab, onLeft: false)
        browser.select(tab)
        XCTAssertNotNil(browser.activeSplit)
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        browser.focusPane(other)
        XCTAssertEqual(replies, [0])
        XCTAssertNil(browser.asking)
    }

    func testCombinedRequestCannotBypassIndividualRefusal() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        CaptureChoices.set(true, for: .cameraAndMicrophone, origin: origin)
        CaptureChoices.set(false, for: .camera, origin: origin)
        var reply: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { reply = $0 }
        XCTAssertEqual(reply, .deny)
        XCTAssertNil(browser.asking)
        XCTAssertTrue(CaptureChoices.combinedBlocked(origin: origin))
    }

    func testPrivatePeekDoesNotUseSavedCombinedPermission() async throws {
        let (browser, _, frame) = try await fixture(shy: true)
        defer { browser.forgetCaptureChoices(); browser.closePeek(); browser.closeAll() }
        let peek = Tab(shy: true)
        browser.prepare(peek)
        browser.peekTab = peek
        let origin = "https://screen.example"
        CaptureChoices.set(true, for: .camera, origin: origin)
        CaptureChoices.set(true, for: .microphone, origin: origin)
        var answer: WKPermissionDecision?
        browser.askedForCapture(peek.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertNil(answer)
        XCTAssertEqual(browser.asking?.wants, "camera and microphone")
        try await Task.sleep(for: .milliseconds(550))
        browser.allowCapture()
        XCTAssertEqual(answer, .grant)
        XCTAssertNil(Store.settings.object(forKey: "capture.\(origin)|\(WKMediaCaptureType.cameraAndMicrophone.rawValue)"))
    }

    func testIndividualPromptsUpdateBothAliasesAndAllowCombinedRequest() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        for type: WKMediaCaptureType in [.camera, .microphone] {
            var answer: WKPermissionDecision?
            browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: type) { answer = $0 }
            XCTAssertNil(answer)
            try await Task.sleep(for: .milliseconds(550))
            browser.allowCapture()
            XCTAssertEqual(answer, .grant)
        }
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: origin), .allow)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: origin), .allow)
        XCTAssertTrue(CaptureChoices.combinedAllowed(origin: origin))
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertEqual(answer, .grant)
    }

    func testCombinedRequestUsesBothIndividualAllows() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        CaptureChoices.set(false, for: .cameraAndMicrophone, origin: origin)
        CaptureChoices.set(true, for: .camera, origin: origin)
        CaptureChoices.set(true, for: .microphone, origin: origin)
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertEqual(answer, .grant)
        XCTAssertTrue(CaptureChoices.combinedAllowed(origin: origin))
    }

    func testCombinedGrantIsRememberedForEachDevice() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertEqual(browser.asking?.wants, "camera and microphone")
        try await Task.sleep(for: .milliseconds(550))
        browser.allowCapture()
        XCTAssertEqual(answer, .grant)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: origin), .allow)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: origin), .allow)
    }

    func testLegacyCombinedGrantDoesNotBypassIndividualAsk() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        CaptureChoices.set(true, for: .camera, origin: origin)
        for key in CaptureChoices.keys(.cameraAndMicrophone, origin: origin) { Store.settings.set(true, forKey: key) }
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertNil(answer)
        XCTAssertEqual(browser.asking?.wants, "microphone")
        browser.cancelCapture()
    }

    func testCombinedRefusalPreservesPreviouslyAllowedDevice() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        CaptureChoices.set(true, for: .camera, origin: origin)
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertEqual(browser.asking?.wants, "microphone")
        try await Task.sleep(for: .milliseconds(550))
        browser.denyCapture()
        XCTAssertEqual(answer, .deny)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: origin), .allow)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: origin), .refuse)
    }

    func testLegacyCombinedRefusalDoesNotHideIndividualChoices() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        let origin = "https://screen.example"
        for key in CaptureChoices.keys(.cameraAndMicrophone, origin: origin) { Store.settings.set(false, forKey: key) }
        var answer: WKPermissionDecision?
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { answer = $0 }
        XCTAssertNil(answer)
        XCTAssertEqual(browser.asking?.wants, "camera and microphone")
        try await Task.sleep(for: .milliseconds(550))
        browser.denyCapture()
        XCTAssertEqual(answer, .deny)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: origin), .refuse)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: origin), .refuse)
    }

    func testChangingSettingCancelsVisibleRequestInAnotherWindow() async throws {
        let (first, _, _) = try await fixture()
        let (second, tab, frame) = try await fixture()
        Browsers.register(first)
        Browsers.register(second)
        defer { first.forgetCaptureChoices(); first.closeAll(); second.closeAll() }
        var replies: [WKPermissionDecision] = []
        second.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .camera) { replies.append($0) }
        XCTAssertNotNil(second.asking)
        let changed = CaptureChoices.set(false, for: .camera, origin: "https://screen.example")
        Browser.cancelSiteQuestions(keys: changed, including: first)
        XCTAssertEqual(replies, [.deny])
        XCTAssertNil(second.asking)
    }

    func testRefusingCameraCancelsOtherWindowsCombinedPrompt() async throws {
        let (first, firstTab, firstFrame) = try await fixture()
        let (second, secondTab, secondFrame) = try await fixture()
        Browsers.register(first)
        Browsers.register(second)
        defer { first.forgetCaptureChoices(); first.closeAll(); second.closeAll() }
        var combined: [WKPermissionDecision] = []
        var camera: [WKPermissionDecision] = []
        first.askedForCapture(firstTab.web, origin: firstFrame.securityOrigin, frame: firstFrame, type: .cameraAndMicrophone) { combined.append($0) }
        second.askedForCapture(secondTab.web, origin: secondFrame.securityOrigin, frame: secondFrame, type: .camera) { camera.append($0) }
        try await Task.sleep(for: .milliseconds(550))
        second.denyCapture()
        first.allowCapture()
        XCTAssertEqual(camera, [.deny])
        XCTAssertEqual(combined, [.deny])
        XCTAssertNil(first.asking)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: "https://screen.example"), .refuse)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: "https://screen.example"), .ask)
    }

    func testStaleVisiblePromptCannotOverrideNewAnswer() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        var replies: [WKPermissionDecision] = []
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .cameraAndMicrophone) { replies.append($0) }
        CaptureChoices.set(false, for: .camera, origin: "https://screen.example")
        try await Task.sleep(for: .milliseconds(550))
        browser.allowCapture()
        XCTAssertEqual(replies, [.deny])
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: "https://screen.example"), .refuse)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: "https://screen.example"), .ask)
    }

    func testNotificationAnswerInvalidatesQueuedRequest() async throws {
        let (first, firstTab, firstFrame) = try await fixture()
        let (second, secondTab, secondFrame) = try await fixture()
        Browsers.register(first)
        Browsers.register(second)
        defer { first.forgetCaptureChoices(); first.closeAll(); second.closeAll() }
        first.prefs.siteNotifications = true
        second.prefs.siteNotifications = true
        second.newTab()
        var firstReply: [Bool] = []
        var queued: [Bool] = []
        first.askedForNotifications(firstTab.web, origin: firstFrame.securityOrigin) { firstReply.append($0) }
        second.askedForNotifications(secondTab.web, origin: secondFrame.securityOrigin) { queued.append($0) }
        try await Task.sleep(for: .milliseconds(550))
        first.denyCapture()
        second.select(secondTab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(firstReply, [false])
        XCTAssertEqual(queued, [false])
        XCTAssertNil(second.asking)
    }

    func testLocationAnswerCancelsOtherVisiblePrompt() async throws {
        let (first, firstTab, firstFrame) = try await fixture()
        let (second, secondTab, secondFrame) = try await fixture()
        Browsers.register(first)
        Browsers.register(second)
        defer { first.forgetCaptureChoices(); first.closeAll(); second.closeAll() }
        var other: [WKPermissionDecision] = []
        first.askedForLocation(firstTab.web, origin: firstFrame.securityOrigin, frame: firstFrame) { _ in }
        second.askedForLocation(secondTab.web, origin: secondFrame.securityOrigin, frame: secondFrame) { other.append($0) }
        try await Task.sleep(for: .milliseconds(550))
        first.denyCapture()
        second.allowCapture()
        XCTAssertEqual(other, [.deny])
        XCTAssertNil(second.asking)
        XCTAssertEqual(CaptureChoices.choice(.location, origin: "https://screen.example"), .refuse)
    }

    func testChangingSettingInvalidatesQueuedRequest() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        browser.newTab()
        var replies: [WKPermissionDecision] = []
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .camera) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        let changed = CaptureChoices.set(false, for: .camera, origin: "https://screen.example")
        Browser.cancelSiteQuestions(keys: changed, including: browser)
        browser.select(tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies, [.deny])
        XCTAssertNil(browser.asking)
    }

    func testChangingNotificationInvalidatesQueuedRequest() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.forgetCaptureChoices(); browser.closeAll() }
        browser.prefs.siteNotifications = true
        browser.newTab()
        var replies: [Bool] = []
        browser.askedForNotifications(tab.web, origin: frame.securityOrigin) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        let changed = CaptureChoices.set(false, for: .notifications, origin: "https://screen.example")
        Browser.cancelSiteQuestions(keys: changed, including: browser)
        browser.select(tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies, [false])
    }

    private func ask(_ browser: Browser, _ tab: Tab, _ frame: WKFrameInfo, reply: @escaping (Int) -> Void) {
        // The local reply keeps even a broken implementation from opening the picker.
        browser.askedToShareScreen(tab.web, origin: frame.securityOrigin, frame: frame,
                                  systemAudio: false, decisionHandler: reply)
    }

    private func fixture(shy: Bool = false) async throws -> (Browser, Tab, WKFrameInfo) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        XCTAssertTrue(Store.testing)
        let browser = Browser(record: WindowRecord())
        browser.forgetCaptureChoices()
        let tab = Tab(shy: shy)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        browser.select(tab)
        let receiver = FrameReceiver()
        let controller = tab.web.configuration.userContentController
        controller.add(receiver, name: "screenFixture")
        defer { controller.removeScriptMessageHandler(forName: "screenFixture") }
        tab.web.loadHTMLString("<script>webkit.messageHandlers.screenFixture.postMessage('ready')</script>",
                               baseURL: URL(string: "https://screen.example/"))
        for _ in 0..<200 {
            if let frame = receiver.frame { return (browser, tab, frame) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("WebKit fixture did not load")
        throw NSError(domain: "ScreenPermissionTests", code: 1)
    }
}

@MainActor
private final class FrameReceiver: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
