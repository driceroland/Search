import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

@MainActor
final class Browser: NSObject, ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: Tab.ID? {
        didSet {
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            guard oldValue != activeID, let old = oldValue else { return }
            linkStatus.dismiss()
            tabs.first { $0.id == old }?.touch()
        }
    }

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
    let prefs = Preferences()
    let linkStatus = LinkStatus()
    /// The settings panel.
    @Published var tuning = false
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false

    // MARK: - bookmarks

    let bookmarks = Bookmarks()
    /// The full list, for taking things out.
    @Published var bookmarking = false
    /// The dropdown off the button.
    @Published var bookmarksOpen = false

    /// ⇧⌘B. The page you are on, at the end of the list.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        guard !bookmarks.contains(url) else {
            announce("Already a bookmark")
            return
        }
        bookmarks.add(url, title: tab.title)
        announce("Bookmarked")
    }

    /// Another browser's bookmarks, folders and all — and, behind them, the
    /// icons it had for those sites, so the menu wears them from the start
    /// instead of a letter each. Returns how many pages came over.
    @discardableResult
    func takeBookmarks(from source: Chromium.Source) -> Int {
        let found = Chromium.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.glide) { prefs.sidebar.toggle() }
    }

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? searchURL(for: typed)
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

    let history = History()
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

    let curtain = Curtain()
    let loot = Loot()
    let floater = Float()
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
        let spot: CGRect
        let logins: [Login]
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    private var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    private var lowering: DispatchWorkItem?

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
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.address) == list.host,
              (tab.address?.scheme?.lowercased() == "http") == list.clear
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

    /// What came back from another browser's store, put in the keychain.
    func took(_ outcome: Result<Chromium.Found, Error>, from source: Chromium.Source) {
        switch outcome {
        case .success(let found):
            var kept = 0
            for login in found.logins
            where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
                kept += 1
            }
            var never = Vault.never
            found.never.forEach { never.insert($0) }
            Vault.never = never
            relist()
            announce(kept == 0 ? "Nothing new in \(source.name)" : "\(kept) passwords from \(source.name)")
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(source.name) didn't give up its keychain key")
        case .failure:
            announce("Nothing readable in \(source.name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: Chromium.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Chromium.places(in: source)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                done(places.count)
            }
        }
    }

    /// Takes in a CSV as Google Password Manager exports one. The file is read
    /// once and never copied.
    func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A passwords export, as Chrome, Dia or Google Password Manager write it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            announce("Couldn't read that file as text")
            return
        }
        let result = Vault.take(csv: text)
        relist()
        announce(
            result.skipped == 0
                ? "\(result.kept) passwords in the keychain"
                : "\(result.kept) in the keychain, \(result.skipped) skipped"
        )
    }

    // MARK: - what is kept, and getting rid of it

    @Published var recalling = false
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
        Store.settings.set(decision == .grant, forKey: "capture." + askedAbout)
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
        if tab.pin == nil {
            tab.pin = tab.monogram
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
        tabDraft = Address.pretty(url)
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
        if draft.isEmpty || tab.address.map({ Address.pretty($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?

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

    func announce(_ text: String) {
        announcement = text
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announcement = nil }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
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

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Downloads still under way. See `keep(_:)`.
    var downloading: [WKDownload] = []
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
    /// A link's page, peeked at over this one (see Peek.swift).
    @Published var peekTab: Tab?
    /// Which way the last change of space went: 1 to the next, -1 back.
    @Published var spaceStep = 1

    // MARK: - beginning and ending

    override init() {
        super.init()
        Shield.shared.enabled = prefs.shielded
        Shield.shared.compile()
        if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
        if prefs.bench {
            Bench.shared.start(for: self)
        } else if prefs.benchRefused {
            announce("“Let a script drive Search” was turned on outside Settings, and stays off")
        }
        welcoming = !prefs.welcomed
        // Asked to stay out of the way: it starts that way (see Fold.swift).
        folded = prefs.sidebar && prefs.sideHides
        // Once a day, quietly: is there a newer one?
        Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
        FormRelay.passkeysOffered = prefs.passkeys

        // The History menu lists what the history holds, and the menu is drawn
        // from this object's changes — so the history's are passed on.
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it.
        Favicons.shared.arrived = { [weak self] host, image in
            guard let self else { return }
            for tab in tabs where tab.address?.host()?.lowercased() == host {
                tab.icon = image
            }
        }
        // The little window's own three buttons.
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

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            watchForSleep()
        }

        // What a deleted space left behind, if WebKit wouldn't let it go then.
        Spaces.sweep()
        Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))
        // The space you were in, when there are spaces (see Spaces.swift).
        if prefs.usesSpaces, let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            spaceID = last
            Spaces.current = last
        }
        restoreSession()
        if prefs.usesSpaces { preloadSpaces() }
    }

    /// The row of tabs the space on screen had last time, or one empty tab.
    func restoreSession() {
        let saved = Session.read(space: spaceID)
        guard !saved.tabs.isEmpty else {
            // A blank tab costs nothing until it is asked for its page. Its
            // web view — and with it WebKit's helper processes — is built a
            // moment after the window is up, so that the first address typed
            // finds everything already running, and the first frame never
            // had to share the CPU with it.
            let tab = Tab()
            adopt(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
                guard let tab, tab.isBlank else { return }
                _ = tab.web
            }
            return
        }
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab()
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tabs.append(tab)
        }
        guard !tabs.isEmpty else {
            adopt(Tab())
            return
        }
        let here = min(max(0, saved.active), tabs.count - 1)
        activeID = tabs[here].id
        // Only the one you were looking at actually loads.
        tabs[here].wake()
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
        Session.write(
            now: now,
            space: spaceID,
            .init(
                tabs: tabs.compactMap { tab in
                    guard !tab.shy, !tab.bench else { return nil }
                    // A sleeping tab holds its address in `pending`; asking for
                    // it there too means a pin can never be written out of
                    // existence by whatever its web view happens to be showing.
                    guard let url = tab.pending ?? tab.address,
                          url.scheme?.hasPrefix("http") == true
                    else { return nil }
                    return Session.Entry(
                        url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name
                    )
                },
                active: tabs.firstIndex { $0.id == activeID } ?? 0
            )
        )
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
        let tab = Tab()
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
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab) {
        // A peek is over the tab it was opened from; another tab puts it away.
        if peekTab != nil, tab.id != activeID { closePeek() }
        cancelTabEdit()
        summoning = false
        suggesting = nil
        guard tab.id != activeID else { return }
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        leaving()
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
                let fresh = Tab()
                remember(tab, at: 0)
                tab.close()
                adopt(fresh)
                tabs = [fresh]
                activeID = fresh.id
                typed = ""
            }
            return
        }

        remember(tab, at: index)
        tab.close()
        tabs.remove(at: index)
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
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab()
        prepare(tab)
        leaving()
        tabs.insert(tab, at: min(ghost.index, tabs.count))
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
    }

    private func remember(_ tab: Tab, at index: Int) {
        guard !tab.shy, let url = tab.address else { return }
        ghosts.append(Ghost(url: url, title: tab.title, index: index))
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

    func step(_ direction: Int) {
        guard tabs.count > 1, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let next = (here + direction + tabs.count) % tabs.count
        select(tabs[next])
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil) -> Tab {
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        let tab = if let source, source.shy, page == nil {
            Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else {
            Tab(configuration: page)
        }
        prepare(tab)
        tabs.insert(tab, at: atEnd ? tabs.count : placeForNew())
        tab.go(to: url)
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
            Tab(bench: tab.bench, configuration: page)
        }
        prepare(fresh)
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
        if #available(macOS 15.4, *) { return Extensions.unpopped(Extensions.current(url)) }
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
    /// over the page it had just sent you to.
    func pickBookmark(_ url: URL) {
        bookmarking = false
        bookmarksOpen = false
        visit(url)
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
        let saved = Session.read(space: space)
        var row: [Tab] = []
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            row.append(tab)
        }
        let active = row.indices.contains(saved.active) ? row[saved.active].id : row.first?.id
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

    /// The window last in front. Asked once the app has gone to the back,
    /// macOS no longer says which window was main.
    static weak var front: Browser?

    func appLeft() {
        guard prefs.floatsAway, Browser.front == nil || Browser.front === self else { return }
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
                self.floater.lift(tab.web)
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
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
        tab.onMiddleClick = { [weak self] tab, url in self?.open(url, foreground: false, from: tab) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot in
            guard let self else { return }
            guard let spot else {
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
                  let host = curtain.host(of: tab.address)
            else { return }
            // A page that came over plain http can have been written by
            // anyone on the way here — a café's network, a hotel's. It is
            // offered only what was kept from plain http too, never an
            // account kept from the https site of the same name.
            let inTheClear = tab.address?.scheme?.lowercased() == "http"
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
        if !typed.isEmpty,
           Address.url(from: typed) == nil,
           let asked = searchURL(for: typed) {
            list.append(
                Suggestion(key: typed, title: prefs.engine.name(custom: prefs.customEngine), url: asked, kind: .search)
            )
        }
        offers = list
        ending = history.completion(for: typed, among: offers.filter { $0.kind != .open })
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
        if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
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
    func submit() {
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
        (active ?? tabs.first)?.go(to: url)
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

    func reload() { active?.reload() }
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
        if ExtensionAuth.intercept(url, browser: self, from: webView) {
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
            open(url, foreground: action.modifierFlags.contains(.shift), from: tab(for: webView))
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

    /// An address for another app — mail, a call, a meeting. Only the page
    /// itself may ask, or a click inside one of its frames; a frame that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        guard action.targetFrame?.isMainFrame ?? true || clicked else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
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
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
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
        let key = "\(host)|\(type.rawValue)"

        if let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
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
        askedAbout = key
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
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
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
        guard let tab = tab(for: webView), let url = tab.address else { return }
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
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)

        guard !prefs.asksWhereToSave else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = downloadsFolder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }
            completionHandler(url)
            announce("Downloading \(url.lastPathComponent)")
            return
        }

        completionHandler(Browser.free(name, in: downloadsFolder))
        announce("Downloading \(name)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        loot.add(
            Keep(
                name: file.lastPathComponent,
                from: download.originalRequest?.url?.host() ?? "",
                path: file.path,
                date: Date()
            )
        )
        announce("Saved \(file.lastPathComponent)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloading.removeAll { $0 === download }
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





