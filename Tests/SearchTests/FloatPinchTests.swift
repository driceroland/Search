import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class FloatPinchTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "float-pinch-\(getpid())", 1)
        super.setUp()
    }

    func testPinchResizesFloatingWindowWithoutZoomingPage() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let saved = Store.settings.object(forKey: "float.frame")
        let away = Float.benchAway
        Store.settings.removeObject(forKey: "float.frame")
        Float.benchAway = NSPoint(x: -30000, y: -30000)
        let floater = Float()
        // The browser window with the keys, behind the floating one: macOS
        // sends a trackpad pinch there, not to the window under the fingers.
        let key = NSWindow(contentRect: NSRect(x: -30100, y: -30100, width: 900, height: 640),
                           styleMask: [.titled], backing: .buffered, defer: false)
        key.isReleasedWhenClosed = false
        defer {
            floater.drop()
            key.close()
            Float.benchAway = away
            Store.settings.set(saved, forKey: "float.frame")
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 440, height: 247))
        web.allowsMagnification = true
        floater.lift(web)
        let panel = try XCTUnwrap(web.window)
        let original = panel.frame.size
        XCTAssertFalse(web.allowsMagnification)

        func pinch(_ amount: CGFloat, _ phase: NSEvent.Phase, at spot: NSPoint) -> Bool {
            Float.steer(Pinch(amount, phase, in: key, at: key.convertPoint(fromScreen: spot)))
        }
        let over = NSPoint(x: panel.frame.minX + 80, y: panel.frame.minY + 80)
        XCTAssertTrue(pinch(0, .began, at: over))
        XCTAssertTrue(pinch(0.25, .changed, at: over))
        XCTAssertEqual(panel.frame.width, original.width * 1.25, accuracy: 1)
        XCTAssertEqual(panel.frame.height / panel.frame.width, original.height / original.width, accuracy: 0.001)
        // Still this window's while the fingers stay down, wherever the
        // pointer has got to as it grew.
        XCTAssertTrue(pinch(-0.2, .changed, at: NSPoint(x: panel.frame.maxX + 50, y: over.y)))
        XCTAssertEqual(panel.frame.width, original.width, accuracy: 1)
        XCTAssertTrue(pinch(-0.99, .changed, at: over))
        XCTAssertEqual(panel.frame.width, panel.minSize.width, accuracy: 1)
        XCTAssertTrue(pinch(0, .ended, at: over))
        XCTAssertEqual(web.pageZoom, 1)
        XCTAssertEqual(web.magnification, 1)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(panel.frame) })

        // A pinch that starts anywhere else is the page's, as it always was.
        let sized = panel.frame
        let beside = NSPoint(x: panel.frame.maxX + 200, y: panel.frame.minY + 80)
        XCTAssertFalse(pinch(0, .began, at: beside))
        XCTAssertFalse(pinch(0.3, .changed, at: beside))
        XCTAssertEqual(panel.frame, sized)

        // Under a window above it, an alert's say, the pinch is that window's.
        let inside = NSPoint(x: panel.frame.minX + 20, y: panel.frame.minY + 20)
        let alert = NSWindow(contentRect: NSRect(x: inside.x - 10, y: inside.y - 10, width: 40, height: 40),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        alert.isReleasedWhenClosed = false
        alert.level = .modalPanel
        alert.orderFrontRegardless()
        XCTAssertFalse(pinch(0, .began, at: inside), "a window over the floating one takes its own pinches")
        XCTAssertFalse(pinch(0, .ended, at: inside))
        alert.close()

        // Closed under the fingers: the rest of that pinch is nobody's, and
        // the page behind never hears a pinch it didn't see begin.
        XCTAssertTrue(pinch(0, .began, at: inside))
        floater.drop()
        XCTAssertTrue(web.allowsMagnification)
        XCTAssertTrue(pinch(0.3, .changed, at: inside), "the rest of a pinch begun over it is not the page's")
        XCTAssertTrue(pinch(0, .ended, at: inside))
        XCTAssertFalse(pinch(0, .began, at: inside), "a closed window takes no pinches")
    }

    /// With another app in front, macOS sends a pinch to that app: a click
    /// on the floating window brings Search in front with the keys in it,
    /// and only a click: not the pointer passing over it, nor a press that
    /// may be the start of moving it. (A test run can't come in front; the
    /// keys it can see.)
    func testClickOnFloatingWindowGivesItTheKeysWhileSearchIsBehind() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let away = Float.benchAway
        Float.benchAway = NSPoint(x: -30000, y: -30000)
        let floater = Float()
        defer {
            floater.drop()
            Float.benchAway = away
        }
        floater.lift(NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 247)))
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible })
        let controls = try XCTUnwrap(panel.contentView?.hitTest(NSPoint(x: 80, y: 80)))
        XCTAssertFalse(NSApp.isActive)
        controls.mouseEntered(with: NSEvent())
        XCTAssertFalse(panel.isKeyWindow, "passing over it takes nothing from the app in front")
        controls.mouseDown(with: Click())
        XCTAssertFalse(panel.isKeyWindow, "pressing may be the start of moving it")
        controls.mouseUp(with: Click())
        XCTAssertTrue(panel.isKeyWindow)
    }

    private final class Click: NSEvent {
        override init() { super.init() }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var type: NSEvent.EventType { .leftMouseDown }
        override var locationInWindow: NSPoint { NSPoint(x: 80, y: 80) }
    }

    private final class Pinch: NSEvent {
        private let amount: CGFloat
        private let part: NSEvent.Phase
        private let host: NSWindow
        private let spot: NSPoint
        init(_ amount: CGFloat, _ part: NSEvent.Phase, in host: NSWindow, at spot: NSPoint) {
            self.amount = amount
            self.part = part
            self.host = host
            self.spot = spot
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var magnification: CGFloat { amount }
        override var phase: NSEvent.Phase { part }
        override var type: NSEvent.EventType { .magnify }
        override var window: NSWindow? { host }
        override var locationInWindow: NSPoint { spot }
    }
}
