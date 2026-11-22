import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The downloads card stands by the button that can be seen. With Settings ›
/// Buttons at the top on, the column draws the doors at its foot as well as
/// up in the lights' row and hides whichever it isn't using; both buttons
/// heard the list being asked for, and the hidden one at the top won, so the
/// card hung from the column's top instead of its foot (#1350).
@MainActor
final class DownloadsAnchorTests: XCTestCase {
    private var window: NSWindow?
    private var browser: Browser?
    private var restore: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        browser?.downloadsHanging = false
        window?.contentView = nil
        window?.close()
        browser?.closeAll()
        restore?()
        window = nil
        browser = nil
        try await settle()
        try await super.tearDown()
    }

    func testCardStandsByTheFootWhenTheDoorsHaveNoRoomUp() async throws {
        let panel = try await hang(columnWidth: 250)
        let column = try XCTUnwrap(window)
        XCTAssertLessThan(panel.frame.midY, column.frame.midY,
                          "the doors are at the foot: the card hangs beside them, not from the top")
    }

    func testCardHangsFromTheDoorsUpWhenTheyFit() async throws {
        let panel = try await hang(columnWidth: 420)
        let column = try XCTUnwrap(window)
        XCTAssertGreaterThan(panel.frame.midY, column.frame.midY,
                             "the doors are up in the lights' row: the card hangs from them")
    }

    private func hang(columnWidth: CGFloat) async throws -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let before = (prefs.sidebar, prefs.doorsUp, prefs.alwaysShowsDownloads, prefs.downloadsOpening, prefs.sideWidth)
        restore = {
            (prefs.sidebar, prefs.doorsUp, prefs.alwaysShowsDownloads, prefs.downloadsOpening, prefs.sideWidth) = before
        }
        let browser = Browser(record: WindowRecord())
        self.browser = browser
        browser.prefs.sidebar = true
        browser.prefs.doorsUp = true
        browser.prefs.alwaysShowsDownloads = true
        browser.prefs.downloadsOpening = .popover
        browser.prefs.sideWidth = columnWidth
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: columnWidth, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        self.window = window
        try await settle()
        browser.showDownloads()
        try await settle()
        return try XCTUnwrap(window.childWindows?.first, "the card must be showing")
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }
}
