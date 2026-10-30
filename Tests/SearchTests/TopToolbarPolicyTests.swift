import XCTest
@testable import Search

final class TopToolbarPolicyTests: XCTestCase {
    @MainActor
    func testDefaultsAndExplicitEmptySelectionPersist() {
        let name = "search-top-toolbar-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }

        let prefs = TopToolbarPreferences(store: store)
        XCTAssertTrue(prefs.enabled)
        XCTAssertEqual(prefs.items, [.windowControls, .address, .sidebar, .extensions, .downloads, .tools])
        prefs.hideAll()
        XCTAssertTrue(TopToolbarPreferences(store: store).items.isEmpty)
        prefs.set(.address, visible: true)
        XCTAssertEqual(TopToolbarPreferences(store: store).items, [.address])
        prefs.showAll()
        XCTAssertEqual(prefs.items, Set(TopToolbarItem.allCases))
    }

    @MainActor
    func testUnknownItemsAreIgnoredAndEnabledPreferencePersists() {
        let name = "search-top-toolbar-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }

        store.set(["unknown-future-item", "settings"], forKey: TopToolbarPreferences.key)
        store.set(false, forKey: TopToolbarPreferences.enabledKey)
        let prefs = TopToolbarPreferences(store: store)
        XCTAssertEqual(prefs.items, [.settings])
        XCTAssertFalse(prefs.enabled)
        prefs.enabled = true
        XCTAssertTrue(TopToolbarPreferences(store: store).enabled)
    }

    func testRevealEligibilityHoldAndTrafficLightsPolicy() {
        XCTAssertTrue(TopToolbarRevealPolicy.eligible(compact: true, fullscreen: false, immersed: false, enabled: true, hasItems: true))
        XCTAssertFalse(TopToolbarRevealPolicy.eligible(compact: false, fullscreen: false, immersed: false, enabled: true, hasItems: true))
        XCTAssertFalse(TopToolbarRevealPolicy.eligible(compact: true, fullscreen: true, immersed: false, enabled: true, hasItems: true))
        XCTAssertFalse(TopToolbarRevealPolicy.eligible(compact: true, fullscreen: false, immersed: true, enabled: true, hasItems: true))
        XCTAssertFalse(TopToolbarRevealPolicy.eligible(compact: true, fullscreen: false, immersed: false, enabled: false, hasItems: true))
        XCTAssertFalse(TopToolbarRevealPolicy.eligible(compact: true, fullscreen: false, immersed: false, enabled: true, hasItems: false))

        XCTAssertTrue(TopToolbarRevealPolicy.shouldHold(pointerInside: true, editing: false, popup: false, menuTracking: false))
        XCTAssertTrue(TopToolbarRevealPolicy.shouldHold(pointerInside: false, editing: true, popup: false, menuTracking: false))
        XCTAssertTrue(TopToolbarRevealPolicy.shouldHold(pointerInside: false, editing: false, popup: true, menuTracking: false))
        XCTAssertTrue(TopToolbarRevealPolicy.shouldHold(pointerInside: false, editing: false, popup: false, menuTracking: true))
        XCTAssertFalse(TopToolbarRevealPolicy.shouldHold(pointerInside: false, editing: false, popup: false, menuTracking: false))

        XCTAssertTrue(TopToolbarRevealPolicy.showsWindowControls(selected: true, revealed: true, fullscreen: false))
        XCTAssertFalse(TopToolbarRevealPolicy.showsWindowControls(selected: false, revealed: true, fullscreen: false))
        XCTAssertFalse(TopToolbarRevealPolicy.showsWindowControls(selected: true, revealed: false, fullscreen: false))
        XCTAssertFalse(TopToolbarRevealPolicy.showsWindowControls(selected: true, revealed: true, fullscreen: true))
    }

    func testRevealedToolbarReservesContentSpace() {
        XCTAssertEqual(TopToolbarLayoutPolicy.contentInset(eligible: true, revealed: true), 44)
        XCTAssertEqual(TopToolbarLayoutPolicy.contentInset(eligible: true, revealed: false), 0)
        XCTAssertEqual(TopToolbarLayoutPolicy.contentInset(eligible: false, revealed: true), 0)
    }

    func testMoreRightHandIconsShrinkAddressInsteadOfStayingInFixedBox() {
        let normal = TopToolbarLayoutPolicy.widths(total: 1100, leading: 116, trailing: 86, hasAddress: true)
        let pinned = TopToolbarLayoutPolicy.widths(total: 1100, leading: 116, trailing: 170, hasAddress: true)
        XCTAssertEqual(pinned.trailing - normal.trailing, 84, accuracy: 0.01)
        XCTAssertEqual(normal.address - pinned.address, 84, accuracy: 0.01)
        let narrow = TopToolbarLayoutPolicy.widths(total: 640, leading: 212, trailing: 500, hasAddress: true)
        XCTAssertGreaterThanOrEqual(narrow.address, 100)
        XCTAssertLessThan(narrow.trailing, 500)
        XCTAssertLessThanOrEqual(narrow.address + narrow.trailing + 212 + 26, 640)
    }

    func testHeliumCurveAndPartialTransitionTiming() {
        XCTAssertEqual(TopToolbarRevealPolicy.bezier, [0.2, 0, 0, 1])
        XCTAssertEqual(TopToolbarRevealPolicy.cursorExitGrace, 3)
        XCTAssertEqual(TopToolbarRevealPolicy.hoverLeeway, 8)
        XCTAssertEqual(TopToolbarRevealPolicy.progress(at: 0), 0, accuracy: 0.00001)
        XCTAssertEqual(TopToolbarRevealPolicy.progress(at: 1), 1, accuracy: 0.00001)
        XCTAssertGreaterThan(TopToolbarRevealPolicy.progress(at: 0.5), 0.8)
        XCTAssertEqual(TopToolbarRevealPolicy.duration(current: 0.7, showing: true), 0.06, accuracy: 0.0001)
        XCTAssertEqual(TopToolbarRevealPolicy.duration(current: 0.7, showing: false), 0.14, accuracy: 0.0001)
    }

    func testTimingAndTitlesAreStable() {
        XCTAssertEqual(TopToolbarRevealPolicy.height, 44)
        XCTAssertEqual(TopToolbarRevealPolicy.triggerHeight, 6)
        XCTAssertEqual(TopToolbarRevealPolicy.revealDelay, 0)
        XCTAssertEqual(TopToolbarRevealPolicy.hideDelay, 0.15)
        XCTAssertEqual(TopToolbarRevealPolicy.animationDuration, 0.20)
        XCTAssertEqual(TopToolbarItem.reload.title, "Reload / Stop")
        XCTAssertEqual(TopToolbarItem.tools.id, "tools")
    }
}
