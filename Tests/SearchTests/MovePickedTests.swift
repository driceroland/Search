import AppKit
import XCTest
@testable import Search

/// Several tabs picked in the column go into a group together (idea 1092),
/// by the tab menu (Browser.move(_:toGroup:) with the picked tabs) or by a
/// drag of one of them (Browser.move(_:toGroup: GroupDropTarget)), in the
/// order the column has them, and one undo puts them all back. Pin folders
/// go the same way through Browser.movePins, checked in a hidden probe by
/// Tests/move_picked.py, where the pins have their files.
@MainActor
final class MovePickedTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        Browser.lastMove = nil
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(100))
        try await super.tearDown()
    }

    /// Seven tabs, the first in a group "Work", the fourth in front, and
    /// five picked around it: two, three, five, six, seven.
    private func setUpPicked() -> (Browser, [Tab], UUID, [Tab]) {
        let browser = makeBrowser()
        let t = browser.tabs
        let work = browser.addTabGroup(containing: t[0])
        browser.editingGroupID = nil
        browser.select(t[3])
        let five = [t[1], t[2], t[4], t[5], t[6]]
        for tab in five { browser.extendTabSelection(to: tab, modifiers: .command) }
        // The first ⌘-click picked the tab in front too: let it go.
        browser.extendTabSelection(to: t[3], modifiers: .command)
        XCTAssertEqual(browser.pickedTabs.map(\.id), five.map(\.id))
        return (browser, t, work, five)
    }

    private func state(_ browser: Browser) -> [String] {
        browser.tabs.map { "\($0.id)/\($0.groupID?.uuidString ?? "")" } + browser.tabGroups.map(\.id.uuidString)
    }

    func testTheMenuMovesThemAllInOrderAndOneUndoBringsThemBack() {
        let (browser, t, work, five) = setUpPicked()
        let before = state(browser)
        browser.move(browser.pickedTabs, toGroup: work)
        XCTAssertEqual(browser.tabs(in: work).map(\.id), ([t[0]] + five).map(\.id), "after Work's own, in their order")
        XCTAssertTrue(browser.canUndoMove)
        browser.undoMove()
        XCTAssertEqual(state(browser), before, "every one back, in one step")
        XCTAssertFalse(browser.canUndoMove, "nothing more to undo")
    }

    func testADragOfOneTakesThePickedWithIt() {
        let (browser, t, work, five) = setUpPicked()
        let before = state(browser)
        browser.move(t[5], toGroup: GroupDropTarget(group: work, member: t[0].id, after: false))
        XCTAssertEqual(browser.tabs(in: work).map(\.id), (five + [t[0]]).map(\.id), "before Work's tab, in their order")
        browser.undoMove()
        XCTAssertEqual(state(browser), before)
    }

    func testNewGroupHoldsThemInOrderAndUndoTakesItAway() {
        let (browser, _, work, five) = setUpPicked()
        let before = state(browser)
        guard let fresh = browser.addTabGroup(containing: browser.pickedTabs) else { return XCTFail("no group") }
        XCTAssertEqual(browser.tabs(in: fresh).map(\.id), five.map(\.id))
        XCTAssertEqual(browser.tabGroups.map(\.id), [work, fresh])
        browser.undoMove()
        XCTAssertEqual(state(browser), before, "the new group goes, the five back")
    }

    func testAChangeSinceTheMoveKeepsItFromBeingUndone() {
        let (browser, t, work, _) = setUpPicked()
        browser.move(browser.pickedTabs, toGroup: work)
        browser.move(t[3], toGroup: work)
        XCTAssertFalse(browser.canUndoMove, "the row isn't as the move left it")
        let after = state(browser)
        browser.undoMove()
        XCTAssertEqual(state(browser), after, "nothing undone")
    }

    func testOneTabNotPickedMovesAlone() {
        let browser = makeBrowser()
        let t = browser.tabs
        let work = browser.addTabGroup(containing: t[0])
        browser.select(t[2])
        browser.move(t[4], toGroup: GroupDropTarget(group: work))
        XCTAssertEqual(browser.tabs(in: work).map(\.id), [t[0], t[4]].map(\.id))
        XCTAssertNil(browser.group(of: t[3]))
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins)
        restorePreferences = { (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins) = previous }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = true
        browser.prefs.splitView = false
        browser.prefs.listsPins = false
        for word in ["one", "two", "three", "four", "five", "six", "seven"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }
}
