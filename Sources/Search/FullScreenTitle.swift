import AppKit
import WebKit

// A video in full screen, shared from Discord, Zoom or Meet (idea 1245).
// WebKit lends the page to a full-screen window of its own, and that window
// has no title: a screen-share picker lists windows by name, so it offered
// only "Search", the browser's window, which shows WebKit's placeholder, the
// page blurred under "Click to Exit Full Screen". The full-screen window now
// takes the page's title, kept as the title changes, so the pickers list it.
// (sharingType has nothing to do with it, and macOS ignores .none since 15.4.)
@MainActor
enum FullScreenTitle {
    /// `page`'s full-screen window named after the page, once WebKit has it
    /// there. A browser's own window is never renamed.
    static func follow(_ page: WKWebView) {
        guard page.fullscreenState == .inFullscreen, let window = page.window,
              !Browsers.all.contains(where: { $0.window === window }) else { return }
        name(window, title: page.title, url: page.url)
    }

    /// What a picker shows for the page: its title, or its site while it has none.
    static func label(title: String?, url: URL?) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return url?.host ?? "Search"
    }

    static func name(_ window: NSWindow, title: String?, url: URL?) {
        // A titled window would join the Window menu: this one stays out.
        window.isExcludedFromWindowsMenu = true
        let wanted = label(title: title, url: url)
        if window.title != wanted { window.title = wanted }
    }
}
