import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

/// What every window shares: the settings, History, bookmarks, the
/// downloads list and the downloads under way, and hidden elements. Each window's Browser holds only its own tabs and
/// what is drawn over them.
@MainActor
enum Shared {
    static let prefs = Preferences()
    static let loot = Loot()
    static let fetches = Fetches()
}

@MainActor
final class Browser: NSObject, ObservableObject {
    static var activeFileImports: [UUID: ImportFile.Control] = [:]
    static var fileImportTerminating = false

    static func cancelAllFileImports() -> Bool {
        fileImportTerminating = true
        for control in activeFileImports.values { control.cancel() }
        return !activeFileImports.isEmpty
    }

    static var hasActiveFileImports: Bool { !activeFileImports.isEmpty }
    /// With folders, every change to the row ends with it put back in the
    /// order it is shown in (see arrangeFolders): a pin moved or made lands
    /// wherever its own code puts it, and its folder's tabs are then taken
    /// back together. ⌘1–9, ⌃Tab and the extensions' tab indexes read this
    /// row, so it and what is on screen never disagree.
    @Published var tabs: [Tab] = [] {
        didSet {
            arrangeFolders()
            if !selectedTabIDs.isEmpty {
                let valid = selectedTabIDs.intersection(Set(tabs.map(\.id)))
                if valid != selectedTabIDs { selectedTabIDs = valid }
            }
            if let selectionAnchor, !tabs.contains(where: { $0.id == selectionAnchor }) {
                self.selectionAnchor = nil
            }
        }
    }
    /// Tabs picked with Command or Shift. The active page remains where it is.
    @Published private(set) var selectedTabIDs: Set<Tab.ID> = []
    private var selectionAnchor: Tab.ID?
    /// The spaces whose pinned squares, rows and folders are folded away,
    /// leaving only the open tabs. Kept across launches.
    @Published private(set) var pinsFolded: Set<UUID> = Set(
        (Store.settings.stringArray(forKey: "pinsFolded") ?? []).compactMap(UUID.init)
    )
    var pinsHidden: Bool { pinsFolded.contains(spaceID) }
    func togglePins() {
        if !pinsFolded.insert(spaceID).inserted { pinsFolded.remove(spaceID) }
        Store.settings.set(pinsFolded.map(\.uuidString), forKey: "pinsFolded")
    }
    @Published var splits: [TabSplit] = []
    /// The folder whose name is being typed, in place (see FolderRow).
    @Published var editingFolderID: UUID?
    /// An agent's page shown over the tabs' in this window, to watch (see
    /// AgentSide.swift). Going to any tab puts it away.
    @Published var watchingAgent: String?
    /// The tab on screen: none while an agent's page is over it, so its
    /// row isn't drawn as the one you're on, and a click on it goes to it
    /// rather than to its address.
    var shownID: Tab.ID? { watchingAgent == nil ? activeID : nil }
    /// The tab whose sign-in is being offered to the agent (HandoverCard).
    @Published var handingOver: Tab?
    @Published var activeID: Tab.ID? {
        didSet {
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            // A question the page asked while it was in the background.
            if let id = activeID, id != oldValue, let held = heldDialogs.removeValue(forKey: id) {
                DispatchQueue.main.async { held.forEach { $0.present() } }
            }
            guard oldValue != activeID else { return }
            if watchingAgent != nil { watchAgent(nil) }
            if displayTab?.id == oldValue { cancelDisplay() }
            clearTabSelection()
            // What was found belongs to the page just left; the words typed
            // go on to be looked for on this one.
            invalidateFindPage(retryOnActiveTab: true)
            guard let old = oldValue else { return }
            linkStatus.dismiss()
            let left = tabs.first { $0.id == old }
            left?.touch()
            if let pair = splits.first(where: { $0.contains(old) }),
               activeID.map({ !pair.contains($0) }) ?? true,
               let partner = tabs.first(where: { $0.id == pair.partner(of: old) }) {
                partner.touch()
            }
            // The page to come back to, when the pair is chosen again.
            if let id = activeID,
               let index = splits.firstIndex(where: { $0.contains(id) }), splits[index].focused != id {
                splits[index].focused = id
            }
            // The switcher's order and pictures, most recently used first.
            // Focus moving within a pair isn't leaving it; a pair left is
            // one entry, under its first page.
            if let pair = splits.first(where: { $0.contains(old) }) {
                if let id = activeID, pair.contains(id) { return }
                tabSwitcher.cancel()
                if let first = tabs.first(where: { $0.id == pair.left }) {
                    tabSwitcher.left(first, alive: Set((tabs + parkedTabs).map(\.id)))
                }
                return
            }
            tabSwitcher.cancel()
            if let left { tabSwitcher.left(left, alive: Set((tabs + parkedTabs).map(\.id))) }
        }
    }

    var activeSplit: TabSplit? {
        guard let activeID else { return nil }
        return splits.first { $0.contains(activeID) }
    }

    /// The pair a tab is in.
    func split(for tab: Tab) -> TabSplit? {
        return splits.first { $0.contains(tab.id) }
    }

    /// Whether a tab has a place of its own in the row: any tab but a
    /// pair's later pages, which share the first one's.
    func standsInRow(_ tab: Tab) -> Bool {
        split(for: tab).map { $0.left == tab.id } ?? true
    }

    var displayedTabs: [Tab] {
        return tabs.filter { tab in !splits.contains { $0.contains(tab.id) && $0.left != tab.id } }
    }

    var visibleTabIDs: Set<Tab.ID> {
        guard let activeID else { return [] }
        guard let pair = activeSplit else { return [activeID] }
        return Set(pair.tabs)
    }

    /// Whether a pair can stand as it is in a row: all its tabs there, next
    /// to each other in its order, none pinned, of one kind.
    /// A pair kept while Split View was off may have come apart since.
    static func holds(_ pair: TabSplit, in row: [Tab]) -> Bool {
        let places = pair.tabs.compactMap { id in row.firstIndex { $0.id == id } }
        guard pair.tabs.count >= 2, places.count == pair.tabs.count, let first = places.first,
              places == Array(first..<first + places.count) else { return false }
        let members = places.map { row[$0] }
        return members.allSatisfy { tab in
            tab.pin == nil && !tab.bench && tab.shy == members[0].shy
        }
    }

    let tabSwitcher = TabSwitcher()

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Shared.prefs
    let linkStatus = LinkStatus()
    /// Settings, as a card over the page, as it first was: something you
    /// set and put away, not a page to keep open (see ContentView.panels).
    @Published var tuning = false

    // MARK: - bookmarks

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
    /// The dropdown off the button.
    @Published var bookmarksOpen = false
    /// What hangs off the button instead of the list: the card for one
    /// bookmark, its name and folder, as ⇧⌘B opens it.
    @Published var bookmarkCard: Bookmark.ID?

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
    @Published var fileImport: FileImportJob?
    var fileImportControl: ImportFile.Control?

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

    /// ⌘S: the column folded away, and slid out over the page for a look
    /// while it is (see Fold.swift).
    @Published var folded = false
    @Published var peeking = false

