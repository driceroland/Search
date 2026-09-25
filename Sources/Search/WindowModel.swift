import SwiftUI
import WebKit
import Combine

/// One window, for identity across a drag and a session file.
struct WindowID: Hashable, Codable {
    var rawValue: UUID
}

/// One window's tab row and the chrome that belongs to it: what is on screen
/// in this window — which tabs it shows, which one is active, what is in the
/// address field, whether find is up. Shared services live on the profile.
@MainActor
final class WindowModel: ObservableObject, Identifiable {
    typealias ID = WindowID

    let id: WindowID
    /// Profile-wide services. Unowned: a window never outlives the profile.
    unowned let profile: Browser

    /// Where the next NSWindow should sit. Set by detach or session restore,
    /// consumed by dress() once, then nil.
    var frameRequest: CGRect?

    // MARK: - the row

    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: Tab.ID? {
        didSet {
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            guard oldValue != activeID, let old = oldValue else { return }
            profile.linkStatus.dismiss()
            tabs.first { $0.id == old }?.touch()
        }
    }

    /// The space this window is in. New tabs come from here; the row swaps
    /// when this changes (see Spaces.swift).
    @Published var spaceID: Space.ID
    /// Rows of the spaces this window is not showing.
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    @Published var spaceSwipe: CGFloat = 0
    @Published var makingSpace = false
    /// Which way the last change of space went: 1 to the next, -1 back.
    @Published var spaceStep = 1

