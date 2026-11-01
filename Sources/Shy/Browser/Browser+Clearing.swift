import SwiftUI
import WebKit
import Combine

// What is kept, and getting rid of it.
extension Browser {
    enum RecallMode {
        case history, clearing
    }

    /// History, in a tab.
    var recalling: Bool {
        get { pageTab(.history) != nil }
        set { if newValue { show(InternalPage(.history)) } else { putAway(.history) } }
    }

    /// Downloads, in a tab.
    var hoarding: Bool {
        get { pageTab(.downloads) != nil }
        set { if newValue { show(InternalPage(.downloads)) } else { putAway(.downloads) } }
    }

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space and every profile. Clearing it signs you out of
    /// everything, which is the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        for profile in Profiles.shared.list {
            Profiles.store(profile.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Signed out of everything")
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        for profile in Profiles.shared.list {
            Profiles.store(profile.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared")
    }

    /// Every profile's: the button says every address you have been to.
    func clearHistory() {
        Profiles.shared.list.forEach { Profiles.history($0.id).forget() }
        // And what reopens with ⇧⌘T, in every window, and the copies of a
        // history that once didn't read (Store.quarantine): kept for a bad
        // read, never past being told to forget.
        Browsers.all.forEach { $0.ghosts = [] }
        Browsers.forgetClosed()
        Store.forgetUnreadable { $0.hasPrefix("history") }
        // The sites' icons are a list of where you have been, too, and so
        // are the searches learned from sites visited (SiteSearch.swift).
        Favicons.forgetEverything()
        Profiles.shared.list.forEach { SiteSearch.forget(in: $0.id) }
        announce("History cleared")
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }
}
