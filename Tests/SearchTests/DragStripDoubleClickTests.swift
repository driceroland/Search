import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Search

/// Double-clicking the top of the window zooms once instead of zooming and
/// immediately bouncing back, and double-clicking empty tab-row space opens a
/// new tab without also zooming the window.
///
/// Since idea 744 kept `window.isMovable = true` while hovering `DragStrip`,
/// AppKit's `NSThemeFrame` title bar double-click recognizer fires inside the
/// top 32 pt `titlebarRect` unless `DragStrip.Strip` claims the double-click
/// with its own `NSClickGestureRecognizer`.
@MainActor
final class DragStripDoubleClickTests: XCTestCase {
    private var windows: [TrackingWindow] = []
    private var eventNumber = 100
    private var originalIsActive: IMP?
    private var activationPolicy: NSApplication.ActivationPolicy?

    private final class TrackingWindow: NSWindow {
        var zoomCalls = 0
        private var simulatedZoomed = false

        override var isKeyWindow: Bool { true }
        override var isZoomed: Bool { simulatedZoomed }

        override func zoom(_ sender: Any?) {
            zoomCalls += 1
            simulatedZoomed.toggle()
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        let app = NSApplication.shared
        activationPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // Under headless/locked-screen `swift test`, NSApp.isActive stays false
        // and AppKit skips title bar gesture recognizers. Temporarily report
        // active and restore in tearDown.
        if let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) {
            originalIsActive = method_getImplementation(method)
            let alwaysActive: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(alwaysActive))
        }
    }

    override func tearDown() async throws {
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        if let originalIsActive,
           let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) {
            method_setImplementation(method, originalIsActive)
            self.originalIsActive = nil
        }
        if let activationPolicy {
            NSApp.setActivationPolicy(activationPolicy)
            self.activationPolicy = nil
        }
        try await super.tearDown()
    }

    func testDoubleClickInTitlebarZoomsOnceWhenMovable() async throws {
        let (window, _) = makeWindow(reserved: 0, trailing: 0, onDoubleClick: nil)
        sendDoubleClick(at: NSPoint(x: 400, y: window.frame.height - 10), in: window)

        XCTAssertEqual(window.zoomCalls, 1, "AppKit and DragStrip must not both zoom on one double-click")
        XCTAssertTrue(window.isZoomed, "window stays maximized after a single double-click")
        XCTAssertTrue(window.isMovable, "window remains movable for window managers")
    }

    func testDoubleClickWhenAlreadyZoomedRestoresOnce() async throws {
        let (window, _) = makeWindow(reserved: 0, trailing: 0, onDoubleClick: nil)
        window.zoom(nil)
        window.zoomCalls = 0
        XCTAssertTrue(window.isZoomed)

        sendDoubleClick(at: NSPoint(x: 400, y: window.frame.height - 10), in: window)

        XCTAssertEqual(window.zoomCalls, 1, "already-zoomed window must restore once, not bounce back")
        XCTAssertFalse(window.isZoomed, "window stays restored after double-clicking the top")
    }

    func testDoubleClickBelowNativeTitlebarRectZoomsOnce() async throws {
        let (window, _) = makeWindow(reserved: 0, trailing: 0, onDoubleClick: nil)
        sendDoubleClick(at: NSPoint(x: 400, y: window.frame.height - 42), in: window)

        XCTAssertEqual(window.zoomCalls, 1, "lower part of the 52 pt strip zooms once")
        XCTAssertTrue(window.isZoomed)
    }

    // MARK: - harness

    private func makeWindow(
        reserved: CGFloat,
        trailing: CGFloat,
        band: CGFloat? = nil,
        onDoubleClick: (() -> Void)?
    ) -> (TrackingWindow, DragStrip.Strip) {
        let window = TrackingWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Off every screen, and never in the way of the pointer: the
        // events are handed to it directly.
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isMovable = true

        let strip = DragStrip.Strip(frame: NSRect(x: 0, y: 600 - 52, width: 800, height: 52))
        strip.reserved = reserved
        strip.trailing = trailing
        strip.band = band
        strip.onDoubleClick = onDoubleClick
        window.contentView?.addSubview(strip)

        // Match ContentView.dress + Lights.place: 52 pt titlebar container above contentView.
        if let close = window.standardWindowButton(.closeButton),
           let container = close.superview?.superview,
           let content = window.contentView,
           let frame = content.superview {
            var rect = container.frame
            rect.size.height = 52
            rect.origin.y = window.frame.height - 52
            container.frame = rect
            frame.addSubview(container, positioned: .above, relativeTo: content)
        }

        window.orderFrontRegardless()
        windows.append(window)

        // Prime event dispatch on the freshly ordered window.
        let t = ProcessInfo.processInfo.systemUptime
        send(.leftMouseDown, at: NSPoint(x: 400, y: 300), clicks: 1, time: t, in: window)
        send(.leftMouseUp, at: NSPoint(x: 400, y: 300), clicks: 1, time: t + 0.01, in: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        window.zoomCalls = 0
        return (window, strip)
    }

    private func sendDoubleClick(at point: NSPoint, in window: TrackingWindow) {
        let t = ProcessInfo.processInfo.systemUptime
        for clicks in [1, 2] {
            let offset = Double(clicks - 1) * 0.05
            send(.leftMouseDown, at: point, clicks: clicks, time: t + offset, in: window)
            send(.leftMouseUp, at: point, clicks: clicks, time: t + offset + 0.01, in: window)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int, time: TimeInterval, in window: NSWindow) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: time,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        window.sendEvent(event)
    }
}
