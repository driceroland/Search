import AppKit
import SwiftUI

// The traffic lights, where a Mac app with a toolbar has them — set in from the
// corner and centred in the strip's height — without the toolbar.
//
// An empty toolbar is the public way to move them, and it was how this window
// did it. On macOS 26 a toolbar also rounds the window's corners almost twice
// as much: 31.5 points against 17.5 for a window without one, measured, and
// 17.5 is what Claude's window and the Finder have. So the window has no
// toolbar, and the three buttons are put where one would have put them, by
// hand — which is how Claude's own window does it. AppKit lays its title bar
// out again whenever it sees fit (a resize, full screen, the window becoming
// key), so every time it does, the buttons are put back.

@MainActor
final class Lights: NSObject {
    /// Where the close button's centre goes, from the window's top-left: where
    /// a unified toolbar put it, which Metrics.lights and sideLights are
    /// measured from.
    static let centre = CGPoint(x: 26, y: 26)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    /// Starts looking after a window's lights, once. `moved` hears each time
    /// they have been put in place.
    /// `fullScreen` hears each time AppKit lays the title bar out in full
    /// screen, where the buttons are left where it puts them.
    static func keep(_ window: NSWindow, centreX: @escaping () -> CGFloat, moved: @escaping () -> Void,
                     fullScreen: @escaping () -> Void) {
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window, centreX: centreX, moved: moved, fullScreen: fullScreen)
    }

    static func refresh(_ window: NSWindow?) {
        guard let window else { return }
        kept[ObjectIdentifier(window)]?.place()
    }

    private weak var window: NSWindow?
    private let moved: () -> Void
    private let fullScreen: () -> Void
    private let centreX: () -> CGFloat
    private var placing = false
    /// AppKit's own spacing between the three, read once from its first
    /// layout and kept. Read again on every pass, it was caught while AppKit
    /// was halfway through putting them back after a resize — one button
    /// moved, the next not yet — and the three closed up from 23 points apart
    /// to 13, on top of each other, a spacing each later pass then copied
    /// from the one before. Reproduced with ./bench resize, 23 Sep 2026.
    private let spacing: CGFloat

    private init(_ window: NSWindow, centreX: @escaping () -> CGFloat, moved: @escaping () -> Void,
                 fullScreen: @escaping () -> Void) {
        self.window = window
        self.centreX = centreX
        self.moved = moved
        self.fullScreen = fullScreen
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let centre = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(place), name: name, object: window)
        }
        // The title bar's own views moving is the surest sign AppKit has just
        // laid them out again.
        let buttons = self.buttons
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                centre.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    @objc private func place() {
        guard !placing, let window else { return }
        // Full screen keeps its title bar in a window of its own, laid out by
        // macOS; the buttons are left to it. It moves the title bar there
        // after saying full screen has begun, though, and shows all of it
        // again on the way, so what is shown of it is settled here.
        if window.styleMask.contains(.fullScreen) {
            fullScreen()
            return
        }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        // A title bar as tall as the strip, so the buttons can sit lower in it.
        let height = Metrics.strip
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        // Only the row moves; the spacing is AppKit's, from its first layout.
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: centreX() - size.width / 2 + CGFloat(index) * spacing,
                y: bar.bounds.height - Lights.centre.y - size.height / 2
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        moved()
    }
}

extension Lights {
    /// AppKit's spacing between a window's buttons, as its Lights read it.
    static func spacing(of window: NSWindow) -> CGFloat {
        kept[ObjectIdentifier(window)]?.spacing ?? 20
    }
}

/// The three buttons in the column's corner while the window is full screen.
///
/// Full screen takes a window's own buttons into a bar of macOS's that comes
/// down only with the menu bar, so the column's corner stood empty and the
/// lights were nowhere until the pointer went up for them. These are fresh
/// buttons of the system's own make, so they look as the real ones do, glyphs
/// and all, set where the real ones sit out of full screen. The real ones are
/// hidden meanwhile (see Fold.fullScreen), or both came down at once.
struct FullScreenLights: NSViewRepresentable {
    func makeNSView(context: Context) -> Row { Row() }
    func updateNSView(_ row: Row, context: Context) {}

    final class Row: NSView {
        private var buttons: [NSButton] = []
        private var hovering = false

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, buttons.isEmpty else { return }
            let spacing = Lights.spacing(of: window)
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable])
                else { continue }
                let size = button.frame.size
                button.setFrameOrigin(NSPoint(
                    x: Lights.centre.x - size.width / 2 + CGFloat(index) * spacing,
                    y: Lights.centre.y - size.height / 2
                ))
                button.target = window
                switch type {
                case .closeButton: button.action = #selector(NSWindow.performClose(_:))
                case .zoomButton: button.action = #selector(NSWindow.toggleFullScreen(_:))
                // A full-screen window can't go to the Dock; macOS's own
                // yellow is greyed out there too.
                default: button.isEnabled = false
                }
                addSubview(button)
                buttons.append(button)
            }
            let area = buttons.reduce(NSRect.null) { $0.union($1.frame) }
            addTrackingArea(NSTrackingArea(rect: area, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }

        /// The buttons ask `_mouseInGroup:` only when their state changes: told
        /// to redraw, they drew the same again, and the glyphs came only with
        /// a click. So each is switched off and on again, which is a change of
        /// state that changes nothing. Found with the buttons in a window of
        /// their own, 29 Sep 2026.
        private func hover(_ on: Bool) {
            hovering = on
            for button in buttons {
                let enabled = button.isEnabled
                button.isEnabled = !enabled
                button.isEnabled = enabled
            }
        }

        /// Asked by each button of the row it sits in: the pointer over any
        /// one of the three shows the ×, − and arrows on all of them, as it
        /// does in a title bar.
        @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovering }
    }
}
