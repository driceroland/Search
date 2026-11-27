import AppKit
import SwiftUI

// The window's name: never drawn, since the title bar is hidden, but read by
// macOS. A window without one is left out of the Dock icon's menu and the
// Window menu, so a window put away in the Dock could not be found again.
// It is named for the page in front, as Safari's are; a private tab only as
// one, since its page is nobody else's business.
struct WindowTitle: View {
    @ObservedObject var tab: Tab
    let window: NSWindow?

    /// What the window is called for a page: the name you gave the tab, else
    /// the page's own, else the app's.
    static func name(page: String, private shy: Bool) -> String {
        if shy { return "Private Tab" }
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Search" : trimmed
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: apply)
            .onChange(of: tab.title) { _, _ in later() }
            .onChange(of: tab.name) { _, _ in later() }
    }

    private func apply() {
        if let window { WindowTitle.set(tab, in: window) }
    }

    /// A page's title changes in steps — gone as the next page commits,
    /// then its own, then often again as its scripts settle (YouTube's do on
    /// every video) — and each title the window took laid its title bar out
    /// again and put the traffic lights back: two or three times a link
    /// followed, on the main thread while the new page's frames waited for
    /// it (idea 1327). Only the last of a quick run is set, a moment on.
    private func later() {
        guard let window else { return }
        WindowTitle.soon(tab, in: window)
    }

    private final class Waiting {
        weak var tab: Tab?
        weak var window: NSWindow?
        init(_ tab: Tab, _ window: NSWindow) { self.tab = tab; self.window = window }
    }
    @MainActor private static var waiting: [ObjectIdentifier: Waiting] = [:]
    /// Long enough for a page's title to go and come back, short enough
    /// that the Window menu never shows the page before.
    static let settle: TimeInterval = 0.25

    @MainActor static func soon(_ tab: Tab, in window: NSWindow) {
        let key = ObjectIdentifier(window)
        let first = waiting[key] == nil
        waiting[key] = Waiting(tab, window)
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            MainActor.assumeIsolated {
                guard let last = waiting.removeValue(forKey: key), let tab = last.tab, let window = last.window else { return }
                set(tab, in: window)
            }
        }
    }

    /// Names the window for the tab in front. Also called as the window is
    /// first set (WindowSetup), so its name doesn't wait for the next change.
    static func set(_ tab: Tab, in window: NSWindow) {
        let title = name(page: tab.name ?? tab.title, private: tab.shy)
        guard window.title != title else { return }
        window.title = title
        // A new title makes AppKit lay the title bar out again, and the
        // traffic lights go back to where it puts them: the zoom button came
        // up out of line on each tab switch. Looked at now, and once more
        // after the layout that follows, and put back only if they moved.
        Lights.refreshIfMoved(window)
        DispatchQueue.main.async { Lights.refreshIfMoved(window) }
    }
}
