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
            .onChange(of: tab.title) { _, _ in apply() }
            .onChange(of: tab.name) { _, _ in apply() }
            .onChange(of: window) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        let title = WindowTitle.name(page: tab.name ?? tab.title, private: tab.shy)
        guard window.title != title else { return }
        window.title = title
        // A new title makes AppKit lay the title bar out again, and the
        // traffic lights go back to where it puts them: the zoom button came
        // up out of line on each tab switch. Put back now, and once more
        // after the layout that follows.
        Lights.refresh(window)
        DispatchQueue.main.async { Lights.refresh(window) }
    }
}
