import SwiftUI
import WebKit
import Combine

// Bookmarks: the window's side of them (Bookmarks.swift).
extension Browser {
    /// The profile of the space on screen (see Profiles.swift).
    var profileID: UUID { space.profileID }

    /// Its profile's bookmarks, and below its history: another space's
    /// profile, another list.
    var bookmarks: Bookmarks { Profiles.bookmarks(profileID) }

    /// The full list, for taking things out, in a tab.
    var bookmarking: Bool {
        get { pageTab(.bookmarks) != nil }
        set { if newValue { show(InternalPage(.bookmarks)) } else { putAway(.bookmarks) } }
    }

    /// The page you are on is kept, wherever it is filed.
    var pageKept: Bool {
        active?.address.map(bookmarks.contains) ?? false
    }

    /// ⇧⌘B. The page you are on, at the end of the list, and the card off
    /// the button to name it and file it — or the card for it, if it was
    /// kept already. Without the button on screen (the tabs folded away)
    /// there is nothing to hang the card from, and a word says what
    /// happened instead.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        let kept = bookmarks.bookmark(for: url)
        guard let id = (kept ?? bookmarks.add(url, title: tab.title))?.id else { return }
        guard !folded else {
            announce(kept == nil ? "Bookmarked" : "Already a bookmark")
            return
        }
        bookmarkCard = id
        bookmarksOpen = true
    }

    /// The button: the list, never a card left from before.
    func toggleBookmarks() {
        if !bookmarksOpen { bookmarkCard = nil }
        bookmarksOpen.toggle()
    }

    struct FileImportJob: Identifiable {
        let id: UUID
        let filename: String
        var message: String
        var completed = 0
        var total: Int?
        var cancelling = false
    }

    func cancelFileImport() {
        guard fileImport != nil else { return }
        fileImport?.cancelling = true
        fileImport?.message = "Cancelling…"
        fileImportControl?.cancel()
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        if let site = siteChip { return site.url(for: typed) }
        if let url = Address.file(from: typed) ?? Address.url(from: typed) { return url }
        if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
           let url = Engine.url(for: rest, template: keyword.template) {
            return url
        }
        return searchURL(for: typed)
    }

    var history: History { Profiles.history(profileID) }

    var active: Tab? { tabs.first { $0.id == activeID } }

    var fieldShowing: Bool { editing || active?.isBlank ?? false }

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) { return offers[picked].key }
        return typed + (ending ?? "")
    }
}
