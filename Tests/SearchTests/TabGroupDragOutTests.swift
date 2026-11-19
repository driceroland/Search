import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A tab carried out of its group and let go among the tabs in none leaves
/// the group and lands there (#1009). Where it lands is worked out from the
/// drawn rows (GroupDropFrames.leaving), the move itself is the browser's
/// (Browser.move(_:outOfGroupBefore:)), and a hand carries one out of a
/// group in the column and across the top, hosted as RowCarryTests does, in
/// a borderless window far off every screen. Icons only goes through the
/// same rows and the same drop (SideBar.groupRows), and is not carried by
/// hand here.
@MainActor
final class TabGroupDragOutTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "group-drag-out-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("group-drag-out-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        TabDrag.testPointer = nil
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - where it lands

    func testWhereATabLetGoOutsideItsGroupLands() {
        let group = TabGroup(id: UUID(), name: "Group", collapsed: false)
        let other = TabGroup(id: UUID(), name: "Other", collapsed: false)
        let first = UUID(), source = UUID(), elsewhere = UUID(), looseA = UUID(), looseB = UUID()
        for vertical in [false, true] {
            let rect: (CGFloat, CGFloat) -> CGRect = { start, length in
                vertical ? CGRect(x: 10, y: start, width: 80, height: length)
                    : CGRect(x: start, y: 10, width: length, height: 80)
            }
            let point: (CGFloat) -> CGPoint = { position in
                vertical ? CGPoint(x: 30, y: position) : CGPoint(x: position, y: 30)
            }
            // Group 0–90, Other 100–150, then two tabs in no group.
            let frames = [
                group.id: GroupDropFrame(group: group.id, rect: rect(0, 20)),
                first: GroupDropFrame(group: group.id, tab: first, rect: rect(30, 30)),
                source: GroupDropFrame(group: group.id, tab: source, rect: rect(60, 30)),
                other.id: GroupDropFrame(group: other.id, rect: rect(100, 20)),
                elsewhere: GroupDropFrame(group: other.id, tab: elsewhere, rect: rect(120, 30)),
            ]
            let loose = [looseA: rect(160, 30), looseB: rect(200, 30)]
            let leaving: (CGPoint, UUID) -> LooseDrop? = { point, tab in
                GroupDropFrames.leaving(point, frames: frames, loose: loose, groups: [group, other],
                                        source: tab, vertical: vertical)
            }
            XCTAssertNil(leaving(point(75), source), "on its own place: it stays")
            XCTAssertNil(leaving(point(5), source), "along its own group's run: it stays")
            XCTAssertNil(leaving(point(130), source), "level with another group: that group's to take")
            XCTAssertEqual(leaving(point(170), source), LooseDrop(before: looseA), "before the first in no group")
            XCTAssertEqual(leaving(point(195), source), LooseDrop(before: looseB), "between the two")
            XCTAssertEqual(leaving(point(260), source), LooseDrop(before: nil), "past them all: after the last")
            XCTAssertEqual(leaving(point(95), source), LooseDrop(before: looseA), "between the groups: the first in no group")
            XCTAssertNil(leaving(point(170), looseA), "a tab in no group leaves nothing")
            let aside = vertical ? CGPoint(x: 400, y: 170) : CGPoint(x: 170, y: 400)
            XCTAssertNil(leaving(aside, source), "off to the side of the row: not a place in it")
            XCTAssertEqual(GroupDropFrames.leaving(point(260), frames: frames, loose: [:], groups: [group, other],
                                                   source: source, vertical: vertical),
                           LooseDrop(before: nil), "no tab in no group: at the end")
        }
    }

    // MARK: - the move

    func testTheMoveOutOfAGroup() throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.move(t[1], toGroup: group)
        browser.move(t[2], toGroup: group)
        // Group: one two three. In none: four five.
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id))

        browser.move(t[1], outOfGroupBefore: t[4].id)
        XCTAssertNil(browser.group(of: t[1]), "out of the group")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[2], t[3], t[1], t[4]].map(\.id), "in front of five")

        browser.move(t[2], outOfGroupBefore: nil)
        XCTAssertEqual(browser.tabs.last?.id, t[2].id, "after the last")

        // In no group already: nothing moves.
        let order = browser.tabs.map(\.id)
        browser.move(t[3], outOfGroupBefore: t[1].id)
        XCTAssertEqual(browser.tabs.map(\.id), order)

        // The last tab out takes the group with it, as Remove from Group does.
        browser.move(t[0], outOfGroupBefore: t[3].id)
        XCTAssertFalse(browser.tabGroups.contains { $0.id == group }, "the empty group goes")
        XCTAssertEqual(browser.tabs.first?.id, t[0].id)
    }

    func testWhatGoesWithItGoesOutToo() throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        for tab in t[1...3] { browser.move(tab, toGroup: group) }
        // A pair leaves whole and stays a pair.
        browser.pair(t[2], with: t[1], onLeft: false)
        XCTAssertNotNil(browser.split(for: t[1]))
        browser.move(t[1], outOfGroupBefore: nil)
        XCTAssertNil(browser.group(of: t[1]))
        XCTAssertNil(browser.group(of: t[2]))
        XCTAssertNotNil(browser.split(for: t[1]), "still a pair")
        XCTAssertEqual(Array(browser.tabs.suffix(2)).map(\.id), [t[1], t[2]].map(\.id))

        // Tabs picked together leave together.
        browser.select(t[0])
        browser.extendTabSelection(to: t[3], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([t[0].id, t[3].id]))
        browser.move(t[0], outOfGroupBefore: t[4].id)
        XCTAssertNil(browser.group(of: t[0]))
        XCTAssertNil(browser.group(of: t[3]))
        XCTAssertFalse(browser.tabGroups.contains { $0.id == group }, "nothing left in it")
    }

    func testNothingWithGroupsOff() {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.prefs.usesTabGroups = false
        browser.move(t[0], outOfGroupBefore: nil)
        XCTAssertEqual(t[0].groupID, group, "asleep with groups off, not taken out")
    }

    // MARK: - by hand

    func testCarriedOutOfItsGroupDownTheColumn() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.move(t[1], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = makeWindow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        // Down the rows from their top: the heading 0–28, one 30–58, two
        // 60–88, then three, four, five and New tab; empty from about 190.
        let grab: CGFloat = 44

        // A hand that barely moves leaves it where it was.
        try await carry(from: grab, to: grab + 8, in: window)
        XCTAssertEqual(browser.group(of: t[0]), group, "stayed in its group")

        // Down past everything, into the column's empty foot.
        try await carry(from: grab, to: 250, in: window)
        XCTAssertNil(browser.group(of: t[0]), "out of its group")
        XCTAssertEqual(browser.tabs.last?.id, t[0].id, "after the last tab in no group")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[1].id], "the other stays")
    }

    func testCarriedOutOfItsGroupAlongTheTop() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.move(t[1], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = try makeTopRow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let y = Metrics.strip / 2
        // The heading at about 100, one from 160 to 300, then two, three,
        // four, and five ending near 930, before the buttons.
        let x: CGFloat = 210
        let end: CGFloat = 945
        try await send(.leftMouseDown, at: NSPoint(x: x, y: y), in: window)
        for step in stride(from: x + 4, through: end, by: 4) {
            try await send(.leftMouseDragged, at: NSPoint(x: step, y: y), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: end, y: y), in: window)
        try await settle()
        XCTAssertNil(browser.group(of: t[0]), "out of its group")
        XCTAssertEqual(browser.tabs.last?.id, t[0].id, "after the last tab in no group")
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs, prefs.sideIcons)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs, prefs.sideIcons) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = true
        browser.prefs.splitView = true
        browser.prefs.listsPins = false
        browser.prefs.roomyTabs = false
        browser.prefs.sideIcons = false
        for word in ["one", "two", "three", "four", "five"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    private func makeTopRow(_ browser: Browser) throws -> NSWindow {
        browser.prefs.sidebar = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func point(y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - y)
    }

    private func carry(from: CGFloat, to: CGFloat, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: point(y: from, in: window), in: window)
        for y in stride(from: from + 2, through: to, by: 2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: point(y: to, in: window), in: window)
        try await settle()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
