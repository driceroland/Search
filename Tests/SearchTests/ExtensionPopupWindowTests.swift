import AppKit
import WebKit
import XCTest
@testable import Search

/// An extension's popup window (windows.create with type "popup"), on the
/// model only: no window is ever made here.
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

    private static func extensionFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Popup test", "version": "1.0"}"#.write(
            to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return folder
    }
}
