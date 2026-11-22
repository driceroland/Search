import AppKit
import SwiftUI

// Handoff: the page in front is offered to your iPhone, iPad and other Macs,
// as Safari's is, so it comes up in their app switcher (or at the end of the
// Dock) and opens there in the browser. macOS carries it between devices
// signed in to the same Apple Account; Search itself sends nothing anywhere.
// On for a new install once the welcome is left, with its switch on the
// welcome's first page; off for an install from before until asked for
// (SyncDefault.swift), since the address does leave this Mac. Never for
// a private tab, a space signed out of the others, or a page that isn't on
// the web.
//
// The activity hangs on the window: AppKit makes the main window's current
// and drops it when another window or app takes over, so with several
// windows the one you're looking at is the one offered.
//
// The other way, a page handed off from your iPhone or another Mac opens
// here when Search is your default browser (Links.application(_:continue:)),
// only if it is an http or https address.
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
    /// a tab that keeps something and shares it with the profile. Never a
    /// private tab — one opened from a private one has its store without
    /// being marked shy, so the store is asked too — and never a space signed
    /// out of the others, whose pages stay out of everything else.
    static func address(of tab: Tab) -> URL? {
        let store = tab.store
        guard !tab.shy, store.isPersistent, Spaces.owner(of: store) == nil,
              let url = tab.committed, web(url)
        else { return nil }
        return url
    }

    /// A page handed off from another device, if it may be opened: only an
    /// http or https address, never a file, a script or another app's link.
    static func incoming(_ activity: NSUserActivity) -> URL? {
        incoming(type: activity.activityType, url: activity.webpageURL)
    }

    static func incoming(type: String, url: URL?) -> URL? {
        guard type == NSUserActivityTypeBrowsingWeb, let url, web(url), url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func web(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
