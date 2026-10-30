import XCTest
@testable import Search

final class SidebarControlsTests: XCTestCase {
    func testFooterCustomizationPersistsIncludingAnExplicitEmptySelection() async {
        await MainActor.run {
            let name = "search-footer-test-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name) }
            let prefs = SidebarFooterPreferences(store: store)
            XCTAssertTrue(prefs.contains(.tools))
            prefs.hideAll()
            XCTAssertTrue(prefs.items.isEmpty)
            XCTAssertTrue(SidebarFooterPreferences(store: store).items.isEmpty)
            prefs.set(.bookmarks, visible: true)
            XCTAssertEqual(SidebarFooterPreferences(store: store).items, [.bookmarks])
            prefs.showAll()
            XCTAssertEqual(prefs.items, Set(SidebarFooterItem.allCases))
        }
    }

    func testUnknownFooterItemsAreIgnoredInsteadOfRestoringHiddenButtons() async {
        await MainActor.run {
            let name = "search-footer-test-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name) }
            store.set(["unknown-future-button", "settings"], forKey: SidebarFooterPreferences.key)
            XCTAssertEqual(SidebarFooterPreferences(store: store).items, [.settings])
            store.set(["unknown-future-button"], forKey: SidebarFooterPreferences.key)
            XCTAssertTrue(SidebarFooterPreferences(store: store).items.isEmpty)
        }
    }

    func testCollapsedHoverCloseIsOnlyForTheActiveUnpinnedTab() {
        XCTAssertTrue(IconRailInteraction.showsClose(active: true, hovering: true, pinned: false, editing: false, dragging: false))
        XCTAssertFalse(IconRailInteraction.showsClose(active: false, hovering: true, pinned: false, editing: false, dragging: false))
        XCTAssertFalse(IconRailInteraction.showsClose(active: true, hovering: false, pinned: false, editing: false, dragging: false))
        XCTAssertFalse(IconRailInteraction.showsClose(active: true, hovering: true, pinned: true, editing: false, dragging: false))
        XCTAssertFalse(IconRailInteraction.showsClose(active: true, hovering: true, pinned: false, editing: true, dragging: false))
        XCTAssertFalse(IconRailInteraction.showsClose(active: true, hovering: true, pinned: false, editing: false, dragging: true))
    }

    func testClosePressCancelsOnDragAndLeavingTheTarget() {
        var press = RailClosePress()
        press.begin(at: CGPoint(x: 10, y: 10))
        press.move(to: CGPoint(x: 20, y: 10))
        XCTAssertFalse(press.finish(at: CGPoint(x: 10, y: 10), inside: true))
        press.begin(at: CGPoint(x: 10, y: 10))
        XCTAssertFalse(press.finish(at: CGPoint(x: 10, y: 10), inside: false))
        press.begin(at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(press.finish(at: CGPoint(x: 10, y: 10), inside: true))
        XCTAssertFalse(press.finish(at: CGPoint(x: 10, y: 10), inside: true))
    }

    func testAudioBadgeDoesNotBecomeACloseTarget() {
        XCTAssertTrue(RailClosePress.hit(at: CGPoint(x: 15, y: 15), size: CGSize(width: 30, height: 30), audio: false))
        XCTAssertFalse(RailClosePress.hit(at: CGPoint(x: 20, y: 20), size: CGSize(width: 30, height: 30), audio: true))
        XCTAssertFalse(RailClosePress.hit(at: CGPoint(x: 2, y: 2), size: CGSize(width: 30, height: 30), audio: false))
        XCTAssertEqual(SidebarFooter.height(count: 0, width: 232), 0)
    }

    func testAnimationTimingAndNewTabPlacementMatchReferencePolicy() {
        XCTAssertEqual(IconRailInteraction.expandCollapseDuration, 0.25)
        XCTAssertEqual(IconRailInteraction.newTabPlacement, .afterTabs)
        XCTAssertEqual(IconSideBar.tile, 30)
    }
}
