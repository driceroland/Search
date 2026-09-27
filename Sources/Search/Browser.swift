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
    /// With groups on, every change to the row ends with it put back in the
    /// order it is shown in (see arrangeGroupedTabs): a tab made by a link,
    /// Peek, the little window or Move to Space lands wherever its own code
    /// puts it, and is then taken to its group or out of the groups' way.
    /// ⌘1–9, ⌃Tab and the extensions' tab indexes read this row, so it and
    /// what is on screen never disagree.
    @Published private(set) var tabs: [Tab] = [] {
        didSet { arrangeGroupedTabs() }
    }
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
            guard oldValue != activeID, let old = oldValue else { return }
            linkStatus.dismiss()
            let left = tabs.first { $0.id == old }
            left?.touch()
            // The switcher's order and pictures, most recently used first.
            tabSwitcher.cancel()
            if let left { tabSwitcher.left(left, alive: Set((tabs + parkedTabs).map(\.id))) }
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
    @discardableResult
    func takeBookmarks(from source: ImportSource, profile: String? = nil, replacing: Bool = false) -> (added: Int, already: Int) {
        let found = source.bookmarks(profile: profile)
        if replacing, let earlier = ImportRecords.of(source.name), !earlier.bookmarkIDs.isEmpty {
            bookmarks.withdraw(earlier.bookmarkIDs)
            ImportRecords.forgetBookmarks(source.name)
        }
        let (count, already, ids) = bookmarks.takeNoting(found, from: source.name)
        ImportRecords.note(source.name, bookmarks: ids, bookmarks: count)
        announce(
            Bookmarks.count(found) == 0 ? "No bookmarks in \(source.name)"
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
        return (count, already)
    }

    /// The "Bring things over" sheet, open while set: the browser it
    /// starts on by name, or "" for the first one found.
    @Published var bringingIn: String?
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
    @Published var editing = false
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
    @Published var needle = "" { didSet { look(forward: true) } }
    /// Set when the page doesn't hold what was asked for.
    @Published private(set) var missed = false
    @Published private(set) var findFocus = 0

    func openFind() {
        guard active?.isBlank == false else { return }
        finding = true
        findFocus += 1
    }

    func closeFind() {
        guard finding else { return }
        finding = false
        needle = ""
        missed = false
        // There is no public way to call off a find, but letting go of the
        // selection is what taking the highlight away amounts to.
        active?.web.evaluateJavaScript("window.getSelection().removeAllRanges()")
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = active?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let web = active?.web, !needle.isEmpty else {
            missed = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        web.find(needle, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.missed = !result.matchFound }
        }
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

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText, .zip, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bring In"
        panel.message = "A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        announce(takeFile(url).said)
    }

    /// The file's bookmarks, history and passwords, taken in as a browser's
    /// are: bookmarks merged without doubles, history counted once. Says
    /// what came in, and after Safari's export, that the file holds your
    /// passwords in the clear.
    @discardableResult
    func takeFile(_ url: URL) -> (said: String, bookmarks: Int, already: Int, places: Int, kept: Int, skipped: Int) {
        let found = ImportFile.read(url)
        guard !found.isEmpty else {
            return ("Nothing to bring in from that file", 0, 0, 0, 0, 0)
        }
        let name = found.fromSafari ? "Safari" : url.deletingPathExtension().lastPathComponent
        let (added, already) = bookmarks.take(found.bookmarks, from: name)
        for place in found.places { history.take(place.url, title: place.title, count: place.count, last: place.last) }
        if !found.places.isEmpty { history.settle() }
        var kept = 0, skipped = 0
        for text in found.passwords {
            let result = Vault.take(csv: text)
            kept += result.kept
            skipped += result.skipped
        }
        if !found.passwords.isEmpty { relist() }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if added > 0 || already > 0 {
            parts.append(already == 0 ? count(added, "bookmark", "bookmarks") : "\(count(added, "new bookmark", "new bookmarks")), \(already) already here")
        }
        if !found.places.isEmpty { parts.append(count(found.places.count, "place", "places")) }
        if kept > 0 || skipped > 0 {
            parts.append(skipped == 0 ? count(kept, "password", "passwords") : "\(count(kept, "password", "passwords")), \(skipped) skipped")
        }
        var said = parts.joined(separator: " · ")
        if found.fromSafari, kept > 0 {
            said += " — the exported file holds your passwords in the clear: delete it now"
        }
        return (said, added, already, found.places.count, kept, skipped)
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
        // The sites' icons are a list of where you have been, too.
        Favicons.shared.forgetAll()
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
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func denyCapture() { answerCapture(.deny) }

    private func answerCapture(_ decision: WKPermissionDecision) {
        guard let decide else { return }
        // Remembered per site, so a call you take every week asks once.
        if !askedAbout.isEmpty { Store.settings.set(decision == .grant, forKey: "capture." + askedAbout) }
        decide(decision)
        self.decide = nil
        askedAbout = ""
        asking = nil
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
        announce("Camera and microphone choices forgotten")
    }

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    @Published var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    func pin(_ tab: Tab) {
        // Pins are the space's, kept on disk and shown in every window: a
        // private tab can't be one, or its page would outlive it there.
        guard !tab.shy else { return }
        if tab.pin == nil {
            let previousGroup = tab.groupID
            tab.groupID = nil
            removeEmptyGroup(previousGroup)
            tab.pin = tab.monogram
            tab.home = tab.pending ?? tab.address
            // Pinned tabs live at the head of the row, in the order they were
            // pinned, so their letters never move under your hand.
            if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
                let home = max(0, pinnedCount - 1)
                if here != home {
                    tabs.move(
                        fromOffsets: IndexSet(integer: here),
                        toOffset: home > here ? home + 1 : home
                    )
                }
            }
        }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
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
        tab.pin = nil
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

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        let groupID: UUID?
        /// When it was closed, to weigh against a window closed since.
        var at = Date()

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

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
            Favicons.shared.arrived = { host, image in
                let lower = host.lowercased()
                for browser in Browsers.all {
                    for tab in browser.tabs + browser.parkedTabs {
                        guard let tabHost = tab.address?.host()?.lowercased() else { continue }
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
        // Built apart and put in the row at once: the saved front tab is
        // counted in the file's order, which the groups may rearrange.
        var row: [Tab] = []
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.home = Browser.home(of: entry, at: url)
            tab.groupID = entry.pin == nil && tabGroups.contains(where: { $0.id == entry.groupID })
                ? entry.groupID : nil
            row.append(tab)
        }
        let saidFront = row.indices.contains(saved.active) ? row[saved.active] : nil
        row = reconcilePins(row, space: spaceID)
        let front = saidFront.flatMap { f in row.contains { $0 === f } ? f : nil }
            ?? (saved.tabs.isEmpty ? nil : row.first { $0.pin == nil } ?? row.first)
        tabs += row
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
            Extensions.shared.whenStarted(within: 1.5) { [weak first] in _ = first?.wake() }
        } else {
            first.wake()
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
        writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups), now: now)
    }

    // MARK: - pins, the same in every window

    /// What makes this row's pinned tabs pins, in their order.
    private func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin, !tab.shy else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            return PinDef(id: tab.pinID ?? UUID(), letter: letter,
                          home: (tab.home ?? tab.pending ?? tab.address)?.absoluteString ?? "",
                          title: tab.title, name: tab.name)
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
            tab.home = URL(string: def.home)
            out.append(tab)
        }
        for gone in pinned { gone.close() }
        return out + loose
    }

    /// Another window changed a space's pins: this window's row there follows.
    func pinsChanged(in space: UUID) {
        if space == spaceID {
            let row = reconcilePins(tabs, space: space)
            if row.map(\.id) != tabs.map(\.id) { tabs = row }
            if !tabs.contains(where: { $0.id == activeID }) {
                activeID = tabs.first { $0.pin == nil }?.id ?? tabs.first?.id
                if activeID == nil { newTab() }
            }
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups), now: false)
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
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
    func takeArc(_ sidebar: ArcSidebar) -> (spaces: Int, pins: Int, tabs: Int) {
        var made = 0, pins = 0, added = 0
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
            }
            Pins.set(target.id, defs, from: self)
            pinsChanged(in: target.id)
            added += takeAsleep(Browser.opened(target.space?.pinned ?? []), into: target.id)
        }
        return (made, pins, added)
    }

    /// Arc's pinned list, folders opened out in their order.
    private static func opened(_ nodes: [ArcSidebar.Node]) -> [ArcSidebar.Item] {
        nodes.flatMap { node -> [ArcSidebar.Item] in
            switch node {
            case .item(let item): [item]
            case .folder(let folder): opened(folder.items)
            }
        }
    }

    /// Pages as tabs at the end of a space's row, asleep: the row on
    /// screen, a parked one, or the one saved for a space not brought up.
    private func takeAsleep(_ items: [ArcSidebar.Item], into space: UUID) -> Int {
        func asleep(_ item: ArcSidebar.Item) -> Tab {
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: item.url, title: item.title)
            return tab
        }
        func fresh(_ have: [String]) -> [ArcSidebar.Item] {
            var seen = Set(have)
            return items.filter { seen.insert($0.url.absoluteString).inserted }
        }
        if space == spaceID {
            let new = fresh(tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            tabs += new.map(asleep)
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups), now: true)
            return new.count
        }
        if var row = parked[space] {
            let new = fresh(row.tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            row.tabs += new.map(asleep)
            parked[space] = row
            return new.count
        }
        var row = readRow(space)
        let new = fresh(row.tabs.map(\.url))
        row.tabs += new.map { Session.Entry(url: $0.url.absoluteString, title: $0.title) }
        writeRow(space, row, now: true)
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
        rows[spaceID.uuidString] = session(tabs, active: activeID, groups: tabGroups)
        for (space, row) in parked {
            rows[space.uuidString] = session(row.tabs, active: row.active, groups: readRow(space).groups)
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
        tabs = []
    }

    private func session(_ tabs: [Tab], active id: Tab.ID?, groups: [TabGroup]? = nil) -> Session.Shape {
        var entries: [Session.Entry] = []
        var active = 0
        for tab in tabs {
            guard kept(tab), let url = tab.pending ?? tab.address else { continue }
            if tab.id == id { active = entries.count }
            entries.append(Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name,
                home: tab.pin == nil ? nil : tab.home?.absoluteString, groupID: tab.groupID,
                pinID: tab.pin == nil ? nil : tab.pinID
            ))
        }
        // The tab you were on isn't kept — a private or blank one: the one
        // kept just before it comes back in front, not the first of the row.
        if let id, let at = tabs.firstIndex(where: { $0.id == id }), !kept(tabs[at]) {
            active = max(0, tabs[..<at].filter(kept).count - 1)
        }
        let keptGroups = groups?.filter { group in
            entries.contains { $0.groupID == group.id }
        }
        return .init(tabs: entries, active: active, groups: keptGroups)
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
        let groups = readRow(space).groups
        writeRow(space, session(row.tabs, active: row.active, groups: groups), now: now)
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
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && !$0.shy }) {
            if let end = tabs.indices.last, tabs.firstIndex(where: { $0.id == blank.id }) != end {
                move(blank, to: end)
            }
            if activeID != blank.id { leaving() }
            activeID = blank.id
            summoning = false
            typed = ""
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
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab, floatPrevious: Bool = true) {
        // A folded group opens for the tab you go to in it. With groups off,
        // they are kept as they were and nothing about them is saved.
        if prefs.usesTabGroups, let id = tab.groupID,
           let index = tabGroups.firstIndex(where: { $0.id == id }), tabGroups[index].collapsed {
            tabGroups[index].collapsed = false
            writeSession(now: true)
        }
        // A peek is over the tab it was opened from; another tab puts it away.
        if peekTab != nil, tab.id != activeID { closePeek() }
        cancelTabEdit()
        summoning = false
        suggesting = nil
        // Back on a tab with the caret still in a box, the list may come again.
        looked = nil
        guard tab.id != activeID else { return }
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
        rememberSession()
        editing = false
        typed = ""
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }

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

        remember(tab, at: index)
        tab.close()
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        if activeID == tab.id {
            // The neighbour on the right, or the last one if there is no
            // right — through select(), same as everywhere else you land on
            // a tab, so one that was never built yet actually wakes up
            // instead of sitting there blank until a manual reload.
            select(tabs[min(index, tabs.count - 1)])
        }
        rememberSession()
    }

    /// Everything but this one. Pinned tabs are put down rather than removed —
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: Tab) {
        select(keep)
        // The list is read once: closing walks the row and can add to it.
        for tab in tabs.filter({ $0.id != keep.id }) {
            close(tab)
        }
        select(keep)
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text) else { return }
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
        reopen(ghost)
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        tab.groupID = prefs.usesTabGroups && tabGroups.contains(where: { $0.id == ghost.groupID })
            ? ghost.groupID : nil
        leaving()
        tabs.insert(tab, at: min(ghost.index, tabs.count))
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
    }

    private func remember(_ tab: Tab, at index: Int) {
        guard !tab.shy, let url = tab.address else { return }
        ghosts.append(Ghost(url: url, title: tab.title, index: index, groupID: tab.groupID))
        if ghosts.count > 12 { ghosts.removeFirst() }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }),
              index != here, tabs.indices.contains(index)
        else { return }
        // The pinned block and the loose one don't mix: a letter that wandered
        // into the middle of the titles would stop meaning anything.
        let pinned = pinnedCount
        if tab.pin != nil, index >= pinned { return }
        if tab.pin == nil, index < pinned { return }
        tabs.move(fromOffsets: IndexSet(integer: here), toOffset: index > here ? index + 1 : index)
        rememberSession()
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

        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        if activeID == tab.id {
            if tabs.count > 1 {
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
        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        if activeID == tab.id {
            if tabs.count > 1 {
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
        let blanks = tabs.filter { $0.isBlank && !$0.bench }
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

    func move(_ tab: Tab, toGroup id: UUID?) {
        guard tabs.contains(where: { $0.id == tab.id }), tab.pin == nil, !tab.shy, !tab.bench,
              id == nil || tabGroups.contains(where: { $0.id == id }) else { return }
        let previousGroup = tab.groupID
        tab.groupID = id
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
        let peers = tabs(in: group)
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
        let pins = tabs.filter { $0.pin != nil }
        let grouped = tabGroups.flatMap { group in tabs.filter { self.group(of: $0) == group.id } }
        let ungrouped = tabs.filter { $0.pin == nil && group(of: $0) == nil }
        let order = pins + grouped + ungrouped
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
        return group.collapsed ? members.filter { $0.id == activeID } : members
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
        guard prefs.usesTabGroups else { return tabs }
        return tabs.filter { $0.pin != nil }
            + tabGroups.flatMap { visibleTabs(in: $0) }
            + tabs(in: nil)
    }

    /// ⌃Tab, ⌃⇧Tab: the next tab on screen, round to the first again. It
    /// walks the whole row from the tab you are on, so it finds its way out
    /// even when that tab is one the row doesn't show.
    func step(_ direction: Int) {
        guard tabs.count > 1, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let shown = Set(shownTabs.map(\.id))
        for n in 1..<tabs.count {
            let next = tabs[((here + direction * n) % tabs.count + tabs.count) % tabs.count]
            if shown.contains(next.id) { select(next); return }
        }
    }

    /// ⌘1–8: the tab in that place on screen.
    func select(index: Int) {
        let shown = shownTabs
        guard shown.indices.contains(index) else { return }
        select(shown[index])
    }

    /// ⌃Tab with the switcher on: the space's tabs, the most recently used
    /// first. Nothing changes until ⌃ is let go of (`commitTabSwitch`).
    func switchTabs(backwards: Bool) {
        guard let activeID else { return }
        // With spaces, every space is a row of it, each space's tabs where
        // they are parked (made now for a space not visited since launch).
        var rows: [(space: Space, row: [Tab.ID], showing: Tab.ID?)] = []
        if prefs.usesSpaces, spaces.count > 1 {
            preloadSpaces()
            rows = spaces.map { space in
                space.id == spaceID
                    ? (space, tabs.map(\.id), activeID)
                    : (space, parked[space.id]?.tabs.map(\.id) ?? [], parked[space.id]?.active)
            }
        }
        tabSwitcher.step(row: tabs.map(\.id), current: activeID, backwards: backwards, spaces: rows)
    }

    func commitTabSwitch(picking id: Tab.ID? = nil) {
        guard let target = tabSwitcher.finish(picking: id) else { return }
        // A card in another space's row: that space, then the tab.
        if !tabs.contains(where: { $0.id == target }),
           let space = parked.first(where: { $0.value.tabs.contains { $0.id == target } })?.key {
            switchSpace(to: space)
        }
        guard let tab = tabs.first(where: { $0.id == target }) else { return }
        select(tab)
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
        fresh.name = tab.name
        prepare(fresh)
        fresh.groupID = tab.groupID
        let wasActive = activeID == tab.id
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
    /// looking at, and marked as not yours.
    @discardableResult
    func benchOpen(_ url: URL) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(bench: true, configuration: Browser.extensionConfiguration(for: url))
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
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let job = tab.web.printOperation(with: info)
        job.view?.frame = tab.web.bounds
        job.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        let saved = readRow(space)
        let savedGroups = saved.groups ?? []
        var row: [Tab] = []
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.home = Browser.home(of: entry, at: url)
            tab.groupID = entry.pin == nil && savedGroups.contains(where: { $0.id == entry.groupID })
                ? entry.groupID : nil
            row.append(tab)
        }
        let said = row.indices.contains(saved.active) ? row[saved.active].id : nil
        row = reconcilePins(row, space: space)
        let active = said.flatMap { id in row.contains { $0.id == id } ? id : nil } ?? row.first?.id
        return Parked(tabs: row, active: active)
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own.
    func showRow(_ row: [Tab], active: Tab.ID?) {
        tabs = row
        activeID = active ?? row.first?.id
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        guard let here = tabs.firstIndex(where: { $0.id == activeID }) else { return tabs.count }
        return max(here + 1, pinnedCount)
    }

    /// A tab made outside the row — a peek being kept — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        rememberSession()
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
        lift(active, quietly: true)
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Search
    /// comes back.
    private var liftedAway = false

    func appLeft() {
        guard prefs.floatsAway, Browsers.front == nil || Browsers.front === self else { return }
        liftedAway = !floater.showing
        lift(active, quietly: true)
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
        lift(active, quietly: false)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    private func lift(_ tab: Tab?, quietly: Bool) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else { return }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) { return }
        tab.web.evaluateInSearch(Isolate.on) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
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
        tab.onLink = { [weak self] tab, address in
            guard let self, prefs.showsLinks, tab.id == activeID else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
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
        tab.onField = { [weak self] tab, spot in
            guard let self else { return }
            guard let spot else {
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
            guard prefs.fillsPasswords, tab.id == activeID, pickedInto != tab.id,
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
            let known = Array(Vault.logins(matching: host).filter { !inTheClear || $0.clear }.prefix(5))
            suggesting = known.isEmpty ? nil : Suggesting(tab: tab.id, spot: spot, logins: known, host: host, clear: inTheClear)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host)
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

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            picked = nil
            return
        }

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
        typed = active?.address?.absoluteString ?? ""
        editing = true
        focusRequest += 1
    }

    func dismiss() {
        summoning = false
        cycling = false
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
    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
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
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView) {
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
        let alert = NSAlert()
        alert.messageText = "Open \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
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
        keep(download)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
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
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
        fetches.start(download)
        // Noted now, while its page is still there to ask: a private tab's
        // download is saved where you say, and left out of the list.
        if let web = download.webView, tab(for: web)?.shy == true { unlisted.insert(ObjectIdentifier(download)) }
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
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        // Remembered for the origin that asked — http://site and
        // https://site, or another port, are other sites — and never for a
        // private tab, which leaves nothing behind.
        let site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        let key = "\(site)|\(type.rawValue)"
        let shy = tab(for: webView)?.shy ?? false

        if !shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = shy ? "" : key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type))
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
        if tab.id == activeID { linkStatus.dismiss() }
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
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
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
        let file = whereToSave(asked ?? suggestedFilename)
        completionHandler(file)
        if let file {
            fetches.going(download, to: file)
            announce("Downloading \(file.lastPathComponent)")
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        fetches.finish(download, file: download.progress.fileURL)
        let listed = unlisted.remove(ObjectIdentifier(download)) == nil
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)")
            return
        }
        if #available(macOS 15.4, *), let asked = download.originalRequest?.url,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: download.originalRequest?.url)
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

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled. The name
    /// comes from the page, so only its last part is taken: never a path
    /// out of the folder.
    private func whereToSave(_ name: String) -> URL? {
        let last = (name as NSString).lastPathComponent
        let name = ["", ".", "..", "/"].contains(last) ? "download" : last
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
        fetches.fail(download)
        announce("Download failed")
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
