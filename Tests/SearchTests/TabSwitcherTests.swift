import AppKit
import XCTest
@testable import Search

@MainActor
final class TabSwitcherTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-switcher-\(getpid())", 1)
        super.setUp()
    }

    func testResetCancelsDelayedRevealAndDiscardsPictures() async throws {
        let switcher = TabSwitcher()
        let first = UUID(), second = UUID()
        let address = try XCTUnwrap(URL(string: "https://example.test"))
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        XCTAssertNotNil(switcher.preview(for: first, address: address))

        switcher.reset()
        XCTAssertNil(switcher.preview(for: first, address: address))
        // A result arriving after reset cannot repopulate the cache.
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        XCTAssertNil(switcher.preview(for: first, address: address))

        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.reset()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(switcher.visible)
        XCTAssertFalse(switcher.active)
        XCTAssertNil(switcher.selectedID)
    }
}
