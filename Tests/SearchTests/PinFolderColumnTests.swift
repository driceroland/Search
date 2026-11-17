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
        setenv("SEARCH_PROBE", "pin-folders-\(getpid())", 1)
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
        for window in windows { window.contentView = nil }
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
