import AppKit
import WebKit

// Back to a page's full screen after ⌘Tab. A video, or a page that asked for
// full screen, is lent to WebKit's own full-screen window, in a Space of its
// own; the browser's window is left behind with WebKit's placeholder in it,
// the page blurred under "Click to Exit Full Screen". Left with ⌘Tab from the
// video and come back to with ⌘Tab, macOS made the browser's window key and
// showed its desktop: the placeholder, not the video (25 Nov 2026).
// Nothing of Search's fronts a window on coming back (the app's didBecomeActive
// watchers only note the time, put the launcher away and bring a floating
// video home), so the choice was the system's.
//
// Now the window that was key as the app was left is noted, if it is WebKit's
// full-screen window with a page still in it; coming back, if another window
// has been made key since, the full-screen window is made key and front again,
// and macOS goes to its Space. Only then: left from the browser's window — the window
// itself in macOS full screen, or beside a video kept in its own Space
// (Preferences.keepsWindow) — it is the browser's window that comes back, as
// before. Nor when a click brought the app back: the click is where you
// meant to be, and on the placeholder it is how full screen is left.
@MainActor
enum FullScreenReturn {
    /// WebKit's full-screen window, key as the app was left.
    private static weak var left: NSWindow?
    private static var watches: [NSObjectProtocol] = []

    static func start() {
        guard watches.isEmpty else { return }
        let center = NotificationCenter.default
        watches = [
            // Before the key window resigns, which it does as the app goes.
            center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { leaving(key: NSApp.keyWindow) }
            },
            // A turn later: AppKit hands out the key window as it activates.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { back() } }
            },
        ]
    }

    /// The app being left with `key` the key window.
    static func leaving(key: NSWindow?) {
        left = key.flatMap { holdsFullScreenPage($0) ? $0 : nil }
    }

    /// The app back: the full-screen window it was left from, key and front
    /// again. Never in a test run, whose windows stay off every screen.
    static func back() {
        defer { left = nil }
        guard !Store.testing,
              let window = returning(left: left, key: NSApp.keyWindow,
                                     clicked: NSEvent.pressedMouseButtons != 0,
                                     fills: holdsFullScreenPage)
        else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// The window to bring back to, or none to leave things as they are:
    /// `left`, the window key as the app was left, if it still holds a page in
    /// full screen (`fills`), is still on screen, and isn't already key; and
    /// the app wasn't brought back by a click (`clicked`).
    static func returning(left: NSWindow?, key: NSWindow?, clicked: Bool,
                          fills: (NSWindow) -> Bool) -> NSWindow? {
        guard !clicked, let left, left !== key, left.isVisible, fills(left) else { return nil }
        return left
    }

    /// Whether `window` is WebKit's full-screen window for a tab's page: the
    /// page is in it, not in its browser's window, and full screen.
    static func holdsFullScreenPage(_ window: NSWindow) -> Bool {
        Browsers.all.contains { browser in
            window !== browser.window && browser.tabs.contains { tab in
                guard let page = tab.built else { return false }
                return page.window === window && page.fullscreenPhase == .inFullscreen
            }
        }
    }
}
