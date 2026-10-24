import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class TabShortcutHintTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-shortcut-hints-\(getpid())", 1)
        super.setUp()
    }

    func testDefaultAndPersistence() {
        let saved = Store.settings.object(forKey: "tabs.shortcuts")
        defer { Store.settings.set(saved, forKey: "tabs.shortcuts") }
        Store.settings.removeObject(forKey: "tabs.shortcuts")
        XCTAssertFalse(Preferences().showsTabShortcuts)
        let prefs = Preferences()
        prefs.showsTabShortcuts = true
        XCTAssertTrue(Preferences().showsTabShortcuts)
    }

    func testNumbersFollowVisibleTabsIncludingPinsGroupsAndSplits() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.showsTabShortcuts, prefs.usesTabGroups, prefs.splitView)
        defer {
            browser.closeAll()
            prefs.showsTabShortcuts = saved.0
            prefs.usesTabGroups = saved.1
            prefs.splitView = saved.2
        }
        prefs.showsTabShortcuts = true
        prefs.usesTabGroups = false
        browser.commandHeld = true
        for count in 1...11 {
            if count > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(count)")!, title: "Tab \(count)")
            assertNumbers(browser)
        }
        let pinned = browser.tabs[3]
        browser.pin(pinned)
        defer { browser.unpin(pinned) }
        prefs.splitView = true
        let left = browser.tabs[5], right = browser.tabs[6]
        browser.pair(right, with: left, onLeft: false)
        XCTAssertNil(browser.tabShortcutNumbers[right.id])
        assertNumbers(browser)
        prefs.usesTabGroups = true
        let grouped = browser.tabs.filter { $0.pin == nil && $0.id != left.id && $0.id != right.id }.prefix(2)
        let group = browser.addTabGroup(containing: grouped.first!)
        browser.move(grouped.last!, toGroup: group)
        browser.select(browser.tabs.last!)
        browser.toggleTabGroup(group)
        for tab in grouped { XCTAssertNil(browser.tabShortcutNumbers[tab.id]) }
        assertNumbers(browser)
        browser.move(browser.tabs.last!, to: 1)
        assertNumbers(browser)
        browser.commandHeld = false
        XCTAssertTrue(browser.tabShortcutNumbers.isEmpty)
        browser.commandHeld = true
        prefs.showsTabShortcuts = false
        XCTAssertTrue(browser.tabShortcutNumbers.isEmpty)
    }

    func testCommandEventsAndFocusLoss() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.showsTabShortcuts, prefs.sidebar, prefs.usesTabGroups, prefs.splitView)
        prefs.showsTabShortcuts = true
        prefs.sidebar = true
        prefs.usesTabGroups = false
        prefs.splitView = true
        for number in 1...11 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        window.orderFrontRegardless()
        let previousFront = Front.shared.browser
        Front.shared.set(browser)
        defer {
            Front.shared.set(previousFront)
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
            browser.closeAll()
            prefs.showsTabShortcuts = saved.0
            prefs.sidebar = saved.1
            prefs.usesTabGroups = saved.2
            prefs.splitView = saved.3
        }
        try await settle()
        try await flags(.command, in: window)
        XCTAssertTrue(browser.commandHeld)
        XCTAssertEqual(browser.tabShortcutNumbers.count, 9)
        for number in [2, 9] {
            let hinted = try XCTUnwrap(browser.tabShortcutNumbers.first { $0.value == number }?.key)
            try press(number, browser: browser, window: window)
            XCTAssertEqual(browser.activeID, hinted, "The physical shortcut must select its hinted tab")
        }
        let tabs = browser.tabs
        browser.pin(tabs[4])
        defer { browser.unpin(tabs[4]) }
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        prefs.usesTabGroups = true
        let splitGroup = browser.addTabGroup(containing: tabs[0])
        let group = browser.addTabGroup(containing: tabs[2])
        browser.move(tabs[3], toGroup: group)
        XCTAssertNil(browser.tabShortcutNumbers[splitGroup], "An expanded heading has no number")
        XCTAssertNil(browser.tabShortcutNumbers[group])
        XCTAssertNotNil(browser.tabShortcutNumbers[tabs[2].id])
        XCTAssertNotNil(browser.tabShortcutNumbers[tabs[3].id])
        XCTAssertNil(browser.tabShortcutNumbers[tabs[1].id], "A split counts once")
        try press(try XCTUnwrap(browser.tabShortcutNumbers[tabs[3].id]), browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[3].id)
        browser.select(tabs[1])
        browser.select(tabs.last!)
        browser.toggleTabGroup(splitGroup)
        browser.toggleTabGroup(group)
        tabs[2].touch(at: Date(timeIntervalSinceNow: -100))
        tabs[3].touch(at: Date(timeIntervalSinceNow: -10))
        XCTAssertNotNil(browser.tabShortcutNumbers[splitGroup])
        XCTAssertNotNil(browser.tabShortcutNumbers[group])
        for tab in tabs.prefix(4) { XCTAssertNil(browser.tabShortcutNumbers[tab.id]) }
        try press(1, browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[4].id, "Pins keep their place before the groups")
        browser.moveTabGroup(group, to: 0)
        XCTAssertEqual(browser.tabShortcutNumbers[group], 2)
        try press(2, browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[3].id, "A folded group selects its most recently used page")
        XCTAssertTrue(browser.tabGroups.first { $0.id == group }?.collapsed == true)
        XCTAssertNil(browser.tabShortcutNumbers[tabs[3].id], "The active member has no duplicate number")
        tabs[2].touch(at: Date(timeIntervalSinceNow: 10))
        try press(try XCTUnwrap(browser.tabShortcutNumbers[group]), browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[3].id, "An active folded group keeps its current page")
        try press(try XCTUnwrap(browser.tabShortcutNumbers[splitGroup]), browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[1].id, "A folded split restores its focused page")
        XCTAssertTrue(browser.tabGroups.first { $0.id == splitGroup }?.collapsed == true)
        XCTAssertNil(browser.tabShortcutNumbers[tabs[0].id])
        XCTAssertNil(browser.tabShortcutNumbers[tabs[1].id])
        try press(9, browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs.last?.id, "Command 9 counts folded groups as one target")
        browser.toggleTabGroup(group)
        XCTAssertNil(browser.tabShortcutNumbers[group])
        XCTAssertNotNil(browser.tabShortcutNumbers[tabs[2].id])
        try press(try XCTUnwrap(browser.tabShortcutNumbers[tabs[2].id]), browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs[2].id)
        XCTAssertFalse(browser.tabGroups.first { $0.id == group }?.collapsed == true)
        assertNumbers(browser)
        for tab in browser.tabs where tab.pin == nil && browser.group(of: tab) == nil {
            browser.move(tab, toGroup: splitGroup)
        }
        browser.toggleTabGroup(splitGroup)
        tabs.last?.touch(at: Date(timeIntervalSinceNow: 20))
        XCTAssertEqual(browser.tabShortcutTargets.last?.id, splitGroup)
        try press(9, browser: browser, window: window)
        XCTAssertEqual(browser.activeID, tabs.last?.id, "Command 9 can select a folded heading at the end")
        XCTAssertTrue(browser.tabGroups.first { $0.id == splitGroup }?.collapsed == true)
        try await flags([], in: window)
        XCTAssertFalse(browser.commandHeld)
        try await flags(.command, in: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(browser.commandHeld)
        try await flags(.command, in: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(browser.commandHeld)
        try await flags(.command, in: window)
        prefs.showsTabShortcuts = false
        XCTAssertTrue(browser.tabShortcutNumbers.isEmpty)
        try await flags(.command, in: window)
        XCTAssertFalse(browser.commandHeld)
    }

    private func assertNumbers(_ browser: Browser, file: StaticString = #filePath, line: UInt = #line) {
        let shown = browser.tabShortcutTargets
        for (index, tab) in shown.enumerated() {
            let expected = index < 8 ? index + 1 : (index == shown.count - 1 ? 9 : nil)
            XCTAssertEqual(browser.tabShortcutNumbers[tab.id], expected, file: file, line: line)
        }
    }

    private func press(_ number: Int, browser: Browser, window: NSWindow) throws {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let characters = number == 2 ? "é" : String(number)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: codes[number - 1]))
        XCTAssertNil(ContentView.keyHooks[ObjectIdentifier(browser)]?(event))
    }

    private func flags(_ flags: NSEvent.ModifierFlags, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55))
        NSApp.postEvent(event, atStart: false)
        if let queued = NSApp.nextEvent(matching: .flagsChanged, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        try await settle()
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
}
