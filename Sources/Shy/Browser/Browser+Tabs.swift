import SwiftUI
import WebKit
import Combine

// MARK: - tabs

extension Browser {
    /// A pin can be split with: its page goes into the pair as a tab of its
    /// own, and the pin stays where it is (see splittable).
    func canSplit(_ first: Tab, with second: Tab) -> Bool {
        first.id != second.id && !first.bench && !second.bench
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
        let dragged = splittable(dragged)
        let target = splittable(target)
        detachSplit(dragged)
        detachSplit(target)
        var row = tabs.filter { $0.id != dragged.id }
        guard let index = row.firstIndex(where: { $0.id == target.id }) else { return }
        row.insert(dragged, at: onLeft ? index : index + 1)
        let left = onLeft ? dragged : target
        let right = onLeft ? target : dragged
        splits.append(TabSplit(tabs: [left.id, right.id], focused: dragged.id))
        tabs = row
        focusPane(dragged)
        for pane in [left, right] where !pane.isBlank {
            if !pane.wake() { pane.revive() }
        }
        rememberSession()
    }

    func startSplit() {
        // Two tabs picked in the column: those two side by side.
        if pickedPair != nil { return pairPickedTabs() }
        guard let shown = active, !shown.bench else { return }
        if let pair = activeSplit {
            if let right = tabs.first(where: { $0.id == pair.right }) { focusPane(right) }
            return
        }
        let current = splittable(shown)
        let right = Tab(shy: current.shy,
                        configuration: current.shy ? Web.configuration(shy: true, store: current.store)
                            : Web.configuration(space: spaceID))
        prepare(right)
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
        guard let current = active else { return }
        if tab.id == current.id { return startSplit() }
        guard split(for: tab)?.contains(current.id) != true else { return focusPane(tab) }
        guard canSplit(tab, with: current) else { return }
        pair(tab, with: current, onLeft: false)
    }

