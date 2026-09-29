import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

/// What every window shares: the settings, History, bookmarks, the
/// downloads list and the downloads under way, hidden elements, and the
/// one floating video. Each window's Browser holds only its own tabs and
/// what is drawn over them.
@MainActor
enum Shared {
    static let prefs = Preferences()
    static let bookmarks = Bookmarks()
    static let history = History()
    static let curtain = Curtain()
    static let loot = Loot()
    static let floater = Float()
    static let fetches = Fetches()
}

@MainActor
final class Browser: NSObject, ObservableObject {
    private static var activeFileImports: [UUID: ImportFile.Control] = [:]
    private static var fileImportTerminating = false

    static func cancelAllFileImports() -> Bool {
        fileImportTerminating = true
        for control in activeFileImports.values { control.cancel() }
        return !activeFileImports.isEmpty
    }

    static var hasActiveFileImports: Bool { !activeFileImports.isEmpty }
    /// With groups on, every change to the row ends with it put back in the
    /// order it is shown in (see arrangeGroupedTabs): a tab made by a link,
    /// Peek, the little window or Move to Space lands wherever its own code
    /// puts it, and is then taken to its group or out of the groups' way.
    /// ⌘1–9, ⌃Tab and the extensions' tab indexes read this row, so it and
    /// what is on screen never disagree.
    @Published private(set) var tabs: [Tab] = [] {
        didSet { arrangeGroupedTabs() }
    }
    @Published private(set) var splits: [TabSplit] = []
    /// Named tab sections in the current space, in display order.
    @Published var tabGroups: [TabGroup] = []
    @Published var editingGroupID: UUID?
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
            // What was found belongs to the page just left; the words typed
            // go on to be looked for on this one.
            invalidateFindPage(retryOnActiveTab: true)
            guard let old = oldValue else { return }
            linkStatus.dismiss()
            let left = tabs.first { $0.id == old }
            left?.touch()
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }),
               activeID.map({ !pair.contains($0) }) ?? true,
               let partner = tabs.first(where: { $0.id == pair.partner(of: old) }) {
                partner.touch()
            }
            // The page to come back to, when the pair is chosen again.
            if prefs.splitView, let id = activeID,
               let index = splits.firstIndex(where: { $0.contains(id) }), splits[index].focused != id {
                splits[index].focused = id
            }
            // The switcher's order and pictures, most recently used first.
            // Focus moving within a pair isn't leaving it; a pair left is
            // one entry, under its first page.
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }) {
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
        guard prefs.splitView, let activeID else { return nil }
        return splits.first { $0.contains(activeID) }
    }

    /// The pair a tab is in, while Split View is on. Turned off, pairs are
    /// kept, as groups are, and nothing acts on them until it is back on.
    func split(for tab: Tab) -> TabSplit? {
        guard prefs.splitView else { return nil }
        return splits.first { $0.contains(tab.id) }
    }

    /// Whether a tab has a place of its own in the row: any tab but a
    /// pair's later pages, which share the first one's.
    func standsInRow(_ tab: Tab) -> Bool {
        split(for: tab).map { $0.left == tab.id } ?? true
    }

    var displayedTabs: [Tab] {
        guard prefs.splitView else { return tabs }
        return tabs.filter { tab in !splits.contains { $0.contains(tab.id) && $0.left != tab.id } }
    }

    var visibleTabIDs: Set<Tab.ID> {
        guard let activeID else { return [] }
        guard let pair = activeSplit else { return [activeID] }
        return Set(pair.tabs)
    }

    /// Whether a pair can stand as it is in a row: all its tabs there, next
    /// to each other in its order, none pinned, of one kind and one group.
    /// A pair kept while Split View was off may have come apart since.
    static func holds(_ pair: TabSplit, in row: [Tab]) -> Bool {
        let places = pair.tabs.compactMap { id in row.firstIndex { $0.id == id } }
        guard pair.tabs.count >= 2, places.count == pair.tabs.count, let first = places.first,
              places == Array(first..<first + places.count) else { return false }
        let members = places.map { row[$0] }
        return members.allSatisfy { tab in
            tab.pin == nil && !tab.bench && tab.shy == members[0].shy && tab.groupID == members[0].groupID
        }
    }

    let tabSwitcher = TabSwitcher()

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Shared.prefs
    let linkStatus = LinkStatus()
    /// The settings panel.
    @Published var tuning = false
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false
    /// What's new, once after an update (see WhatsNew.swift).
    @Published var newsShowing = false
    /// Every version's notes: Settings › About › What's New…
    @Published var notesShowing = false

    // MARK: - bookmarks

    let bookmarks = Shared.bookmarks
    /// The full list, for taking things out.
    @Published var bookmarking = false
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

    /// Another browser's bookmarks, folders and all — one profile's, or
    /// every profile's when nil — and, behind them, the icons it had for
    /// those sites, so the menu wears them from the start instead of a
    /// letter each. Returns how many pages came over, and how many were
    /// here already. `replacing`: what came from this browser before —
    /// as recorded, nothing guessed — is taken out first, and these come
    /// fresh in its place.
    ///
    /// Only when every profile read cleanly: a file that didn't read is not
    /// an empty browser, and taking out what came before for it lost
    /// bookmarks for good (#375). Then what came before stays, what could be
    /// read is added as usual, and `kept` says so.
    @discardableResult
    func takeBookmarks(from source: ImportSource, profile: String? = nil, replacing: Bool = false) -> (added: Int, already: Int, kept: Bool) {
        let read = source.bookmarkRead(profile: profile)
        let found = read.nodes
        var kept = false
        if replacing, let earlier = ImportRecords.of(source.name), !earlier.bookmarkIDs.isEmpty {
            if read.complete {
                bookmarks.withdraw(earlier.bookmarkIDs)
                ImportRecords.forgetBookmarks(source.name)
            } else {
                kept = true
            }
        }
        let (count, already, ids) = bookmarks.takeNoting(found, from: source.name)
        ImportRecords.note(source.name, bookmarks: ids, bookmarks: count)
        announce(
            kept ? "Couldn't read all of \(source.name)'s bookmarks: what came from it before was kept"
                : Bookmarks.count(found) == 0 ? "No bookmarks in \(source.name)"
                : count == 0 ? "The bookmarks from \(source.name) were all here already"
                : already == 0 ? "\(count) bookmarks from \(source.name)"
                : "\(count) new bookmarks from \(source.name), \(already) already here"
        )
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return (count, already, kept)
    }

    /// The "Bring things over" sheet, open while set: the browser it
    /// starts on by name, or "" for the first one found.
    @Published var bringingIn: String?
    struct FileImportJob: Identifiable {
        let id: UUID
        let filename: String
        var message: String
        var completed = 0
        var total: Int?
        var cancelling = false
    }
    @Published private(set) var fileImport: FileImportJob?
    private var fileImportControl: ImportFile.Control?

    func cancelFileImport() {
        guard fileImport != nil else { return }
        fileImport?.cancelling = true
        fileImport?.message = "Cancelling…"
        fileImportControl?.cancel()
    }
    /// The sheet opened from Settings › Extensions: only the extensions
    /// ticked, on a browser that has some. Read once as it opens.
    var bringingExtensions = false

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.glide) { prefs.sidebar.toggle() }
    }

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        if let site = siteChip { return site.url(for: typed) }
        if let url = Address.url(from: typed) { return url }
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
        didSet { if !editing, siteChip != nil { siteChip = nil } }
    }
    /// The site the list offers to search, for what has been typed so far
    /// (Settings › General › Search a site from the address field).
    @Published private(set) var siteOffer: SearchSite?
    /// The site Tab put in the field: what is typed next searches it.
    @Published var siteChip: SearchSite? {
        didSet { if siteChip != oldValue { guess() } }
    }
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    @Published var typed = "" { didSet { guess() } }

    let history = Shared.history
    /// What the field is offering, best first.
    @Published private(set) var offers: [Suggestion] = []
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    @Published private(set) var ending: String?
    /// Which row the arrow keys have walked to, if any.
    @Published var picked: Int?
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published private(set) var focusRequest = 0

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    @Published private(set) var summoning = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var fieldShowing: Bool { editing || active?.isBlank ?? true }

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) { return offers[picked].key }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    @Published var finding = false
    /// The AI panel's conversation about the page, while it is open.
    @Published var assisting: Assistant?
    /// The Settings page it opens on next.
    var settingsPage: SettingsPanel.Page {
        get { SettingsPanel.Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general }
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
    private struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }
    private var findSpec: FindSpec?
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
        guard active?.isBlank == false else { return }
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
    private func invalidateFindPage(retryOnActiveTab: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retryOnActiveTab, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = active, !tab.loading, !tab.isBlank else { return }
        look(forward: true)
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        announce("Paused")
    }

    // MARK: - taking things off pages

    let curtain = Shared.curtain
    let loot = Shared.loot
    let floater = Shared.floater
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
        guard let tab = active, !tab.isBlank else { return }
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

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published private(set) var offering: Offer?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published private(set) var suggesting: Suggesting?

    struct Suggesting: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        let logins: [Login]
        /// The Mac's passkeys for a page waiting for one under its field.
        var passkeys: [Passkeys.Offered] = []
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
        /// When it came up. A page can put the caret in a sign-in box
        /// itself, an invisible one under the pointer included: a click that
        /// was already on its way is not a choice, so the list takes none for
        /// its first half second, as Chrome's does.
        var shown = Date()
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    private var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    private var lowering: DispatchWorkItem?
    /// The page whose accounts were last looked up for the box the caret is
    /// in. The box reports where it is on every frame of a scroll so the
    /// list can follow it; the keychain is asked once per box, not per frame.
    private var looked: (tab: Tab.ID, host: String, clear: Bool)?
    /// The sign-in box the caret is in, for a list that changes while it is
    /// there: the page's passkeys arrive when they arrive.
    private var field: (tab: Tab.ID, spot: CGRect, passwords: Bool)?

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// The caret in a sign-in box: the accounts kept for this site, and the
    /// Mac's passkeys for a page waiting for one, hang from the box, and go
    /// when the caret does. Nothing is filled on its own — the way Safari
    /// does it, and what a person expects.
    private func hang(from tab: Tab, _ spot: CGRect?, passwords: Bool) {
        guard let spot else {
            if field?.tab == tab.id { field = nil }
            if looked?.tab == tab.id { looked = nil }
            if pickedInto == tab.id { pickedInto = nil }
            guard suggesting?.tab == tab.id else { return }
            lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, suggesting?.tab == tab.id else { return }
                suggesting = nil
            }
            lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        lowering?.cancel()
        field = (tab.id, spot, passwords)
        guard tab.id == activeID, pickedInto != tab.id,
              let host = curtain.host(of: tab.pageAddress)
        else { return }
        // A page that came over plain http can have been written by
        // anyone on the way here — a café's network, a hotel's. It is
        // offered only what was kept from plain http too, never an
        // account kept from the https site of the same name.
        let inTheClear = tab.pageAddress?.scheme?.lowercased() == "http"
        // The same box, moved by a scroll: the list up follows it, keeping
        // its accounts and the moment it came up (a click is refused for
        // its first half second, which every frame used to start again);
        // a box with no accounts stays without, and the keychain isn't
        // asked again until the caret leaves.
        if let looked, looked.tab == tab.id, looked.host == host, looked.clear == inTheClear {
            if var up = suggesting, up.tab == tab.id, up.spot != spot {
                up.spot = spot
                suggesting = up
            }
            return
        }
        looked = (tab.id, host, inTheClear)
        // Passwords only for a box that goes with one: a box for passkeys
        // alone has no password to put anywhere.
        let known = prefs.fillsPasswords && passwords
            ? Array(Vault.logins(matching: host).filter { !inTheClear || $0.clear }.prefix(5)) : []
        let passkeys = Passkeys.shared.offered(in: tab.built)
        guard !known.isEmpty || !passkeys.isEmpty else {
            suggesting = nil
            return
        }
        // What is under the pointer changed: the half second starts again.
        if let up = suggesting, up.tab == tab.id, up.logins == known, up.passkeys == passkeys {
            suggesting?.spot = spot
            return
        }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: known, passkeys: passkeys, host: host, clear: inTheClear)
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Login) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }) else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        tab.fill(user: login.user, password: login.password) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the sign-in fields anymore") }
        }
        Vault.touch(login)
    }

    /// One of the passkeys in the list: the Mac's sheet for it, and the
    /// page's request answered with it.
    func choose(_ passkey: Passkeys.Offered) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let web = tab.built else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        Passkeys.shared.sign(in: web, with: passkey.id)
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    @Published var managing = false { didSet { if managing { relist() } } }
    /// The list, without secrets: see `Kept` and `Vault.all()`.
    @Published private(set) var saved: [Kept] = []
    @Published var hunting = ""

    struct SiteRow {
        let host: String
        let logins: [Kept]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all() }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce("Kept for \(host)")
    }

    func forget(_ login: Kept) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Kept) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            // Read here, once the Mac has said who this is: what the panel
            // drew its list from holds no secrets.
            guard let password = Vault.secret(of: login) else {
                self.announce("The keychain refused it")
                return
            }
            let board = NSPasteboard.general
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(password, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if board.changeCount == copied { board.clearContents() }
            }
            announce("Password copied")
        }
    }

    /// What came back from another browser's store, put in the keychain,
    /// with the sites it was told never to ask about. Saving one already
    /// kept updates it, so bringing the same in again adds nothing twice.
    /// Returns how many were kept.
    func keep(_ found: Chromium.Found) -> Int {
        var kept = 0
        for login in found.logins
        where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
            kept += 1
        }
        var never = Vault.never
        found.never.forEach { never.insert($0) }
        Vault.never = never
        relist()
        return kept
    }

    /// The same, said as it lands.
    func took(_ outcome: Result<Chromium.Found, Error>, from name: String) {
        switch outcome {
        case .success(let found):
            let kept = keep(found)
            ImportRecords.note(name, passwords: kept)
            announce(kept == 0 ? "Nothing new in \(name)" : "\(kept) passwords from \(name)")
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(name) didn't give up its keychain key")
        case .failure(Mozilla.Trouble.primaryPassword):
            announce("\(name) has a primary password — export your passwords from it (Settings › Passwords › ⋯ › Export) and bring in the CSV file")
        case .failure:
            announce("Nothing readable in \(name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: ImportSource, profile: String? = nil, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = source.places(profile: profile)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                ImportRecords.note(source.name, places: places.count)
                done(places.count)
            }
        }
    }

    /// Something another browser exported: a bookmarks page, a passwords
    /// file, or Safari's own export (see ImportFile). Read once, never copied.
    func importFile() {
        guard fileImport == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText, .zip, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bring In"
        panel.message = "A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { announce((await takeFile(url)).said) }
    }

    /// The file's bookmarks, history and passwords, taken in as a browser's
    /// are: bookmarks merged without doubles, history counted once. Says
    /// what came in, and after Safari's export, that the file holds your
    /// passwords in the clear.
    struct FileTake {
        let said: String
        let bookmarks: Int
        let already: Int
        let places: Int
        let kept: Int
        let skipped: Int
        let cancelled: Bool
    }

    @discardableResult
    func takeFile(_ url: URL) async -> FileTake {
        guard !Browser.fileImportTerminating, fileImport == nil else { return FileTake(said: "An import is already running", bookmarks: 0, already: 0, places: 0, kept: 0, skipped: 0, cancelled: false) }
        let id = UUID()
        fileImport = FileImportJob(id: id, filename: url.lastPathComponent, message: "Reading…")
        let control = ImportFile.Control { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileImport?.id == id, self.fileImport?.cancelling == false else { return }
                self.fileImport?.message = progress.message
                self.fileImport?.completed = progress.completed
                self.fileImport?.total = progress.total
            }
        }
        fileImportControl = control
        Browser.activeFileImports[id] = control
        defer {
            Browser.activeFileImports[id] = nil
            if fileImport?.id == id { fileImport = nil; fileImportControl = nil }
        }
        var added = 0, already = 0, places = 0, kept = 0, skipped = 0
        var safari = false
        var failed = false
        var mergedBookmarks = false
        do {
            let found: ImportFile.Found = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ImportFile.read(url, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            safari = found.fromSafari
            try control.checkCancellation()
            let name = found.fromSafari ? "Safari" : url.deletingPathExtension().lastPathComponent
            if !found.bookmarks.isEmpty {
                fileImport?.message = "Merging bookmarks…"
                fileImport?.completed = 0
                fileImport?.total = nil
                let result = try await bookmarks.takeFile(found.bookmarks, from: name, control: control)
                mergedBookmarks = true
                added = result.added
                already = result.already
            }
            if !found.places.isEmpty {
                fileImport?.message = "Adding history…"
                fileImport?.completed = 0
                fileImport?.total = found.places.count
                for batch in stride(from: 0, to: found.places.count, by: 200) {
                    guard !control.isCancelled else { break }
                    let end = min(batch + 200, found.places.count)
                    for place in found.places[batch..<end] {
                        history.take(place.url, title: place.title, count: place.count, last: place.last)
                        places += 1
                    }
                    fileImport?.completed = places
                    fileImport?.total = found.places.count
                    await Task.yield()
                }
                if places > 0 { history.settle() }
            }
            if !found.passwords.isEmpty && !control.isCancelled {
                fileImport?.message = "Saving passwords…"
                fileImport?.completed = 0
                fileImport?.total = nil
                for text in found.passwords {
                    guard !control.isCancelled else { break }
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Vault.take(csv: text, control: control))
                        }
                    }
                    kept += result.kept
                    skipped += result.skipped
                }
            }
        } catch {
            failed = !control.isCancelled
        }
        if kept > 0 || skipped > 0 {
            saved = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Vault.all())
                }
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if added > 0 || already > 0 {
            parts.append(already == 0 ? count(added, "bookmark", "bookmarks") : "\(count(added, "new bookmark", "new bookmarks")), \(already) already here")
        }
        if places > 0 { parts.append(count(places, "place", "places")) }
        if kept > 0 || skipped > 0 {
            parts.append(skipped == 0 ? count(kept, "password", "passwords") : "\(count(kept, "password", "passwords")), \(skipped) skipped")
        }
        var said = parts.joined(separator: " · ")
        if control.isCancelled {
            said = said.isEmpty ? (mergedBookmarks ? "Import cancelled after merging bookmarks" : "Import cancelled; nothing was changed") : "Import cancelled after " + said
        }
        else if failed { said = said.isEmpty ? "That file couldn't be read" : "Import stopped after " + said }
        else if said.isEmpty { said = mergedBookmarks ? "Bookmark folders imported" : "Nothing to bring in from that file" }
        if safari, kept > 0 {
            said += " — the exported file holds your passwords in the clear: delete it now"
        }
        return FileTake(said: said, bookmarks: added, already: already, places: places, kept: kept, skipped: skipped, cancelled: control.isCancelled)
    }

    // MARK: - what is kept, and getting rid of it

    enum RecallMode {
        case history, clearing
    }

    // One state keeps closing History from leaving its clearing controls open.
    @Published var recallMode: RecallMode?
    var recalling: Bool {
        get { recallMode != nil }
        set { recallMode = newValue ? .history : nil }
    }
    @Published var hoarding = false
    @Published var recallHunt = ""

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
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
        announce("Cache cleared")
    }

    func clearHistory() {
        history.forget()
        // The sites' icons are a list of where you have been, too, and so
        // are the searches learned from sites visited (SiteSearch.swift).
        Favicons.shared.forgetAll()
        SiteSearch.forget()
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
        /// When it came up. A page can time a click to land where Allow is
        /// about to be: the card takes none in its first half second.
        var shown = Date()
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func allowCaptureOnce() { answerCapture(.grant, keep: false) }
    func denyCapture() { answerCapture(.deny) }

    private func answerCapture(_ decision: WKPermissionDecision, keep: Bool = true) {
        guard let decide, let asking, Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        // Remembered per site, so a call you take every week asks once.
        if keep, !askedAbout.isEmpty { Store.settings.set(decision == .grant, forKey: "capture." + askedAbout) }
        decide(decision)
        self.decide = nil
        askedAbout = ""
        self.asking = nil
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
    private(set) static var locationAnswered: String?

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    @Published var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    /// The pins drawn as squares: those not kept as rows, and every pin
    /// while the rows are off. They come first among the pins, so a
    /// square's place in the grid is its place in the row.
    var squarePins: [Tab] { tabs.filter { $0.pin != nil && !($0.listed && prefs.showsPinRows) } }
    /// The pins kept as rows, under the squares (see Tab.listed). None
    /// while the rows are off: they are drawn as squares then.
    var listedPins: [Tab] { prefs.showsPinRows ? tabs.filter { $0.pin != nil && $0.listed } : [] }

    /// `listed`: as a row under the squares rather than as a square.
    func pin(_ tab: Tab, listed: Bool = false) {
        // Drawn again even when the tab stays where it is (see unpin).
        objectWillChange.send()
        // Pins are the space's, kept on disk and shown in every window: a
        // private tab can't be one, or its page would outlive it there.
        guard !tab.shy else { return }
        detachSplit(tab)
        if tab.pin == nil {
            let previousGroup = tab.groupID
            tab.groupID = nil
            removeEmptyGroup(previousGroup)
            tab.pin = tab.monogram
            tab.home = tab.pending ?? tab.address
            // Pinned tabs live at the head of the row, in the order they were
            // pinned, so their letters never move under your hand: a square
            // after the squares, a row after the rows.
            tab.listed = listed
            settlePin(tab)
        }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
    }

    /// A square made a row, or a row a square: it keeps its letter, its
    /// page and its home, and moves to the nearer end of its new kind (the
    /// top of the rows, or the end of the squares), so it travels no
    /// further than the line between them.
    func setListed(_ tab: Tab, _ listed: Bool) {
        guard tab.pin != nil, tab.listed != listed else { return }
        objectWillChange.send()
        if editingPin == tab.id { editingPin = nil }
        tab.listed = listed
        settlePin(tab, first: listed)
        writeSession(now: true)
    }

    /// A pin put in its place: the squares, then the rows, then everything
    /// else. `first`: at the head of its kind rather than the end.
    private func settlePin(_ tab: Tab, first: Bool = false) {
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        var row = tabs
        row.remove(at: here)
        let squares = row.filter { $0.pin != nil && !$0.listed }.count
        let pins = row.filter { $0.pin != nil }.count
        row.insert(tab, at: tab.listed ? (first ? squares : pins) : squares)
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
    }

    /// The squares ahead of the rows, each kind in its own order. Pins
    /// only; everything else is left as it is.
    static func tiered(_ pins: [Tab]) -> [Tab] {
        pins.filter { !$0.listed } + pins.filter(\.listed)
    }

    /// A pin's page, from the session: the one it was pinned at, or — for a
    /// pin from before pins kept theirs — where it was when it came back.
    static func home(of entry: Session.Entry, at url: URL) -> URL? {
        guard entry.pin != nil else { return nil }
        return entry.home.flatMap(URL.init(string:)) ?? url
    }

    /// A double-click on the pin you are on: back to the page it was pinned
    /// at, as a pin in Arc goes home (#141). Already there, the double-click
    /// changes its letter, as it always did.
    func goHome(_ tab: Tab) {
        guard tab.pin != nil else { return }
        guard let home = tab.home, !Browser.samePage(home, tab.address) else { return editLetter(tab) }
        tab.go(to: home)
        rememberSession()
    }

    /// The same page, give or take a trailing slash.
    static func samePage(_ one: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        func bare(_ url: URL) -> String {
            var text = url.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return bare(one) == bare(other)
    }

    /// Change Letter, or a double-click on the square itself.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was — a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        tab.pin = String(first).uppercased()
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        // The row is drawn again whether or not the tab moves. Unpinning the
        // only tab, or the last pin, leaves it where it is; `tabs` didn't
        // change, only the tab did, and the column went on drawing it as a
        // pinned square — with no letter left, an empty tile — and never as
        // a row (from X).
        objectWillChange.send()
        tab.pin = nil
        tab.listed = false
        tab.home = nil
        tab.pinID = nil
        defer { writeSession(now: true) }
        // Back out of the pinned block, to the head of the loose tabs.
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = pinnedCount
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        rememberSession()
    }

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published private(set) var renamingTab = false

    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.address else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.editable(url)
        editingTab = tab.id
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
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        renamingTab = false
        tabDraft = ""
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

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() {
        guard let tab = active, let url = tab.address else { return }
        // A backslash first, so the ones added next aren't doubled; then both
        // brackets, either of which would end or break the link's text.
        let title = tab.label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(url.absoluteString))", forType: .string)
        announce("Link copied")
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
    @Published private(set) var ghosts: [Ghost] = []

    /// Groups closed with Close Group, kept while a tab they held can still
    /// come back with ⌘⇧T: the first one back brings its group back too,
    /// named as it was and where it was among the others.
    private var closedGroups: [UUID: (group: TabGroup, at: Int)] = [:]

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        let groupID: UUID?
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

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// The Clear under way, whose tabs are remembered together.
    private var clearing: UUID?
    /// The last Clear, and the empty tab it left in front: an undo takes
    /// that tab away again while it is still empty.
    private var lastClear: (batch: UUID, blank: Tab.ID?)?

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
        didSet { Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id)) }
    }
    @Published var spaceID = Space.firstID
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    @Published var spaceSwipe: CGFloat = 0
    @Published var makingSpace = false
    /// A tab being sent into the Space being made from its context menu.
    var afterSpaceCreated: ((Space) -> Void)?
    /// A link's page, peeked at over this one (see Peek.swift).
    @Published var peekTab: Tab?
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
    var shut = false
    /// Its window is there to be seen — on screen, or behind a hidden app.
    var isOpen: Bool { window != nil && !shut }
    /// Its window fills the screen. macOS takes the window's buttons away
    /// then, so the room kept for them at the top goes too (idea 184).
    @Published var fullScreen = false
    /// The extension a popup window was opened for (windows.create with
    /// type "popup"), or nil for a browser window. Such a window is small,
    /// the page under a thin line with its site; it is never saved, never
    /// brought back, and never the window menus act on (see Windows.swift).
    var extensionPopup: String?
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
    init(record: WindowRecord?) {
        super.init()
        let first = !Browser.booted
        Browser.booted = true
        usesFiles = record == nil
        if first {
            Shield.shared.enabled = prefs.shielded
            Shield.shared.compile()
            if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
            if prefs.bench {
                Bench.shared.start(for: self)
            } else if prefs.benchRefused {
                announce("“Let a script drive Search” was turned on outside Settings, and stays off")
            }
            welcoming = !prefs.welcomed
            newsShowing = WhatsNew.due(prefs: prefs, welcoming: welcoming)
            // Once a day, quietly: is there a newer one?
            Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
            FormRelay.passkeysOffered = prefs.passkeys
            // An icon that arrives is put on every tab showing that site, in
            // every window, not only the one that happened to ask for it.
            Favicons.shared.arrived = { site, image in
                let lower = site.lowercased()
                for browser in Browsers.all {
                    for tab in browser.tabs + browser.parkedTabs {
                        guard let tabHost = tab.address.flatMap(Favicons.site) else { continue }
                        if tabHost == lower || tabHost == "www." + lower || lower == "www." + tabHost {
                            tab.icon = image
                        }
                    }
                }
            }
            // What a deleted space left behind, if WebKit wouldn't let it go then.
            Spaces.sweep()
        }
        // Asked to stay out of the way: it starts that way (see Fold.swift).
        folded = prefs.sidebar && prefs.sideHides

        // The History menu lists what the history holds, and the menu is drawn
        // from this object's changes — so the history's are passed on.
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // A page's passkeys for under its field, arriving while the caret
        // is already there, or going with the page's request.
        NotificationCenter.default.publisher(for: Passkeys.offeredChanged)
            .sink { [weak self] note in
                guard let self, let web = note.object as? WKWebView, let field, let tab = tab(for: web),
                      tab.id == field.tab
                else { return }
                looked = nil
                hang(from: tab, field.spot, passwords: field.passwords)
            }
            .store(in: &bag)

        // So are the pins.
        NotificationCenter.default.publisher(for: Pins.changed)
            .sink { [weak self] note in
                guard let self, (note.object as? Browser) !== self, let space = note.userInfo?["space"] as? UUID else { return }
                pinsChanged(in: space)
            }
            .store(in: &bag)

        // The spaces are every window's: one renamed, added or taken away in
        // another window is so here too.
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] note in
                guard let self, let list = note.object as? [Space], list != spaces else { return }
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
            watchForSleep()
        }

        Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))
        if let record {
            // Another window: the space it showed, and its own rows.
            self.record = record
            if prefs.usesSpaces, spaces.contains(where: { $0.id == record.space }) { spaceID = record.space }
        } else if prefs.usesSpaces, let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            // The space you were in, when there are spaces (see Spaces.swift).
            spaceID = last
            Spaces.current = last
        }
        restoreSession()
        if prefs.usesSpaces { preloadSpaces() }
    }

    /// The floating video's buttons answer the window whose video it is:
    /// set as it comes out of one (see lift).
    private func ownFloater() {
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came, let tab = self.tabs.first(where: { $0.id == came }) {
                self.select(tab)
            }
            // Never a test run's: a probe started hidden stays off every screen.
            guard !Store.testing else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.where_) { found in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.toggle) { playing in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onClose = { [weak self] in self?.land() }
    }

    /// The row of tabs the space on screen had last time, or one empty tab.
    /// The pins are every window's (see Pins.swift): a window new to this
    /// space has them too, before an empty tab.
    func restoreSession() {
        let saved = readRow(spaceID)
        tabGroups = (saved.groups ?? []).filter { group in
            saved.tabs.contains { $0.groupID == group.id }
        }
        let restored = restoreRow(saved, space: spaceID, groups: tabGroups)
        splits = restored.splits
        tabs += restored.tabs
        // No tab in front (a fresh start, see Session.startFresh): an empty
        // one beside the pins.
        let front = saved.tabs.isEmpty || saved.active < 0 ? nil
            : restored.active.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first { $0.pin == nil } ?? tabs.first
        guard let first = front else {
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
            return
        }
        activeID = first.id
        // Only the one you were looking at actually loads. Started hidden,
        // it waits for the extensions, which load at once then, so that
        // their scripts meant to run before the page's do (#199); a
        // visible launch keeps loading it alongside the first frame.
        if #available(macOS 15.4, *), NSApp.isHidden, Extensions.shared.starting {
            Extensions.shared.whenStarted(within: 1.5) { [weak self] in
                guard let self else { return }
                for tab in self.tabs where self.visibleTabIDs.contains(tab.id) { _ = tab.wake() }
            }
        } else {
            for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.$usesSpaces
            .dropFirst()
            .sink { [weak self] on in if on { self?.preloadSpaces() } else { self?.leaveSpaces() } }
            .store(in: &bag)
        prefs.$usesTabGroups
            .dropFirst()
            .sink { [weak self] on in
                guard let self, on else { return }
                // Sent before the setting changes, so it is passed on.
                arrangeGroupedTabs(on)
                writeSession(now: true)
            }
            .store(in: &bag)
        prefs.$splitView
            .dropFirst()
            .sink { [weak self] on in
                // Off, the pairs stay, as groups do; back on, the ones that
                // came apart meanwhile go. The others' files are looked at
                // when their spaces come back (see restoreRow).
                guard let self else { return }
                // Off, no page is drawn over on its own: what a page asked
                // is answered as dismissed rather than left unanswered.
                guard on else { return dropQuestions() }
                splits = splits.filter { Browser.holds($0, in: self.tabs) }
                for key in parked.keys {
                    if let row = parked[key] { parked[key]?.splits = row.splits.filter { Browser.holds($0, in: row.tabs) } }
                }
                writeSession(now: true)
            }
            .store(in: &bag)
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

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Search — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now.
        prefs.$showsLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { linkStatus.dismiss() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
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
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
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
                guard let self, let web = active?.web else { return }
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

    private func relook() {
        Favicons.shared.relook(tabs.filter { !$0.asleep })
    }

    func writeSession(now: Bool = false) {
        // The pins as they are here, for the other windows (see Pins.swift).
        Pins.set(spaceID, pinDefs(tabs), from: self)
        writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: now)
    }

    // MARK: - pins, the same in every window

    /// What makes this row's pinned tabs pins, in their order.
    private func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin, !tab.shy else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            return PinDef(id: tab.pinID ?? UUID(), letter: letter,
                          home: (tab.home ?? tab.pending ?? tab.address)?.absoluteString ?? "",
                          title: tab.title, name: tab.name, listed: tab.listed ? true : nil)
        }
    }

    /// A row with the space's pins as they are now: this window's own tab
    /// for each, relettered and in order, one made asleep at its page for a
    /// pin new to this window, and the tab of a pin taken away closed. A
    /// pinned tab from before pins had ids is matched by letter and page,
    /// then by place.
    func reconcilePins(_ row: [Tab], space: UUID) -> [Tab] {
        let defs = Pins.defs(space)
        var pinned = row.filter { $0.pin != nil && !$0.shy }
        let loose = row.filter { $0.pin == nil || $0.shy }
        var out: [Tab] = []
        for def in defs {
            let found = pinned.first { $0.pinID == def.id }
                ?? pinned.first { $0.pinID == nil && $0.pin == def.letter && ($0.home?.absoluteString ?? "") == def.home }
                ?? pinned.first { $0.pinID == nil }
            let tab: Tab
            if let found {
                pinned.removeAll { $0 === found }
                tab = found
            } else {
                tab = Tab(configuration: Web.configuration(space: space))
                prepare(tab)
                tab.restore(url: URL(string: def.home) ?? URL(string: "about:blank")!, title: def.title, name: def.name)
            }
            tab.pinID = def.id
            if tab.pin != def.letter { tab.pin = def.letter }
            if tab.name != def.name { tab.name = def.name }
            if tab.listed != (def.listed == true) { tab.listed = def.listed == true }
            tab.home = URL(string: def.home)
            out.append(tab)
        }
        for gone in pinned { gone.close() }
        // In the order they were written, which already holds it; a file
        // put together by hand, or an import, may not.
        return Browser.tiered(out) + loose
    }

    /// Another window changed a space's pins: this window's row there follows.
    func pinsChanged(in space: UUID) {
        if space == spaceID {
            // Drawn again even when only a pin's letter or name changed.
            objectWillChange.send()
            let row = reconcilePins(tabs, space: space)
            if row.map(\.id) != tabs.map(\.id) { tabs = row }
            if !tabs.contains(where: { $0.id == activeID }) {
                activeID = tabs.first { $0.pin == nil }?.id ?? tabs.first?.id
                if activeID == nil { newTab() }
            }
            splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in tabs.contains { $0.id == id } }
            }
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: false)
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
            row.splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in row.tabs.contains { $0.id == id } }
            }
            if !row.tabs.contains(where: { $0.id == row.active }) { row.active = row.tabs.first?.id }
            parked[space] = row
        }
    }

    /// Arc's sidebar brought over (see ImportArc.swift). Each of its spaces
    /// becomes a space here — the one of the same name if there is one,
    /// signed in with the others when Arc's used its first profile — its
    /// pinned list the space's tabs, asleep until gone to, folders opened
    /// out in their order; the favourites, the icons above every space of
    /// a profile in Arc, become the pins of that profile's spaces. A lone space, with spaces off, comes
    /// into the one there is; more than one turns spaces on. Nothing twice:
    /// a page already in the row, or a pin already there, isn't added again.
    @discardableResult
    func takeArc(_ sidebar: ArcSidebar, from source: ImportSource? = nil, profile: String? = nil)
        -> (spaces: Int, pins: Int, tabs: Int) {
        var made = 0, pins = 0, added = 0
        // Every address this brings in, for its icon below.
        var brought: [URL] = []
        var targets: [(id: UUID, space: ArcSidebar.Space?)] = []
        if sidebar.spaces.count > 1 || (prefs.usesSpaces && !sidebar.spaces.isEmpty) {
            if !prefs.usesSpaces { prefs.usesSpaces = true }
            var list = spaces
            for arc in sidebar.spaces {
                if let same = list.first(where: { $0.name.localizedCaseInsensitiveCompare(arc.name) == .orderedSame }) {
                    targets.append((same.id, arc))
                } else {
                    let space = Space(id: UUID(), name: arc.name, colour: 0, icon: arc.symbol,
                                      sharesSignIns: arc.profile == "Default")
                    list.append(space)
                    targets.append((space.id, arc))
                    made += 1
                }
            }
            if made > 0 {
                spaces = list
                Spaces.write(list)
            }
        } else {
            targets = [(spaceID, sidebar.spaces.first)]
        }
        for target in targets {
            var defs = Pins.defs(target.id)
            // A space's own profile's favourites, as Arc shows them above it.
            let favourites = target.space.flatMap { sidebar.favoritesByProfile[$0.profile] } ?? sidebar.favorites
            for favourite in favourites where !defs.contains(where: { $0.home == favourite.url.absoluteString }) {
                let host = favourite.url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                defs.append(PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                                   home: favourite.url.absoluteString, title: favourite.title, name: nil))
                pins += 1
                brought.append(favourite.url)
            }
            Pins.set(target.id, defs, from: self)
            pinsChanged(in: target.id)
            let pinned = Browser.opened(target.space?.pinned ?? [])
            brought += pinned.map(\.item.url)
            added += takeAsleep(pinned, into: target.id)
        }
        adoptIcons(for: brought, from: source, profile: profile)
        return (made, pins, added)
    }

    /// The icons for what Arc's side of the import brought in, from Arc's own
    /// cache, as the bookmarks take theirs (see takeBookmarks). A pin and a
    /// tab read the icon cache as they are made, and these were made a moment
    /// ago, when nothing had been put there for them yet: without this every
    /// one of them wears a letter until its page is opened, which is the only
    /// other way an icon arrives (see Favicons.fetch).
    private func adoptIcons(for urls: [URL], from source: ImportSource?, profile: String?) {
        guard let source, !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            guard !icons.isEmpty else { return }
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                // The ones made before the icons arrived, now that they are here.
                for tab in self.tabs + self.parkedTabs where tab.icon == nil { tab.adoptIcon() }
                self.objectWillChange.send()
            }
        }
    }

    /// Arc's pinned list, folders opened out in their order, each page with
    /// the top folder it came from: a tab group's name, when groups are on.
    private static func opened(_ nodes: [ArcSidebar.Node], in folder: String? = nil) -> [(item: ArcSidebar.Item, folder: String?)] {
        nodes.flatMap { node -> [(item: ArcSidebar.Item, folder: String?)] in
            switch node {
            case .item(let item): [(item, folder)]
            case .folder(let inner): opened(inner.items, in: folder ?? inner.title)
            }
        }
    }

    /// Pages as tabs at the end of a space's row, asleep: the row on
    /// screen, a parked one, or the one saved for a space not brought up.
    /// With tab groups on, a page from one of Arc's folders goes into the
    /// group of that name in the space, made if there is none; with them
    /// off, the folders stay opened out. Groups are never turned on here.
    private func takeAsleep(_ items: [(item: ArcSidebar.Item, folder: String?)], into space: UUID) -> Int {
        let grouping = prefs.usesTabGroups
        func asleep(_ item: ArcSidebar.Item) -> Tab {
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: item.url, title: item.title)
            return tab
        }
        func fresh(_ have: [String]) -> [(item: ArcSidebar.Item, folder: String?)] {
            var seen = Set(have)
            return items.filter { seen.insert($0.item.url.absoluteString).inserted }
        }
        /// The group a folder's pages go into, by name, made if missing.
        func group(_ folder: String?, in groups: inout [TabGroup]) -> UUID? {
            guard grouping, let folder else { return nil }
            if let same = groups.first(where: { $0.name == folder }) { return same.id }
            let made = TabGroup(id: UUID(), name: folder, collapsed: false)
            groups.append(made)
            return made.id
        }
        if space == spaceID {
            let new = fresh(tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            var groups = tabGroups
            tabs += new.map { page in
                let tab = asleep(page.item)
                tab.groupID = group(page.folder, in: &groups)
                return tab
            }
            if groups != tabGroups {
                tabGroups = groups
                arrangeGroupedTabs()
            }
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: true)
            return new.count
        }
        // A parked row's groups are the ones saved for it (see allRows).
        var saved = readRow(space)
        var groups = parked[space]?.groups ?? saved.groups ?? []
        if var row = parked[space] {
            let new = fresh(row.tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            row.tabs += new.map { page in
                let tab = asleep(page.item)
                tab.groupID = group(page.folder, in: &groups)
                return tab
            }
            row.groups = groups
            parked[space] = row
            if groups != (saved.groups ?? []) {
                saved.groups = groups
                writeRow(space, saved, now: true)
            }
            return new.count
        }
        let new = fresh(saved.tabs.map(\.url))
        saved.tabs += new.map { page in
            Session.Entry(url: page.item.url.absoluteString, title: page.item.title,
                          groupID: group(page.folder, in: &groups))
        }
        if grouping { saved.groups = groups }
        writeRow(space, saved, now: true)
        return new.count
    }

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
        rows[spaceID.uuidString] = session(tabs, active: activeID, groups: tabGroups, splits: splits)
        for (space, row) in parked {
            rows[space.uuidString] = session(row.tabs, active: row.active, groups: row.groups ?? readRow(space).groups, splits: row.splits)
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
        if floating != nil { land() }
        if peekTab != nil { closePeek() }
        for tab in tabs + parkedTabs { tab.close() }
        parked = [:]
        splits = []
        tabs = []
    }

    private func session(_ tabs: [Tab], active id: Tab.ID?, groups: [TabGroup]? = nil, splits: [TabSplit] = []) -> Session.Shape {
        var entries: [Session.Entry] = []
        var active = 0
        var indices: [Tab.ID: Int] = [:]
        for tab in tabs {
            guard kept(tab), let url = tab.pending ?? tab.address else { continue }
            if tab.id == id { active = entries.count }
            indices[tab.id] = entries.count
            entries.append(Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name,
                home: tab.pin == nil ? nil : tab.home?.absoluteString, groupID: tab.groupID,
                pinID: tab.pin == nil ? nil : tab.pinID,
                listed: tab.pin != nil && tab.listed ? true : nil
            ))
        }
        // The tab you were on isn't kept — a private or blank one: the one
        // kept just before it comes back in front, not the first of the row.
        if let id, let at = tabs.firstIndex(where: { $0.id == id }), indices[id] == nil {
            active = max(0, tabs[..<at].filter(kept).count - 1)
        }
        let keptGroups = groups?.filter { group in
            entries.contains { $0.groupID == group.id }
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
        return .init(tabs: entries, active: active, groups: keptGroups, splits: savedSplits)
    }

    /// Whether a tab goes into the session: not a private one or the
    /// bench's, and only with a web address. A sleeping view is blank, so
    /// `pending` must win or its page will disappear from the next session.
    private func kept(_ tab: Tab) -> Bool {
        // A tab holding an extension's sign-in answer (Tab.hold) carries its
        // code in the address: that is never written down.
        !tab.shy && !tab.bench && tab.held == nil && (tab.pending ?? tab.address)?.scheme?.hasPrefix("http") == true
    }

    /// Another space's row. Its groups are the ones in its own file, the
    /// only place a space off screen keeps them: written without them, the
    /// space would lose every group it had.
    private func writeSession(now: Bool, space: UUID, row: Parked) {
        let groups = row.groups ?? readRow(space).groups
        writeRow(space, session(row.tabs, active: row.active, groups: groups, splits: row.splits), now: now)
    }

    private func rememberSession() {
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

    // MARK: - tabs

    /// A pin can be split with: its page goes into the pair as a tab of its
    /// own, and the pin stays where it is (see splittable).
    func canSplit(_ first: Tab, with second: Tab) -> Bool {
        prefs.splitView && first.id != second.id && !first.bench && !second.bench
            && first.shy == second.shy
            && tabs.contains(where: { $0.id == first.id })
            && tabs.contains(where: { $0.id == second.id })
    }

    /// Zen's rule for pins: a pin never goes into a pair — it keeps its
    /// place among the pins, in every window (Pins.swift) — but its page
    /// does, as a new tab beside the other page. Anything else is itself.
    private func splittable(_ tab: Tab) -> Tab {
        guard tab.pin != nil, let url = tab.address ?? tab.home else { return tab }
        let copy = Tab(configuration: Web.configuration(space: spaceID))
        prepare(copy)
        tabs.insert(copy, at: tabs.count)
        copy.go(to: url)
        return copy
    }

    func pair(_ dragged: Tab, with target: Tab, onLeft: Bool) {
        guard canSplit(dragged, with: target) else { return }
        if floating == dragged.id || floating == target.id { land() }
        let dragged = splittable(dragged)
        let target = splittable(target)
        detachSplit(dragged)
        detachSplit(target)
        let oldGroup = dragged.groupID
        dragged.groupID = target.groupID
        var row = tabs.filter { $0.id != dragged.id }
        guard let index = row.firstIndex(where: { $0.id == target.id }) else { return }
        row.insert(dragged, at: onLeft ? index : index + 1)
        let left = onLeft ? dragged : target
        let right = onLeft ? target : dragged
        splits.append(TabSplit(tabs: [left.id, right.id], focused: dragged.id))
        tabs = row
        removeEmptyGroup(oldGroup)
        focusPane(dragged)
        for pane in [left, right] where !pane.isBlank {
            if !pane.wake() { pane.revive() }
        }
        rememberSession()
    }

    func startSplit() {
        guard prefs.splitView, let shown = active, !shown.bench else { return }
        if let pair = activeSplit {
            if let right = tabs.first(where: { $0.id == pair.right }) { focusPane(right) }
            return
        }
        if floating == shown.id { land() }
        let current = splittable(shown)
        let right = Tab(shy: current.shy,
                        configuration: current.shy ? Web.configuration(shy: true, store: current.store)
                            : Web.configuration(space: spaceID))
        prepare(right)
        right.groupID = current.groupID
        guard let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        splits.append(TabSplit(tabs: [current.id, right.id], focused: right.id))
        tabs.insert(right, at: index + 1)
        focusPane(right)
        editing = true
        typed = ""
        focusRequest += 1
        rememberSession()
    }

    func detachSplit(_ tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        splits.remove(at: index)
        rememberSession()
    }

    /// Once a drag of the divider is over, or once an arrow key moved it:
    /// the drag itself is followed by the stage alone (see PaneStage).
    func setSplitFraction(_ id: UUID, fraction: Double) {
        guard fraction.isFinite, let index = splits.firstIndex(where: { $0.id == id }) else { return }
        let sizes = TabSplit.clamp([fraction, 1 - fraction])
        guard splits[index].sizes != sizes else { return }
        splits[index].sizes = sizes
        rememberSession()
    }

    func focusPane(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if let pair = split(for: tab), activeSplit?.id == pair.id {
            guard activeID != tab.id else { return }
            if peekTab != nil { closePeek() }
            // Find stays open with what it was looking for, and looks in
            // this page instead (see activeID).
            cancelTabEdit()
            summoning = false
            suggesting = nil
            looked = nil
            editing = false
            typed = ""
            activeID = tab.id
            tab.touch()
            rememberSession()
        } else {
            select(tab)
        }
    }

    /// An extension asking for a tab to be the one in front. A page of the
    /// pair on screen is in view already: the keys stay where they are, so
    /// an extension can't move typing from one page to the other.
    func activateForExtension(_ tab: Tab) {
        if let pair = activeSplit, pair.contains(tab.id) { return }
        select(tab)
    }

    /// ⌃⌘← and ⌃⌘→: the page on that side.
    func focusPane(onLeft: Bool) {
        guard let pair = activeSplit,
              let tab = tabs.first(where: { $0.id == (onLeft ? pair.left : pair.right) }) else { return }
        focusPane(tab)
    }

    /// A tab's menu › Open in Split View: that tab beside the page on
    /// screen. Asked of the page on screen itself, an empty page beside it.
    func openInSplit(_ tab: Tab) {
        guard prefs.splitView, let current = active else { return }
        if tab.id == current.id { return startSplit() }
        guard split(for: tab)?.contains(current.id) != true else { return focusPane(tab) }
        guard canSplit(tab, with: current) else { return }
        pair(tab, with: current, onLeft: false)
    }

    /// The divider's menu › Swap Pages.
    func swapSplit() {
        guard let pair = activeSplit, let index = splits.firstIndex(where: { $0.id == pair.id }) else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        guard members.count == pair.tabs.count, let start = tabs.firstIndex(where: { $0.id == pair.left }) else { return }
        splits[index].tabs.reverse()
        splits[index].sizes.reverse()
        var row = tabs.filter { !pair.contains($0.id) }
        row.insert(contentsOf: members.reversed(), at: min(start, row.count))
        tabs = row
        rememberSession()
    }

    /// The divider's menu › Even Out, or a double-click on it.
    func evenSplit() {
        guard let pair = activeSplit else { return }
        setSplitFraction(pair.id, fraction: 0.5)
    }

    /// The divider's menu › Close Both.
    func closeSplit() {
        guard let pair = activeSplit else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        for tab in members { close(tab) }
    }

    /// An empty page of a pair given an open tab: the tab takes its place,
    /// and the empty one goes. Chosen from the list the empty page shows.
    func fill(_ blank: Tab, with tab: Tab) {
        guard let pair = split(for: blank), blank.isBlank, tab.id != blank.id, !pair.contains(tab.id),
              !tab.bench, tab.shy == blank.shy,
              let at = tabs.firstIndex(where: { $0.id == blank.id }) else { return }
        let tab = splittable(tab)
        detachSplit(tab)
        let oldGroup = tab.groupID
        tab.groupID = blank.groupID
        var row = tabs.filter { $0.id != tab.id }
        let place = row.firstIndex(where: { $0.id == blank.id }) ?? min(at, row.count)
        row[place] = tab
        replaceSplitMember(blank.id, with: tab.id)
        tabs = row
        removeEmptyGroup(oldGroup)
        blank.close()
        activeID = tab.id
        editing = false
        typed = ""
        if !tab.wake() { tab.revive() }
        rememberSession()
    }

    func focusOtherPane() {
        guard let pair = activeSplit,
              let other = tabs.first(where: { $0.id == (activeID == pair.left ? pair.right : pair.left) }) else { return }
        focusPane(other)
    }

    func moveDisplayedTab(_ tab: Tab, to index: Int) {
        let shown = displayedTabs
        guard shown.indices.contains(index),
              let representative = split(for: tab)?.left ?? (tabs.contains(where: { $0.id == tab.id }) ? tab.id : nil),
              let from = shown.firstIndex(where: { $0.id == representative }), from != index else { return }
        let anchor = shown[index]
        let moving = split(for: tab).map { pair in tabs.filter { pair.contains($0.id) } } ?? [tab]
        guard moving.allSatisfy({ ($0.pin == nil) == (anchor.pin == nil) }), joins(tab, kindOf: anchor) else { return }
        let ids = Set(moving.map(\.id))
        var row = tabs.filter { !ids.contains($0.id) }
        guard let target = row.firstIndex(where: { $0.id == anchor.id }) else { return }
        let targetSize = split(for: anchor) == nil ? 1 : 2
        row.insert(contentsOf: moving, at: from < index ? target + targetSize : target)
        tabs = row
        rememberSession()
    }

    /// Whether a pin carried onto another may land there. With the rows
    /// shown, a square goes among squares and a row among rows; the menu
    /// moves one between them. With them off every pin is drawn a square,
    /// so one carried across the hidden line becomes the kind it landed
    /// among, which keeps the squares ahead of the rows (see settlePin).
    private func joins(_ tab: Tab, kindOf anchor: Tab) -> Bool {
        guard tab.pin != nil, anchor.pin != nil, tab.listed != anchor.listed else { return true }
        if prefs.showsPinRows { return false }
        tab.listed = anchor.listed
        return true
    }

    func dropTabIntoStrip(_ tab: Tab, before target: Tab?) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let target {
            guard target.id != tab.id,
                  let targetIndex = tabs.firstIndex(where: { $0.id == target.id }),
                  split(for: tab)?.contains(target.id) != true,
                  (tab.pin == nil) == (target.pin == nil), joins(tab, kindOf: target) else { return }
            let targetStart = split(for: target).flatMap { pair in tabs.firstIndex { $0.id == pair.left } } ?? targetIndex
            detachSplit(tab)
            let previousGroup = tab.groupID
            tab.groupID = target.groupID
            var row = tabs.filter { $0.id != tab.id }
            row.insert(tab, at: sourceIndex < targetStart ? targetStart - 1 : targetStart)
            tabs = row
            removeEmptyGroup(previousGroup)
        } else {
            detachSplit(tab)
            var row = tabs
            row.remove(at: sourceIndex)
            row.insert(tab, at: tab.pin == nil ? row.count : row.filter { $0.pin != nil && (tab.listed || !$0.listed) }.count)
            tabs = row
        }
        rememberSession()
    }

    func newTab() {
        // On a private tab, a new one is private too: ⌘T from a page that
        // keeps nothing and landing on one that keeps everything is how a
        // private search ends up in the history.
        if active?.shy == true {
            newShyTab()
            return
        }
        // An extension's new tab page, if one asked and you said yes.
        if #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            open(page, foreground: true)
            summoning = false
            rememberSession()
            return
        }
        // Never two empty tabs. One already open anywhere in the row comes to
        // its end and is the one opened, with whatever was typed into it and
        // never gone to cleared away — a row of identical empty tabs is what
        // pressing ⌘T twice, or holding it, used to leave.
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && !$0.shy && split(for: $0) == nil }) {
            if let end = tabs.indices.last, tabs.firstIndex(where: { $0.id == blank.id }) != end {
                move(blank, to: end)
            }
            if activeID != blank.id { leaving() }
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            rememberSession()
            return
        }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        adopt(tab)
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// A blank tab given an extension's new tab page: the page needs a view
    /// built from that extension's configuration, so it is a new tab in the
    /// blank one's place.
    func replaceBlank(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        page.groupID = tab.groupID
        replaceSplitMember(tab.id, with: page.id)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab, floatPrevious: Bool = true) {
        if let pair = split(for: tab), activeSplit?.id == pair.id, activeID != tab.id {
            focusPane(tab)
            return
        }
        // A folded group opens for the tab you go to in it. With groups off,
        // they are kept as they were and nothing about them is saved.
        if prefs.usesTabGroups, let id = tab.groupID,
           let index = tabGroups.firstIndex(where: { $0.id == id }), tabGroups[index].collapsed {
            tabGroups[index].collapsed = false
            writeSession(now: true)
        }
        // A peek is over the tab it was opened from; another tab puts it away.
        if peekTab != nil, tab.id != activeID { closePeek() }
        // Before ⌘K is put away below: its words were for finding a tab, not
        // a draft for the blank one it was pressed on.
        if tab.id != activeID, !summoning, let here = active, here.isBlank { here.draft = typed }
        cancelTabEdit()
        summoning = false
        suggesting = nil
        // Back on a tab with the caret still in a box, the list may come again.
        looked = nil
        guard tab.id != activeID else { return }
        // The AI panel is about the page it was opened on.
        if assisting != nil { closeAssistant() }
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        if floatPrevious { leaving() }
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() { tab.revive() }
        if let pair = activeSplit,
           let other = tabs.first(where: { $0.id == (pair.left == tab.id ? pair.right : pair.left) }),
           !other.isBlank, !other.wake() { other.revive() }
        rememberSession()
        editing = false
        typed = tab.isBlank ? tab.draft : ""
    }

    /// ⌘W closes what is in front: a peek, then a panel over the page
    /// (Settings, History and the rest), then the tab. In Chrome these
    /// panels are tabs, and ⌘W on one closes it; closing the page behind it
    /// instead took the one thing you couldn't see. Escape puts things away
    /// in the same order, so the two keys agree on what is in front.
    func closeFront() {
        if peekTab != nil { closePeek() }
        else if closePanel() { return }
        else if let tab = active { close(tab) }
    }

    /// The panel over the page put away, if one is up — for ⌘W and Escape
    /// both. Whether there was one.
    func closePanel() -> Bool {
        if notesShowing { notesShowing = false }
        else if newsShowing { newsShowing = false }
        else if tuning { tuning = false }
        else if bookmarking { bookmarking = false }
        else if managing { managing = false }
        else if bringingIn != nil { bringingIn = nil }
        else if recalling { recalling = false }
        else if hoarding { hoarding = false }
        else { return false }
        return true
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let pair = split(for: tab)
        let partner = pair.flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land() }

        // A pinned tab is not closed by ⌘W — it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row.
        if tab.pin != nil {
            tab.rest()
            // Ordinary tabs first. Falling back to the most recent tab of any
            // kind meant closing one pin landed you on another pin, and ⌘W
            // bounced between the two instead of getting you out of them.
            let others = tabs.filter { $0.id != tab.id && !$0.asleep }
            let loose = others.filter { $0.pin == nil }
            if let back = (loose.isEmpty ? others : loose).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else {
                newTab()
            }
            writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            if tab.isBlank {
                NSApp.keyWindow?.performClose(nil)
            } else {
                let fresh = Tab(configuration: Web.configuration(space: spaceID))
                remember(tab, at: 0)
                tab.close()
                adopt(fresh)
                tabs = [fresh]
                activeID = fresh.id
                typed = ""
                removeEmptyGroup(tab.groupID)
            }
            return
        }

        remember(tab, at: index, partner: partner?.id, onLeft: pair?.left == tab.id)
        tab.close()
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        if activeID == tab.id {
            // The neighbour on the right, or the last one if there is no
            // right — through select(), same as everywhere else you land on
            // a tab, so one that was never built yet actually wakes up
            // instead of sitting there blank until a manual reload.
            select(partner ?? tabs[min(index, tabs.count - 1)])
        }
        rememberSession()
    }

    /// Everything but this one. Pinned tabs are put down rather than removed —
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: Tab) {
        select(keep)
        // The list is read once: closing walks the row and can add to it.
        let partner = split(for: keep).flatMap { $0.partner(of: keep.id) }
        for tab in tabs.filter({ $0.id != keep.id && $0.id != partner }) {
            close(tab)
        }
        select(keep)
    }

    /// Arc's Clear, on the line above the tabs that come and go: each of
    /// them closed as ⌘W closes it, and all of it remembered as one, so a
    /// single ⇧⌘T puts every tab back. Pins stay, and so does a tab group:
    /// a section you named is one you are keeping. The page on screen goes
    /// last, once an empty tab has taken its place: closed first, a
    /// neighbour would wake only to be closed.
    func clearTabs() {
        let going = tabs.filter { $0.pin == nil && !$0.bench && group(of: $0) == nil }
        guard !going.isEmpty else { return }
        let batch = UUID(), was = activeID
        clearing = batch
        defer {
            clearing = nil
            if let at = ghosts.lastIndex(where: { $0.batch == batch && $0.was == was }) { ghosts[at].front = true }
        }
        lastClear = (batch, nil)
        for tab in going where !visibleTabIDs.contains(tab.id) { close(tab) }
        let onScreen = going.filter { visibleTabIDs.contains($0.id) }
        // Already an empty tab in front: that is where Clear leaves you.
        guard !onScreen.isEmpty, !(onScreen.count == 1 && onScreen[0].isBlank) else { return }
        // After the others went, so it can't reuse an empty one among them.
        // It may still reuse one of yours, in a group: that one is yours to
        // keep, and only a tab Clear made is taken away again by the undo.
        let had = Set(tabs.map(\.id))
        newTab()
        lastClear = (batch, activeID.flatMap { had.contains($0) ? nil : $0 })
        for tab in onScreen where tab.id != activeID { close(tab) }
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    // A page decides what a link dragged out of it carries: never
                    // script, nor an extension's page, which would open with
                    // that extension's own powers.
                    guard let url, !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text),
                          !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left.
    func reopen() {
        // A window closed after the last tab was: the window comes back, as
        // in Safari and Chrome (see Windows.swift).
        if let window = Browsers.lastClosedAt, window > (ghosts.last?.at ?? .distantPast), Browsers.reopenWindow() { return }
        guard let ghost = ghosts.last else { return }
        if let batch = ghost.batch { reopen(batch: batch) } else { reopen(ghost) }
    }

    /// What ⇧⌘T brings back, for its menu items: a Clear's tabs, by how
    /// many, or the one tab (or the window) it always did.
    var reopenTitle: String {
        guard let last = ghosts.last, let batch = last.batch,
              (Browsers.lastClosedAt ?? .distantPast) <= last.at else { return "Reopen Closed Tab" }
        let count = ghosts.filter { $0.batch == batch }.count
        return count == 1 ? "Reopen Cleared Tab" : "Reopen \(count) Cleared Tabs"
    }

    /// Everything one Clear closed, back as it was: each tab at its place,
    /// the newest closed first, so each goes into the row as it stood just
    /// before that tab left it. They come back asleep, as last session's
    /// tabs do, but for the one you were on, which comes back in front; the
    /// empty tab Clear left there goes, if nothing has been typed into it.
    /// A Clear made from a pin leaves you on the pin.
    private func reopen(batch: UUID) {
        let members = ghosts.filter { $0.batch == batch }
        ghosts.removeAll { $0.batch == batch }
        var back: [Tab.ID: Tab] = [:]
        var front: Tab?
        for ghost in members.reversed() {
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            // No group to put it back in, as reopen(_:) does for a tab from
            // a closed group (closedGroups): Clear never takes a tab that is
            // in a group (see clearTabs), so none of these was in one.
            tab.restore(url: ghost.url, title: ghost.title)
            tabs.insert(tab, at: safeInsertionIndex(ghost.index))
            if let was = ghost.was { back[was] = tab }
            if ghost.front { front = tab }
            // A pair cleared together: its other half came back just before,
            // beside it already. Made a pair again as it stands, not through
            // pair(), which would take the focus and wake both pages.
            if let id = ghost.partner, let partner = back[id],
               split(for: partner) == nil, canSplit(tab, with: partner) {
                let pair = TabSplit(tabs: ghost.onLeft ? [tab.id, partner.id] : [partner.id, tab.id], focused: tab.id)
                if Browser.holds(pair, in: tabs) { splits.append(pair) }
            }
        }
        if let front { select(front) }
        if let clear = lastClear, clear.batch == batch, let id = clear.blank,
           let blank = tabs.first(where: { $0.id == id }), blank.isBlank, blank.draft.isEmpty, activeID != id {
            close(blank)
        }
        lastClear = nil
        rememberSession()
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        var regrouped = false
        if prefs.usesTabGroups, let id = ghost.groupID, !tabGroups.contains(where: { $0.id == id }),
           let closed = closedGroups.removeValue(forKey: id) {
            var group = closed.group
            group.collapsed = false
            tabGroups.insert(group, at: min(closed.at, tabGroups.count))
            regrouped = true
        }
        tab.groupID = prefs.usesTabGroups && tabGroups.contains(where: { $0.id == ghost.groupID })
            ? ghost.groupID : nil
        leaving()
        tabs.insert(tab, at: safeInsertionIndex(ghost.index))
        if regrouped { arrangeGroupedTabs() }
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
        // Back into its pair, if the page it was beside is still alone.
        if let id = ghost.partner, let partner = tabs.first(where: { $0.id == id }),
           split(for: partner) == nil, canSplit(tab, with: partner) {
            pair(tab, with: partner, onLeft: ghost.onLeft)
        }
    }

    private func remember(_ tab: Tab, at index: Int, partner: Tab.ID? = nil, onLeft: Bool = false) {
        guard !tab.shy, let url = tab.address else { return }
        ghosts.append(Ghost(url: url, title: tab.title, index: index, groupID: tab.groupID,
                            partner: partner, onLeft: onLeft, was: tab.id, batch: clearing))
        // Twelve steps back, a Clear counting as one: its tabs come back
        // together or not at all, however many there were.
        var steps = Set<UUID>()
        let count = ghosts.reduce(0) { total, ghost in
            guard let batch = ghost.batch else { return total + 1 }
            return steps.insert(batch).inserted ? total + 1 : total
        }
        if count > 12, let oldest = ghosts.first {
            if let batch = oldest.batch { ghosts.removeAll { $0.batch == batch } } else { ghosts.removeFirst() }
        }
        closedGroups = closedGroups.filter { id, _ in ghosts.contains { $0.groupID == id } }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        guard tabs.indices.contains(index) else { return }
        let target = tabs[index]
        let representative = split(for: target)?.left ?? target.id
        guard let destination = displayedTabs.firstIndex(where: { $0.id == representative }) else { return }
        moveDisplayedTab(tab, to: destination)
    }

    /// Put a tab in another space. If its store changes, ask only when the
    /// page has unsaved form entries; the new view then opens in that space.
    func move(_ tab: Tab, toSpace id: UUID, then: (() -> Void)? = nil) {
        guard prefs.usesSpaces, id != spaceID,
              spaces.contains(where: { $0.id == id }),
              tabs.contains(where: { $0.id == tab.id }), !tab.bench,
              tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
        else { return }

        let complete: () -> Void = { [weak self, weak tab] in
            guard let self, let tab, self.finishMove(tab, toSpace: id) else { return }
            then?()
        }
        guard !tab.shy, tab.store !== Spaces.store(for: id) else {
            complete()
            return
        }
        let from = spaceID
        tab.unsaved { [weak self, weak tab] unsaved in
            guard let self, let tab, self.spaceID == from,
                  self.tabs.contains(where: { $0.id == tab.id }),
                  let destination = self.spaces.first(where: { $0.id == id })
            else { return }
            if unsaved {
                Ask.sure(
                    "Move Tab?",
                    detail: "This page has unsaved form entries. It will reopen in “\(destination.name)” with that Space’s sign-ins, so the entries may be lost.",
                    confirm: "Move",
                    then: complete
                )
            } else {
                complete()
            }
        }
    }

    @discardableResult
    private func finishMove(_ tab: Tab, toSpace id: UUID) -> Bool {
        guard prefs.usesSpaces, id != spaceID,
              let destination = spaces.first(where: { $0.id == id }),
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)

        if floating == tab.id { land() }
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
        removeEmptyGroup(tab.groupID)
        if tabs.isEmpty { adopt(Tab(configuration: Web.configuration(space: spaceID))) }

        tab.rehome(in: id)
        // Its group stays behind: the space it goes to has groups of its own.
        tab.groupID = nil
        var row = parked[id] ?? loadRow(id)
        let place = tab.pin == nil ? row.tabs.count : (row.tabs.firstIndex { $0.pin == nil } ?? row.tabs.count)
        row.tabs.insert(tab, at: place)
        if row.active == nil { row.active = tab.id }
        parked[id] = row

        writeSession(now: true)
        writeSession(now: true, space: id, row: row)
        announce("Moved to \(destination.name)")
        return true
    }

    // MARK: - a tab to another window

    /// The tab's menu: Move to New Window, or to another window. The tab
    /// goes as it is, page and all, into the other window's row after the
    /// tab it's on, in front there; into a space with other sign-ins it
    /// reopens with those, as Move to Space does. Not a pin: pins are
    /// already in every window.
    func moveToWindow(_ tab: Tab, _ target: Browser?, at point: NSPoint? = nil) {
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
        let over = Browsers.all.first { $0 !== self && $0.isOpen && $0.window?.frame.contains(point) == true }
        guard over != nil || tabs.count > 1 else { return false }
        // After the drag has let go, not inside it.
        DispatchQueue.main.async { [weak self] in self?.moveToWindow(tab, over, at: point) }
        return true
    }

    /// Out of this row, not closed: it is on its way to another window.
    private func detach(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)
        if floating == tab.id { land() }
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
        removeEmptyGroup(tab.groupID)
        tab.groupID = nil
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

    /// A section can be made empty, then filled from a tab's menu.
    @discardableResult
    func addTabGroup(containing tab: Tab) -> UUID {
        let id = UUID()
        tabGroups.append(TabGroup(id: id, name: "Group \(tabGroups.count + 1)", collapsed: false))
        editingGroupID = id
        move(tab, toGroup: id)
        // A tab that can't be in a group (a pin, a private one) leaves none behind.
        removeEmptyGroup(id)
        writeSession(now: true)
        return id
    }

    func renameTabGroup(_ id: UUID, to name: String) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabGroups[index].name = trimmed
        writeSession(now: true)
    }

    func toggleTabGroup(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].collapsed.toggle()
        writeSession(now: true)
    }

    func removeTabGroup(_ id: UUID) {
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        tabGroups.removeAll { $0.id == id }
        arrangeGroupedTabs()
        if editingGroupID == id { editingGroupID = nil }
        writeSession(now: true)
    }

    /// Close Group, in a group's menu: the group and every tab in it, each
    /// closed as ⌘W closes it, so ⌘⇧T brings them back one by one and into
    /// the group again (see closedGroups). The page on screen goes last, as
    /// with Clear, so no neighbour wakes only to be closed.
    func closeTabGroup(_ id: UUID) {
        guard let at = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        closedGroups[id] = (tabGroups[at], at)
        let going = tabs.filter { $0.groupID == id }
        for tab in going where !visibleTabIDs.contains(tab.id) { close(tab) }
        for tab in going where visibleTabIDs.contains(tab.id) { close(tab) }
        // The group goes with its last tab; an empty one goes here.
        if tabGroups.contains(where: { $0.id == id }) { removeTabGroup(id) }
        writeSession(now: true)
    }

    func move(_ tab: Tab, toGroup id: UUID?) {
        guard tabs.contains(where: { $0.id == tab.id }), tab.pin == nil, !tab.shy, !tab.bench,
              id == nil || tabGroups.contains(where: { $0.id == id }) else { return }
        let previousGroup = tab.groupID
        guard previousGroup != id else { return }
        // A pair is one place in the row: moved into a group or out of one,
        // both halves go, and stay a pair. Dragged apart in the row, one
        // half leaves on its own (see dropTabIntoStrip).
        let partner = split(for: tab).flatMap { pair in
            tabs.first { $0.id == (pair.left == tab.id ? pair.right : pair.left) }
        }
        tab.groupID = id
        partner?.groupID = id
        removeEmptyGroup(previousGroup)
        arrangeGroupedTabs()
        if let id, let index = tabGroups.firstIndex(where: { $0.id == id }) {
            tabGroups[index].collapsed = false
        }
        writeSession(now: true)
    }

    /// Reorder only among peers in the displayed section. The underlying
    /// tab row remains flat for keyboard shortcuts and the top strip.
    func move(_ tab: Tab, within group: UUID?, to index: Int) {
        let peers = tabs(in: group).filter(standsInRow)
        guard let from = peers.firstIndex(where: { $0.id == tab.id }),
              peers.indices.contains(index), from != index,
              let destination = tabs.firstIndex(where: { $0.id == peers[index].id }) else { return }
        move(tab, to: destination)
    }

    func moveTabGroup(_ id: UUID, to index: Int) {
        guard let from = tabGroups.firstIndex(where: { $0.id == id }),
              tabGroups.indices.contains(index), from != index else { return }
        tabGroups.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        arrangeGroupedTabs()
        writeSession(now: true)
    }

    /// The row in the order it is shown: the pins, each group's tabs in the
    /// groups' order, then the tabs in none. The one place that order is
    /// made, run after every change to the row (see `tabs`) and to a group.
    /// Nothing while groups are off: the row stays as you left it.
    private func arrangeGroupedTabs(_ on: Bool? = nil) {
        guard on ?? prefs.usesTabGroups else { return }
        let representatives = displayedTabs
        let pins = representatives.filter { $0.pin != nil }
        let grouped = tabGroups.flatMap { group in representatives.filter { self.group(of: $0) == group.id } }
        let ungrouped = representatives.filter { $0.pin == nil && group(of: $0) == nil }
        let order = (pins + grouped + ungrouped).flatMap { tab -> [Tab] in
            guard let pair = split(for: tab), pair.left == tab.id else { return [tab] }
            return pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        }
        // Setting the row runs this again, which then finds nothing to do.
        guard !order.elementsEqual(tabs, by: { $0.id == $1.id }) else { return }
        tabs = order
    }

    /// The group a tab is shown in: none for a pin, or for a group this space
    /// doesn't have, which is shown with the loose tabs rather than lost.
    func group(of tab: Tab) -> UUID? {
        guard tab.pin == nil, let id = tab.groupID, tabGroups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func tabs(in group: UUID?) -> [Tab] {
        tabs.filter { $0.pin == nil && self.group(of: $0) == group }
    }

    /// A folded group shows its name alone — and the tab you are on, if it
    /// is in there, so the page on screen always has its place in the row.
    func visibleTabs(in group: TabGroup) -> [Tab] {
        let members = tabs(in: group.id)
        let shown = members.filter(standsInRow)
        return group.collapsed ? shown.filter { $0.id == (activeSplit?.left ?? activeID) } : shown
    }

    /// A group lasts as long as its tabs: the last one gone, it goes too.
    private func removeEmptyGroup(_ id: UUID?) {
        guard let id, !tabs.contains(where: { $0.groupID == id }) else { return }
        tabGroups.removeAll { $0.id == id }
        if editingGroupID == id { editingGroupID = nil }
    }

    /// The tabs as they are on screen: with groups on, the ones folded away
    /// in a group are not among them. ⌘1–9 and ⌃Tab count these, so the key
    /// goes to the tab you see in that place, never to one you can't.
    var shownTabs: [Tab] {
        guard prefs.usesTabGroups else { return displayedTabs }
        return displayedTabs.filter { $0.pin != nil }
            + tabGroups.flatMap { visibleTabs(in: $0) }
            + tabs(in: nil).filter(standsInRow)
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

    /// ⌘1–8: the tab in that place on screen.
    func select(index: Int) {
        let shown = shownTabs
        guard shown.indices.contains(index) else { return }
        select(entry(shown[index]))
    }

    /// ⌃Tab with the switcher on: the space's tabs, the most recently used
    /// first. Nothing changes until ⌃ is let go of (`commitTabSwitch`).
    func switchTabs(backwards: Bool) {
        guard let activeID else { return }
        // A pair once, under its first page, pictured with its other one.
        tabSwitcher.partners = prefs.splitView
            ? Dictionary(splits.map { ($0.left, $0.right) }, uniquingKeysWith: { first, _ in first }) : [:]
        tabSwitcher.step(row: tabs.filter(standsInRow).map(\.id), current: activeSplit?.left ?? activeID,
                         backwards: backwards)
    }

    /// A click while the switcher is up, at a point in the window's own
    /// top-left coordinates: on a card, that card; outside the panel, the
    /// switcher goes. True when the click was the switcher's. Taken before any
    /// view sees it, because ⌃ is held for as long as the switcher is up, and
    /// a ⌃-click is a right-click to AppKit, not a click the card's button
    /// can be counted on to take. From #358, by oddharsh.
    func clickTabSwitcher(at point: CGPoint) -> Bool {
        guard tabSwitcher.visible else { return false }
        guard tabSwitcher.panelFrame.contains(point) else {
            tabSwitcher.cancel()
            return true
        }
        // Between two cards: the switcher's, and nothing happens.
        if let id = tabSwitcher.card(at: point) { commitTabSwitch(picking: id) }
        return true
    }

    func commitTabSwitch(picking id: Tab.ID? = nil) {
        guard let target = tabSwitcher.finish(picking: id),
              let tab = tabs.first(where: { $0.id == target }) else { return }
        select(entry(tab))
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
        // A link opened from a grouped tab joins its group, only while groups
        // are on: turned off, they sleep, and nothing new goes into one.
        if prefs.usesTabGroups, let source, !tab.shy, !tab.bench { tab.groupID = source.groupID }
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
        fresh.name = tab.name
        prepare(fresh)
        fresh.groupID = tab.groupID
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

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held, or when the one you are on is busy playing in the float.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true, from: active)
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
            bookmarking = false
            bookmarksOpen = false
        }
        if inNewTab {
            open(url, foreground: foreground, from: active, mayWait: true)
        } else {
            visit(url)
        }
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        // Never two empty private tabs, as ⌘T never makes two empty ones:
        // one already open comes to the end of the row and is the one opened.
        if let blank = tabs.last(where: { $0.isBlank && $0.shy && !$0.bench }) {
            if let end = tabs.indices.last, tabs.firstIndex(where: { $0.id == blank.id }) != end {
                move(blank, to: end)
            }
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
        adopt(tab)
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

    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        guard let tab = active, !tab.isBlank, let window = NSApp.keyWindow else { return }
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
        var restored = restoreRow(saved, space: space, groups: saved.groups ?? [])
        if restored.active == nil { restored.active = restored.tabs.first?.id }
        restored.groups = saved.groups
        return restored
    }

    private func restoreRow(_ saved: Session.Shape, space: UUID, groups: [TabGroup]) -> Parked {
        var row: [Tab] = []
        var bySavedIndex: [Int: Tab] = [:]
        for (savedIndex, entry) in saved.tabs.enumerated() {
            // An empty page is never written; the first builds of Split View
            // on main wrote one for an empty half.
            guard let url = URL(string: entry.url), entry.url != "about:blank" else { continue }
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.listed = entry.pin != nil && entry.listed == true
            tab.home = Browser.home(of: entry, at: url)
            tab.groupID = entry.pin == nil && groups.contains(where: { $0.id == entry.groupID })
                ? entry.groupID : nil
            row.append(tab)
            bySavedIndex[savedIndex] = tab
        }
        let said = bySavedIndex[saved.active]?.id
        row = reconcilePins(row, space: space)
        // Pairs, whether Split View is on or not: off, they wait, as groups
        // do. Each tab in one pair at most, and only a pair that still holds.
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
    func showRow(_ row: [Tab], active: Tab.ID?, splits restored: [TabSplit] = []) {
        splits = restored
        tabs = row
        activeID = active ?? row.first?.id
    }

    private func replaceSplitMember(_ old: Tab.ID, with new: Tab.ID) {
        guard let index = splits.firstIndex(where: { $0.contains(old) }) else { return }
        splits[index].replace(old, with: new)
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        guard let here = tabs.firstIndex(where: { $0.id == activeID }) else { return tabs.count }
        let after = activeSplit.flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? here
        return max(after + 1, pinnedCount)
    }

    /// A tab made outside the row — a peek being kept — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: safeInsertionIndex(index))
        rememberSession()
    }

    private func safeInsertionIndex(_ proposed: Int) -> Int {
        let index = min(max(0, proposed), tabs.count)
        guard index < tabs.count, split(for: tabs[index]).map({ $0.left != tabs[index].id }) == true else { return index }
        return index + 1
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    private func leaving() {
        guard prefs.floatsOnLeave else { return }
        lift(active, quietly: true, otherwise: otherPane)
    }

    /// With a pair on screen, its other page: what floats when the focused
    /// one has nothing playing.
    private var otherPane: Tab? {
        guard let pair = activeSplit, let id = activeID else { return nil }
        return tabs.first { $0.id == pair.partner(of: id) }
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Search
    /// comes back.
    private var liftedAway = false

    func appLeft() {
        guard prefs.floatsAway, Browsers.front == nil || Browsers.front === self else { return }
        liftedAway = !floater.showing
        lift(active, quietly: true, otherwise: otherPane)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = floating, id == activeID { land() }
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        lift(active, quietly: false, otherwise: otherPane)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    /// `otherwise`: the other page of a pair, tried when this one has
    /// nothing playing.
    private func lift(_ tab: Tab?, quietly: Bool, otherwise: Tab? = nil) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else {
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        // A video filling the screen stays in its own space, as in Safari.
        // Its page is lent to WebKit's full-screen window, and moving it out
        // into the floating one left that window up, empty and black, to
        // come back to.
        guard tab.web.fullscreenState == .notInFullscreen else { return }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. Nor from one you grounded in
        // its site card. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map(Grounded.holds) == true {
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        tab.web.evaluateInSearch(Isolate.on) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
                    if let otherwise { return self.lift(otherwise, quietly: quietly) }
                    if !quietly { self.announce("Nothing is playing here") }
                    return
                }
                self.floating = tab.id
                tab.floating = true
                self.ownFloater()
                self.floater.lift(tab.web)
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
        // Another window's video: that window takes it back.
        if floating == nil, let owner = Browsers.all.first(where: { $0 !== self && $0.floating != nil }) {
            return owner.land()
        }
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        guard let id = floating, let tab = tabs.first(where: { $0.id == id }) else { return }
        floating = nil
        tab.floating = false
        tab.web.evaluateInSearch(Isolate.off)
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
            guard let self, prefs.showsLinks, visibleTabIDs.contains(tab.id) else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
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
        tab.onMiddleClick = { [weak self] tab, url in self?.open(url, foreground: false, from: tab, mayWait: true) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot, passwords in
            self?.hang(from: tab, spot, passwords: passwords)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            // an extension's own page isn't a site: Bitwarden's unlock pin was offered as its password.
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host), tab.address.flatMap(Browser.extensionHost(of:)) == nil
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.shared.passwordSavingTakenBy != nil { return }
            let known = Vault.logins(for: host)
            // Nothing to ask about one that is already known.
            if var same = known.first(where: { $0.user == user && $0.password == password }) {
                // Where it was last used is where it is offered from now on.
                same.clear = clear
                Vault.touch(same)
                return
            }
            let offer = Offer(
                login: Login(host: host, user: user, password: password, used: nil, clear: clear),
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
                guard let tab, !tab.shy, let url = tab.address else { return }
                self?.history.retitle(url, title)
            }
            .store(in: &bag)
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

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
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    private func guess() {
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
        let site = prefs.searchesSites && !summoning ? SiteSearch.match(typed) : nil
        if siteOffer != site { siteOffer = site }

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
        let command = prefs.commandBar ? AddressCommand.matching(typed, in: self) : nil
        if let command { list.insert(.command(command), at: 0) }
        offers = list
        // Neither a page already open nor a command has an address to
        // complete towards. And with a command on top, Return runs it: a
        // grey ending in the field ("history" finishing as history.com)
        // would promise a place Return doesn't go to.
        ending = command != nil ? nil
            : history.completion(for: typed, among: offers.filter { $0.kind != .open && !$0.kind.isCommand })
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
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
        guard prefs.searchesSites, siteChip == nil, let site = siteOffer else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    /// Tab, or the right arrow at the end of the line: take what is offered.
    func acceptEnding() {
        guard let ending, !ending.isEmpty else { return }
        typed += ending
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
        summoning = false
        // Never a name and password written into the address: they would be
        // on screen, and in whatever you copy from here.
        typed = active?.address.map { url -> String in
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
        if aside {
            // Opened behind the page by hand, as a ⌘-clicked link is: it may
            // wait to load (Settings › Tabs › Load background tabs…).
            open(url, foreground: front, from: active, mayWait: true)
        } else {
            (active ?? tabs.first)?.go(to: url)
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

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Every navigation is decided in `decide` below; this form of the
    /// question also hands over the page's preferences, the only place a
    /// site allowed to play sound by itself can say so (see Autoplay). Only
    /// a page that is allowed to load, in the tab's own frame, is touched.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decide(webView, action) { [weak self] policy in
            if policy == .allow, action.targetFrame?.isMainFrame ?? true, let url = action.request.url {
                let shy = self?.tab(for: webView)?.shy == true || !webView.configuration.websiteDataStore.isPersistent
                Autoplay.apply(to: preferences, for: url, shy: shy)
            }
            decisionHandler(policy, preferences)
        }
    }

    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    private func decide(
        _ webView: WKWebView,
        _ action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView)
            || AISignIn.intercept(url, mainFrame: action.targetFrame?.isMainFrame == true, in: tab(for: webView), browser: self) {
            decisionHandler(.cancel)
            return
        }

        // 0.0.0.0, as a dev server prints it: this Mac, as localhost (see
        // Address.reachable). Only the page itself; a frame goes nowhere.
        if action.targetFrame?.isMainFrame == true, let local = Address.reachable(url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: local))
            return
        }

        // A website returning to a public extension page needs another view.
        if #available(macOS 15.4, *), routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // Shift-click, when Settings says so: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
           let from = tab(for: webView), peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            open(url, foreground: action.modifierFlags.contains(.shift), from: tab(for: webView), mayWait: true)
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain.css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    @available(macOS 15.4, *)
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    @available(macOS 15.4, *)
    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab) -> Bool {
        guard !tab.shy,
              let context = Extensions.shared.controller.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            self.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        tab(for: webView)?.extensionReturn.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect, #available(macOS 15.4, *),
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. The page itself
    /// may ask, or a frame of the page's own site — Zoom's, Teams' and
    /// Slack's "open the app" pages load it into a frame of their own from a
    /// script — or a click inside any frame. A frame from another site that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        let source: WKFrameInfo? = action.sourceFrame
        let top = webView.url?.host()?.lowercased() ?? ""
        let asker = source?.securityOrigin.host.lowercased() ?? ""
        let ownSite = source?.isMainFrame == true
            || (!top.isEmpty && !asker.isEmpty && Vault.registrable(asker) == Vault.registrable(top))
        // No target frame is a new window asked for: the frame asking is
        // judged, as for any other frame.
        guard action.targetFrame?.isMainFrame ?? false || clicked || ownSite else {
            if Store.testing { Browser.handedOff.append("\(scheme): ignored") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if Store.testing { Browser.handedOff.append("\(scheme): no app") }
            return
        }
        // A test run can't show the question (see Dialogs): it says it would.
        if Store.testing {
            Browser.handedOff.append("\(scheme): asked")
            return
        }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(name)\u{201D}?"
            alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                guard answer == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        }, drop: {})
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let from = tab(for: webView)?.id ?? activeID
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        let tab = Tab(shy: tab(for: webView)?.shy ?? false, configuration: configuration)
        tab.popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        adopt(tab)
        tab.opener = from
        activeID = tab.id
        editing = false
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It forgets the address; and
    /// when a page's link opened it, it closes, as in Safari and Chrome, and
    /// you are back on that page. A tab you opened yourself stays, as a new
    /// tab, and so does a window's only tab: closing it would close the
    /// window.
    private func dropEmpty(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.committed == nil, tab.pin == nil else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        guard let opener = tab.opener, tabs.count > 1 else { return }
        if tab.id == activeID, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(
        _ download: WKDownload,
        from suppliedWebView: WKWebView? = nil,
        continuing entry: FetchEntry? = nil,
        operationID: UUID? = nil,
        helper: WKWebView? = nil
    ) {
        let webView = suppliedWebView ?? download.webView
        // Find privacy before publishing the entry. A private transfer is
        // still tracked internally so its delegate and Finder progress clean
        // up correctly, but it never enters the shared Downloads panel.
        let isPrivate = entry == nil && webView.map {
            !$0.configuration.websiteDataStore.isPersistent || anyTab(for: $0)?.shy == true
        } == true
        download.delegate = self
        if !downloading.contains(where: { $0 === download }) { downloading.append(download) }
        if isPrivate { unlisted.insert(ObjectIdentifier(download)) }
        else { unlisted.remove(ObjectIdentifier(download)) }
        guard fetches.start(
            download,
            owner: self,
            webView: webView,
            listed: !isPrivate,
            entry: entry,
            operationID: operationID,
            helper: helper
        ) else {
            relinquish(download)
            download.cancel { _ in }
            return
        }
        // A true resume may continue the preserved target without asking its
        // delegate for a destination again. Publish Finder progress as soon
        // as the resumed WKDownload is attached; `going` coalesces a later
        // destination callback for the same URL.
        if entry != nil, let destination = entry?.destination {
            fetches.going(download, to: destination, cancel: finderCancellation(for: download))
        }
    }

    /// Pause an active download. WebKit's cancellation callback is the
    /// authoritative source of resume data and also owns cleanup if no
    /// delegate failure callback arrives.
    func pauseDownload(_ entry: FetchEntry) {
        guard entry.canPause, let operation = fetches.beginStop(entry, action: .pause) else { return }
        stopDownload(operation)
    }

    func resumeDownload(_ entry: FetchEntry) {
        guard let operation = fetches.beginResume(entry), let data = operation.resumeData else { return }
        operation.webView.resumeDownload(fromResumeData: data) { download in
            self.continueDownload(download, operation)
        }
    }

    /// From the start, to the folder it went to, under the name it was asked
    /// for: numbered afresh, " 2" and on, past whatever is there now, the
    /// last attempt's half-written file let go first.
    func retryDownload(_ entry: FetchEntry) {
        let folder = entry.destination?.deletingLastPathComponent() ?? downloadsFolder
        guard let operation = fetches.beginRetry(entry, destination: { Self.free(entry.retryName, in: folder) }),
              let request = operation.request else { return }
        operation.webView.startDownload(using: request) { download in
            self.continueDownload(download, operation)
        }
    }

    private func continueDownload(_ download: WKDownload, _ operation: Fetches.StartOperation) {
        guard fetches.accepts(operation) else {
            download.cancel { _ in }
            return
        }
        keep(
            download, from: operation.webView, continuing: operation.entry, operationID: operation.operationID,
            helper: operation.helper ? operation.webView : nil
        )
    }

    /// Active rows stop; paused and failed rows are removed and release their
    /// in-memory resume data and the store they were asked with.
    func cancelDownload(_ entry: FetchEntry) {
        switch entry.state {
        case .downloading:
            guard let operation = fetches.beginStop(entry, action: .cancel) else { return }
            stopDownload(operation)
        case .pausing:
            _ = fetches.upgradeStopToCancel(entry)
        case .resuming:
            fetches.removeStarting(entry)
        case .paused, .failed:
            fetches.removeStopped(entry)
        }
    }

    /// A space deleted: its downloads go with it, whatever they were doing,
    /// as Cancel or Remove would take them, and with them the store they
    /// kept and any view made to ask with it. Its cookies can then be
    /// erased, and nothing is asked with them again.
    func forgetDownloads(of store: WKWebsiteDataStore) {
        for entry in fetches.entries where entry.store === store { cancelDownload(entry) }
    }

    private func stopDownload(_ operation: Fetches.StopOperation) {
        let fetches = self.fetches
        operation.download.cancel { resumeData in
            DispatchQueue.main.async {
                guard let ended = fetches.stopped(operation, resumeData: resumeData) else { return }
                ended.owner.relinquish(operation.download)
            }
        }
    }

    /// Called for both delegate completion and WKDownload.cancel completion;
    /// idempotence handles WebKit choosing either callback order.
    func relinquish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
    }

    private func finderCancelled(_ download: WKDownload) {
        guard let operation = fetches.beginFinderStop(download) else { return }
        stopDownload(operation)
    }

    private func finderCancellation(for download: WKDownload) -> @Sendable () -> Void {
        { [weak self, weak download] in
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.finderCancelled(download)
            }
        }
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// The camera or microphone, for a tab's page or an extension's popup.
    ///
    /// Remembered for the origin that asked — http://site and https://site,
    /// or another port, are other sites — and never for a private tab, which
    /// leaves nothing behind. An extension's page asking — its popup, or a
    /// frame of its own inside a website (a recorder's camera bubble) — is
    /// named as the extension and remembered for it, never for the site it
    /// sits in: allowing the bubble must not give the site the camera.
    func askedForCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                         decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // An extension capturing, however it went about it: the pill says so.
        if #available(macOS 15.4, *) { ExtensionCapture.shared.watchCapture(webView, frame: frame) }
        let asker = frame.securityOrigin
        let host: String
        let site: String
        if Browser.extensionScheme(asker.protocol) {
            host = Browser.extensionName(asker.host)
            site = "\(asker.protocol.lowercased())://\(asker.host.lowercased())"
        } else {
            host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
            site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        }
        let key = "\(site)|\(type.rawValue)"
        let shy = tab(for: webView).map { $0.shy || !webView.configuration.websiteDataStore.isPersistent } ?? false

        if !shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // Asked over its own page only, as a page's other questions are (see
        // ask): a tab behind, or the other page of a pair, waits until you go
        // to it, and is asked then — never over the page you are on.
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(.deny) }
            // One question at a time. A second page asking while the first is
            // still waiting is refused rather than queued behind it.
            guard decide == nil else { return decisionHandler(.deny) }
            decide = decisionHandler
            askedAbout = shy ? "" : key
            asking = CaptureAsk(host: host, wants: Browser.name(for: type))
        }, drop: { decisionHandler(.deny) })
    }

    /// An extension's own scheme, today's or the one it had before.
    static func extensionScheme(_ scheme: String) -> Bool {
        ["chrome-extension", "webkit-extension"].contains(scheme.lowercased())
    }

    /// An extension by the name it shows, for a question it asks.
    static func extensionName(_ id: String) -> String {
        if #available(macOS 15.4, *), let found = Extensions.shared.installed.first(where: { $0.id.lowercased() == id.lowercased() }) {
            return found.name
        }
        return "An extension"
    }

    /// A page asking where you are. WebKit asks this through a delegate
    /// method that isn't public on the Mac; unanswered, every page is refused.
    ///
    /// Only the page on screen, and only for itself: the tab in front, and
    /// the page's own origin or a frame of that same origin. WebKit already
    /// keeps frames from elsewhere out unless the page lets them in
    /// (allow="geolocation"); here they don't get to borrow the page's
    /// answer at all. Remembered per origin, as the camera is, and never for
    /// a private tab.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func askedForLocation(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let give: (WKPermissionDecision) -> Void = { decision in
            guard Store.testing else { return decisionHandler(decision) }
            Browser.locationAnswered = decision == .grant ? "granted" : "denied"
            decisionHandler(.deny)
        }
        // WebKit names the page's origin for a frame it let in, whoever the
        // frame is: the frame's own is what counts.
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        let asker = frame.securityOrigin
        guard let tab = tab(for: webView), tab.id == activeID, !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              site == Browser.origin(scheme, host, page.port ?? 0),
              Browser.origin(asker.protocol, asker.host, asker.port) == site
        else { return give(.deny) }
        let key = "\(site)|location"
        if !tab.shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            return give(remembered ? .grant : .deny)
        }
        // One question at a time, as for the camera.
        guard decide == nil else { return give(.deny) }
        decide = give
        askedAbout = tab.shy ? "" : key
        let named = Browser.extensionScheme(origin.protocol) ? Browser.extensionName(origin.host) : origin.host
        asking = CaptureAsk(host: named, wants: "location", once: true, keeps: !tab.shy)
    }

    /// A page asking to send notifications. Asked over its own page, as the
    /// camera is, and only for the page's own origin; kept per origin under
    /// the same "capture." keys, so Forget choices takes it back. A private
    /// tab, or Settings › Privacy's switch off, is refused without a card.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func askedForNotifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        guard prefs.siteNotifications, let tab = tab(for: webView), !tab.shy, webView.configuration.websiteDataStore.isPersistent,
              !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              Browser.origin(scheme, host, page.port ?? 0) == site
        else { return decisionHandler(false) }
        if let remembered = SiteNotifications.choices[site] { return decisionHandler(remembered) }
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(false) }
            guard decide == nil else { return decisionHandler(false) }
            decide = { decision in
                if decision == .grant { SiteNotifications.shared.authorize() }
                decisionHandler(decision == .grant)
                SiteNotifications.shared.objectWillChange.send()
            }
            askedAbout = "\(site)|notifications"
            asking = CaptureAsk(host: origin.host, wants: "notifications")
        }, drop: { decisionHandler(false) })
    }

    /// "scheme://host[:port]", the way an origin is kept for its answers.
    static func origin(_ scheme: String, _ host: String, _ port: Int) -> String {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)" + (port == 0 || standard ? "" : ":\(port)")
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.didCommit()
        tab.extensionReturn.finished(navigation)
        if tab.id == activeID {
            invalidateFindPage(retryOnActiveTab: false)
            linkStatus.dismiss()
        }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = anyTab(for: webView), let url = tab.address else { return }
        tab.uncover()
        // The find bar still open over a page that has just come in: look
        // for the same words on it.
        if tab.id == activeID, finding, findSpec == nil,
           !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            look(forward: true)
        }
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
        // A site's home page that says where its search is (OpenSearch):
        // with Search a site on, it joins the list (see SiteSearch.learn).
        if prefs.searchesSites, url.scheme == "https", url.path.isEmpty || url.path == "/" {
            webView.evaluateInSearch(SiteSearch.lookup) { value in
                guard let text = value as? String, let description = URL(string: text) else { return }
                MainActor.assumeIsolated { SiteSearch.learn(from: url, description: description) }
            }
        }
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        tab(for: webView)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        tab(for: webView)?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }

    /// The tab a page belongs to, in the space on screen or another: a page
    /// still loading when you went to another space finishes there, and
    /// still goes into History with its icon.
    func anyTab(for webView: WKWebView) -> Tab? {
        tab(for: webView) ?? parkedTabs.first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let chosen = fetches.destination(for: download)
        let name = Browser.fileName(asked ?? suggestedFilename)
        let file = chosen ?? whereToSave(name)
        guard let file else {
            if let ended = fetches.destinationCancelled(download) {
                ended.owner.relinquish(download)
            } else {
                relinquish(download)
            }
            completionHandler(nil)
            return
        }
        fetches.going(download, to: file, cancel: finderCancellation(for: download))
        // A retry is numbered afresh from the name asked for, or the one you
        // gave it: never from "report 2.pdf", whose own " 2" is not its name.
        if chosen == nil { fetches.entry(for: download)?.retryName = prefs.asksWhereToSave ? file.lastPathComponent : name }
        completionHandler(file)
        announce("Downloading \(file.lastPathComponent)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = fetches.entry(for: download)
        let source = download.originalRequest?.url ?? entry?.request?.url
        let file = download.progress.fileURL ?? entry?.destination
        let listed = !unlisted.contains(ObjectIdentifier(download))
        let ended = fetches.finish(download, file: file)
        (ended?.owner ?? self).relinquish(download)
        guard ended != nil else { return }
        guard let file else {
            announce("Download finished")
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)")
            return
        }
        if #available(macOS 15.4, *), let asked = source,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: source)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let file = whereToSave(suggestedFilename ?? "") else { return }
        do {
            try data.write(to: file)
            saved(file, from: originatingURL)
        } catch {
            announce("Download failed")
        }
    }

    /// A page's own print(): the Print… item in a page's own menu, or ⌘P in
    /// an editor that keeps the key for itself (the page has it first, see
    /// `pageFirst`). WebKit hands it to a delegate that answers this name,
    /// outside the public framework, and to nobody otherwise: the button did
    /// nothing at all, and neither did ⌘P.
    ///
    /// The page waits while the sheet is up, as it does in Safari: WebKit
    /// holds its script until `done`, and draws the pages meanwhile. Only the
    /// tab in front of the window you are in may ask, one sheet at a time: a
    /// tab behind, or another window's, is answered with nothing, as Safari
    /// does. And a site that asks again each time the sheet is cancelled
    /// asks no more after the second cancel within ten seconds, until the
    /// tab goes to another site (see PrintSheet).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: NSObject,
        pdfFirstPageSize: CGSize,
        completionHandler done: @escaping () -> Void
    ) {
        guard let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
              let tab = anyTab(for: webView), tab.id == activeID, !tab.isBlank,
              PrintSheet.allows(tab)
        else { done(); return }
        let sheet = PrintSheet(tab) { done() }
        Browser.printing(webView, frame: frame).runModal(
            for: window, delegate: sheet,
            didRun: #selector(PrintSheet.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(sheet).toOpaque()
        )
    }

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled. The name
    /// comes from the page, so only its last part is taken: never a path
    /// out of the folder.
    private func whereToSave(_ name: String) -> URL? {
        let name = Browser.fileName(name)
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func fileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return ["", ".", "..", "/"].contains(last) ? "download" : last
    }

    private func saved(_ file: URL, from source: URL?) {
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date()))
        announce("Saved \(file.lastPathComponent)", file: file)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard let ended = fetches.fail(download, error: error, resumeData: resumeData) else { return }
        ended.owner.relinquish(download)
        if ended.announceFailure { announce("Download failed") }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// What a page's print() is waiting on: told when the sheet has gone,
