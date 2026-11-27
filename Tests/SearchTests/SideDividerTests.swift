import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Idea 1255: the bookmarks bar in the column and a pin kept as a square
/// drew two lines one under the other: the bookmarks' own and the keep line
/// (KeepLine), with nothing between them. One line between two sections,
/// whatever is shown. The column is drawn into a bitmap from an
/// NSHostingView that is never put in a window, and its thin full-width
/// lines counted. SEARCH_DIVIDER_PNG=<folder> keeps the pictures.
@available(macOS 14, *)
@MainActor
final class SideDividerTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restorePreferences: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for browser in browsers {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        browsers.removeAll()
        try await super.tearDown()
    }

    func testEveryCombinationDrawsOneLineBetweenSections() async throws {
        // (bookmarks, squares, rows, groups) → lines expected, top to bottom:
        // the bookmarks' or the keep line under what is kept, never both
        // back to back.
        struct Case { let marks: Bool, squares: Int, rows: Int, groups: Bool, folder: Bool, lines: Int }
        let cases = [
            Case(marks: false, squares: 0, rows: 0, groups: false, folder: false, lines: 0),
            Case(marks: true, squares: 0, rows: 0, groups: false, folder: false, lines: 1),
            Case(marks: false, squares: 1, rows: 0, groups: false, folder: false, lines: 1),
            Case(marks: true, squares: 1, rows: 0, groups: false, folder: false, lines: 1), // the report
            Case(marks: true, squares: 2, rows: 0, groups: false, folder: false, lines: 1),
            Case(marks: false, squares: 0, rows: 1, groups: false, folder: false, lines: 1),
            Case(marks: true, squares: 0, rows: 1, groups: false, folder: false, lines: 2),
            Case(marks: true, squares: 1, rows: 1, groups: false, folder: false, lines: 2),
            Case(marks: true, squares: 1, rows: 0, groups: true, folder: false, lines: 2),
            Case(marks: true, squares: 1, rows: 0, groups: false, folder: true, lines: 2),
            Case(marks: true, squares: 0, rows: 0, groups: false, folder: true, lines: 1),
        ]
        for c in cases {
            let name = "marks\(c.marks ? 1 : 0)-sq\(c.squares)-rows\(c.rows)-groups\(c.groups ? 1 : 0)-folder\(c.folder ? 1 : 0)"
            let found = try await lines(marks: c.marks, squares: c.squares, rows: c.rows, groups: c.groups, folder: c.folder, name: name)
            XCTAssertEqual(found.count, c.lines, "\(name): lines at \(found)")
            for (a, b) in zip(found, found.dropFirst()) {
                XCTAssertGreaterThan(b - a, 20, "\(name): two lines back to back at \(a) and \(b)")
            }
        }
    }

    // MARK: -

    /// The y of each thin line across the column, top down.
    private func lines(marks: Bool, squares: Int, rows: Int, groups: Bool, folder: Bool, name: String) async throws -> [Int] {
        let browser = makeBrowser(marks: marks, groups: groups, folder: folder)
        let tabs = browser.tabs
        for tab in tabs.prefix(squares) { browser.pin(tab) }
        for tab in tabs.dropFirst(squares).prefix(rows) { browser.pin(tab, listed: true) }
        if groups { _ = browser.addTabGroup(containing: tabs[4]) }
        if folder { _ = browser.newPinFolder(rename: false) }
        browser.select(tabs[5])
        let width = browser.prefs.columnWidth
        let host = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["SEARCH_DIVIDER_PNG"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        defer {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            for group in browser.tabGroups { browser.removeTabGroup(group.id) }
            for folder in browser.pinFolders { browser.deletePinFolder(folder.id) }
            for root in browser.bookmarks.roots { browser.bookmarks.remove(root.id) }
        }
        return Self.thinLines(rep)
    }

    /// Runs of at most two rows of pixels where almost the whole width,
    /// inset from either side, is one colour unlike the margin's: a line,
    /// not a row's fill, which is a row tall.
    static func thinLines(_ rep: NSBitmapImageRep) -> [Int] {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let scale = CGFloat(w) / rep.size.width
        func px(_ x: Int, _ y: Int) -> [CGFloat] {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
            return [c.redComponent * c.alphaComponent, c.greenComponent * c.alphaComponent,
                    c.blueComponent * c.alphaComponent, c.alphaComponent]
        }
        let from = Int(24 * scale), to = w - Int(24 * scale)
        var lineRows: [Bool] = []
        for y in 0..<h {
            let margin = px(Int(3 * scale), y)
            let first = px(from, y)
            var off = 0, same = 0, total = 0
            for x in stride(from: from, to: to, by: 2) {
                let p = px(x, y)
                total += 1
                if zip(p, margin).contains(where: { abs($0 - $1) > 0.012 }) { off += 1 }
                if !zip(p, first).contains(where: { abs($0 - $1) > 0.02 }) { same += 1 }
            }
            lineRows.append(off * 10 >= total * 9 && same * 10 >= total * 9)
        }
        var out: [Int] = []
        var y = 0
        while y < h {
            guard lineRows[y] else { y += 1; continue }
            var end = y
            while end + 1 < h, lineRows[end + 1] { end += 1 }
            if end - y + 1 <= Int(2 * scale) { out.append(Int(CGFloat(y) / scale)) }
            y = end + 1
        }
        return out
    }

    private func makeBrowser(marks: Bool, groups: Bool, folder: Bool) -> Browser {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.sideIcons, prefs.sidePosition, prefs.usesTabGroups, prefs.listsPins, prefs.usesSpaces,
                        prefs.sharesPins, prefs.bookmarksBar, prefs.bookmarksInSidebar, prefs.pinFolders)
        restorePreferences = {
            (prefs.sidebar, prefs.sideIcons, prefs.sidePosition, prefs.usesTabGroups, prefs.listsPins, prefs.usesSpaces,
             prefs.sharesPins, prefs.bookmarksBar, prefs.bookmarksInSidebar, prefs.pinFolders) = previous
        }
        Disk.drain()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Store.folder.path)) ?? []
        where name.hasPrefix("session") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name))
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.tabsLayout = .left
        browser.prefs.usesTabGroups = groups
        browser.prefs.listsPins = true
        browser.prefs.pinFolders = folder
        browser.prefs.sharesPins = false
        browser.prefs.bookmarksBar = marks
        browser.prefs.bookmarksInSidebar = marks
        if marks {
            browser.bookmarks.add(URL(string: "https://example.com/mark")!, title: "Mark")
        }
        for word in ["one", "two", "three", "four", "five", "six", "seven"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.com/\(word)")!, title: word)
        }
        return browser
    }
}