    /// The tabs picked in the column (⌘- or ⇧-click) that are shown, in the
    /// column's order.
    var pickedTabs: [Tab] {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }
    }

    /// What a right-click among the picked tabs does to all of them, then
    /// the picking is over.
    func closePicked() {
        let picked = pickedTabs
        clearTabSelection()
        for tab in picked { close(tab) }
    }

    func pinPicked(listed: Bool = false) {
        let picked = pickedTabs.filter { $0.pin == nil && $0.isWeb && !$0.shy }
        clearTabSelection()
        for tab in picked { pin(tab, listed: listed) }
    }

    func movePicked(toSpace id: UUID) {
        let picked = pickedTabs
        clearTabSelection()
        for tab in picked { move(tab, toSpace: id) }
    }

    func sleepPicked() {
        let picked = pickedTabs
        clearTabSelection()
        for tab in picked { sleep(tab) }
    }

    /// Exactly two tabs picked, and already the two pages of one pair.
    var pickedTabsArePaired: Bool {
        let picked = pickedTabs
        return picked.count == 2 && split(for: picked[0])?.contains(picked[1].id) == true
    }

    /// Exactly two tabs picked that can go side by side: what Open 2 Tabs in
    /// Split View and ⌥⌘N pair. More than two isn't a pair — Split View holds
    /// two pages — so the menu's item is off then and ⌥⌘N does what it does
    /// without a selection.
    var pickedPair: (left: Tab, right: Tab)? {
        let picked = pickedTabs
        guard picked.count == 2, !pickedTabsArePaired,
              canSplit(picked[0], with: picked[1]) else { return nil }
        return (picked[0], picked[1])
    }

    /// The two picked tabs side by side, the first in the column on the
    /// left. Both keep their pages (nothing loads again); either one in
    /// another pair leaves it first, as a drag onto a page's edge does; a
    /// pin stays a pin and its page goes in as a tab (see splittable). The
    /// pair lands where the left one was — where the right one was when the
    /// left is a pin — and the tab asked from has the keys. The selection
    /// is done with.
    func pairPickedTabs(focus asked: Tab? = nil) {
        guard let (left, right) = pickedPair else { return }
        clearTabSelection()
        if left.pin != nil && right.pin == nil {
            pair(left, with: right, onLeft: true)
        } else {
            pair(right, with: left, onLeft: false)
        }
        if let asked, let made = split(for: asked), activeSplit?.id == made.id {
            focusPane(asked)
        }
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
        var row = tabs.filter { $0.id != tab.id }
        let place = row.firstIndex(where: { $0.id == blank.id }) ?? min(at, row.count)
        row[place] = tab
        replaceSplitMember(blank.id, with: tab.id)
        tabs = row
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
    /// A folder's rows move among their own; into or out of one is the
    /// folders' to say (see move(_:toFolder:at:)).
    private func joins(_ tab: Tab, kindOf anchor: Tab) -> Bool {
        guard tab.folder == anchor.folder else { return false }
        guard tab.pin != nil, anchor.pin != nil, tab.listed != anchor.listed else { return true }
        return false
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
            var row = tabs.filter { $0.id != tab.id }
            row.insert(tab, at: sourceIndex < targetStart ? targetStart - 1 : targetStart)
            tabs = row
        } else {
            detachSplit(tab)
            var row = tabs
            row.remove(at: sourceIndex)
            row.insert(tab, at: tab.pin == nil ? row.count : row.filter { $0.pin != nil && (tab.listed || !$0.listed) }.count)
            tabs = row
        }
        rememberSession()
    }

    /// ⌘T, the + button and the menu. With the floating field turned on and
    /// a page in front, the field comes up over that page instead of a blank
    /// tab: the tab is made by Return, not by asking for one. Anywhere else
    /// — a blank tab already in front, or an extension's new tab page you
    /// chose — it is an ordinary new tab.
    func launch() {
        guard prefs.floatingNewTab, let tab = active, !tab.isBlank, peekTab == nil else {
            newTab()
            return
        }
        if #available(macOS 15.4, *), Extensions.of(profileID).newTabPage != nil {
            newTab()
            return
        }
        // Again while it is up: it stays, with what was typed cleared.
        reviewing = false
        cancelTabEdit()
        summoning = false
        siteChip = nil
        typed = ""
        editing = true
        launching = true
        focusRequest += 1
    }

    func newTab() {
        // Off an agent's page: the new tab is what you'll see, even when it
        // is the empty one already in front underneath.
        if watchingAgent != nil { watchAgent(nil) }
        if websitePopup {
            if active?.shy == true { tabDestination.newShyTab() } else { tabDestination.newTab() }
            return
        }
        // On a private tab, a new one is private too: ⌘T from a page that
        // keeps nothing and landing on one that keeps everything is how a
        // private search ends up in the history.
        if active?.shy == true {
            newShyTab()
            return
        }
        // An extension's new tab page, if one asked and you said yes. One
        // added since that also asks is still asked, over the page it would
        // take the place of: which one has new tabs stays yours to say.
        if #available(macOS 15.4, *), let page = Extensions.of(profileID).newTabPage {
            let tab = open(page, foreground: true)
            summoning = false
            rememberSession()
            Extensions.of(profileID).offerNewTabPage(into: tab)
            return
        }
        // Reuse an empty tab at the chosen position, clearing its draft:
        // repeated ⌘T must not leave a row of identical empty tabs.
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && !$0.shy && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            rememberSession()
            // Asked here too: the blank a window opens with is the one the
            // first ⌘T after adding an extension lands on.
            if #available(macOS 15.4, *) { Extensions.of(profileID).offerNewTabPage(into: blank) }
            return
        }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        if #available(macOS 15.4, *) { Extensions.of(profileID).offerNewTabPage(into: tab) }
    }

    /// A new tab given an extension's new tab page, whether blank or showing
    /// another extension's: the page needs a view built from that
    /// extension's configuration, so it is a new tab in the old one's place.
    func replaceNewTab(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        replaceSplitMember(tab.id, with: page.id)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    /// An agent's page on show in this window, or none.
    func watchAgent(_ id: String?) {
        watchingAgent = id
        if id == nil { Agent.shared.reroom() }
    }

    func select(_ tab: Tab, floatPrevious: Bool = true) {
        if watchingAgent != nil { watchAgent(nil) }
        if let pair = split(for: tab), activeSplit?.id == pair.id, activeID != tab.id {
            focusPane(tab)
            return
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
        // An extension's panel opened for one tab goes and comes with it.
        sidePanelFollows(tab)
        // Coming back to the tab whose video is out brings it home first, so
        // it is never sent out and back in the same breath.
        if pictured == tab.id { unpicture() }
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

    /// ⌘W closes what is in front: a peek, then a card over the page (What's
    /// New), then the tab. Settings, History and the rest are tabs of their
    /// own, as in Chrome, and ⌘W on one closes it. Escape puts things away
    /// in the same order, so the two keys agree on what is in front.
    func closeFront() {
        // The floating new tab is the thing in front: ⌘W takes it away and
        // leaves the page under it.
        if launching { dismiss(); return }
        if peekTab != nil { closePeek() }
        else if closePanel() { return }
        else if let tab = active { close(tab) }
        // Nothing left in front: ⌘W once more closes the window.
        else { closeWindow() }
    }

    /// No tab in front: the window empty, ⌘T or ⌘L for a new tab.
    private func emptied() {
        activeID = nil
        editing = false
        typed = ""
    }

    /// ⇧⌘W: the whole window, its tabs with it, as the red button closes it.
    func closeWindow() {
        window?.performClose(nil)
    }

    /// The panel over the page put away, if one is up — for ⌘W and Escape
    /// both. Whether there was one.
    func closePanel() -> Bool {
        // History and the rest are tabs (InternalPages.swift): ⌘W closes
        // them as it closes any tab, and Escape leaves them be.
        if tuning { tuning = false }
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

        // A tab whose video is in picture in picture takes the window with
        // it. Left alone, the window went on playing a page belonging to a
        // tab that no longer exists.
        if pictured == tab.id { unpicture() }

        // A pinned tab is not closed by ⌘W — it is put down. Only Unpin
        // takes it out of the row.
        if tab.pin != nil {
            // Wandered off, and on screen: back to the page it was pinned
            // at, and you stay on it.
            if activeID == tab.id, wandered(tab) {
                goHome(tab)
                return
            }
            // Put down is gone home, as Arc's pins are: the pin wakes on the
            // page it was pinned at, not wherever its links had taken it.
            tab.rest(at: tab.home)
            // Off screen already: nothing else moves.
            guard activeID == tab.id else {
                writeSession(now: true)
                return
            }
            // An ordinary tab, or a new one; never another pin, which you
            // hadn't asked for and ⌘W would bounce you between.
            let loose = tabs.filter { $0.id != tab.id && $0.pin == nil }
            let awake = loose.filter { !$0.asleep }
            if let back = (awake.isEmpty ? loose : awake).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else {
                emptied()
            }
            writeSession(now: true)
            return
        }

        // The last tab that isn't a pin, on screen — or the only tab: the
        // window is left empty. Not closed, which isn't what closing a tab
        // asks for, and not on a pin you hadn't asked for (#537), nor on a
        // new tab to close again. ⌘W on the empty window closes it.
        if activeID == tab.id,
           !tabs.contains(where: { $0.id != tab.id && $0.pin == nil }) {
            if !tab.isBlank { remember(tab, at: index, partner: partner?.id, onLeft: pair?.left == tab.id) }
            tab.close()
            tabs.remove(at: index)
            emptied()
            rememberSession()
            return
        }

        remember(tab, at: index, partner: partner?.id, onLeft: pair?.left == tab.id)
        tab.close()
        tabs.remove(at: index)
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
    /// single ⇧⌘T puts every tab back. Pins stay, and so do the folders,
    /// whose tabs are pinned rows. So does the page you are on, and its
    /// partner in a split, and with Settings' switch any tab playing sound.
    func clearTabs() {
        let going = tabs.filter {
            $0.pin == nil && !$0.bench && !visibleTabIDs.contains($0.id)
                && !(prefs.clearKeepsPlaying && $0.noisy)
        }
        guard !going.isEmpty else { return }
        closingTogether { batch in clear(going, batch: batch) }
    }

    /// Tabs closed as one act, a Clear: remembered together, so
    /// that one ⇧⌘T brings every one of them back (see reopen(batch:)), and
    /// the one you were on, if it went too, in front.
    private func closingTogether(_ close: (UUID) -> Void) {
        let batch = UUID(), was = activeID
        batching = batch
        defer {
            batching = nil
            if let at = ghosts.lastIndex(where: { $0.batch == batch && $0.was == was }) { ghosts[at].front = true }
        }
        close(batch)
    }

    private func clear(_ going: [Tab], batch: UUID) {
        lastClear = (batch, nil)
        for tab in going { close(tab) }
    }

    /// What a link dropped on the tabs may open: a website, or a file
    /// from the Finder. A page decides what a link dragged out of it
    /// carries — script, a data: page, an extension's page with that
    /// extension's powers, Shy's own pages, another app's address — and none
    /// of that is what a person dragging a link means.
    nonisolated static func mayDrop(_ url: URL) -> Bool {
        ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
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
                    guard let url, Browser.mayDrop(url) else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text), Browser.mayDrop(url) else { return }
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
        if let window = Browsers.lastClosedAt, window > (closedHere.last?.at ?? .distantPast), Browsers.reopenWindow() { return }
        guard let ghost = closedHere.last else { return }
        if let batch = ghost.batch { reopen(batch: batch) } else { reopen(ghost) }
    }

    /// What ⇧⌘T brings back, for its menu items: a Clear's tabs by how
    /// many, or the one tab (or the window) it always did.
    var reopenTitle: String {
        guard let last = closedHere.last, let batch = last.batch,
              (Browsers.lastClosedAt ?? .distantPast) <= last.at else { return "Reopen Closed Tab" }
        let count = closedHere.filter { $0.batch == batch }.count
        return count == 1 ? "Reopen Cleared Tab" : "Reopen \(count) Cleared Tabs"
    }

    /// Everything one Clear closed, back as it was: each tab at its place,
    /// the newest closed first, so each goes into the row as it stood just
    /// before that tab left it. They come back asleep, as last
    /// session's tabs do, but for the one you were on, which comes back in
    /// front; the empty tab Clear left there goes, if nothing has been
    /// typed into it. Closed from somewhere else, a pin say, you stay there.
    private func reopen(batch: UUID) {
        let members = ghosts.filter { $0.batch == batch }
        ghosts.removeAll { $0.batch == batch }
        var back: [Tab.ID: Tab] = [:]
        var front: Tab?
        for ghost in members.reversed() {
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
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
        // Only this Clear's own undo lets its empty tab go: a later one,
        // undone first, leaves this one's still to undo.
        if lastClear?.batch == batch { lastClear = nil }
        rememberSession()
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        guard ghost.profile == profileID else { return }
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        leaving()
        tabs.insert(tab, at: safeInsertionIndex(ghost.index))
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
        ghosts.append(Ghost(url: url, title: tab.title, index: index,
                            partner: partner, onLeft: onLeft, was: tab.id, batch: batching, profile: profile(of: tab)))
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
        guard id != spaceID,
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
        guard id != spaceID,
              let destination = spaces.first(where: { $0.id == id }),
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
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

        tab.rehome(in: id)
        // Its folder stays behind: the space it goes to has folders of its
        // own. A pinned row comes in among that space's rows.
        tab.folder = nil
        var row = parked[id] ?? loadRow(id)
        // A pin is that space's pin from now on, in pins.json too: kept only
        // in its row, the next look at the space's pins (another window's
        // change, a change to the shared pins, or a relaunch before the space
        // was opened) found it in no list and closed it.
        // Squares ahead of rows there too (see Browser.tiered).
        if tab.pin != nil, let pin = pinDefs([tab]).first {
            let defs = Pins.defs(id).filter { $0.id != pin.id } + [pin]
            Pins.set(id, defs.filter { $0.listed != true } + defs.filter { $0.listed == true }, from: self)
        }
        let squares = row.tabs.filter { $0.pin != nil && !$0.listed }.count
        let pins = row.tabs.firstIndex { $0.pin == nil } ?? row.tabs.count
        let place = tab.pin == nil ? row.tabs.count : (tab.listed ? pins : squares)
        row.tabs.insert(tab, at: place)
        if row.active == nil { row.active = tab.id }
        parked[id] = row

        writeSession(now: true)
        writeSession(now: true, space: id, row: row)
        announce("Moved to \(destination.name)")
        return true
    }
}
