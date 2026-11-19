import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Settings › Downloads › Open Downloads: a tab unless asked for, and each
/// choice going where it says — the button closing what it opened, ⇧⌘J
/// only ever showing — and the floating card kept off the button. On the
/// model only: no window is ever shown.
@MainActor
final class DownloadsOpeningTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "downloads-opening-\(getpid())", 1)
        super.setUp()
    }

    private var saved: Any?

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        saved = Store.settings.object(forKey: "downloads.open")
    }

    override func tearDown() async throws {
        Store.settings.set(saved, forKey: "downloads.open")
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
    }

    func testATabUnlessAskedAndNothingWrittenForReadingIt() {
        Store.settings.removeObject(forKey: "downloads.open")
        XCTAssertEqual(Preferences().downloadsOpening, .tab)
        XCTAssertNil(Store.settings.object(forKey: "downloads.open"))

        Store.settings.set("panel", forKey: "downloads.open")
        XCTAssertEqual(Preferences().downloadsOpening, .panel)
        Store.settings.set("somewhere", forKey: "downloads.open")
        XCTAssertEqual(Preferences().downloadsOpening, .tab)
        // The Finder was a choice for a while: chosen then, a tab now.
        Store.settings.set("folder", forKey: "downloads.open")
        XCTAssertEqual(Preferences().downloadsOpening, .tab)
    }

    func testTheTab() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.downloadsOpening = .tab
        browser.showDownloads(toggles: true)
        XCTAssertTrue(browser.hoarding)
        XCTAssertFalse(browser.downloadsHanging)
        XCTAssertNil(browser.sidePanel)
    }

    func testUnderTheButton() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.downloadsOpening = .popover
        browser.showDownloads()
        XCTAssertTrue(browser.downloadsHanging)
        // ⇧⌘J again: still there.
        browser.showDownloads()
        XCTAssertTrue(browser.downloadsHanging)
        // The button: away.
        browser.showDownloads(toggles: true)
        XCTAssertFalse(browser.downloadsHanging)
        XCTAssertFalse(browser.hoarding)
    }

    func testTheSidePanel() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.downloadsOpening = .panel
        // Whatever was in the panel makes way.
        browser.sidePanel = .site(url: URL(string: "https://example.com/")!, space: browser.spaceID)
        browser.sidePanelShown = true
        browser.showDownloads()
        XCTAssertEqual(browser.sidePanel, .downloads)
        XCTAssertTrue(browser.sidePanelShown)
        browser.showDownloads()
        XCTAssertEqual(browser.sidePanel, .downloads)
        browser.showDownloads(toggles: true)
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertFalse(browser.hoarding)
    }

    /// The floating card, and its window with its margin, never lie over the
    /// downloads button: tabs across the top, the column on either side,
    /// with names or icons only, in a roomy window and a squeezed one.
    func testTheFloatingCardNeverLiesOverItsButton() {
        let windows = [NSRect(x: 0, y: 0, width: 1180, height: 780),
                       NSRect(x: 0, y: 0, width: 420, height: 260),
                       NSRect(x: 0, y: 0, width: 260, height: 180)]
        for frame in windows {
            let room = frame.insetBy(dx: Metrics.cardGap, dy: Metrics.cardGap)
            let door = NSSize(width: 26, height: 26)
            let places: [(String, Edge, NSRect)] = [
                ("the row across the top", .bottom,
                 NSRect(origin: NSPoint(x: frame.maxX - 60, y: frame.maxY - 34), size: door)),
                ("the column's foot, on the left", .trailing,
                 NSRect(origin: NSPoint(x: 150, y: 10), size: door)),
                ("the column's foot, on the right", .leading,
                 NSRect(origin: NSPoint(x: frame.maxX - 176, y: 10), size: door)),
                ("icons only, on the left", .trailing,
                 NSRect(origin: NSPoint(x: 9, y: 40), size: door)),
                ("icons only, on the right", .leading,
                 NSRect(origin: NSPoint(x: frame.maxX - 35, y: 40), size: door)),
            ]
            for (name, edge, button) in places {
                let spot = DownloadsFloat.layout(edge: edge, button: button, room: room, width: 380,
                                                 windowHeight: frame.height)
                let place = "\(name) in \(Int(frame.width))×\(Int(frame.height))"
                XCTAssertFalse(spot.card.intersects(button), "the card over the button: \(place)")
                XCTAssertFalse(spot.window.intersects(button), "its window over the button: \(place)")
                XCTAssertTrue(spot.window.contains(spot.card), place)
            }
        }
    }

    /// As tall as what it lists, up to half the window (idea 739): an empty
    /// list is a short card, not a quarter of the window of nothing.
    func testTheFloatingCardFollowsWhatItLists() {
        let frame = NSRect(x: 0, y: 0, width: 1180, height: 780)
        let button = NSRect(x: 1120, y: 746, width: 26, height: 26)
        func card(_ content: CGFloat?) -> NSRect {
            DownloadsFloat.layout(edge: .bottom, button: button, room: frame.insetBy(dx: 8, dy: 8), width: 380,
                                  windowHeight: 780, content: content).card
        }
        XCTAssertEqual(card(150).height, 150, "as tall as its list")
        XCTAssertEqual(card(149.2).height, 150, "whole points")
        XCTAssertEqual(card(900).height, 390, "half the window at most")
        XCTAssertEqual(card(nil).height, 390)
        XCTAssertEqual(card(40).height, 120, "never less than its title and a line")
        XCTAssertEqual(card(150).width, 380)
        XCTAssertEqual(card(150).maxX, button.maxX, "its right edge with the button's")
        XCTAssertEqual(card(150).maxY, button.minY - Metrics.cardGap, "hanging from under the button")
    }

    /// Its shadow and edge have room on every side, the button's too: with
    /// none there, the card beside the column was cut off flat on its left
    /// (idea 739). Its window reaches the button's edge, never over it.
    func testTheFloatingCardHasRoomOnTheButtonsSide() {
        let room = NSRect(x: 8, y: 8, width: 1164, height: 764)
        let button = NSRect(x: 150, y: 10, width: 26, height: 26)
        let spot = DownloadsFloat.layout(edge: .trailing, button: button, room: room, width: 380,
                                         windowHeight: 780, content: 200)
        XCTAssertGreaterThan(spot.card.minX, spot.window.minX, "room for its shadow on its left")
        XCTAssertEqual(spot.window.minX, button.maxX, "up to the button, not over it")
        XCTAssertEqual(spot.card.minY, button.minY, "level with the button's bottom")
        XCTAssertEqual(spot.card.height, 200)
    }

    /// The card's own height is what it holds: more downloads, a taller card.
    func testTheCardIsMeasuredByWhatItHolds() throws {
        let browser = Browser(record: WindowRecord())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("float-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); browser.loot.forgetAll() }
        browser.loot.forgetAll()
        let empty = DownloadsFloat.height(of: browser, width: 380)
        for index in 0..<3 {
            let file = folder.appendingPathComponent("file \(index).pdf")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            browser.loot.add(Keep(name: file.lastPathComponent, from: "example.com", path: file.path, date: Date()))
        }
        let three = DownloadsFloat.height(of: browser, width: 380)
        XCTAssertGreaterThan(empty, 60)
        XCTAssertLessThan(empty, 170, "an empty list is a short card")
        XCTAssertGreaterThan(three, empty + 150, "three downloads, three rows taller")
    }
}
