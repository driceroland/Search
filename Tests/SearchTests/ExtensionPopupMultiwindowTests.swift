import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopupMultiwindowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "popup-multiwindow-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testAnchorsAreScopedToTheirBrowserWindow() {
        let b1 = Browser(record: WindowRecord())
        let b2 = Browser(record: WindowRecord())

        let w1 = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
        w1.isReleasedWhenClosed = false
        let v1 = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        w1.contentView?.addSubview(v1)

        let w2 = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
        w2.isReleasedWhenClosed = false
        let v2 = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        w2.contentView?.addSubview(v2)

        let extID = "test-extension-\(UUID().uuidString)"

        Extensions.shared.registerAnchor(v1, for: extID, in: b1)
        Extensions.shared.registerAnchor(v2, for: extID, in: b2)

        XCTAssertTrue(Extensions.shared.anchor(for: extID, in: b1) === v1,
                      "Anchor in window 1 must return window 1's view")
        XCTAssertTrue(Extensions.shared.anchor(for: extID, in: b2) === v2,
                      "Anchor in window 2 must return window 2's view")

        XCTAssertTrue(Extensions.shared.isOwnButton(v1, for: extID))
        XCTAssertTrue(Extensions.shared.isOwnButton(v2, for: extID))

        Extensions.shared.detach(b2)
        XCTAssertNil(Extensions.shared.anchors[ObjectIdentifier(b2)], "Closed window's anchors must be removed")
        XCTAssertTrue(Extensions.shared.anchor(for: extID, in: b1) === v1, "Remaining window's anchors must stay intact")

        Extensions.shared.detach(b1)
        w1.close()
        w2.close()
    }

    func testUnpinnedExtensionFallsBackToTargetWindowPuzzleButton() {
        let b1 = Browser(record: WindowRecord())
        let b2 = Browser(record: WindowRecord())

        let w1 = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
        w1.isReleasedWhenClosed = false
        let puzzle1 = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        w1.contentView?.addSubview(puzzle1)

        let w2 = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
        w2.isReleasedWhenClosed = false
        let puzzle2 = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        w2.contentView?.addSubview(puzzle2)

        Extensions.shared.registerAnchor(puzzle1, for: Extensions.menuAnchor, in: b1)
        Extensions.shared.registerAnchor(puzzle2, for: Extensions.menuAnchor, in: b2)

        let unpinnedID = "unpinned-ext-\(UUID().uuidString)"

        XCTAssertTrue(Extensions.shared.anchor(for: unpinnedID, in: b1) === puzzle1,
                      "Unpinned extension in window 1 must hang from window 1's puzzle button")
        XCTAssertTrue(Extensions.shared.anchor(for: unpinnedID, in: b2) === puzzle2,
                      "Unpinned extension in window 2 must hang from window 2's puzzle button")

        Extensions.shared.detach(b1)
        Extensions.shared.detach(b2)
        w1.close()
        w2.close()
    }
}
