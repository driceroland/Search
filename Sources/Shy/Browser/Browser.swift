import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.
//
// This file holds what the window knows and how it begins; what it does with
// that is beside it, one concern to a file: Browser+Tabs, +Rows, +Opening and
// +Windows for tabs and where they go; +Field and +TabAddress for typing an
// address; +Find, +Curtain, +Picture and +Capture for what happens on a page;
// +Bookmarks, +Passwords, +Downloads, +Clearing and +Announce for what is kept
// and said; +Pins, +Profiles, +InternalPages and +WebKit for the rest.

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
    @Published var selectedTabIDs: Set<Tab.ID> = []
    var selectionAnchor: Tab.ID?
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

    /// The dropdown off the button.
    @Published var bookmarksOpen = false
    /// What hangs off the button instead of the list: the card for one
    /// bookmark, its name and folder, as ⇧⌘B opens it.
    @Published var bookmarkCard: Bookmark.ID?

    @Published var fileImport: FileImportJob?
    var fileImportControl: ImportFile.Control?

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
    @Published var siteOffer: SearchSite?
    /// The site Tab put in the field: what is typed next searches it.
    @Published var siteChip: SearchSite? {
        didSet { if siteChip != oldValue { guess() } }
    }
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    @Published var typed = "" { didSet { guess() } }

    /// What the field is offering, best first.
    @Published var offers: [Suggestion] = []
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    @Published var ending: String?
    /// Which row the arrow keys have walked to, if any.
    @Published var picked: Int?
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published var focusRequest = 0 {
        didSet { focusAsked = CACurrentMediaTime() }
    }
    /// When the field was last asked for the keys and hasn't taken them yet.
    var focusAsked: CFTimeInterval?
    /// What was typed in that moment, for the field once it has the keys.
    var heldKeys: [NSEvent] = []

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    @Published var summoning = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

    @Published var finding = false
    /// The side panel, beside the page (see SidePanel.swift): up or
    /// not, and what is in it.
    @Published var sidePanelShown = false
    @Published var sidePanel: SidePanelContent?
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
    @Published var missed = false
    @Published var findFocus = 0
    /// The count and which match is current, as the page last answered.
    @Published var findResult: PageFind.Result?

    let pageFind = PageFind()
    var findSpec: FindSpec?
    /// Goes up whenever what is looked for, or the page it is looked for on,
    /// changes: an answer for an older one is dropped.
    var findGeneration: UInt64 = 0
    /// One question to the page at a time. Letters typed while it answers
    /// wait here, and only the last of them is asked next: on a long page
    /// every letter would otherwise queue a whole search of its own.
    var findAsking: UInt64?
    var findAsked: UInt64 = 0
    /// A new search not yet asked, and Next / Previous presses not yet sent.
    var findFresh = false
    var findSteps = 0
    var resettingFind = false
    weak var findWeb: WKWebView?

    let loot = Shared.loot
    /// True while the pointer is picking things to hide.
    @Published var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    /// What a private tab took off its page, kept for that page only.
    var passingVeils: [Tab.ID: [String]] = [:]

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

    // One state keeps closing History from leaving its clearing controls open.
    @Published var recallMode: RecallMode?
    @Published var recallHunt = ""

    @Published var asking: CaptureAsk?
    var decide: ((WKPermissionDecision) -> Void)?
    /// WebKit's screen-sharing answers: deny (0), screen (1), window (2).
    var decideDisplay: ((Int) -> Void)?
    weak var displayTab: Tab?
    var displayHeld: HeldQuestion?
    var displayRequest: UUID?
    var askedAbout = ""

    // MARK: - pinning (the rest in Browser+Pins.swift)
    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }
    /// The pins drawn as squares: those not kept as rows. They come first
    /// among the pins, so a square's place in the grid is its place in the
    /// row.
    var squarePins: [Tab] { tabs.filter { $0.pin != nil && !$0.listed } }

    // MARK: - carried onto the pins, and off them: Browser+Pins.swift

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published var renamingTab = false
    /// What the field in the tab offers as you type, as ⌘L's does (#534),
    /// and the row the arrow keys are on.
    @Published var tabOffers: [Suggestion] = []
    @Published var tabPicked: Int?
    /// The address the edit began with: nothing is offered for that.
    var tabOriginal = ""

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published var announcement: String?
    /// The file a "Saved …" line is about: clicked, the line shows it in
    /// the Finder, and it stays long enough to be clicked.
    @Published var announcedFile: URL?
    /// Downloads while they happen (see Fetching.swift).
    let fetches = Shared.fetches

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    @Published var ghosts: [Ghost] = []

    /// The Clear under way, whose tabs are remembered
    /// together (see closingTogether).
    var batching: UUID?
    /// The last Clear, and the empty tab it left in front: an undo takes
    /// that tab away again while it is still empty.
    var lastClear: (batch: UUID, blank: Tab.ID?)?

    var bag = Set<AnyCancellable>()
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
    /// Downloads from private tabs, which the Downloads list never shows.
    var unlisted: Set<ObjectIdentifier> = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    var hush: DispatchWorkItem?
    var zoomShown = 100
    var remembering = false
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
    var followed: UUID?
    var profileBag: Set<AnyCancellable> = []
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
    var usesFiles = false
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

    // MARK: - tabs: Browser+Tabs.swift

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Shy
    /// comes back.
    var liftedAway = false

    /// The tab whose video Shy last sent to macOS's picture in picture, to
    /// bring back when you return to it.
    var pictured: Tab.ID?

    /// Asks the engine for the words it would suggest, when Settings ›
    /// General › Suggestions from your search engine is on and these words
    /// may leave the Mac (EngineSuggest.sendable). What it said for the
    /// words before stays, those that still fit, until it answers these:
    /// rows that came and went with every key would be a list nobody could
    /// read.
    let suggester = EngineSuggester()
    /// The engine's last words, and what they answered.
    var engineWords: (asked: String, words: [String]) = ("", [])
}