    var active: Tab? { tabs.first { $0.id == activeID } }
    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }
    var fieldShowing: Bool { editing || active?.isBlank ?? true }

    // MARK: - omnibox

    /// The address field, raised over a page by ⌘L. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    @Published var editing = false
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    @Published var typed = "" { didSet { guess() } }
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
    /// True while the field is a switcher rather than an address bar.
    @Published private(set) var summoning = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

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

    // MARK: - this window's chrome

    @Published var folded = false
    @Published var peeking = false
    /// A link's page, peeked at over this one (see Peek.swift).
    @Published var peekTab: Tab?
    /// Tabs you closed in this window, newest last, so ⌘⇧T can put them back.
    @Published private(set) var ghosts: [Ghost] = []

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place.
    @Published var editingPin: Tab.ID?

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published private(set) var renamingTab = false

    private var bag = Set<AnyCancellable>()
    private var zoomShown = 100

    init(id: WindowID = WindowID(rawValue: UUID()), profile: Browser, spaceID: Space.ID = Space.firstID) {
        self.id = id
        self.profile = profile
        self.spaceID = spaceID
        // Prefs and other profile state redraw this window's chrome too.
        profile.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: - tabs

    /// A tab of this row by id.
    func tab(_ id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id }
    }

    /// A tab for this window's space. Passing the space keeps a window that
    /// is not in the first space from picking up whichever store
    /// `Spaces.current` last pointed at.
    func makeTab(shy: Bool = false) -> Tab {
        Tab(configuration: Web.configuration(shy: shy, space: spaceID))
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
            profile.rememberSession()
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
            profile.rememberSession()
            return
        }
        let tab = makeTab()
        adopt(tab)
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        profile.rememberSession()
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: tab) }
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
        profile.announce("A tab that keeps nothing")
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
        profile.suggesting = nil
        guard tab.id != activeID else { return }
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if profile.floating == tab.id { profile.land() }
        leaving()
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() { tab.revive() }
        profile.rememberSession()
        editing = false
        typed = ""
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to
        // a tab that no longer exists.
        if profile.floating == tab.id { profile.land() }

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
            profile.writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            if tab.isBlank {
                // Closing the last blank tab closes this window, not whatever
                // window happens to be key.
                profile.close(self)
            } else {
                let fresh = makeTab()
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
        profile.rememberSession()
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
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self?.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                    guard let text, let url = Address.url(from: text) else { return }
                    DispatchQueue.main.async { self?.open(url, foreground: true) }
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
        let tab = makeTab()
        prepare(tab)
        leaving()
        tabs.insert(tab, at: min(ghost.index, tabs.count))
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
    }

    func remember(_ tab: Tab, at index: Int) {
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
        profile.rememberSession()
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
        profile.rememberSession()
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
        profile.bookmarking = false
        profile.bookmarksOpen = false
        visit(url)
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
              let url = profile.destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        guard let here = tabs.firstIndex(where: { $0.id == activeID }) else { return tabs.count }
        return max(here + 1, pinnedCount)
    }

    /// A tab made outside the row — a peek being kept, or one handed over
    /// from another window — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tab.enter(self)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        profile.rememberSession()
    }

    /// Adopt a brand-new tab into the row: wire it up and append.
    func adopt(_ tab: Tab) {
        prepare(tab)
        tab.enter(self)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Out of the row, leaving selection and the session right. Returns the
    /// tab so the caller can hand it on. Empty-row policy is not here.
    @discardableResult
    func release(_ tab: Tab) -> Tab {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return tab }
        if profile.floating == tab.id { profile.land() }
        tabs.remove(at: i)
        tab.enter(nil)
        if activeID == tab.id {
            activeID = tabs.indices.contains(min(i, tabs.count - 1)) ? tabs[min(i, tabs.count - 1)].id : nil
        }
        profile.rememberSession()
        return tab
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    private func leaving() {
        guard profile.prefs.floatsOnLeave else { return }
        profile.lift(active, quietly: true)
    }

    // MARK: - pinning

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
        profile.writeSession(now: true)
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
        profile.writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        defer { profile.writeSession(now: true) }
        // Back out of the pinned block, to the head of the loose tabs.
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = pinnedCount
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        profile.rememberSession()
    }

    // MARK: - the address, in the tab itself

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
            profile.writeSession(now: true)
            return
        }
        guard let url = profile.destination(for: tabDraft) else {
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
            || profile.destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
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
        profile.reviewing = false
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
        var list = profile.history.suggestions(for: typed, limit: 3)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty,
           Address.url(from: typed) == nil,
           let asked = profile.searchURL(for: typed) {
            list.append(
                Suggestion(
                    key: typed,
                    title: profile.prefs.engine.name(custom: profile.prefs.customEngine),
                    url: asked, kind: .search
                )
            )
        }
        offers = list
        ending = profile.history.completion(for: typed, among: offers.filter { $0.kind != .open })
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
            target = profile.destination(for: typed)
        }

        guard let url = target else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    // MARK: - find

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

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.profile.announce("Nothing to read on this page")
        }
    }

    func reload() { active?.reload() }
    func back() { active?.back() }
    func forward() { active?.forward() }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        profile.announce("Paused")
    }

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        guard let url = active?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        profile.announce("Address copied")
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
        profile.announce("Link copied")
    }

    // MARK: - session

    /// This window's row as the session file keeps it.
    func sessionShape(tabs row: [Tab], active: Tab.ID?) -> Session.WindowShape {
        Session.WindowShape(
            id: id.rawValue,
            tabs: sessionEntries(row),
            active: row.firstIndex { $0.id == active } ?? 0,
            frame: profile.host(of: self)?.frame ?? frameRequest
        )
    }

    /// Entries for one row, as the session file keeps them.
    func sessionEntries(_ row: [Tab]) -> [Session.Entry] {
        row.compactMap { tab in
            guard !tab.shy, !tab.bench else { return nil }
            // A sleeping tab holds its address in `pending`; asking for it
            // there too means a pin can never be written out of existence by
            // whatever its web view happens to be showing.
            guard let url = tab.pending ?? tab.address,
                  url.scheme?.hasPrefix("http") == true
            else { return nil }
            return Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name
            )
        }
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        guard let shape = Self.row(in: Session.read(space: space), for: id) else {
            return Parked(tabs: [], active: nil)
        }
        var row: [Tab] = []
        for entry in shape.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            row.append(tab)
        }
        let active = row.indices.contains(shape.active) ? row[shape.active].id : row.first?.id
        return Parked(tabs: row, active: active)
    }

    /// This window's row in a space's session, or the first one still free.
    static func row(in shape: Session.Shape, for id: WindowID) -> Session.WindowShape? {
        if let mine = shape.windows.first(where: { $0.id == id.rawValue }) { return mine }
        return shape.windows.first { $0.id == nil } ?? shape.windows.first
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own.
    func showRow(_ row: [Tab], active: Tab.ID?) {
        tabs = row
        activeID = active ?? row.first?.id
    }

    /// The row of tabs this window's space had last time, or one empty tab.
    func restoreSession() {
        let shape = Self.row(in: Session.read(space: spaceID), for: id) ?? Session.WindowShape(id: nil, tabs: [], active: 0)
        guard !shape.tabs.isEmpty else {
            // A blank tab costs nothing until it is asked for its page. Its
            // web view — and with it WebKit's helper processes — is built a
            // moment after the window is up, so that the first address typed
            // finds everything already running, and the first frame never
            // had to share the CPU with it.
            let tab = makeTab()
            adopt(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
                guard let tab, tab.isBlank else { return }
                _ = tab.web
            }
            return
        }
        for entry in shape.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = makeTab()
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tabs.append(tab)
        }
        guard !tabs.isEmpty else {
            adopt(makeTab())
            return
        }
        let here = min(max(0, shape.active), tabs.count - 1)
        activeID = tabs[here].id
        // Only the one you were looking at actually loads.
        tabs[here].wake()
    }

    // MARK: - spaces

    var space: Space {
        profile.spaces.first { $0.id == spaceID } ?? profile.spaces[0]
    }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// ⌃1–⌃9, and the menu on the space's dot.
    func switchSpace(to id: UUID) {
        guard profile.prefs.usesSpaces else { return }
        enter(id)
    }

    private func enter(_ id: UUID) {
        guard id != spaceID, let to = profile.spaces.firstIndex(where: { $0.id == id }) else { return }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (profile.spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        cancelTabEdit()
        if profile.floater.showing { profile.land() }
        profile.writeSession(now: true)

        // The row on screen is parked as it is, sound and all: music or a
        // stream keeps playing in the space you left, as it does in a tab
        // you left. ⌘⇧M, or its speaker, stops it.
        parked[spaceID] = Parked(tabs: tabs, active: activeID)

        spaceID = id
        Spaces.current = id
        Store.settings.set(id.uuidString, forKey: "space.current")
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            showRow(back.tabs, active: back.active)
            if let active, !active.wake() { active.revive() }
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        editing = active?.isBlank ?? true
        typed = ""
        askFocus()
        profile.announce(space.name)
    }

    /// Every other space's row, made ahead of time, so the column can show
    /// the next space beside this one while two fingers bring it in.
    func preloadSpaces() {
        for space in profile.spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    func switchSpace(index: Int) {
        guard profile.spaces.indices.contains(index) else { return }
        switchSpace(to: profile.spaces[index].id)
    }

    // MARK: - peek (see Peek.swift)

    /// Shift-click on a link, from a tab in the row.
    func peek(_ url: URL, from tab: Tab) {
        let page = makeTab(shy: tab.shy)
        prepare(page)
        page.go(to: url)
        withAnimation(Motion.settle) { peekTab = page }
    }

    /// Put away: the page goes with the panel.
    func closePeek() {
        guard let page = peekTab else { return }
        withAnimation(Motion.quick) { peekTab = nil }
        page.close()
    }

    /// Kept: a tab beside the one it was opened from, and in front.
    func keepPeek() {
        guard let page = peekTab else { return }
        let place = placeForNew()
        withAnimation(Motion.quick) { peekTab = nil }
        insert(page, at: place)
        select(page)
    }

    // MARK: - fold (see Fold.swift)

    /// ⌘S. The column, or the strip across the top, out of the way, or back.
    func toggleFold() {
        peeking = false
        withAnimation(Motion.glide) { folded.toggle() }
    }

    /// The folded column out over the page, or back in.
    func peek(_ out: Bool) {
        withAnimation(Motion.glide) { peeking = out }
    }

    // MARK: - wiring a tab

    /// Hand a new or newly-moved tab to this window: navigation stays on the
    /// profile (shared WebKit plumbing); the page callbacks that answer with
    /// window state point here.
    func prepare(_ tab: Tab) {
        tab.delegate = profile
        tab.onLink = { [weak self] tab, address in
            guard let self, profile.prefs.showsLinks, tab.id == activeID else { return }
            profile.linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = profile.curtain.host(of: tab.address) else { return }
            profile.curtain.hide(selector, label: label, note: note, on: host)
            let css = profile.curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            profile.announce("Hidden — ⌘Z puts it back")
        }
        tab.onPickEnd = { [weak self] _ in self?.profile.veiling = false }
        tab.onImageMenu = { [weak self] tab, url in self?.profile.showImageMenu(for: tab, at: url) }
        tab.searchName = { [weak self] in
            self.map { $0.profile.prefs.engine.name(custom: $0.profile.prefs.customEngine) }
        }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = profile.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.profile.addFromStore(tab) }
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
                if profile.pickedInto == tab.id { profile.pickedInto = nil }
                guard profile.suggesting?.tab == tab.id else { return }
                profile.lowering?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, profile.suggesting?.tab == tab.id else { return }
                    profile.suggesting = nil
                }
                profile.lowering = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return
            }
            profile.lowering?.cancel()
            guard profile.prefs.fillsPasswords, tab.id == activeID, profile.pickedInto != tab.id,
                  let host = profile.curtain.host(of: tab.address)
            else { return }
            // A page that came over plain http can have been written by
            // anyone on the way here — a café's network, a hotel's. It is
            // offered only what was kept from plain http too, never an
            // account kept from the https site of the same name.
            let inTheClear = tab.address?.scheme?.lowercased() == "http"
            let known = Array(Vault.logins(matching: host).filter { !inTheClear || $0.clear }.prefix(5))
            profile.suggesting = known.isEmpty
                ? nil
                : Browser.Suggesting(tab: tab.id, spot: spot, logins: known, host: host, clear: inTheClear)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            guard let self, profile.prefs.savesPasswords, !password.isEmpty, !tab.shy,
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
            let offer = Browser.Offer(
                login: Login(host: host, user: user, password: password, used: nil, clear: clear),
                changed: known.contains { $0.user == user }
            )
            guard profile.offering != offer else { return }
            profile.offering = offer
        }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.profile.announce("Couldn't hide that — \(reason)")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            profile.announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.profile.rememberSession() }
            .store(in: &bag)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                guard let tab, !tab.shy, let url = tab.address else { return }
                self?.profile.history.retitle(url, title)
            }
            .store(in: &bag)
    }
}
