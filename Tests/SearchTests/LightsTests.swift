import AppKit
import XCTest
@testable import Search

/// The traffic lights stay where Lights puts them when one of them is moved
/// back while they are being placed. A window manager that sizes the window
/// the moment it opens (OmniWM, for one) left the zoom button where AppKit
/// lays it out, over the minimise button, until the window was resized: most
/// likely the move came inside Lights.place, was dropped there, and nothing
/// came after it. This moves the button from `moved`, which Lights calls at the end of
/// its pass, still inside it; should that call ever move out of the pass,
/// the move here no longer lands inside one and the test proves nothing,
/// which the check on `inPass` catches.
@MainActor
final class LightsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testAButtonMovedWhilePlacingIsPutBack() {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }

        let appKits = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0)?.frame.origin }
        XCTAssertEqual(appKits.count, 3)

        var armed = false
        var inPass = false
        Lights.keep(window, centreX: { _ in Lights.centre.x }) { [weak window] in
            guard armed, let zoom = window?.standardWindowButton(.zoomButton) else { return }
            armed = false
            inPass = true
            zoom.setFrameOrigin(appKits[2])
        }
        let placed = Bench.lights(of: window)
        XCTAssertEqual(placed.count, 3)
        XCTAssertNotEqual(window.standardWindowButton(.zoomButton)?.frame.origin, appKits[2],
                          "Lights moved the zoom button off AppKit's spot to begin with")

        armed = true
        Lights.refresh(window)
        XCTAssertTrue(inPass, "the zoom button was moved during the pass")

        let settled = expectation(description: "the next turn of the main loop")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 1)

        XCTAssertEqual(Bench.lights(of: window), placed, "the three are back where Lights put them")
    }
}
