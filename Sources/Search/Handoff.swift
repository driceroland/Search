import AppKit
import SwiftUI

// Handoff: the page in front is offered to your iPhone, iPad and other Macs,
// as Safari's is, so it comes up in their app switcher (or at the end of the
// Dock) and opens there in the browser. macOS carries it between devices
// signed in to the same Apple Account; Search itself sends nothing anywhere.
// Off unless asked for, since the address does leave this Mac, and never for
// a private tab or a page that isn't on the web.
//
// The activity hangs on the window: AppKit makes the main window's current
// and drops it when another window or app takes over, so with several
// windows the one you're looking at is the one offered.
struct Handoff: View {
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    let window: NSWindow?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: apply)
            .onChange(of: tab.committed) { _, _ in apply() }
            .onChange(of: tab.title) { _, _ in apply() }
            .onChange(of: prefs.handoff) { _, _ in apply() }
    }

    private func apply() {
        if let window { Handoff.offer(prefs.handoff ? tab : nil, in: window) }
    }

    /// Offers the tab's page from this window, or withdraws what was offered
    /// when there is no tab, or nothing that may go.
    static func offer(_ tab: Tab?, in window: NSWindow) {
        guard let tab, let url = address(of: tab) else {
            window.userActivity?.invalidate()
            window.userActivity = nil
            return
        }
        let activity = window.userActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = tab.name ?? tab.title
        window.userActivity = activity
    }

    /// The page actually on screen, if it may be offered: a web address, in
    /// a tab that keeps something. A tab opened from a private one has the
    /// private one's store without being marked shy, so the store is asked too.
    static func address(of tab: Tab) -> URL? {
        let shy = tab.shy || tab.built.map { !$0.configuration.websiteDataStore.isPersistent } == true
        guard !shy, let url = tab.committed, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
