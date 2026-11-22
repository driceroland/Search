import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Folders in pinned rows in a real window's model: made, filled, nested,
/// folded, deleted, the row's order kept as drawn, and the column drawn off
/// screen reading the same lines back. The column is hosted in a window
/// that is never ordered in, as the bench's `column` draws it.
@MainActor
final class PinFolderColumnTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    /// The four tabs makeBrowser made, in order: a session left by the
    /// test before may have brought others back first.
    private var made: [Search.Tab] = []

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-folders-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        // Closed, not only emptied: ordered in far off the screens, a window
        // left open counts as shown, and later tests that check nothing was
        // shown (PopupGestureRelayTests, SidePanelPrivacyTests,
        // WebsitePopupTests) failed on it.
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            PinFolders.set(browser.spaceID, [], from: nil)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            Session.write(now: true, space: browser.spaceID, Session.Shape(tabs: [], active: 0))
        }
        made.removeAll()
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    func testFoldersKeepTheRowInTheOrderDrawn() throws {
        let browser = makeBrowser()
        let (one, two, three, four) = try pinned(browser)

        let work = try XCTUnwrap(browser.newPinFolder(named: "Work", holding: two, rename: false))
        XCTAssertTrue(browser.showsPinFolderRows)
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 0 one", "pin 0 three", "pin 0 four"])
        XCTAssertEqual(browser.listedPins.map(\.title), ["two", "one", "three", "four"], "saved order = drawn order")

        let docs = try XCTUnwrap(browser.newPinFolder(named: "Docs", in: work, rename: false))
        browser.movePin(four, into: docs)
        XCTAssertEqual(described(browser), ["folder 0 Work", "folder 1 Docs", "pin 2 four", "pin 1 two", "pin 0 one", "pin 0 three"])
        XCTAssertEqual(browser.listedPins.map(\.title), ["four", "two", "one", "three"])
        // pins.json has it too, in the same order, each with its folder.
        let saved = Pins.defs(browser.spaceID).filter { $0.listed == true }
        XCTAssertEqual(saved.map(\.title), ["four", "two", "one", "three"])
        XCTAssertEqual(saved.map(\.folder), [docs, work, nil, nil])

        // Let go beside a pin: in its folder, before it.
        browser.movePin(three, to: PinTree.Place(folder: work, anchor: two.id, after: false))
        XCTAssertEqual(described(browser), ["folder 0 Work", "folder 1 Docs", "pin 2 four", "pin 1 three", "pin 1 two", "pin 0 one"])

        browser.setPinFolderFolded(work, true)
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 0 one"])
        browser.setPinFolderFolded(work, false)

        // Three deep and no deeper.
        let third = try XCTUnwrap(browser.newPinFolder(named: "Third", in: docs, rename: false))
        XCTAssertNil(browser.newPinFolder(named: "Fourth", in: third, rename: false), "nothing four deep")

        // Delete: what it held goes up.
        browser.deletePinFolder(docs)
        XCTAssertEqual(four.pinFolder, work)
        XCTAssertEqual(browser.pinFolders.first { $0.id == third }?.parent, work)

        // A square is in no folder.
        browser.setListed(two, false)
        XCTAssertNil(two.pinFolder)
        _ = one
    }

    func testTheColumnDrawsTheFolders() async throws {
        let browser = makeBrowser()
        let (_, two, _, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newPinFolder(named: "Work", holding: two, rename: false))
        _ = browser.newPinFolder(named: "Inner", in: work, rename: false)
        SideBar.drawnPinLines = []
        let width = Double(browser.prefs.columnWidth)
        let host = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs).frame(width: width, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let drawn = SideBar.drawnPinLines.map { "\($0[0]) \($0[1]) \($0[2])" }
        XCTAssertEqual(drawn, ["folder 0 Work", "folder 1 Inner", "pin 1 two", "pin 0 one", "pin 0 three", "pin 0 four"])
        XCTAssertFalse(window.isVisible, "never ordered in")
    }

    /// A folder's row is a tab row's height, its
    /// title the size of a tab's.
    func testAFolderRowIsAsTallAsATabRow() async throws {
        let browser = makeBrowser()
        let (_, two, three, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newPinFolder(named: "Work", holding: two, rename: false))
        browser.movePin(three, into: work)
        SideBar.drawnPinFrames = [:]
        let width = Double(browser.prefs.columnWidth)
        let host = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs).frame(width: width, height: 360))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let folder = try XCTUnwrap(SideBar.drawnPinFrames[work])
        let pin = try XCTUnwrap(SideBar.drawnPinFrames[two.id])
        XCTAssertEqual(folder.height, browser.prefs.sideRow, "folder row")
        XCTAssertEqual(folder.height, pin.height, "folder row")
        if let out = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: picture)
            try picture.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("pin-folder-rows-normal.png"))
        }
        XCTAssertFalse(window.isVisible, "never ordered in")
    }

    /// A folder's heading dragged in the column itself: out of the folder
    /// holding it to the top, before another folder, then into one. Mouse
    /// events straight to a borderless window far off every screen, never
    /// activated.
    func testAFolderIsMovedByDraggingItsHeading() async throws {
        let browser = makeBrowser()
        let (one, two, _, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newPinFolder(named: "Work", holding: two, rename: false))
        let docs = try XCTUnwrap(browser.newPinFolder(named: "Docs", in: work, rename: false))
        _ = try XCTUnwrap(browser.newPinFolder(named: "Home", holding: one, rename: false))
        XCTAssertEqual(described(browser), ["folder 0 Work", "folder 1 Docs", "pin 1 two", "folder 0 Home", "pin 1 one",
                                            "pin 0 three", "pin 0 four"])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        // Ordered in far off every screen, as PinDragTests does: a window
        // never ordered in gets no drag. The app may not activate.
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        SideBar.drawnPinFrames = [:]
        try await Task.sleep(for: .milliseconds(300))
        // Where the rows' own space is in the window: the column's 10-point
        // inset, and the lines' tops as they were drawn.
        func line(_ id: UUID) throws -> CGRect { try XCTUnwrap(SideBar.drawnPinFrames[id]) }
        let row = browser.prefs.sideRow + 2
        let origin = try XCTUnwrap(SideBar.drawnPinTop)
        func at(_ y: CGFloat) -> NSPoint { NSPoint(x: 80, y: window.frame.height - (origin + y)) }

        // Docs, out of Work, over the pin "three" at the top: to the top.
        let docsAt = try line(docs).midY
        let threeAt = try line(three(browser)).midY
        try await drag(from: at(docsAt), through: [at(docsAt + row / 2), at(threeAt)], in: window)
        XCTAssertEqual(browser.pinFolders.first { $0.id == docs }?.parent ?? nil, nil, "out of Work")
        XCTAssertEqual(described(browser).filter { $0.hasPrefix("folder") }, ["folder 0 Work", "folder 0 Home", "folder 0 Docs"])

        // Docs again, to the top of Work's heading: before Work.
        try await Task.sleep(for: .milliseconds(300))
        let docsNow = try line(docs).midY
        let workTop = try line(work).minY + 3
        try await drag(from: at(docsNow), through: [at(docsNow - row / 2), at(workTop)], in: window)
        XCTAssertEqual(described(browser).filter { $0.hasPrefix("folder") }, ["folder 0 Docs", "folder 0 Work", "folder 0 Home"])

        // Home into Work, over the middle of its heading: nested.
        try await Task.sleep(for: .milliseconds(300))
        let homeAt = try line(browser.pinFolders.first { $0.name == "Home" }!.id).midY
        let workMid = try line(work).midY + 4
        try await drag(from: at(homeAt), through: [at(homeAt - row / 2), at(workMid)], in: window)
        XCTAssertEqual(browser.pinFolders.first { $0.name == "Home" }?.parent, work, "nested")
        XCTAssertFalse(window.isKeyWindow)
    }

    private func three(_ browser: Browser) -> UUID {
        browser.listedPins.first { $0.title == "three" }!.id
    }

    private func drag(from start: NSPoint, through points: [NSPoint], in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        for target in points {
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 12).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                try await send(.leftMouseDragged, at: NSPoint(x: last.x + (target.x - last.x) * f,
                                                            y: last.y + (target.y - last.y) * f), in: window)
            }
            last = target
        }
        try await Task.sleep(for: .milliseconds(120))
        try await send(.leftMouseUp, at: last, in: window)
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }

    func testWithTheSwitchOffTheRowsAreFlat() throws {
        let browser = makeBrowser()
        let (_, two, _, _) = try pinned(browser)
        let work = browser.newPinFolder(named: "Work", holding: two, rename: false)
        XCTAssertNotNil(work)
        browser.prefs.pinFolders = false
        XCTAssertFalse(browser.showsPinFolderRows)
        // Kept for the switch, as tab groups are.
        XCTAssertEqual(two.pinFolder, work)
        XCTAssertEqual(Pins.defs(browser.spaceID).first { $0.id == two.pinID }?.folder, work)
    }

    // MARK: - helpers

    private func described(_ browser: Browser) -> [String] {
        browser.pinRowLines().map { line in
            switch line {
            case .folder(let folder, let depth): "folder \(depth) \(folder.name)"
            case .pin(let tab, let depth): "pin \(depth) \(tab.title)"
            case .item(let item, _, let depth): "item \(depth) \(item.title)"
            }
        }
    }

    /// Four tabs pinned as rows, in order, and a tab in front after them.
    private func pinned(_ browser: Browser) throws -> (Search.Tab, Search.Tab, Search.Tab, Search.Tab) {
        let tabs = made
        XCTAssertEqual(tabs.count, 4)
        for tab in tabs { browser.pin(tab, listed: true) }
        browser.newTab()
        XCTAssertEqual(browser.listedPins.map(\.title), ["one", "two", "three", "four"])
        return (tabs[0], tabs[1], tabs[2], tabs[3])
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.pinFolders,
                        prefs.usesSpaces, prefs.sharesPins)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.pinFolders,
             prefs.usesSpaces, prefs.sharesPins) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.listsPins = true
        browser.prefs.pinFolders = true
        browser.prefs.sharesPins = false
        for word in ["one", "two", "three", "four"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(word).example/")!, title: word)
            if let last = browser.tabs.last { made.append(last) }
        }
        return browser
    }
}