/// printed or cancelled, so WebKit can let the page's script go on. The
/// sheet's context keeps it alive until then.
@MainActor
final class PrintSheet: NSObject {
    private let done: () -> Void
    private let tab: Tab.ID
    private let site: String?

    init(_ tab: Tab, _ done: @escaping () -> Void) {
        self.tab = tab.id
        self.site = PrintSheet.site(of: tab)
        self.done = done
    }

    /// The sheets a page's print() had cancelled, by tab, on the site it
    /// was on: its origin, not its address, which the page itself can
    /// change with history.pushState between two print()s. Two cancels
    /// within ten seconds and the site asks no more, until the tab goes to
    /// another site or closes.
    private struct Cancels {
        var site: String?
        var when: [Date] = []
        var blocked = false
    }
    private static var cancelled: [Tab.ID: Cancels] = [:]

    private static func site(of tab: Tab) -> String? {
        guard let page = tab.committed else { return nil }
        return "\(page.scheme ?? "")://\(page.host() ?? ""):\(page.port.map(String.init) ?? "")"
    }

    /// Whether this tab's site may bring the sheet up again.
    static func allows(_ tab: Tab) -> Bool {
        guard let seen = cancelled[tab.id], seen.site == site(of: tab) else {
            cancelled[tab.id] = nil
            return true
        }
        return !seen.blocked
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheet>.fromOpaque(contextInfo).release() }
        if !success {
            var seen = PrintSheet.cancelled[tab].flatMap { $0.site == site ? $0 : nil } ?? Cancels(site: site)
            let now = Date()
            seen.when = seen.when.filter { now.timeIntervalSince($0) < 10 } + [now]
            if seen.when.count >= 2 { seen.blocked = true }
            PrintSheet.cancelled[tab] = seen
        }
        done()
    }
}
