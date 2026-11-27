import AppKit
import SwiftUI
import XCTest
@testable import Search

/// View › Hidden on This Site… (idea 1064): a row restored leaves the list at
/// once, and the panel opens away from where the hidden things sat.
@available(macOS 14, *)
@MainActor
final class HiddenPanelTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testRestoredRowLeavesTheListAtOnce() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.active?.restore(url: URL(string: "https://hidden-panel.example/")!, title: "x")
        let host = "hidden-panel.example"
        browser.curtain.restoreAll(on: host)
        defer { browser.curtain.restoreAll(on: host) }
        browser.curtain.hide(Veil(selector: "#one", label: "One", note: "300×80 · top right", date: Date()), on: host)
        browser.curtain.hide(Veil(selector: "#two", label: "Two", note: "300×80 · top right", date: Date()), on: host)
        browser.curtain.hide(Veil(selector: "#three", label: "Three", note: "300×80 · top left", date: Date()), on: host)

        // In a window never ordered in, as the panel is in one: SwiftUI
        // draws again only what has been told it changed.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 500, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: HiddenPanel(browser: browser))
        view.sizingOptions = [.intrinsicContentSize]
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        func height() -> CGFloat {
            view.layoutSubtreeIfNeeded()
            return view.intrinsicContentSize.height
        }
        // Settled first: the tab's page starting makes the browser publish,
        // which would redraw the panel and hide the bug.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let three = height()
        browser.restore(browser.hereVeils[0])
        // The change reaches SwiftUI on the next pass of the run loop, as it
        // would in the window.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let two = height()
        XCTAssertEqual(browser.hereVeils.count, 2)
        XCTAssertLessThan(two, three, "the row restored is gone from the list without reopening it")
    }

    func testOpensAwayFromWhereTheHiddenThingsSat() {
        func veil(_ note: String?) -> Veil { Veil(selector: UUID().uuidString, label: "x", note: note, date: Date()) }
        XCTAssertFalse(HiddenPanel.leading(for: []), "the right edge, as before")
        XCTAssertFalse(HiddenPanel.leading(for: [veil("10×10 · top left"), veil(nil)]))
        XCTAssertTrue(HiddenPanel.leading(for: [veil("10×10 · top right")]), "a thing on the right: the left edge")
        XCTAssertTrue(HiddenPanel.leading(for: [veil("1×1 · middle right"), veil("1×1 · bottom right"), veil("1×1 · top left")]))
        XCTAssertFalse(HiddenPanel.leading(for: [veil("1×1 · top centre")]))
    }

    func testDraggedStaysInTheWindow() {
        let room = CGSize(width: 1000, height: 700)
        let right = HiddenPanelPlace.Spot(leading: false, offset: .zero)
        XCTAssertEqual(HiddenPanelPlace.kept(right, moved: CGSize(width: -200, height: 100), in: room),
                       CGSize(width: -200, height: 100))
        XCTAssertEqual(HiddenPanelPlace.kept(right, moved: CGSize(width: 500, height: 0), in: room).width, 0,
                       "no further right than its corner")
        XCTAssertEqual(HiddenPanelPlace.kept(right, moved: CGSize(width: -5000, height: 0), in: room).width,
                       -(1000 - 380 - 28), "across to the left edge at most")
        let left = HiddenPanelPlace.Spot(leading: true, offset: CGSize(width: 50, height: 0))
        XCTAssertEqual(HiddenPanelPlace.kept(left, moved: CGSize(width: -500, height: 0), in: room).width, 0)
        XCTAssertLessThan(HiddenPanelPlace.kept(left, moved: CGSize(width: 0, height: 5000), in: room).height, 700,
                          "its title stays in the window")
    }
}
