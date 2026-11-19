import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class TabCaptureTests: XCTestCase {
    private var browser: Browser!
    private var windows: [NSWindow] = []
    private var activationPolicy: NSApplication.ActivationPolicy!
    private let permission = CapturePermission()

    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-capture-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    override func tearDown() {
        browser.forgetCaptureChoices()
        browser.closeAll()
        browser = nil
        for window in windows {
            if let web = window.contentView as? WKWebView {
                web.setCameraCaptureState(.none, completionHandler: nil)
                web.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
            window.close()
        }
        windows = []
        NSApp.setActivationPolicy(activationPolicy)
    }

    func testClosingTabEndsCaptureWithoutStoppingAnotherTab() async throws {
        let tab = try await capture()
        let other = try await capture()
        let web = tab.web
        let otherWeb = other.web
        browser.close(tab)
        try await ended(web)
        XCTAssertTrue(browser.tabs.contains { $0 === other })
        XCTAssertEqual(otherWeb.cameraCaptureState, .active)
        XCTAssertEqual(otherWeb.microphoneCaptureState, .active)
    }

    func testClosingLastTabEndsCaptureAndLeavesBlankTab() async throws {
        let tab = try await capture()
        let web = tab.web
        XCTAssertEqual(browser.tabs.count, 1)
        browser.close(tab)
        try await ended(web)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.tabs[0].isBlank)
    }

    func testClosingPinnedTabEndsCaptureAndKeepsPin() async throws {
        let tab = try await capture()
        tab.pin = "C"
        let web = tab.web
        browser.close(tab)
        try await ended(web)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        XCTAssertTrue(tab.asleep)
        XCTAssertEqual(tab.pin, "C")
    }

    func testClosingAllTabsEndsItsCapture() async throws {
        let tab = try await capture()
        let web = tab.web
        browser.closeAll()
        try await ended(web)
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testRefusingCameraStopsOnlyMatchingSiteAndDevice() async throws {
        let target = try await capture(shy: false, origin: "http://localhost")
        let other = try await capture(shy: false, origin: "http://localhost:8001")
        let privateTab = try await capture(shy: true, origin: "http://localhost")
        let web = target.web, otherWeb = other.web, privateWeb = privateTab.web
        let microphone = web.microphoneCaptureState
        let otherCamera = otherWeb.cameraCaptureState, otherMic = otherWeb.microphoneCaptureState
        let privateCamera = privateWeb.cameraCaptureState, privateMic = privateWeb.microphoneCaptureState
        XCTAssertNotEqual(web.cameraCaptureState, .none)
        XCTAssertNotEqual(otherCamera, .none)
        XCTAssertNotEqual(privateCamera, .none)
        browser.setSitePermission(false, kind: .camera, origin: "http://localhost")
        try await waitUntil("camera stops") { web.cameraCaptureState == .none }
        let videoState = try await web.evaluateJavaScript("window.captureStream.getVideoTracks()[0].readyState") as? String
        XCTAssertEqual(videoState, "ended")
        XCTAssertEqual(web.microphoneCaptureState, microphone)
        XCTAssertEqual(otherWeb.cameraCaptureState, otherCamera)
        XCTAssertEqual(otherWeb.microphoneCaptureState, otherMic)
        XCTAssertEqual(privateWeb.cameraCaptureState, privateCamera)
        XCTAssertEqual(privateWeb.microphoneCaptureState, privateMic)
    }

    func testRefusingMicrophoneStopsMatchingTabsAcrossWindows() async throws {
        let otherBrowser = Browser(record: WindowRecord())
        Browsers.register(otherBrowser)
        defer { otherBrowser.closeAll() }
        let first = try await capture(shy: false)
        let second = try await capture(shy: false, owner: otherBrowser)
        let firstWeb = first.web, secondWeb = second.web
        let firstCamera = firstWeb.cameraCaptureState, secondCamera = secondWeb.cameraCaptureState
        XCTAssertNotEqual(firstWeb.microphoneCaptureState, .none)
        XCTAssertNotEqual(secondWeb.microphoneCaptureState, .none)
        browser.setSitePermission(false, kind: .microphone, origin: "http://localhost")
        try await waitUntil("microphones stop") { firstWeb.microphoneCaptureState == .none && secondWeb.microphoneCaptureState == .none }
        for web in [firstWeb, secondWeb] {
            let audioState = try await web.evaluateJavaScript("window.captureStream.getAudioTracks()[0].readyState") as? String
            XCTAssertEqual(audioState, "ended")
        }
        XCTAssertEqual(firstWeb.cameraCaptureState, firstCamera)
        XCTAssertEqual(secondWeb.cameraCaptureState, secondCamera)
    }

    func testRefusingCombinedRequestStopsBothDevices() async throws {
        let target = try await capture(shy: false, origin: "http://localhost")
        let web = target.web
        browser.setSitePermission(false, kind: .cameraAndMicrophone, origin: "http://localhost")
        try await ended(web)
    }

    private func capture(shy: Bool = true, origin: String = "http://localhost", owner: Browser? = nil) async throws -> Tab {
        let configuration = Web.configuration(shy: shy)
        // Refuse to use real hardware if WebKit removes its mock-device seam.
        guard configuration.preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")) else {
            throw XCTSkip("WebKit mock capture devices are unavailable")
        }
        let tab = Tab(shy: shy, configuration: configuration)
        let targetBrowser = owner ?? browser!
        targetBrowser.prepare(tab)
        targetBrowser.insert(tab, at: targetBrowser.tabs.count)
        let web = tab.web
        web.uiDelegate = permission
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        XCTAssertFalse(Bench.onScreen(window))
        window.orderBack(nil)
        XCTAssertFalse(Bench.onScreen(window))
        windows.append(window)
        web.loadHTMLString("<title>Capture fixture</title>", baseURL: URL(string: origin))
        try await waitUntil("load") { web.title == "Capture fixture" && !web.isLoading }
        _ = try await web.evaluateJavaScript("""
            window.captureResult = 'pending';
            navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(stream => {
                window.captureStream = stream;
                window.captureResult = 'started';
            }, error => { window.captureResult = error.name; });
            void 0;
            """)
        try await waitUntil("capture starts") { web.cameraCaptureState == .active && web.microphoneCaptureState == .active }
        try await waitUntil("stream returned") { try await web.evaluateJavaScript("window.captureResult !== 'pending'") as? Bool == true }
        let result = try await web.evaluateJavaScript("window.captureResult") as? String
        XCTAssertEqual(result, "started")
        return tab
    }

    private func ended(_ web: WKWebView) async throws {
        // Retaining the old view makes teardown independent of deallocation.
        try await waitUntil("capture ends") { web.cameraCaptureState == .none && web.microphoneCaptureState == .none }
        let states = try await web.evaluateJavaScript("window.captureStream.getTracks().map(track => track.readyState)") as? [String]
        XCTAssertEqual(states?.sorted(), ["ended", "ended"])
    }

    private func waitUntil(_ description: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await condition() == false {
            guard Date() < deadline else {
                XCTFail("Timed out: \(description)")
                throw NSError(domain: "TabCaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebKit capture state"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class CapturePermission: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
