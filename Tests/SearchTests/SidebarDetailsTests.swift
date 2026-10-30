import XCTest
@testable import Search

final class SidebarDetailsTests: XCTestCase {
    func testNewHoverSupersedesEarlierSnapshot() {
        var state = TabHoverRequestState()
        let a = UUID(), b = UUID()
        let url = URL(string: "https://example.com/a")!
        let first = state.begin(tabID: a, address: url)
        let second = state.begin(tabID: b, address: url)
        XCTAssertFalse(state.accepts(first, tabID: a, address: url, stillPresent: true))
        XCTAssertTrue(state.accepts(second, tabID: b, address: url, stillPresent: true))
    }

    func testExitNavigationAndCloseInvalidateSnapshot() {
        var state = TabHoverRequestState()
        let id = UUID(), url = URL(string: "https://example.com/a")!
        let request = state.begin(tabID: id, address: url)
        XCTAssertFalse(state.accepts(request, tabID: id, address: URL(string: "https://example.com/b"), stillPresent: true))
        XCTAssertFalse(state.accepts(request, tabID: id, address: url, stillPresent: false))
        state.cancel()
        XCTAssertFalse(state.accepts(request, tabID: id, address: url, stillPresent: true))
        XCTAssertNil(state.current)
    }

    func testPendingHoverIsNotDismissedByAnOrdinaryViewUpdate() {
        XCTAssertFalse(TabHoverRequestState.presentationChanged(shownPreviews: nil, shownMemory: nil, previews: true, memory: true))
        XCTAssertFalse(TabHoverRequestState.presentationChanged(shownPreviews: true, shownMemory: true, previews: true, memory: true))
        XCTAssertTrue(TabHoverRequestState.presentationChanged(shownPreviews: true, shownMemory: true, previews: false, memory: true))
    }

    func testPrivatePreviewsAreNotReusable() {
        XCTAssertFalse(TabHoverRequestState.canReusePreview(isPrivate: true, address: URL(string: "https://example.com")))
        XCTAssertFalse(TabHoverRequestState.canReusePreview(isPrivate: false, address: nil))
        XCTAssertTrue(TabHoverRequestState.canReusePreview(isPrivate: false, address: URL(string: "https://example.com")))
    }

    func testOptionalDetailsDefaultOffAndPersistSeparately() async {
        await MainActor.run {
            let name = "search-sidebar-details-test-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name) }
            let prefs = SidebarDetailsPreferences(store: store)
            XCTAssertFalse(prefs.showsPreviews)
            XCTAssertFalse(prefs.showsMemory)
            prefs.showsPreviews = true
            let restored = SidebarDetailsPreferences(store: store)
            XCTAssertTrue(restored.showsPreviews)
            XCTAssertFalse(restored.showsMemory)
            restored.showsMemory = true
            XCTAssertTrue(SidebarDetailsPreferences(store: store).showsMemory)
        }
    }

    func testCompactRailNeedsNoWindowControlBand() {
        XCTAssertEqual(CompactSidebarChrome.topInset(compact: true, folded: false, fullscreen: false, immersed: false), 0)
        XCTAssertEqual(CompactSidebarChrome.topInset(compact: true, folded: true, fullscreen: false, immersed: false), 0)
        XCTAssertEqual(CompactSidebarChrome.topInset(compact: true, folded: false, fullscreen: true, immersed: false), 0)
        XCTAssertEqual(CompactSidebarChrome.topInset(compact: true, folded: false, fullscreen: false, immersed: true), 0)
        XCTAssertEqual(CompactSidebarChrome.lightsX(windowWidth: 1100, right: true, compact: true, sidebarWidth: 42), 1026)
        XCTAssertEqual(CompactSidebarChrome.lightsX(windowWidth: 1100, right: false, compact: true, sidebarWidth: 42), 26)
    }

    func testTrafficLightsAreHiddenOnlyInCompactWindowMode() {
        XCTAssertTrue(CompactSidebarChrome.hidesLights(compact: true, fullscreen: false))
        XCTAssertFalse(CompactSidebarChrome.hidesLights(compact: false, fullscreen: false))
        XCTAssertFalse(CompactSidebarChrome.hidesLights(compact: true, fullscreen: true))
    }

    func testMemoryFormattingDoesNotInventZeroWhenUnavailable() {
        XCTAssertEqual(SidebarMemoryText.bytes(nil), "Not measured")
        XCTAssertEqual(SidebarMemoryText.bytes(0), "0 MB")
        XCTAssertEqual(SidebarMemoryText.bytes(100 * 1_048_576), "100 MB")
        XCTAssertEqual(SidebarMemoryText.bytes(2 * 1_073_741_824), "2.0 GB")
    }
}
