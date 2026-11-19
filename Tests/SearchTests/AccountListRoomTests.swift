import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Many accounts for one site (#1215): the list under a sign-in box is no
/// taller than the room under the box, or goes above it when there is more
/// room there, and scrolls. Drawn off screen, in no window.
@MainActor
final class AccountListRoomTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "bld-account-room-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() { _ = NSApplication.shared }

    private let page = CGSize(width: 800, height: 600)

    private func list(_ count: Int, at y: CGFloat) -> Browser.Suggesting {
        let logins = (0..<count).map { Kept(host: "example.com", user: "user\($0)@example.com") }
        var list = Browser.Suggesting(tab: UUID(), spot: CGRect(x: 40, y: y, width: 280, height: 30),
                                      logins: logins, host: "example.com", clear: false)
        list.shown = Date().addingTimeInterval(-1)
        return list
    }

    /// Where the card is drawn on a page of `page`'s size, and a picture of
    /// it when SEARCH_ACCOUNT_SHOTS names a folder.
    private func drawn(_ asked: Browser.Suggesting, name: String) -> CGRect {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        var card = CGRect.zero
        var view = AccountList(browser: browser, asked: asked)
        view.onFrame = { card = $0 }
        let host = NSHostingView(rootView: FromTopLeft(content: view).frame(width: page.width, height: page.height))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: page)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if let folder = ProcessInfo.processInfo.environment["SEARCH_ACCOUNT_SHOTS"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return card
    }

    func testPlacement() {
        let spot = CGRect(x: 40, y: 120, width: 280, height: 30)
        let under = AccountList.place(spot: spot, height: 600)
        XCTAssertFalse(under.up)
        XCTAssertEqual(under.room, 600 - 150 - 6 - AccountList.margin)
        let low = AccountList.place(spot: CGRect(x: 40, y: 520, width: 280, height: 30), height: 600)
        XCTAssertTrue(low.up, "little room under the box, more above: above")
        XCTAssertEqual(low.room, 520 - 6 - AccountList.margin)
        let tiny = AccountList.place(spot: CGRect(x: 0, y: 40, width: 200, height: 30), height: 120)
        XCTAssertEqual(tiny.room, AccountList.least, "never shorter than that")
    }

    func testAFewAccountsHugTheirRows() {
        let three = drawn(list(3, at: 120), name: "3")
        XCTAssertEqual(three.minY, 156, accuracy: 1, "just under the box")
        XCTAssertLessThan(three.height, 220, "as tall as three rows and the footer")
        XCTAssertGreaterThan(three.height, 100)
    }

    func testManyAccountsStopAtTheFootOfThePage() {
        let ten = drawn(list(10, at: 120), name: "10")
        let forty = drawn(list(40, at: 120), name: "40")
        XCTAssertEqual(ten.minY, 156, accuracy: 1)
        XCTAssertEqual(forty.minY, 156, accuracy: 1)
        XCTAssertLessThanOrEqual(ten.maxY, page.height - AccountList.margin + 1)
        XCTAssertLessThanOrEqual(forty.maxY, page.height - AccountList.margin + 1, "forty don't run off the page")
        XCTAssertGreaterThan(forty.height, 300, "they use the room there is")
    }

    func testABoxNearTheFootHasItsListAbove() {
        let low = drawn(list(40, at: 520), name: "40-low")
        XCTAssertLessThanOrEqual(low.maxY, 520 - 6 + 1, "above the box")
        XCTAssertGreaterThanOrEqual(low.minY, AccountList.margin - 1)
        let few = drawn(list(3, at: 520), name: "3-low")
        XCTAssertEqual(few.maxY, 514, accuracy: 1, "a short list sits right over the box")
    }

    func testTheSmallWindowsBarIsAllowedFor() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        var card = CGRect.zero
        var view = AccountList(browser: browser, asked: list(3, at: 120), top: 34)
        view.onFrame = { card = $0 }
        let host = NSHostingView(rootView: FromTopLeft(content: view).frame(width: page.width, height: page.height))
        host.frame = CGRect(origin: .zero, size: page)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(card.minY, 156 + 34, accuracy: 1)
    }

    /// ↓ past the foot of a long list scrolls it to the row lit. In a window
    /// that is never put on screen: a scroller scrolls only in one.
    func testALitRowIsScrolledTo() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        var asked = list(40, at: 120)
        func root() -> some View { FromTopLeft(content: AccountList(browser: browser, asked: asked)).frame(width: page.width, height: page.height) }
        let host = NSHostingView(rootView: root())
        host.frame = CGRect(origin: .zero, size: page)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func scrollers(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollers) }
        XCTAssertEqual(scrollers(host).first?.contentView.bounds.minY ?? -1, 0, accuracy: 1, "at the top to begin with")
        asked.lit = 37
        host.rootView = root()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertGreaterThan(scrollers(host).first?.contentView.bounds.minY ?? 0, 900, "scrolled down to row 37")
    }
}