    /// The address field, raised over a page by ⌘L. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    @Published var editing = false {
        // The field put away takes its chip with it.
        didSet {
            if !editing, siteChip != nil { siteChip = nil }
            if !editing, launching { launching = false }
        }
    }
    /// True while the field is up over a page for a tab that doesn't exist
    /// yet (Settings › General › New tab in a floating field): Return opens
    /// what was typed in a new tab, and putting the field away leaves the
    /// page you were on as it was.
    @Published var launching = false
    /// The site the list offers to search, for what has been typed so far
    /// (see SiteSearch.swift).
    @Published private(set) var siteOffer: SearchSite?
    /// The site Tab put in the field: what is typed next searches it.
    @Published var siteChip: SearchSite? {
        didSet { if siteChip != oldValue { guess() } }
    }
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    @Published var typed = "" { didSet { guess() } }

    var history: History { Profiles.history(profileID) }
    /// What the field is offering, best first.
    @Published private(set) var offers: [Suggestion] = []
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    @Published private(set) var ending: String?
    /// Which row the arrow keys have walked to, if any.
    @Published var picked: Int?
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published var focusRequest = 0 {
        didSet { focusAsked = CACurrentMediaTime() }
    }
    /// When the field was last asked for the keys and hasn't taken them yet.
    private var focusAsked: CFTimeInterval?
    /// What was typed in that moment, for the field once it has the keys.
    private var heldKeys: [NSEvent] = []

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    @Published var summoning = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var fieldShowing: Bool { editing || active?.isBlank ?? false }

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) { return offers[picked].key }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    @Published var finding = false
    /// The side panel, beside the page (see SidePanel.swift): up or
    /// not, and what is in it.
    @Published var sidePanelShown = false
    @Published var sidePanel: SidePanelContent?
    /// The Settings page it opens on next.
    var settingsPage: SettingsPanel.Page {
        get {
            SettingsPanel.Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general
        }
        set { Store.settings.set(newValue.rawValue, forKey: "settings.page") }
    }
    // The same words written back (the field does, as it appears) aren't
    // a Next: Return and the buttons ask for that themselves.
    @Published var needle = "" {
        didSet { if !resettingFind, oldValue != needle { look(forward: true) } }
    }
    @Published var matchCase = false {
        didSet { if !resettingFind, oldValue != matchCase { look(forward: true) } }
    }
    @Published var wholeWords = false {
        didSet { if !resettingFind, oldValue != wholeWords { look(forward: true) } }
    }
    /// Set when the page doesn't hold what was asked for.
    @Published private(set) var missed = false
    @Published private(set) var findFocus = 0
    /// The count and which match is current, as the page last answered.
    @Published private(set) var findResult: PageFind.Result?

    private let pageFind = PageFind()
    struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }
    var findSpec: FindSpec?
    /// Goes up whenever what is looked for, or the page it is looked for on,
    /// changes: an answer for an older one is dropped.
    private var findGeneration: UInt64 = 0
    /// One question to the page at a time. Letters typed while it answers
    /// wait here, and only the last of them is asked next: on a long page
    /// every letter would otherwise queue a whole search of its own.
    private var findAsking: UInt64?
    private var findAsked: UInt64 = 0
    /// A new search not yet asked, and Next / Previous presses not yet sent.
    private var findFresh = false
    private var findSteps = 0
    private var resettingFind = false
    private weak var findWeb: WKWebView?

    /// A question to the page not answered yet, or one waiting to be asked.
    var findBusy: Bool { findAsking != nil || findFresh || findSteps != 0 }

    var findStatus: String? {
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = findResult else { return nil }
        guard result.available else { return "Search unavailable" }
        if result.nativeFallback {
            if wholeWords && !result.wholeWordsAvailable { return "Whole words unavailable" }
            return result.found ? "Match found" : "No matches"
        }
        guard let index = result.index, let count = result.count, count > 0 else { return "No matches" }
        return "\(index) of \(count)\(result.more ? "+" : "")"
    }

    func openFind() {
        guard active?.isWeb == true else { return }
        finding = true
        findFocus += 1
    }

    func closeFind() {
        guard finding || !needle.isEmpty || findResult != nil else { return }
        // The page's own selection back, and the match's highlight gone.
        resetFindState()
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = active?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let tab = active else {
            missed = false
            findResult = nil
            return
        }

        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missed = false
            findResult = nil
            guard findSpec != nil || findWeb != nil else { return }
            let web = findWeb ?? tab.built
            forgetFind()
            if let web { clearFind(on: web) }
            return
        }

        let web = tab.web
        let spec = FindSpec(tab: tab.id, query: needle, matchCase: matchCase, wholeWords: wholeWords)
        if findSpec != spec || findWeb !== web {
            findGeneration &+= 1
            findSpec = spec
            findWeb = web
            findFresh = true
            findSteps = 0
        } else {
            findSteps += forward ? 1 : -1
        }
        askFind()
    }

    /// Sends what is waiting to the page, unless a question is still out:
    /// its answer sends the next one.
    private func askFind() {
        guard findAsking == nil, let spec = findSpec, let web = findWeb,
              findFresh || findSteps != 0 else { return }
        findAsked &+= 1
        let asking = findAsked
        let generation = findGeneration
        let steps = findSteps
        findAsking = asking
        findFresh = false
        findSteps = 0
        Task { [weak self, weak web] in
            guard let self else { return }
            guard let web, self.activeID == spec.tab, self.active?.built === web else {
                if self.findAsking == asking { self.findAsking = nil }
                return
            }
            let result = await self.pageFind.update(
                on: web,
                query: spec.query,
                matchCase: spec.matchCase,
                wholeWords: spec.wholeWords,
                steps: steps,
                generation: generation
            )
            // Something newer took over while the page was answering.
            guard self.findAsking == asking else { return }
            self.findAsking = nil
            if !result.stale, self.findGeneration == generation, self.findSpec == spec,
               self.activeID == spec.tab, self.active?.built === web {
                self.findResult = result
                self.missed = result.available && !result.found
                    && (!result.nativeFallback || !spec.wholeWords || result.wholeWordsAvailable)
            }
            self.askFind()
        }
    }

    /// Nothing asked or waiting any more; whatever answer is out is dropped.
    private func forgetFind() {
        findGeneration &+= 1
        findSpec = nil
        findWeb = nil
        findAsking = nil
        findFresh = false
        findSteps = 0
    }

    private func clearFind(on web: WKWebView) {
        let generation = findGeneration
        Task { [pageFind] in _ = await pageFind.clear(on: web, generation: generation) }
    }

    private func resetFindState() {
        let web = findWeb
        forgetFind()
        resettingFind = true
        finding = false
        needle = ""
        matchCase = false
        wholeWords = false
        resettingFind = false
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
    }

    /// A tab or document changed under an open find bar. Keep what was typed,
    /// but retire every result and callback tied to the page that just left.
    func invalidateFindPage(retryOnActiveTab: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retryOnActiveTab, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = active, !tab.loading, tab.isWeb else { return }
        look(forward: true)
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        announce("Paused")
    }

    // MARK: - taking things off pages

    /// What is hidden on sites, as the page in front's profile keeps it.
    var curtain: Curtain { Profiles.curtain(active?.profile ?? profileID) }
    let loot = Shared.loot
    /// True while the pointer is picking things to hide.
    @Published private(set) var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, tab.isWeb else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// What a private tab took off its page, kept for that page only.
    private var passingVeils: [Tab.ID: [String]] = [:]

    private func passingCSS(_ id: Tab.ID) -> String {
        (passingVeils[id] ?? []).map { "\n\($0) { display: none !important; }" }.joined()
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        if let tab = active, tab.shy {
            guard var list = passingVeils[tab.id], !list.isEmpty else { return }
            list.removeLast()
            passingVeils[tab.id] = list
            tab.applyVeils(curtain.css(on: hereHost) + passingCSS(tab.id))
            announce("It's back")
            return
        }
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords (the rest in Browser+Passwords.swift)
    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published var offering: Offer?
    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published var suggesting: Suggesting?
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    var lowering: DispatchWorkItem?
    /// The page whose accounts were last looked up for the box the caret is
    /// in. The box reports where it is on every frame of a scroll so the
    /// list can follow it; the keychain is asked once per box, not per frame.
    var looked: (tab: Tab.ID, host: String, clear: Bool, name: Bool)?
    /// The sign-in box the caret is in, for a list that changes while it is
    /// there: the page's passkeys arrive when they arrive.
    var field: (tab: Tab.ID, spot: CGRect, passwords: Bool, name: Bool)?
    /// The list, without secrets: see `Kept` and `Vault.all()`.
    @Published var saved: [Kept] = []
    @Published var hunting = ""
    /// A Remove All… under way, off the main thread (see `forgetShown`).
    @Published var forgetting = false

    // MARK: - what is kept, and getting rid of it

    enum RecallMode {
        case history, clearing
    }

    // One state keeps closing History from leaving its clearing controls open.
    @Published var recallMode: RecallMode?
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
    @Published var recallHunt = ""

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

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        /// Location is also given for this once, and kept only when you say
        /// always; in a private tab it is never kept.
        var once = false
        var keeps = true
        var screen = false
        /// The page also asks for the Mac's own sound with the screen.
        var sound = false
        /// When it came up. A page can time a click to land where Allow is
        /// about to be: the card takes none in its first half second.
        var shown = Date()
        var id: String { host + wants }
    }

    @Published var asking: CaptureAsk?
    var decide: ((WKPermissionDecision) -> Void)?
    /// WebKit's screen-sharing answers: deny (0), screen (1), window (2).
    var decideDisplay: ((Int) -> Void)?
    weak var displayTab: Tab?
    var displayHeld: HeldQuestion?
    var displayRequest: UUID?
    var permissionBusy: Bool { decide != nil || decideDisplay != nil }
    private(set) static var displayAnswered: Int?
    var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func allowCaptureOnce() { answerCapture(.grant, keep: false) }
    func denyCapture() { answerCapture(.deny) }

    func shareScreen() { answerDisplay(1) }
    func shareWindow() { answerDisplay(2) }
    func denyShare() { answerDisplay(0) }

    private func answerDisplay(_ decision: Int) {
        guard decideDisplay != nil, let asking, asking.screen,
              Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        finishDisplay(decision)
    }

    func cancelDisplay(for webView: WKWebView? = nil) {
        guard webView == nil || displayTab?.built === webView else { return }
        finishDisplay(0)
    }

    private func finishDisplay(_ decision: Int) {
        guard let reply = decideDisplay else { return }
        decideDisplay = nil
        displayRequest = nil
        if let tab = displayTab, let held = displayHeld {
            heldDialogs[tab.id]?.removeAll { $0 === held }
        }
        displayHeld = nil
        displayTab = nil
        if asking?.screen == true { asking = nil }
        // A test records the choice without ever opening the system picker.
        if Store.testing { Browser.displayAnswered = decision }
        reply(Store.testing ? 0 : decision)
    }

    /// A page or popup going away must settle its permission callback too,
    /// the screen's included.
    func cancelCapture() {
        cancelDisplay()
        let pending = decide
        decide = nil
        askedAbout = ""
        asking = nil
        pending?(.deny)
    }

    /// A site's camera, microphone, screen or location answer, kept per
    /// profile: what one profile allowed, another still asks about, and a
    /// site can't see in one profile what it was allowed in another and so
    /// tell the two are the same person. Personal's keys are what they
    /// always were.
    ///
    /// Whose answer it is comes from the page's own store, not from the row
    /// on screen: a peek, a little window or a parked space's tab is in no
    /// row, and a private peek once borrowed the space's answer and kept its
    /// own. Nil — nothing read, nothing kept — for a page that keeps nothing,
    /// or whose profile is gone.
    func scoped(_ key: String, for webView: WKWebView) -> String? {
        let store = webView.configuration.websiteDataStore
        guard store.isPersistent, let profile = Profiles.owner(of: store) else { return nil }
        return profile == Profile.personalID ? key : "\(profile.uuidString)|" + key
    }

    private func answerCapture(_ decision: WKPermissionDecision, keep: Bool = true) {
        guard let decide, let asking, Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        // Remembered per site, so a call you take every week asks once.
        if keep, !askedAbout.isEmpty { Store.settings.set(decision == .grant, forKey: "capture." + askedAbout) }
        self.decide = nil
        askedAbout = ""
        self.asking = nil
        decide(decision)
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") || key.hasPrefix(Grounded.prefix) {
            Store.settings.removeObject(forKey: key)
        }
        SiteNotifications.shared.objectWillChange.send()
        announce("Camera, microphone, location and notification choices forgotten")
    }

    /// What was last answered to a page asking where you are, in a test run
    /// — which never goes on to ask the Mac: that would put macOS's own
    /// question on the screen of whoever is working beside it.
    static var locationAnswered: String?

    // MARK: - pinning (the rest in Browser+Pins.swift)
    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }
    /// The pins drawn as squares: those not kept as rows. They come first
    /// among the pins, so a square's place in the grid is its place in the
    /// row.
    var squarePins: [Tab] { tabs.filter { $0.pin != nil && !$0.listed } }

    // MARK: - carried onto the pins, and off them: Browser+Pins.swift

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published private(set) var renamingTab = false
    /// What the field in the tab offers as you type, as ⌘L's does (#534),
    /// and the row the arrow keys are on.
    @Published private(set) var tabOffers: [Suggestion] = []
    @Published private(set) var tabPicked: Int?
    /// The address the edit began with: nothing is offered for that.
    private var tabOriginal = ""

    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.shownURL else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.editable(url)
        tabOriginal = tabDraft
        tabOffers = []
        tabPicked = nil
        editingTab = tab.id
    }

    /// Typed into the field in the tab: its list, and the rest of the
    /// address the field completes to, if any.
    func tabTyped(_ text: String) -> String? {
        tabPicked = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        guard editingTab != nil, !renamingTab, !words.isEmpty, text != tabOriginal else {
            tabOffers = []
            return nil
        }
        let (offers, ending) = placeOffers(for: text)
        tabOffers = offers
        return ending
    }

    /// ↓ and ↑ in the tab's field, off either end and back to what was typed.
    func walkTab(_ step: Int) {
        guard !tabOffers.isEmpty else { return }
        switch tabPicked {
        case nil: tabPicked = step > 0 ? 0 : tabOffers.count - 1
        case let here?:
            let next = here + step
            tabPicked = (next < 0 || next >= tabOffers.count) ? nil : next
        }
    }

    /// A row of the tab's list, clicked or walked to and Return pressed.
    func takeTabOffer(_ offer: Suggestion) {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let open = offer.tab, let other = tabs.first(where: { $0.id == open }) {
            select(other)
        } else {
            tab.go(to: offer.url)
        }
    }

    /// Rename. The name the tab is wearing arrives selected, so typing
    /// replaces it; emptying the field gives the page its own title back.
    func beginTabRename(_ tab: Tab) {
        renamingTab = true
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.name = typed.isEmpty ? nil : typed
            cancelTabEdit()
            writeSession(now: true)
            return
        }
        if let picked = tabPicked, tabOffers.indices.contains(picked) {
            takeTabOffer(tabOffers[picked])
            return
        }
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tabOffers = []
        tabPicked = nil
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        renamingTab = false
        tabDraft = ""
        tabOffers = []
        tabPicked = nil
    }

    /// A click somewhere else — the page, the column below, the rest of the
    /// strip — while a tab's address or name is being edited in the tab: what
    /// was typed is kept, as Return keeps it. An address left as it was loads
    /// nothing again, and a field left empty is let go.
    func finishTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            commitTabEdit()
            return
        }
        let draft = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || tab.address.map({ Address.editable($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?
    /// The file a "Saved …" line is about: clicked, the line shows it in
    /// the Finder, and it stays long enough to be clicked.
    @Published private(set) var announcedFile: URL?
    /// Downloads while they happen (see Fetching.swift).
    let fetches = Shared.fetches

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        guard let url = active?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        announce("Address copied")
    }

    /// ⌥⇧⌘C. The address without its tracking parameters (CleanLink).
    func copyCleanLink() {
        guard let url = active?.address else { return }
        CleanLink.copy(url)
        announce("Clean link copied")
    }

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() {
        guard let tab = active, let url = tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Browser.markdownLink(tab.label, url), forType: .string)
        announce("Link copied")
    }

    /// A page as a Markdown link, its title the text. A backslash first, so
    /// the ones added next aren't doubled; then both brackets, either of
    /// which would end or break the link's text.
    static func markdownLink(_ title: String, _ url: URL) -> String {
        let text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text)](\(url.absoluteString))"
    }

    func announce(_ text: String, file: URL? = nil) {
        announcement = text
        announcedFile = file
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.announcement = nil
            self?.announcedFile = nil
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (file == nil ? 1.7 : 4), execute: work)
    }

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    @Published var ghosts: [Ghost] = []

    /// The ones closed in the profile on screen, the only ones offered back:
    /// an address from one profile — a sign-in link, a document — reopened
    /// in another would be taken there with that one's sign-ins.
    var closedHere: [Ghost] { ghosts.filter { $0.profile == profileID } }

    /// A deleted profile's closed tabs, gone with it.
    func forgetGhosts(of profile: UUID) { ghosts.removeAll { $0.profile == profile } }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        /// When it was closed, to weigh against a window closed since.
        var at = Date()
        /// The other page of the pair it was in, and whether it was on that
        /// page's left: ⇧⌘T puts it back beside it, while that page is alone.
        var partner: Tab.ID? = nil
        var onLeft = false
        /// The tab it was, so a pair closed together finds its other half
        /// again when both come back (see reopen(batch:)).
        var was: Tab.ID? = nil
        /// The Clear it went with: one ⇧⌘T brings back the whole of it.
        var batch: UUID? = nil
        /// Of a Clear's tabs, the one you were on, which comes back in front.
        var front = false
        /// The profile it was signed in as: it comes back only there, never
        /// with another's sign-ins (see closedHere).
        var profile = Profile.personalID

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// The Clear under way, whose tabs are remembered
    /// together (see closingTogether).
    var batching: UUID?
    /// The last Clear, and the empty tab it left in front: an undo takes
    /// that tab away again while it is still empty.
    var lastClear: (batch: UUID, blank: Tab.ID?)?

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Downloads still under way. See `keep(_:)`.
    var downloading: [WKDownload] = []
    /// alert(), confirm() and prompt() from tabs that weren't in front,
    /// waiting for them to be (see Dialogs.swift).
    var heldDialogs: [Tab.ID: [HeldQuestion]] = [:]
    /// Questions asked by a page of the pair on screen, each drawn over its
    /// own page, oldest first (see Dialogs.swift).
    @Published var paneQuestions: [PaneQuestion] = []
    /// What handOff decided, in a test run, for the bench.
    static var handedOff: [String] = []
    /// Downloads from private tabs, which the Downloads list never shows.
    var unlisted: Set<ObjectIdentifier> = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var hush: DispatchWorkItem?
    private var zoomShown = 100
    private var remembering = false
    /// Spaces (see Spaces.swift): every one, the one on screen, and the
    /// rows of tabs of the others.
    @Published var spaces = Spaces.read() {
        didSet {
            Spaces.know(spaces)
            // A space given to another profile: its tabs here reopen signed
            // in as that one (see Tab.rehome).
            let moved = spaces.filter { space in
                oldValue.first { $0.id == space.id }.map { $0.profileID != space.profileID } ?? false
            }
            for space in moved {
                (space.id == spaceID ? tabs : parked[space.id]?.tabs ?? []).forEach { $0.rehome(in: space.id) }
            }
            if !moved.isEmpty { followProfile() }
        }
    }
    @Published var spaceID = Space.firstID
    /// The profile whose history and bookmarks this window passes on.
    private var followed: UUID?
    private var profileBag: Set<AnyCancellable> = []
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    @Published var spaceSwipe: CGFloat = 0
    @Published var makingSpace = false
    /// The profile a space being made starts in (askForSpace).
    var newSpaceProfile: UUID?
    /// A tab being sent into the Space being made from its context menu.
    var afterSpaceCreated: ((Space) -> Void)?
    /// A link's page, peeked at over this one (see Peek.swift).
    @Published var peekTab: Tab?
    /// The tab the peek was opened from: a pin wears the peek's icon while
    /// it is up (see PeekBadge).
    @Published var peekFrom: UUID?
    /// Which way the last change of space went: 1 to the next, -1 back.
    @Published var spaceStep = 1

    // MARK: - beginning and ending

    /// In SwiftUI's own window rather than one made for it (see Windows.swift).
    var inScene = false
    /// Its window, once it has one.
    weak var window: NSWindow? {
        didSet { if window != nil { shut = false } }
    }
    /// Its window closed and kept: the last one, closed with the app running.
    var shut = false {
        didSet { if shut != oldValue { hush(shut) } }
    }

    /// A window closed and kept goes quiet: what was playing in any of its
    /// tabs, every space's, stops; a call loses the camera and microphone;
    /// a video in picture in picture comes back; and nothing plays again
    /// until the window is back. Kept, it was still playing behind a window you had closed.
    private func hush(_ on: Bool) {
        if on {
            unpicture()
            cancelCapture()
        }
        for tab in tabs + parkedTabs {
            guard let web = tab.built else { continue }
            if on {
                web.pauseAllMediaPlayback()
                web.setCameraCaptureState(.none, completionHandler: nil)
                web.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
            web.setAllMediaPlaybackSuspended(on)
        }
    }
    /// Its window is there to be seen — on screen, or behind a hidden app.
    var isOpen: Bool { window != nil && !shut }
    /// Its window fills the screen. macOS takes the window's buttons away
    /// then, so the room kept for them at the top goes too (idea 184).
    @Published var fullScreen = false
    /// The page as a card on the window's ground, the one switch for it
    /// (see CardEdge): with the tabs down the side, unless Settings › Tabs ›
    /// The page as a card is off, and never with the window filling the
    /// screen, where the page goes edge to edge (#607). A page's own video
    /// filling the screen is the window's to add (see ContentView.cards).
    var asCards: Bool { prefs.cards && !fullScreen }
    /// The extension a popup window was opened for (windows.create with
    /// type "popup"), or nil for a browser window. Such a window is small,
    /// the page under a thin line with its site; it is never saved, never
    /// brought back, and never the window menus act on (see Windows.swift).
    var extensionPopup: String?
    /// A sized website pop-up, kept separately from an extension's identity.
    let websitePopup: Bool
    var isPopup: Bool { websitePopup || extensionPopup != nil }
    /// Its saved state, for a window other than the oldest (see Windows.swift).
    var record = WindowRecord()
    /// Whether its rows are the session files' — the oldest window's — or
    /// its own line in windows.json.
    private(set) var usesFiles = false
    /// The first browser does what is done once for the app.
    private static var booted = false

    /// The first window: yesterday's tabs, from the session files.
    override convenience init() { self.init(record: nil) }

    /// `record`: another window's, from windows.json or ⇧⌘T, or a new
    /// window's, empty.
    init(record: WindowRecord?, websitePopup: Bool = false) {
        self.websitePopup = websitePopup
        super.init()
        let first = !Browser.booted
        Browser.booted = true
        // A pop-up window never holds the session files.
        usesFiles = record == nil && !websitePopup
        if first {
            Shield.shared.enabled = prefs.shielded
            Shield.shared.compile()
            if #available(macOS 15.4, *) { Extensions.launch(with: self) }
            #if DEBUG
            if prefs.bench {
                Bench.shared.start(for: self)
            } else if prefs.benchRefused {
                announce("“Let a script drive Shy” was turned on outside Settings, and stays off")
            }
            #endif
            if prefs.agent { Agent.shared.start() }
            FormRelay.passkeysOffered = prefs.passkeys
            // An icon that arrives is looked for again by every tab showing
            // that site, in every window, not only the one that asked for it:
            // each puts on its own page's, or its nearest neighbour's.
            Favicons.arrived = { site in
                let lower = site.lowercased()
                for browser in Browsers.all {
                    for tab in browser.tabs + browser.parkedTabs {
                        guard let tabHost = tab.address.flatMap(Favicons.site) else { continue }
                        if tabHost == lower || tabHost == "www." + lower || lower == "www." + tabHost {
                            tab.adoptIcon()
                        }
                    }
                }
            }
            // What a deleted space left behind, if WebKit wouldn't let it go then.
            Spaces.sweep()
        }
        followProfile()
        // Published before it changes: followed once it has.
        $spaceID
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.followProfile() } }
            .store(in: &bag)

        // A page's passkeys for under its field, arriving while the caret
        // is already there, or going with the page's request.
        NotificationCenter.default.publisher(for: Passkeys.offeredChanged)
            .sink { [weak self] note in
                guard let self, let web = note.object as? WKWebView, let field, let tab = tab(for: web),
                      tab.id == field.tab
                else { return }
                looked = nil
                hang(from: tab, field.spot, passwords: field.passwords, name: field.name)
            }
            .store(in: &bag)

        // So are the pins.
        NotificationCenter.default.publisher(for: Pins.changed)
            .sink { [weak self] note in
                guard let self, !isPopup, (note.object as? Browser) !== self else { return }
                guard let space = note.userInfo?["space"] as? UUID else { return }
                pinsChanged(in: space)
            }
            .store(in: &bag)

        // The spaces are every window's: one renamed, added or taken away in
        // another window is so here too.
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] note in
                guard let self, let list = note.object as? [Space] else { return }
                if websitePopup {
                    if !list.contains(where: { $0.id == self.spaceID }) { window?.close() }
                    return
                }
                guard !isPopup, list != spaces else { return }
                spaces = list
                if !list.contains(where: { $0.id == self.spaceID }) { switchSpace(to: Space.firstID) }
            }
            .store(in: &bag)

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            if !isPopup { watchForSleep() }
            // Before the first frame: tabs whose time ran out while Shy
            // was quit are gone, rather than drawn and taken away a minute on.
            if !isPopup { closeLeftAlone() }
        }

        Spaces.know(spaces)
        if let record {
            // Another window: the space it showed, and its own rows.
            self.record = record
            if spaces.contains(where: { $0.id == record.space }) { spaceID = record.space }
        } else if let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            // The space you were in, when there are spaces (see Spaces.swift).
            spaceID = last
            Spaces.current = last
        }
        // A website pop-up holds only the page WebKit hands over: no pins,
        // restored tabs or warm pages from other spaces.
        guard !websitePopup else { return }
        restoreSession()
        preloadSpaces()
    }

    /// The row of tabs the space on screen had last time, or one empty tab.
    /// The pins are every window's (see Pins.swift): a window new to this
    /// space has them too, before an empty tab.
    func restoreSession() {
        let saved = readRow(spaceID)
        let restored = restoreRow(saved, space: spaceID)
        splits = restored.splits
        tabs += restored.tabs
        // No tab in front (a fresh start, see Session.startFresh): an empty
        // one beside the pins.
        let front = saved.tabs.isEmpty || saved.active < 0 ? nil
            : restored.active.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first { $0.pin == nil } ?? tabs.first
        guard let first = front else {
            frontBlank()
            return
        }
        activeID = first.id
        // Only the one you were looking at actually loads. Started hidden,
        // it waits for the extensions, which load at once then, so that
        // their scripts meant to run before the page's do (#199); a
        // visible launch keeps loading it alongside the first frame.
        if #available(macOS 15.4, *), NSApp.isHidden, Extensions.of(profileID).starting {
            Extensions.of(profileID).whenStarted(within: 1.5) { [weak self] in
                guard let self else { return }
                for tab in self.tabs where self.visibleTabIDs.contains(tab.id) { _ = tab.wake() }
            }
        } else {
            for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
        }
    }

    /// An empty tab at the end of the row, in front: a row with nothing in
    /// front (a fresh start, see Session.startFresh) opens on one, beside its
    /// pins, rather than on the first of them.
    func frontBlank() {
        // A blank tab costs nothing until it is asked for its page. Its
        // web view — and with it WebKit's helper processes — is built a
        // moment after the window is up, so that the first address typed
        // finds everything already running, and the first frame never
        // had to share the CPU with it.
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        adopt(tab)
        activeID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
            guard let tab, tab.isBlank else { return }
            _ = tab.web
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: tabs.compactMap { $0.built?.configuration.userContentController })
                announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        #if DEBUG
        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Shy — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)
        #endif
        prefs.$agent
            .dropFirst()
            .sink { on in if on { Agent.shared.start() } else { Agent.shared.stop() } }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: Profiles.curtain(tab.profile).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInShy(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Every open page that hasn't a size of its own takes the new one.
        // Asleep, a tab has no page to resize; it takes it on waking.
        prefs.$pageZoom
            .dropFirst()
            .sink { [weak self] _ in
                // Published before it is stored; the tabs read the stored one.
                DispatchQueue.main.async {
                    guard let self else { return }
                    for tab in self.tabs + self.parkedTabs where tab.built != nil { tab.applyRememberedZoom() }
                }
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in tabs {
                    tab.arm(hiding: Profiles.curtain(tab.profile).css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // Videos waiting for a click: every tab's next page view follows.
        prefs.$waitsForPlay
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { for tab in self.tabs + self.parkedTabs { tab.playbackChanged() } }
            }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.$autocorrect
            .dropFirst()
            .sink { [weak self] on in
                guard let self, let web = active?.built else { return }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    /// Edit › Substitutions: whether one is on in pages. WebKit keeps a
    /// single answer for every page, so the tab in front's view speaks for
    /// all of them.
    func substitutes(_ kind: Substitution) -> Bool {
        kind.isOn(in: active?.built)
    }

    /// Edit › Substitutions: one switched for every page. Sent to the page's
    /// view rather than to whatever has the keyboard, so the address field
    /// having the caret doesn't make it switch only that field.
    func toggleSubstitution(_ kind: Substitution, in web: WKWebView? = nil) {
        kind.toggle(in: web ?? active?.built ?? (tabs + parkedTabs).lazy.compactMap(\.built).first)
        objectWillChange.send()
    }

    private func relook() {
        Favicons.relook(tabs.filter { !$0.asleep })
    }

    func writeSession(now: Bool = false) {
        guard !isPopup else { return }
        // The pins as they are here, for the other windows (see Pins.swift).
        keepBlocks()
        Pins.set(spaceID, pinDefs(tabs), from: self)
        writeRow(spaceID, session(tabs, active: activeID, splits: splits), now: now)
    }

    // MARK: - pins, the same in every window: Browser+Pins.swift

    // MARK: - this window's rows, wherever they are kept

    /// A space's row as saved: the session files' for the oldest window,
    /// this window's own record for any other.
    func readRow(_ space: UUID) -> Session.Shape {
        usesFiles ? Session.read(space: space) : (record.rows[space.uuidString] ?? Session.Shape(tabs: [], active: 0))
    }

    func writeRow(_ space: UUID, _ shape: Session.Shape, now: Bool) {
        if usesFiles {
            Session.write(now: now, space: space, shape)
        } else {
            record.rows[space.uuidString] = shape
            if now { Browsers.save(now: true) } else { Browsers.saveSoon() }
        }
    }

    /// Every row this window has, by space: the one on screen, the parked
    /// ones, and those saved but not brought up this time.
    func allRows() -> [String: Session.Shape] {
        var rows: [String: Session.Shape] = [:]
        for space in spaces {
            let saved = readRow(space.id)
            if !saved.tabs.isEmpty { rows[space.id.uuidString] = saved }
        }
        rows[spaceID.uuidString] = session(tabs, active: activeID, splits: splits)
        for (space, row) in parked {
            rows[space.uuidString] = session(row.tabs, active: row.active, splits: row.splits)
        }
        return rows
    }

    /// The oldest window closed: this one is the oldest now, and its rows go
    /// into the session files, every space's — an empty row where it has
    /// none, or the closed window's would come back there.
    func becomePrimary() {
        let rows = allRows()
        usesFiles = true
        for space in spaces {
            Session.write(now: true, space: space.id, rows[space.id.uuidString] ?? Session.Shape(tabs: [], active: 0))
        }
        record.rows = [:]
        Store.settings.set(spaceID.uuidString, forKey: "space.current")
        // SwiftUI's window, opened next launch, comes back where this one is.
        window?.saveFrame(usingName: Browsers.sceneID)
    }

    /// Its window closed for good, with others open: every page let go.
    func closeAll() {
        cancelDisplay()
        cancelCapture()
        for questions in heldDialogs.values { questions.forEach { $0.dismiss() } }
        heldDialogs = [:]
        dropQuestions()
        unpicture()
        if peekTab != nil { closePeek() }
        for tab in tabs + parkedTabs { tab.close() }
        parked = [:]
        splits = []
        tabs = []
    }

    func session(_ tabs: [Tab], active id: Tab.ID?, splits: [TabSplit] = []) -> Session.Shape {
        var entries: [Session.Entry] = []
        // A row with nothing in front — a space not yet gone to since a fresh
        // start — stays that way in its file, rather than its first tab (a
        // pin) coming to the front next time.
        var active = id == nil ? -1 : 0
        var indices: [Tab.ID: Int] = [:]
        for tab in tabs {
            guard kept(tab), let url = tab.pending ?? tab.address ?? tab.page?.url else { continue }
            if tab.id == id { active = entries.count }
            indices[tab.id] = entries.count
            entries.append(Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name,
                home: tab.pin == nil ? nil : tab.home?.absoluteString,
                pinID: tab.pin == nil ? nil : tab.pinID,
                // A page on screen is being looked at now, not when it was
                // arrived at: quitting on it is leaving it.
                touched: visibleTabIDs.contains(tab.id) ? Date() : tab.touched,
                letGo: tab.pin == nil ? tab.letGo : nil,
                listed: tab.pin != nil && tab.listed ? true : nil
            ))
        }
        // The tab you were on isn't kept — a private one: the one kept just
        // before it comes back in front, not the first of the row. An empty
        // one stays an empty one, beside the pins (see frontBlank): the tab
        // just before it is the last of the row, often a pin, which then
        // came to the front.
        if let id, let at = tabs.firstIndex(where: { $0.id == id }), indices[id] == nil {
            active = tabs[at].isBlank && !tabs[at].shy ? -1 : max(0, tabs[..<at].filter(kept).count - 1)
        }
        // Only a pair that is whole in the file: one with an empty page, or
        // a private one, isn't written, and its other page comes back alone.
        let savedSplits = splits.compactMap { pair -> Session.Split? in
            let places = pair.tabs.compactMap { indices[$0] }
            guard places.count == pair.tabs.count, places.count >= 2,
                  places == Array(places[0]..<places[0] + places.count) else { return nil }
            return Session.Split(tabs: places, axis: pair.axis, sizes: pair.sizes,
                                 focused: pair.focused.flatMap { indices[$0] })
        }
        return .init(tabs: entries, active: active, splits: savedSplits)
    }

    /// Whether a tab goes into the session: not a private one or the
    /// bench's, and only with a web address. A sleeping view is blank, so
    /// `pending` must win or its page will disappear from the next session.
    private func kept(_ tab: Tab) -> Bool {
        // A tab holding an extension's sign-in answer (Tab.hold) carries its
        // code in the address: that is never written down.
        !tab.shy && !tab.bench && tab.held == nil
            && ((tab.pending ?? tab.address)?.scheme?.hasPrefix("http") == true || tab.page != nil)
    }

    /// Another space's row.
    func writeSession(now: Bool, space: UUID, row: Parked) {
        writeRow(space, session(row.tabs, active: row.active, splits: row.splits), now: now)
    }

    /// The session written a moment from now, for other files.
    func writeSessionSoon() { rememberSession() }

    func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession(now: true)
    }

    // MARK: - tabs: Browser+Tabs.swift

    // MARK: - profiles

    /// The History menu lists what the history holds, and the menu and the
    /// bookmarks are drawn from this object's changes — so the history's and
    /// the bookmarks' of the space's profile are passed on, and another
    /// profile's once the space on screen is in another.
    func followProfile() {
        guard followed != profileID else { return }
        followed = profileID
        profileBag = []
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &profileBag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &profileBag)
        if pageTab(.passwords) != nil { relist() }
        objectWillChange.send()
    }

    /// The profile a tab's page is signed in as: read from its store, so a
    /// page in a small window, a peek or the side panel answers for itself
    /// whatever the window shows now; for a private tab, the space it is in.
    func profile(of tab: Tab) -> UUID {
        if let owner = Profiles.owner(of: tab.store) { return owner }
        if tabs.contains(where: { $0 === tab }) { return profileID }
        let space = parked.first { $0.value.tabs.contains { $0 === tab } }?.key
        return space.flatMap { id in spaces.first { $0.id == id } }?.profileID ?? profileID
    }

    /// The space's menu › Profile: the space, and its tabs, into another.
    func setProfile(_ profile: UUID, of id: UUID) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), spaces[at].profileID != profile else { return }
        var list = spaces
        // Sign-ins of its own stay behind with the profile it leaves: erased
        // now, while the store is still the space's to name (Spaces.erase
        // goes by what the space signs in with), and the space signs in as
        // its new profile does.
        if list[at].sharesSignIns != true, !list[at].isFirst {
            Spaces.erase(id)
            list[at].sharesSignIns = true
        }
        list[at].profile = profile == Profile.personalID ? nil : profile
        spaces = list
        Spaces.write(list)
        announce("\(list[at].name) is in \(Profiles.shared.profile(profile).name)")
    }

    /// The same, asked first: the space's tabs start again signed in as the
    /// other profile, and that is worth a yes.
    func askToMove(_ id: UUID, to profile: UUID) {
        guard let space = spaces.first(where: { $0.id == id }), space.profileID != profile else { return }
        let name = Profiles.shared.profile(profile).name
        let own = space.sharesSignIns != true && !space.isFirst
        Ask.sure("Move “\(space.name)” to “\(name)”?",
                 detail: "Its tabs reload signed in as \(name), with nothing of their old session, and what you do there from now on is kept in \(name)'s history, bookmarks and passwords."
                    + (own ? " The sign-ins this space had of its own are erased." : ""),
                 confirm: "Move") { [weak self] in self?.setProfile(profile, of: id) }
    }

    // MARK: - a tab to another window

    /// The tab's menu: Move to New Window, or to another window. The tab
    /// goes as it is, page and all, into the other window's row after the
    /// tab it's on, in front there; into a space with other sign-ins it
    /// reopens with those, as Move to Space does. Not a pin: pins are
    /// already in every window.
    func moveToWindow(_ tab: Tab, _ target: Browser?, at point: NSPoint? = nil) {
        guard target?.isPopup != true else { return }
        guard tab.pin == nil, !tab.bench, target !== self, tabs.contains(where: { $0.id == tab.id }),
              target != nil || tabs.count > 1 || !tab.isBlank
        else { return }
        let destination = target ?? Browser(record: WindowRecord(space: spaceID))
        detach(tab)
        destination.receive(tab)
        if target == nil {
            // Dragged out: the new window where the tab was let go, its row
            // under the hand.
            let frame = point.map { p -> NSRect in
                let size = window?.frame.size ?? NSSize(width: 1180, height: 780)
                return NSRect(x: p.x - 120, y: p.y - size.height + 20, width: size.width, height: size.height)
            }
            Browsers.open(destination, frame: frame)
        } else {
            destination.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// A tab dragged out of the row and let go outside this window: into
    /// the window it was let go over, or a new one there, as in Chrome and
    /// Safari. False when it was let go over this window, where the drag
    /// keeps its meaning, or can't leave (a pin).
    func dragOut(_ tab: Tab, at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard tab.pin == nil, !tab.bench, let window,
              !window.frame.insetBy(dx: -12, dy: -12).contains(point)
        else { return false }
        let over = Browsers.all.first { $0 !== self && $0.isOpen && !$0.isPopup && $0.window?.frame.contains(point) == true }
        guard over != nil || tabs.count > 1 else { return false }
        // After the drag has let go, not inside it.
        DispatchQueue.main.async { [weak self] in self?.moveToWindow(tab, over, at: point) }
        return true
    }

    /// Out of this row, not closed: it is on its way to another window.
    private func detach(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let web = tab.built { cancelDisplay(for: web) }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)
        if pictured == tab.id { unpicture() }
        if editingTab == tab.id { cancelTabEdit() }
        if activeID == tab.id {
            if let partner {
                select(partner, floatPrevious: false)
            } else if tabs.count > 1 {
                select(tabs[index == tabs.count - 1 ? index - 1 : index + 1], floatPrevious: false)
            } else {
                activeID = nil
            }
        }
        tabs.remove(at: index)
        if tabs.isEmpty { adopt(Tab(configuration: Web.configuration(space: spaceID))) }
        writeSession(now: true)
    }

    /// A tab from another window, in front here. The empty tab a new window
    /// starts with makes way for it.
    func receive(_ tab: Tab) {
        prepare(tab)
        if !tab.shy { tab.rehome(in: spaceID) }
        let blanks = tabs.filter { $0.isBlank && !$0.bench && split(for: $0) == nil }
        tabs.insert(tab, at: placeForNew())
        select(tab, floatPrevious: false)
        if tabs.count - blanks.count == 1 + pinnedCount {
            for blank in blanks { tabs.removeAll { $0 === blank }; blank.close() }
        }
        if let active, active.id == tab.id, tab.asleep { _ = tab.wake() }
        writeSession(now: true)
    }

    /// The row in the order it is shown (see Folders.ordered): run after
    /// every change to the row (see `tabs`), and only with a tab in a
    /// folder to put in its place.
    private func arrangeFolders() {
        guard tabs.contains(where: { $0.folder != nil }) else { return }
        let order = Folders.ordered(tabs, folders: folders)
        // Setting the row runs this again, which then finds nothing to do.
        guard !order.elementsEqual(tabs, by: { $0.id == $1.id }) else { return }
        tabs = order
    }

    /// The folded folder a tab is out of sight in: the outer one if both
    /// are folded. Nil for a tab in none, or in open ones.
    private func foldedAway(_ tab: Tab, in list: [Folder]) -> UUID? {
        guard tab.pin != nil, let id = tab.folder, let folder = list.first(where: { $0.id == id }) else { return nil }
        let outer = folder.parent.flatMap { parent in Folders.tops(list).first { $0.id == parent } }
        if let outer, outer.folded { return outer.id }
        return folder.folded ? folder.id : nil
    }

    /// The tabs as they are on screen: the ones folded away in a folder are
    /// not among them, but for the one in front. Tab cycling and selection
    /// ranges count these; number shortcuts also give folded folders a
    /// place of their own.
    var shownTabs: [Tab] {
        let list = folders
        let front = activeSplit?.left ?? activeID
        return displayedTabs.filter { $0.id == front || foldedAway($0, in: list) == nil }
    }

    /// Number shortcuts count a folded folder once, even while its active tab
    /// is shown below it. Other tab navigation keeps using shownTabs.
    var tabShortcutTargets: [(id: UUID, tab: Tab)] {
        let row = displayedTabs
        let list = folders
        guard !list.isEmpty else { return row.map { ($0.id, $0) } }
        var out: [(id: UUID, tab: Tab)] = []
        var counted = Set<UUID>()
        for tab in row {
            guard let folded = foldedAway(tab, in: list) else {
                out.append((tab.id, tab))
                continue
            }
            guard counted.insert(folded).inserted else { continue }
            let members = row.filter { foldedAway($0, in: list) == folded }
            let current = active.flatMap { now in members.contains { $0.id == now.id } ? now : nil }
            if let tab = current ?? members.max(by: { $0.touched < $1.touched }) { out.append((folded, tab)) }
        }
        return out
    }

    func clearTabSelection() {
        if !selectedTabIDs.isEmpty { selectedTabIDs.removeAll() }
        selectionAnchor = nil
    }

    /// Command toggles one tab; Shift picks the visible run from the last
    /// clicked tab (or the active tab when a selection begins).
    func extendTabSelection(to tab: Tab, modifiers: NSEvent.ModifierFlags) {
        let shown = selectableTabs.map(\.id)
        guard let end = shown.firstIndex(of: tab.id) else { return }
        if modifiers.contains(.shift) {
            let startID = selectionAnchor ?? activeID ?? tab.id
            let start = shown.firstIndex(of: startID) ?? end
            let range = Set(shown[min(start, end)...max(start, end)])
            selectedTabIDs = modifiers.contains(.command) ? selectedTabIDs.union(range) : range
            selectionAnchor = shown[start]
        } else if modifiers.contains(.command) {
            if selectedTabIDs.isEmpty, let active = activeID,
               shown.contains(active) {
                selectedTabIDs.insert(active)
            }
            if !selectedTabIDs.insert(tab.id).inserted { selectedTabIDs.remove(tab.id) }
            selectionAnchor = tab.id
        }
    }

    var selectableTabs: [Tab] {
        shownTabs.flatMap { tab in
            split(for: tab).map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? [tab]
        }
    }

    var visibleSelectedTabCount: Int {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }.count
    }

    var selectedTabLinkCount: Int {
        selectedTabLinks.count
    }

    var selectedTabLinks: [String] {
        selectableTabs.compactMap { tab in
            selectedTabIDs.contains(tab.id) ? tab.address?.absoluteString : nil
        }
    }

    func copySelectedTabLinks() {
        let links = selectedTabLinks
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        announce(links.count == 1 ? "1 address copied" : "\(links.count) addresses copied")
    }

    /// ⌃Tab, ⌃⇧Tab: the next tab on screen, round to the first again. It
    /// walks the whole row from the tab you are on, so it finds its way out
    /// even when that tab is one the row doesn't show.
    func step(_ direction: Int) {
        let shown = Set(shownTabs.map(\.id))
        guard let anchor = activeSplit?.left ?? activeID,
              shown.count > 1 || (shown.count == 1 && !shown.contains(anchor)),
              let here = tabs.firstIndex(where: { $0.id == anchor }) else { return }
        for n in 1..<tabs.count {
            let next = tabs[((here + direction * n) % tabs.count + tabs.count) % tabs.count]
            if shown.contains(next.id) { select(entry(next)); return }
        }
    }

    /// Where a key that picks a place in the row lands: a pair's page that
    /// had the keys last, not always its first.
    private func entry(_ tab: Tab) -> Tab {
        guard let pair = split(for: tab), pair.left == tab.id, let id = pair.focused,
              let focused = tabs.first(where: { $0.id == id }) else { return tab }
        return focused
    }

    /// ⌘1–8: a tab or folded folder in that place, without unfolding it.
    /// The number of the pin you're on takes you back to the tab you were on
    /// before it, as a second press does in Arc.
    func select(index: Int) {
        let targets = tabShortcutTargets
        guard targets.indices.contains(index) else { return }
        let tab = entry(targets[index].tab)
        if tab.pin != nil, activeID == tab.id, let back = tabBefore(tab) {
            select(back)
            return
        }
        select(tab)
    }

    /// The tab last left that is still in the row, other than `tab`.
    func tabBefore(_ tab: Tab) -> Tab? {
        let row = tabs.filter(standsInRow)
        guard let id = tabSwitcher.lastLeft(among: Set(row.map(\.id)), other: tab.id) else { return nil }
        return row.first { $0.id == id }
    }

    /// ⌃Tab: the space's tabs, the most recently used first, and the small
    /// windows beside them. Nothing changes until ⌃ is let go of
    /// (`commitTabSwitch`).
    func switchTabs(backwards: Bool) {
        guard let activeID else { return }
        tabSwitcher.partners = switcherPartners
        tabSwitcher.step(row: tabs.filter(standsInRow).map(\.id), current: activeSplit?.left ?? activeID,
                         backwards: backwards, moons: LittleWindow.stacked)
    }

    /// A pair once, under its first page, pictured with its other one.
    var switcherPartners: [Tab.ID: Tab.ID] {
        Dictionary(splits.map { ($0.left, $0.right) }, uniquingKeysWith: { first, _ in first })
    }

    /// The row as the switcher's grid shows it, for a small window's
    /// switcher to show as its planet (see TabSwitcher.ordered).
    var switcherPlanet: [Tab.ID] {
        tabSwitcher.ordered(row: tabs.filter(standsInRow).map(\.id), current: activeSplit?.left ?? activeID)
    }

    /// A letter pressed on a card while a switcher is up (see
    /// TabSwitcher.Action): the card's tab, or its small window, as its ⌘
    /// key would have it. `switcher` is the one the card is in, this
    /// window's or a small window's.
    func act(_ action: TabSwitcher.Action, onCard id: Tab.ID, in switcher: TabSwitcher) {
        if let little = LittleWindow.holding(id) { return little.act(action, in: switcher) }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // A pair is one card: what's done to it is done to both its pages.
        let partner = switcher.partners[id].flatMap { other in tabs.first { $0.id == other } }
        switch action {
        case .close:
            // A pin not on screen is put down where it is and keeps its
            // card, as ⌘W puts one down, without taking you anywhere.
            if tab.pin != nil, id != activeID, partner == nil {
                tab.rest()
                writeSession(now: true)
                return switcher.redraw()
            }
            switcher.remove(id)
            close(tab)
            if let partner { close(partner) }
        case .reload:
            tab.reload()
            partner?.reload()
        case .mute:
            tab.toggleMute()
            partner?.toggleMute()
            switcher.redraw()
        case .keep:
            break
        }
    }

    /// A tab picked in a small window's switcher: that tab, in this window,
    /// in front. A test run goes to the tab and puts nothing on a screen.
    func bringForward(_ id: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        select(entry(tab))
        guard !Store.testing, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// A click while the switcher is up, at a point in the window's own
    /// top-left coordinates: on a card, that card; outside the panel, the
    /// switcher goes. True when the click was the switcher's. Taken before any
    /// view sees it, because ⌃ is held for as long as the switcher is up, and
    /// a ⌃-click is a right-click to AppKit, not a click the card's button
    /// can be counted on to take. From #358, by oddharsh.
    func clickTabSwitcher(at point: CGPoint) -> Bool {
        tabSwitcher.click(at: point) { commitTabSwitch(picking: $0) }
    }

    func commitTabSwitch(picking id: Tab.ID? = nil) {
        guard let target = tabSwitcher.finish(picking: id) else { return }
        if let tab = tabs.first(where: { $0.id == target }) {
            select(entry(tab))
        } else {
            // A moon: its small window comes forward, and the row stays as
            // it was. Open in Shy is still what moves it in.
            LittleWindow.holding(target)?.front()
        }
    }

    /// A popup has one page; links that need tabs return to its Space.
    var tabDestination: Browser {
        guard websitePopup else { return self }
        let destination = Browsers.ensureWindow()
        destination.switchSpace(to: spaceID)
        return destination
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    ///
    /// `mayWait`: opened behind the page by hand, or one of a batch of links
    /// from another app. With Settings › Tabs › Load background tabs when
    /// you go to them, such a tab keeps its address and loads nothing until
    /// it is gone to, as a tab brought back from the last session does. A
    /// tab in front always loads, and so does one an extension opens, which
    /// may be waiting on its page.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, mayWait: Bool = false) -> Tab {
        if websitePopup {
            return tabDestination.open(url, foreground: foreground, atEnd: atEnd, from: source ?? active, mayWait: mayWait)
        }
        // One of Shy's own pages, from a link, a script or another app:
        // its own tab, one of each (see InternalPages.swift).
        if let own = InternalPage(url: url) { return show(own) }
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        // A new tab is in this window's space, with its sign-ins — not the
        // space of whichever window is in front, when this one is behind it.
        let tab = if let source, source.shy, page == nil {
            Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else {
            Tab(configuration: page ?? Web.configuration(space: spaceID))
        }
        prepare(tab)
        tabs.insert(tab, at: atEnd ? tabs.count : placeForNew())
        if mayWait, !foreground, prefs.lazyTabs, page == nil {
            tab.restore(url: url, title: "")
        } else {
            tab.go(to: url)
        }
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            typed = ""
        }
        return tab
    }

    /// An extension's page sending its own tab to a website — 1Password's
    /// "Sign in" does, when its Mac app isn't connected. The page's view was
    /// built from the extension's configuration, which WebKit keeps to that
    /// extension's own pages, so the load went nowhere and the button did
    /// nothing. The tab is swapped where it stands for an ordinary one on
    /// the site: to the eye, the page went there. The other way round too:
    /// an extension sending a website's tab to one of its own pages.
    func replace(_ tab: Tab, going url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's
        // store, so going back to the web takes a new private one.
        let page = Browser.extensionConfiguration(for: url)
        let fresh = if tab.shy {
            Tab(shy: true, bench: tab.bench, configuration: page
                ?? Web.configuration(shy: true, store: tab.store.isPersistent ? nil : tab.store))
        } else {
            Tab(bench: tab.bench, configuration: page ?? Web.configuration(space: spaceID))
        }
        // Preserve the sign-in popup's link to the page that opened it —
        // and, since a website can now start the swap, what you made of the
        // tab: a pinned one stays pinned, a named one keeps its name.
        fresh.opener = tab.opener
        fresh.popup = tab.popup
        fresh.pin = tab.pin
        fresh.listed = tab.listed
        fresh.folder = tab.folder
        fresh.name = tab.name
        prepare(fresh)
        let wasActive = activeID == tab.id
        replaceSplitMember(tab.id, with: fresh.id)
        tabs[index] = fresh
        fresh.go(to: url)
        if wasActive { activeID = fresh.id }
        tab.close()
        rememberSession()
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.current(url) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    #if DEBUG
    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours. `shy`: a private one, for a test run.
    @discardableResult
    func benchOpen(_ url: URL, shy: Bool = false) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(shy: shy, bench: true, configuration: shy ? nil : Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }
    #endif

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// A bookmark, from the bar, the Bookmarks menu or a list of them: in a
    /// tab of its own, never in place of the one you are on (Drice: opened
    /// from a pin, it took the pin's place). An empty new tab is the one
    /// exception, since nothing is lost by using it. With ⌘ it opens behind.
    func openBookmark(_ url: URL) {
        let behind = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if !behind, let active, active.isBlank || active.page?.kind == .bookmarks, active.pin == nil {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: !behind, from: active, mayWait: behind)
        }
    }

    /// A bookmark picked from the button's list or the full one. Either
    /// goes as the page starts: the list off the button used to stay open
    /// over the page it had just sent you to. A middle-click opens it in a
    /// new tab behind this one and leaves the list open for the next; with
    /// ⇧ it goes to the new tab, and the list closes.
    func pickBookmark(_ url: URL, inNewTab: Bool = false) {
        let foreground = !inNewTab || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if foreground {
            // From the Bookmarks tab, the bookmark opens in it, as Chrome's
            // manager does; Back comes back to the list.
            bookmarksOpen = false
        }
        if inNewTab {
            open(url, foreground: foreground, from: active, mayWait: true)
        } else {
            openBookmark(url)
        }
    }

    /// A page in a new tab, paired with the one on screen as a tab's Open in
    /// Split View pairs it. Used, for one, by the bookmarks bar's Open in
    /// Split View.
    func openInSplit(_ url: URL) {
        openInSplit(open(url, foreground: false, from: active))
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        if watchingAgent != nil { watchAgent(nil) }
        if websitePopup { tabDestination.newShyTab(); return }
        // Never two empty private tabs, as ⌘T never makes two empty ones:
        // one already open is moved to the chosen position.
        if let blank = tabs.last(where: { $0.isBlank && $0.shy && !$0.bench && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            return
        }
        let tab = Tab(shy: true)
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        announce("A tab that keeps nothing")
    }

    /// ⌘D. The same page, beside itself.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true, from: active)
    }

    /// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
    /// place — or a search — in the tab you're on.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// File › Export as PDF…. Unlike Print, this keeps the page's screen
    /// layout and takes its whole current length. WebKit splits only a page
    /// taller than a PDF page can be (200 inches).
    func exportPDF() {
        guard let tab = active, tab.isWeb, let window = tab.web.window ?? self.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (title.isEmpty ? tab.pageAddress?.host() ?? "Page" : title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = stem.lowercased().hasSuffix(".pdf") ? stem : stem + ".pdf"
        panel.directoryURL = downloadsFolder
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let file = panel.url else { return }
            self?.exportPDF(tab, to: file)
        }
    }

    /// Keep the tab the save panel was opened for, even if another is active
    /// when it finishes. The bench passes the current tab without a panel.
    func exportPDF(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            do {
                let data = try result.get()
                try data.write(to: file, options: .atomic)
                self?.announce("Saved \(file.lastPathComponent)", file: file)
                finished?(true)
            } catch {
                self?.announce("Couldn't export page")
                finished?(false)
            }
        }
    }

    /// ⌘P. The system's print sheet, where a paginated PDF can also be saved.
    func printPage() {
        guard let tab = active, tab.isWeb, let window = NSApp.keyWindow else { return }
        Browser.printing(tab.web).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job for a page, or for one frame of it when WebKit names
    /// one: a page's own print() in a frame prints that frame, as in Safari.
    /// The frame's printing is outside the public framework, so it is asked
    /// for first, and a WebKit without it prints the whole page.
    static func printing(_ web: WKWebView, frame: AnyObject? = nil) -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: forFrame) {
            typealias Make = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation
            job = unsafeBitCast(web.method(for: forFrame), to: Make.self)(web, forFrame, info, frame)
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        return job
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        let saved = readRow(space)
        var restored = restoreRow(saved, space: space)
        // As restoreSession has it: nothing in front after a fresh start, so
        // the space opens on an empty tab beside its pins (see enter); and a
        // tab whose place no longer reads falls to the first that isn't a pin.
        if saved.active < 0 {
            restored.active = nil
        } else if restored.active == nil {
            restored.active = restored.tabs.first { $0.pin == nil }?.id ?? restored.tabs.first?.id
        }
        return restored
    }

    private func restoreRow(_ saved: Session.Shape, space: UUID) -> Parked {
        // Tab groups, from a session written before folders, made folders.
        let saved = foldGroups(saved, space: space)
        var row: [Tab] = []
        var bySavedIndex: [Int: Tab] = [:]
        for (savedIndex, entry) in saved.tabs.enumerated() {
            // An empty page is never written; the first builds of Split View
            // on main wrote one for an empty half.
            guard let saved = URL(string: entry.url), entry.url != "about:blank" else { continue }
            // A row read from disk is a browser or window opened afresh: a
            // pin comes back at the page it was pinned at, wherever it had
            // been taken since.
            let home = Browser.home(of: entry, at: saved)
            let url = home ?? saved
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: url == saved ? entry.title : url.host ?? "", name: entry.name)
            // Never later than now: a clock set wrong once would keep the tab forever.
            if let touched = entry.touched { tab.touch(at: min(touched, Date())) }
            tab.letGo = entry.letGo.map { min($0, Date()) }
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.listed = entry.pin != nil && entry.listed == true
            tab.home = home
            row.append(tab)
            bySavedIndex[savedIndex] = tab
        }
        let said = bySavedIndex[saved.active]?.id
        row = reconcilePins(row, space: space)
        // Pairs: each tab in one pair at most, and only a pair that still
        // holds.
        var restoredSplits: [TabSplit] = []
        var taken = Set<Tab.ID>()
        for saved in saved.splits {
            let members = saved.tabs.compactMap { bySavedIndex[$0] }
            guard members.count == saved.tabs.count, !members.contains(where: { taken.contains($0.id) }) else { continue }
            let pair = TabSplit(tabs: members.map(\.id), axis: saved.axis, sizes: saved.sizes,
                                focused: saved.focused.flatMap { bySavedIndex[$0]?.id })
            guard Browser.holds(pair, in: row) else { continue }
            restoredSplits.append(pair)
            taken.formUnion(pair.tabs)
        }
        let active = said.flatMap { id in row.contains { $0.id == id } ? id : nil }
        return Parked(tabs: row, active: active, splits: restoredSplits)
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own.
    /// `blank`: with nothing in front, an empty tab is, rather than the
    /// first of the row (see frontBlank).
    func showRow(_ row: [Tab], active: Tab.ID?, splits restored: [TabSplit] = [], blank: Bool = false) {
        splits = restored
        tabs = row
        if active == nil, blank { return frontBlank() }
        activeID = active ?? row.first?.id
    }

    func replaceSplitMember(_ old: Tab.ID, with new: Tab.ID) {
        guard let index = splits.firstIndex(where: { $0.contains(old) }) else { return }
        splits[index].replace(old, with: new)
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        if prefs.newTabPlace == .top { return pinnedCount }
        if prefs.newTabPlace == .end { return tabs.count }
        guard let here = tabs.firstIndex(where: { $0.id == activeID }) else { return tabs.count }
        let after = activeSplit.flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? here
        return max(after + 1, pinnedCount)
    }

    /// Where ⌘T's tab goes, a private one, and a page a link opens in front
    /// of you: the end of the row, as always, unless the top was chosen.
    /// After current is for links opened from the tab you are on.
    func placeForFront() -> Int {
        prefs.newTabPlace == .top ? pinnedCount : tabs.count
    }

    func placeBlank(_ tab: Tab) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let to = placeForFront()
        // Moving an existing tab removes its old slot before inserting it.
        move(tab, to: from < to ? to - 1 : to)
    }

    /// A tab made outside the row — a peek being kept — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: safeInsertionIndex(index))
        rememberSession()
    }

    func safeInsertionIndex(_ proposed: Int) -> Int {
        let index = min(max(0, proposed), tabs.count)
        guard index < tabs.count, split(for: tabs[index]).map({ $0.left != tabs[index].id }) == true else { return index }
        return index + 1
    }

    func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    func leaving() {
        guard prefs.floatsOnLeave else { return }
        picture(active, quietly: true, otherwise: otherPane)
    }

    /// With a pair on screen, its other page: what goes when the focused
    /// one has nothing playing.
    private var otherPane: Tab? {
        guard let pair = activeSplit, let id = activeID else { return nil }
        return tabs.first { $0.id == pair.partner(of: id) }
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Shy
    /// comes back.
    private var liftedAway = false

    func appLeft() {
        guard prefs.floatsAway, Browsers.front == nil || Browsers.front === self else { return }
        liftedAway = pictured == nil
        picture(active, quietly: true, otherwise: otherPane)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = pictured, id == activeID { unpicture() }
    }

    /// ⌘⇧P, for sending one by hand, or bringing it back.
    func toggleFloat() {
        picture(active, quietly: false, toggle: true, otherwise: otherPane)
    }

    /// The tab whose video Shy last sent to macOS's picture in picture, to
    /// bring back when you return to it.
    var pictured: Tab.ID?

    /// The video playing in `tab` into picture in picture (NativePiP).
    /// `toggle`: ⇧⌘P, which also brings one back.
    private func picture(_ tab: Tab?, quietly: Bool, toggle: Bool = false, otherwise: Tab? = nil) {
        guard let tab, !tab.isBlank, !tab.asleep, tab.web.fullscreenState == .notInFullscreen else {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map({ Grounded.holds($0, in: tab.profile) }) == true {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        tab.web.evaluateInShy(NativePiP.script(toggle: toggle)) { [weak self, weak tab] answer in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                switch answer as? String {
                case "in": self.pictured = tab.id
                case "out": if self.pictured == tab.id { self.pictured = nil }
                case "refused": if !quietly { self.announce("This page keeps its video to itself") }
                default:
                    if let otherwise { return self.picture(otherwise, quietly: quietly, toggle: toggle) }
                    if !quietly { self.announce("Nothing is playing here") }
                }
            }
        }
    }

    /// Back into its tab, from macOS's picture in picture.
    func unpicture() {
        guard let id = pictured else { return }
        pictured = nil
        // Its tab may be parked in another space by now.
        (tabs + parkedTabs).first { $0.id == id }?.web.evaluateInShy(NativePiP.off)
    }

    func prepare(_ tab: Tab) {
        tab.delegate = self
        // With two pages up, the keys going to the other one — Tab walked
        // past the last field of this one — make it the focused page, so the
        // outline, ⌘L and the site card follow what is being typed into.
        tab.onKeys = { [weak self] tab in
            guard let self, let pair = activeSplit, pair.contains(tab.id), activeID != tab.id else { return }
            focusPane(tab)
        }
        tab.onLink = { [weak self] tab, address in
            guard let self, visibleTabIDs.contains(tab.id) else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            let curtain = Profiles.curtain(tab.profile)
            // A private tab writes nothing down, hidden.json included: taken
            // off this page only.
            if tab.shy {
                passingVeils[tab.id, default: []].append(selector)
                tab.applyVeils(curtain.css(on: host) + passingCSS(tab.id))
                announce("Hidden on this page — ⌘Z puts it back")
                return
            }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden — ⌘Z puts it back")
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.searchName = { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        // The middle button on a link opens it beside the tab you are on, as
        // it does in every other browser (see MiddleRelay).
        // From a private tab, the new one is private too, as for ⌘-click.
        tab.onMiddleClick = { [weak self] tab, url in self?.openClicked(url, foreground: false, from: tab, view: tab.built) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }
        tab.onFileLink = { [weak self] tab, url, blank in
            if blank { self?.open(url, foreground: true, from: tab) } else { tab.go(to: url) }
        }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot, passwords, name in
            self?.hang(from: tab, spot, passwords: passwords, name: name)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            // an extension's own page isn't a site: Bitwarden's unlock pin was offered as its password.
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host, in: self.profile(of: tab)), tab.address.flatMap(Browser.extensionHost(of:)) == nil
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.of(profileID).passwordSavingTakenBy != nil { return }
            let profile = self.profile(of: tab)
            let known = Vault.kept(for: host, in: profile)
            // Nothing to ask about one that is already known. Only that
            // account's secret is read, not every one kept for the site.
            if var same = known.first(where: { $0.user == user }).flatMap(Vault.login), same.password == password {
                // Where it was last used is where it is offered from now on.
                same.clear = clear
                Vault.touch(same)
                return
            }
            let offer = Offer(
                login: Login(host: host, user: user, password: password, used: nil, clear: clear, profile: profile),
                changed: known.contains { $0.user == user }
            )
            guard offering != offer else { return }
            offering = offer
        }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.announce("Couldn't hide that — \(reason)")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession() }
            .store(in: &bag)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                // A translated title is the page's in your words, not its own:
                // history keeps the page's (Translate.swift).
                guard let tab, !tab.shy, tab.translator == nil, let url = tab.address else { return }
                guard let self else { return }
                Profiles.history(profile(of: tab)).retitle(url, title)
            }
            .store(in: &bag)
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    /// A key typed between ⌘T and the field taking the keys, kept for it.
    ///
    /// The field comes a turn or two of the run loop after it is asked for —
    /// later still with Split View, where it waits for the stage to say where
    /// the page is — and a hand already typing got there first: the first
    /// letter or two went to the page being left, or nowhere. Held for half
    /// a second at most, and only typing: a key with ⌘ or ⌃ is a shortcut.
    func holdKey(_ event: NSEvent) -> Bool {
        guard let asked = focusAsked, CACurrentMediaTime() - asked < 0.5,
              fieldShowing, editingTab == nil,
              event.modifierFlags.intersection([.command, .control]).isEmpty
        else { return false }
        if heldKeys.isEmpty {
            // The field never came: what was typed goes where it would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.heldKeys.isEmpty else { return }
                self.focusAsked = nil
                self.letGo(in: event.window)
            }
        }
        heldKeys.append(event)
        return true
    }

    /// The field has the keys: what was held goes to it, in order.
    func fieldFocused(in window: NSWindow) {
        focusAsked = nil
        letGo(in: window)
    }

    private func letGo(in window: NSWindow?) {
        let held = heldKeys
        heldKeys = []
        // Straight to the window, which hands a key to whatever has the
        // keys: not back through the app, whose monitor would hold it again.
        for event in held { window?.sendEvent(event) }
    }

    // MARK: - guessing

    /// ⌘K again, with ⌘ still down: one step further down the list.
    func stepSummon() {
        cycling = true
        walk(1)
    }

    /// ⌘ let go of: take whatever the walk landed on.
    func landSummon() {
        guard cycling else { return }
        cycling = false
        guard picked != nil else { return }
        submit()
    }

    /// ⌘K. Only what is open, nothing else.
    func summon() {
        reviewing = false
        cancelTabEdit()
        launching = false
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    private func guess() {
        // Only a plain field asks the engine (see askEngine, at the end).
        if summoning || siteChip != nil || typed.trimmingCharacters(in: .whitespaces).isEmpty {
            suggester.stop()
            engineWords = ("", [])
        }
        guard !summoning else {
            offers = openPages(matching: typed)
            ending = nil
            // The most recent page is already chosen, so ⌘K then Return is the
            // whole gesture.
            picked = offers.isEmpty ? nil : 0
            return
        }

        // A site in the field: only its search, for what is typed after it.
        if let site = siteChip {
            siteOffer = nil
            ending = nil
            picked = nil
            let words = typed.trimmingCharacters(in: .whitespaces)
            offers = words.isEmpty ? [] : site.url(for: words).map {
                [Suggestion(key: words, title: site.name, url: $0, kind: .search)]
            } ?? []
            return
        }

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            picked = nil
            siteOffer = nil
            return
        }
        // "red": Reddit's search, a Tab away.
        let site = !summoning ? SiteSearch.match(typed, in: profileID) : nil
        if siteOffer != site { siteOffer = site }

        (offers, ending) = placeOffers(for: typed)
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
        askEngine()
    }

    // MARK: - the engine's suggestions

    /// Asks the engine for the words it would suggest, when Settings ›
    /// General › Suggestions from your search engine is on and these words
    /// may leave the Mac (EngineSuggest.sendable). What it said for the
    /// words before stays, those that still fit, until it answers these:
    /// rows that came and went with every key would be a list nobody could
    /// read.
    let suggester = EngineSuggester()
    /// The engine's last words, and what they answered.
    private var engineWords: (asked: String, words: [String]) = ("", [])

    /// The question this field may ask the engine, or nil when it may not:
    /// the switch off, a private tab, ⌘K, a site or a shortcut in charge,
    /// or words that look like anything but a search.
    func engineQuestion(for typed: String) -> URL? {
        guard prefs.engineSuggests, !summoning, siteChip == nil, active?.shy != true,
              EngineSuggest.sendable(typed),
              Keyword.match(typed, in: prefs.keywords) == nil
        else { return nil }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineSuggest.url(for: words, engine: prefs.engine, test: EngineSuggest.testEndpoint)
    }

    private func askEngine() {
        guard let question = engineQuestion(for: typed) else {
            suggester.stop()
            engineWords = ("", [])
            return
        }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Until the answer: last time's words that still begin with these.
        let lower = words.lowercased()
        let places = Set(offers.map { $0.key.lowercased() })
        let still = engineWords.words.filter {
            $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && !places.contains($0.lowercased())
        }
        if !still.isEmpty { offers += engineOffers(still) }
        suggester.ask(question, words: words) { [weak self] answer in
            guard let self else { return }
            // Typed on since, or the field gone: nothing to answer.
            guard self.typed.trimmingCharacters(in: .whitespacesAndNewlines) == words,
                  self.fieldShowing, self.engineQuestion(for: self.typed) != nil
            else { return }
            let mine = self.offers.filter { $0.kind != .suggested }
            // A row of the engine's that the arrow keys are on stays put.
            if let picked = self.picked, picked >= mine.count { return }
            self.engineWords = (words, answer)
            let places = Set(mine.map { $0.key.lowercased() })
            self.offers = mine + self.engineOffers(answer.filter { !places.contains($0.lowercased()) })
        }
    }

    private func engineOffers(_ words: [String]) -> [Suggestion] {
        words.prefix(EngineSuggest.most).compactMap { word in
            searchURL(for: word).map { Suggestion(key: word, title: "", url: $0, kind: .suggested) }
        }
    }

    /// What an address field offers for what is typed in it, and the rest of
    /// the address it would complete to: ⌘L's field and the one in the tab
    /// ask the same question (#534).
    func placeOffers(for typed: String) -> (offers: [Suggestion], ending: String?) {
        // Three places and, if it can't be a place, a search. No open pages:
        // ⌘K exists for those, and mixing them in here made the list long
        // enough that reading it cost more than typing the address would have.
        var list = history.suggestions(for: typed, limit: 3)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty, Address.url(from: typed) == nil {
            if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
               let asked = Engine.url(for: rest, template: keyword.template) {
                list.append(Suggestion(key: typed, title: keyword.name, url: asked, kind: .search))
            } else if let asked = searchURL(for: typed) {
                list.append(
                    Suggestion(key: typed, title: prefs.engine.name(custom: prefs.customEngine), url: asked, kind: .search)
                )
            }
        }
        // First, not last: typing "settings" to reach Settings is the whole
        // point, and it would otherwise sit under a search for the word.
        let command = AddressCommand.matching(typed, in: self)
        if let command { list.insert(.command(command), at: 0) }
        // Neither a page already open nor a command has an address to
        // complete towards. And with a command on top, Return runs it: a
        // grey ending in the field ("history" finishing as history.com)
        // would promise a place Return doesn't go to.
        let ending = command != nil ? nil
            : history.completion(for: typed, among: list.filter { $0.kind != .open && !$0.kind.isCommand })
        return (list, ending)
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. On an empty field this is the whole point of the summon: it is
    /// the tab strip, except you read it only when you ask for it.
    private func openPages(matching typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return tabs
            .filter { $0.id != activeID && !$0.isBlank }
            .filter { tab in
                guard !needle.isEmpty else { return true }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return tab.label.lowercased().contains(needle) || address.contains(needle)
            }
            .sorted { $0.touched > $1.touched }
            .prefix(needle.isEmpty ? 6 : 3)
            .compactMap { tab in
                guard let url = tab.address else { return nil }
                return Suggestion(
                    key: tab.label,
                    title: Address.pretty(url),
                    url: url,
                    kind: .open,
                    tab: tab.id
                )
            }
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion) {
        summoning = false
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            select(tab)
        } else if launching {
            open(offer.url, foreground: true, from: active)
        } else {
            (active ?? tabs.first)?.go(to: offer.url)
        }
        editing = false
        typed = ""
        picked = nil
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// Tab with a site offered: the site goes into the field as a chip, and
    /// what was typed to name it is let go. True when it did.
    func lockSiteOffer() -> Bool {
        guard siteChip == nil, let site = siteOffer else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        guard !offers.isEmpty else { return }
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    // MARK: - the address field

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        // ⌘L in an empty window: a new tab, its field ready.
        guard active != nil || activeSplit != nil else { return newTab() }
        summoning = false
        launching = false
        // Never a name and password written into the address: they would be
        // on screen, and in whatever you copy from here.
        typed = active?.shownURL.map { url -> String in
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil
            else { return url.absoluteString }
            parts.user = nil
            parts.password = nil
            return parts.string ?? ""
        } ?? ""
        editing = true
        focusRequest += 1
    }

    func dismiss() {
        summoning = false
        cycling = false
        // The floating new tab was never a tab: nothing is left behind.
        if launching {
            launching = false
            siteChip = nil
            editing = false
            typed = ""
            return
        }
        // Esc with a site in the field: the site goes, the field stays.
        if siteChip != nil {
            siteChip = nil
            return
        }
        // Esc on the empty page of a pair: the page isn't wanted after all.
        if let tab = active, tab.isBlank, split(for: tab) != nil {
            editing = false
            typed = ""
            close(tab)
            return
        }
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    ///
    /// `aside`: ⌘Return, as in Safari. The place opens in a new tab and the
    /// tab you were on is left as it was, behind it unless `front` (⇧⌘Return)
    /// asks to go there.
    func submit(aside: Bool = false, front: Bool = false) {
        // A page already open is switched to, not opened again.
        if let picked, offers.indices.contains(picked),
           let id = offers[picked].tab,
           let tab = tabs.first(where: { $0.id == id }) {
            summoning = false
            // From the empty page of a pair: that tab comes into the pair.
            if let blank = active, blank.isBlank, split(for: blank) != nil, !aside,
               tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true {
                fill(blank, with: tab)
                return
            }
            select(tab)
            editing = false
            typed = ""
            return
        }

        // The switcher proposes nothing but pages you have open. It still has
        // to accept an address typed into it, though — the two fields look
        // alike, and a Return that quietly does nothing is the worst answer
        // either of them could give.
        if summoning {
            summoning = false
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                editing = false
                return
            }
        }

        // The row the arrow keys chose, or else the top one: a command is
        // only ever on top, and there it is what Return does. Walked past,
        // Return goes where it always went.
        let chosen = (picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }) ?? offers.first
        if case .command(let command) = chosen?.kind {
            command.run(on: self)
            editing = false
            typed = ""
            picked = nil
            return
        }

        let target: URL?
        if let picked, offers.indices.contains(picked) {
            target = offers[picked].url
        } else if ending != nil {
            target = Address.url(from: completed)
        } else {
            target = destination(for: typed)
        }

        guard let url = target else {
            refusals += 1
            return
        }
        // shy://settings and the rest: the page's own tab, one of each.
        if let page = InternalPage(url: url) {
            show(page)
            picked = nil
            return
        }
        if launching, !aside {
            // The floating new tab: what was typed gets a tab of its own, and
            // the page the field was raised over stays as it was.
            open(url, foreground: true, from: active)
        } else if aside {
            // Opened behind the page by hand, as a ⌘-clicked link is: it may
            // wait to load (Settings › Tabs › Load background tabs…).
            open(url, foreground: front, from: active, mayWait: true)
        } else if let active {
            active.go(to: url)
        } else {
            // From the empty window: a tab of its own.
            open(url, foreground: true)
        }
        editing = false
        typed = ""
    }

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.announce("Nothing to read on this page")
        }
    }

    func reload(fromOrigin: Bool = false) { active?.reload(fromOrigin: fromOrigin) }
    func back() { active?.back() }
    func forward() { active?.forward() }
}

