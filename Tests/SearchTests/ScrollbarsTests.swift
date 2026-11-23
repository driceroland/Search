import AppKit
import XCTest
@testable import Search

/// Hide scroll bars until you scroll: on, AppKit — and through it WebKit —
/// is told Search prefers overlay scroll bars; off, the Mac's own answer.
@MainActor
final class ScrollbarsTests: XCTestCase {
    func testOverlayOnlyWhileOn() {
        let saved = Scrollbars.fade
        defer { Scrollbars.fade = saved }
        Scrollbars.fade = false
        let mac = NSScroller.preferredScrollerStyle
        Scrollbars.fade = true
        XCTAssertEqual(NSScroller.preferredScrollerStyle, .overlay)
        Scrollbars.fade = false
        XCTAssertEqual(NSScroller.preferredScrollerStyle, mac, "Off: the Mac's answer again")
    }

    func testChangeIsAnnounced() {
        let saved = Scrollbars.fade
        defer { Scrollbars.fade = saved }
        Scrollbars.fade = false
        let heard = expectation(forNotification: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        Scrollbars.fade = true
        wait(for: [heard], timeout: 1)
    }

    func testOffByDefault() {
        let store = UserDefaults(suiteName: "scrollbars-\(UUID().uuidString)")!
        XCTAssertFalse(store.bool(forKey: "scrollbars.fade"))
        XCTAssertNotNil(SettingsIndex.items.first { $0.id == "scrollbars.fade" })
    }
}
