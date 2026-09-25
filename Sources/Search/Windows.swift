import AppKit
import SwiftUI

// More than the one window. ⌘N opens another, with its own tabs and the same
// sign-ins, history and bookmarks as the first. ⇧⌘N opens a private one:
// every tab in it keeps nothing, they share a jar that dies with the window,
// and none of it is written into tomorrow's session.
//
// The first window is the one that was always there. It restores yesterday,
// it is where extensions and the bench live, and it is the only one whose
// tabs are saved. The others are just more of it.

@MainActor
enum Windows {
    /// The window that restores and saves. Set once it exists.
    static weak var home: Browser?
    /// Whichever window was key last, so a menu command lands there.
    static weak var front: Browser?

    private struct Held {
        weak var browser: Browser?
        let window: NSWindow
        let closed: NSObjectProtocol
    }

    private static var held: [Held] = []

    static var living: [Browser] {
        held.compactMap(\.browser)
    }

    /// The window a menu command should act on: the one in front, or the
    /// first, when nothing else is.
    static func acting(fallback: Browser) -> Browser {
        if let front, front.window?.isVisible == true { return front }
        if let key = NSApp.keyWindow,
           let match = living.first(where: { $0.window === key }) {
            return match
        }
        return home ?? fallback
    }

    static func note(_ browser: Browser) {
        if browser.kind == .home { home = browser }
        guard let window = browser.window else { return }
        if let index = held.firstIndex(where: { $0.browser === browser || $0.window === window }) {
            held[index] = Held(browser: browser, window: window, closed: held[index].closed)
        } else {
            watch(browser, window)
        }
        front = browser
    }

    /// ⌘N, and ⇧⌘N when `shy` is set. Cascades off whichever window is in
    /// front, the way every other window on the Mac does.
    static func open(shy: Bool) {
        guard let home else { return }
        let browser = Browser(kind: shy ? .shy : .fresh, sharing: home)
        let controller = NSHostingController(rootView: ContentView(browser: browser))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = shy ? "Private" : "Search"
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        if let key = NSApp.keyWindow ?? NSApp.mainWindow {
            var frame = key.frame
            frame.origin.x += 28
            frame.origin.y -= 28
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        browser.window = window
        watch(browser, window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        front = browser
    }

    /// Keeps the window until it closes, and no longer than that.
    private static func watch(_ browser: Browser, _ window: NSWindow) {
        var closed: NSObjectProtocol?
        closed = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak browser] _ in
            MainActor.assumeIsolated {
                if let closed { NotificationCenter.default.removeObserver(closed) }
                held.removeAll { $0.window === window }
                if let browser, front === browser { front = Windows.home }
            }
        }
        if let closed { held.append(Held(browser: browser, window: window, closed: closed)) }
    }
}
