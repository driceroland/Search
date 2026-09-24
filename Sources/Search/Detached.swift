import AppKit

// One tab's page, out in a window of its own — dragged off the row for a
// second monitor, a reference beside the main one.
//
// Which tab is out is Browser's single-writer policy (detach/attach); this
// class only hosts the view, as Float does for video. No session or history
// knowledge.

@MainActor
final class Detached {
    private var panel: NSPanel?
    private weak var page: NSView?
    private let closer = Closer()

    /// Asked to go away. The browser does the bookkeeping and calls back
    /// into `drop` — one way this window closes, not two.
    var onClose: (() -> Void)?

    var showing: Bool { panel != nil }

    func detach(_ page: NSView, title: String) {
        guard panel == nil else { return }
        self.page = page

        let size = NSSize(width: 880, height: 620)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let spot = Detached.remembered ?? NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: spot,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.title = title
        panel.setFrameAutosaveName("search.detached")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)
        closer.asked = { [weak self] in self?.onClose?() }
        panel.delegate = closer
        // Kept once a move or a resize is over, not on each step of one: at
        // the end of a resize by its edges, as it closes (see drop), and as
        // the app quits with it open, which closes nothing.
        let keep: (Notification.Name, AnyObject) -> NSObjectProtocol = { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak panel] _ in
                MainActor.assumeIsolated {
                    if let panel { Detached.remembered = panel.frame }
                }
            }
        }
        keeping = [
            keep(NSWindow.didEndLiveResizeNotification, panel),
            keep(NSApplication.willTerminateNotification, NSApp),
        ]

        page.removeFromSuperview()
        if let ground = panel.contentView {
            page.frame = ground.bounds
            page.autoresizingMask = [.width, .height]
            ground.addSubview(page)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// The window's last place and size, kept across closing it and quitting,
    /// and given back only while a screen still shows most of it.
    private static var remembered: NSRect? {
        get {
            guard let text = Store.settings.string(forKey: "detached.frame") else { return nil }
            let frame = NSRectFromString(text)
            let shown = NSScreen.screens.contains {
                let seen = $0.visibleFrame.intersection(frame)
                return seen.width * seen.height > 0.6 * frame.width * frame.height
            }
            return frame.width > 100 && shown ? frame : nil
        }
        set { Store.settings.set(newValue.map(NSStringFromRect), forKey: "detached.frame") }
    }

    private var keeping: [NSObjectProtocol] = []

    func retitle(_ title: String) {
        panel?.title = title
    }

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel else { return }
        Detached.remembered = panel.frame
        keeping.forEach(NotificationCenter.default.removeObserver)
        keeping = []
        panel.delegate = nil
        closer.asked = nil
        page?.removeFromSuperview()
        page = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    /// The red button asks the browser first: it does the bookkeeping and
    /// closes the window through `drop`, so a close is never just the view
    /// going away with the tab still naming it.
    private final class Closer: NSObject, NSWindowDelegate {
        var asked: (() -> Void)?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { asked?() }
            return false
        }
    }
}