// MARK: - Shy's own pages, in tabs (see InternalPages.swift)

extension Browser {
    /// The tab in this window's row showing that kind of page, if any.
    func pageTab(_ kind: InternalPage.Kind) -> Tab? {
        tabs.first { $0.page?.kind == kind }
    }

    /// ⌘, ⌘Y ⇧⌘J and the menus: the page's tab, brought forward if it is
    /// open, made otherwise. An empty tab in front becomes the page rather
    /// than being left behind it; a private one doesn't — these pages are
    /// never private, as Chrome's settings never open in an incognito
    /// window — and the page opens beside it.
    @discardableResult
    func show(_ page: InternalPage) -> Tab {
        // A pop-up window holds its one page: Shy's own open beside it.
        if websitePopup { return tabDestination.show(page) }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page(rawValue: detail) {
            settingsPage = section
        }
        // Settings is the card, not a tab, wherever it is asked for from.
        if page.kind == .settings, let active {
            tuning = true
            return active
        }
        if page.kind == .passwords { relist() }
        if page.kind == .history, pageTab(.history) == nil { recallMode = .history }
        let tab: Tab
        if let open = pageTab(page.kind) {
            tab = open
            // Asked for another section, or another browser to bring
            // things from: the open tab moves there, without a step back.
            if page.detail != nil, open.page != page {
                open.show(page, stepping: false)
                objectWillChange.send()
            }
        } else {
            if let blank = active, blank.isBlank, !blank.shy, !blank.bench, blank.pin == nil,
               blank.draft.isEmpty, typed.isEmpty {
                tab = blank
            } else {
                tab = Tab(configuration: Web.configuration(space: spaceID))
                prepare(tab)
                tabs.insert(tab, at: placeForNew())
            }
            tab.show(page)
        }
        if launching { dismiss() }
        summoning = false
        editing = false
        typed = ""
        if activeID != tab.id { select(tab) }
        writeSessionSoon()
        return tab
    }

    /// From one of these pages to another — Settings' "Passwords…", Bring
    /// Things Over's "Show bookmarks": the same tab goes there, and Back
    /// comes back, as a link would. Unless that page is already open in a
    /// tab of its own, which is then the one shown.
    func lead(to page: InternalPage) {
        guard page.kind != .settings, let here = active, here.page != nil, pageTab(page.kind) == nil else {
            show(page)
            return
        }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page(rawValue: detail) {
            settingsPage = section
        }
        here.show(page)
        writeSessionSoon()
    }

    /// The page's tab closed, as ⌘W would close it. For the bench, and the
    /// last few callers that put a panel away.
    func putAway(_ kind: InternalPage.Kind) {
        if kind == .settings { tuning = false }
        guard let tab = pageTab(kind) else { return }
        close(tab)
    }

    /// Settings moved to another of its sections: the tab's address says
    /// so, and comes back there after a relaunch.
    func settingsMoved(to section: SettingsPanel.Page) {
        guard let tab = pageTab(.settings), tab.page?.detail != section.rawValue else { return }
        tab.show(InternalPage(.settings, section.rawValue), stepping: false)
        writeSessionSoon()
    }
}
