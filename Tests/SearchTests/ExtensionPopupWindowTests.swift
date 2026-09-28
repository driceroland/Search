import AppKit
import WebKit
import XCTest
@testable import Search

/// An extension's popup window (windows.create with type "popup"), made but
/// never ordered on screen by the lifecycle test.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPopupWindowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "popup-windows-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() async throws {
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        XCTAssertFalse(NSApp.isActive)
    }

    func testPopupsAreNeverWrittenDown() {
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let popup = Browser(record: WindowRecord())
        popup.extensionPopup = "some-extension"
        Browsers.register(first)
        Browsers.register(popup)
        Browsers.register(second)
        XCTAssertTrue(Browsers.saved.contains { $0 === first })
        XCTAssertTrue(Browsers.saved.contains { $0 === second })
        XCTAssertFalse(Browsers.saved.contains { $0 === popup })
    }

    func testExtensionsSeeAPopupAsOne() async throws {
        let popup = Browser(record: WindowRecord())
        popup.extensionPopup = "some-extension"
        let plain = Browser(record: WindowRecord())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: Self.extensionFolder()))
        XCTAssertEqual(ExtensionWindow(owner: Extensions.shared, browser: popup).windowType(for: context), .popup)
        XCTAssertEqual(ExtensionWindow(owner: Extensions.shared, browser: plain).windowType(for: context), .normal)
    }

    func testAPopupWithASizeButNoPlaceIsCentred() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let sized = try XCTUnwrap(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: 800, height: 850), on: screen))
        XCTAssertEqual(sized, CGRect(x: 320, y: 25, width: 800, height: 850))
        let tall = try XCTUnwrap(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: 400, height: 2000), on: screen))
        XCTAssertEqual(tall.height, 900, "a popup taller than the screen is kept on it")
        XCTAssertNil(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: CGFloat.nan, height: .nan), on: screen))
        XCTAssertNil(Extensions.popupFrame(asked: CGRect(x: 0, y: 0, width: 50, height: 50), on: screen))
    }

    func testCreatedPopupHasAFrameFocusAndCloseLifecycleWithoutBeingShown() async throws {
        let originalFront = Front.shared.browser
        let originalSpace = Spaces.current
        let background = originalFront ?? Browser(record: WindowRecord())
        Browsers.register(background)
        Front.shared.set(background)
        Browsers.watchFrames()

        let popup = Browser(record: WindowRecord())
        popup.extensionPopup = "some-extension"
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let asked = CGRect(x: screen.midX - 240, y: screen.midY - 300, width: 480, height: 600)
        Browsers.open(popup, frame: asked, shouldBeFocused: false, present: false)
        let window = try XCTUnwrap(popup.window)
        let createdFrame = window.frame
        let extensionWindow = ExtensionWindow(owner: Extensions.shared, browser: popup)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: Self.extensionFolder()))

        defer {
            window.orderOut(nil)
            window.close()
            Front.shared.set(originalFront)
            Spaces.current = originalSpace
        }

        XCTAssertFalse(window.isVisible, "the popup test must not present a window")
        XCTAssertFalse(NSApp.isActive)
        XCTAssertTrue(Browsers.all.contains { $0 === popup })
        XCTAssertTrue(Browsers.browser(for: window) === popup)
        XCTAssertEqual(extensionWindow.frame(for: context), createdFrame)
        XCTAssertTrue(Front.shared.browser === background, "an unfocused popup must not take the current browser")
        let focused = Extensions.shared.webExtensionController(
            Extensions.shared.controller, focusedWindowFor: context)
        XCTAssertTrue(focused as? ExtensionWindow === Extensions.shared.window(of: background),
                      "WebKit must retain the previously focused window after didOpenWindow")

        try await extensionWindow.setFrame(CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 540, height: CGFloat.nan), for: context)
        XCTAssertEqual(window.frame.width, 540)
        XCTAssertEqual(window.frame.height, createdFrame.height)
        try await extensionWindow.setFrame(CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: 640), for: context)
        XCTAssertEqual(window.frame.width, 540)
        XCTAssertEqual(window.frame.height, 640)
        let positioned = CGPoint(x: screen.minX + 60, y: screen.minY + 60)
        try await extensionWindow.setFrame(CGRect(x: positioned.x, y: positioned.y, width: CGFloat.nan, height: CGFloat.nan), for: context)
        XCTAssertEqual(window.frame.origin.x, positioned.x)
        XCTAssertEqual(window.frame.origin.y, positioned.y)
        XCTAssertEqual(window.frame.width, 540)
        XCTAssertEqual(window.frame.height, 640)
        XCTAssertFalse(window.isVisible)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(Front.shared.browser === popup, "popup key changes must update the browser in front")

        try await extensionWindow.close(for: context)
        XCTAssertFalse(Browsers.all.contains { $0 === popup }, "closing a popup must retire its browser and detach its extension window")
        XCTAssertFalse(Browsers.browser(for: window) === popup)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(NSApp.isActive)
    }

    private static func extensionFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Popup test", "version": "1.0"}"#.write(
            to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return folder
    }
}
