import AppKit
import XCTest
@testable import Search

@MainActor
final class LittleWindowFrameTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "little-window-frame-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func preview(for browser: Browser) throws -> (LittleWindow, NSWindow) {
        LittleWindow.show(try XCTUnwrap(URL(string: "about:blank")), for: browser, front: false)
        let little = try XCTUnwrap(LittleWindow.all.last)
        let window = try XCTUnwrap(NSApp.window(withWindowNumber: little.windowNumber))
        return (little, window)
    }

    func testPreviewRemembersItsSizeAndPositionAfterClosing() throws {
        let saved = Store.settings.object(forKey: "little.frame")
        defer { Store.settings.set(saved, forKey: "little.frame") }
        Store.settings.removeObject(forKey: "little.frame")
        let browser = Browser(record: WindowRecord())
        let (first, window) = try preview(for: browser)
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let wanted = NSRect(x: screen.minX + 40, y: screen.minY + 50, width: 620, height: 460)
        window.setFrame(wanted, display: false)
        first.close()

        let (second, reopened) = try preview(for: browser)
        defer { second.close() }
        XCTAssertEqual(reopened.frame, wanted)
    }

    func testPreviewRestoresSavedFrameAndRejectsAnUnavailableScreen() throws {
        let saved = Store.settings.object(forKey: "little.frame")
        defer { Store.settings.set(saved, forKey: "little.frame") }
        let browser = Browser(record: WindowRecord())
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let wanted = NSRect(x: screen.minX + 60, y: screen.minY + 70, width: 650, height: 480)
        Store.settings.set(NSStringFromRect(wanted), forKey: "little.frame")
        let (first, restored) = try preview(for: browser)
        XCTAssertEqual(restored.frame, wanted)
        first.close()

        for frame in [NSRect(x: -30000, y: -30000, width: 650, height: 480),
                      NSRect(x: 60, y: 70, width: 10, height: 10)] {
            Store.settings.set(NSStringFromRect(frame), forKey: "little.frame")
            let (little, window) = try preview(for: browser)
            XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 640))
            XCTAssertTrue(screen.intersects(window.frame))
            little.close()
        }
    }

    func testPreviewSavesResizeBeforeItCloses() throws {
        let saved = Store.settings.object(forKey: "little.frame")
        defer { Store.settings.set(saved, forKey: "little.frame") }
        let browser = Browser(record: WindowRecord())
        let (little, window) = try preview(for: browser)
        defer { little.close() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let wanted = NSRect(x: screen.minX + 80, y: screen.minY + 90, width: 700, height: 500)
        window.setFrame(wanted, display: false)
        little.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        XCTAssertEqual(Store.settings.string(forKey: "little.frame"), NSStringFromRect(wanted))
        let (second, reopened) = try preview(for: browser)
        defer { second.close() }
        XCTAssertEqual(reopened.frame, wanted)
    }
}
