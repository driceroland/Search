import SwiftUI
import WebKit
import Combine

// MARK: - pinning

extension Browser {
    /// The pins kept as rows in no folder, under the squares (see
    /// Tab.listed). A folder's are its own (see folderLines).
    var listedPins: [Tab] {
        let known = Set(folders.map(\.id))
        return tabs.filter { $0.pin != nil && $0.listed && $0.folder.map(known.contains) != true }
    }

    /// `listed`: as a row under the squares rather than as a square.
    func pin(_ tab: Tab, listed: Bool = false) {
        // Drawn again even when the tab stays where it is (see unpin).
        objectWillChange.send()
        // Pins are the space's, kept on disk and shown in every window: a
        // private tab can't be one, or its page would outlive it there.
        guard !tab.shy, tab.page == nil else { return }
        detachSplit(tab)
        if tab.pin == nil {
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
        tab.listed = listed
        tab.folder = nil
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

    /// The same tabs in another order, put together elsewhere (see
    /// Folders.swift): anything more or less than the row is refused.
    func reorder(_ row: [Tab]) {
        guard row.count == tabs.count, Set(row.map(\.id)) == Set(tabs.map(\.id)) else { return }
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
    /// at, as a pin in Arc goes home (#141).
    func goHome(_ tab: Tab) {
        guard tab.pin != nil else { return }
        guard let home = tab.home, !Browser.samePage(home, tab.address) else { return }
        tab.go(to: home)
        rememberSession()
    }

    /// The page a pin has wandered to made its pinned page: where a
    /// double-click, ⌘W and a restart take it from now on. It keeps its
    /// letter and name; every window's copy of the pin follows.
    func repin(_ tab: Tab) {
        guard wandered(tab), let here = tab.address, ["http", "https"].contains(here.scheme?.lowercased()) else { return }
        objectWillChange.send()
        tab.home = here
        writeSession(now: true)
    }

    /// A pin no longer on the page it was pinned at.
    func wandered(_ tab: Tab) -> Bool {
        guard tab.pin != nil, let home = tab.home else { return false }
        return !Browser.samePage(home, tab.address)
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

    func unpin(_ tab: Tab) {
        // The row is drawn again whether or not the tab moves. Unpinning the
        // only tab, or the last pin, leaves it where it is; `tabs` didn't
        // change, only the tab did, and the column went on drawing it as a
        // pinned square — with no letter left, an empty tile — and never as
        // a row (from X).
        objectWillChange.send()
        tab.pin = nil
        tab.listed = false
        tab.folder = nil
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
}

// MARK: - carried onto the pins, and off them

extension Browser {
    /// Whether a tab carried onto the pins may become one there. Not a
    /// private tab (see pin), and not a pair: pinning one half would undo
    /// the pair under the hand. Pin Tab in the menu still pins the half
    /// it was asked for.
    func pinsByDrag(_ tab: Tab) -> Bool {
        tab.pin == nil && !tab.shy && split(for: tab) == nil && tabs.contains { $0.id == tab.id }
    }

    /// The place a tab let go at `proposed` among the squares (or, with
    /// `listed`, the pinned rows) would really take: never past the end.
    func pinSlot(_ tab: Tab, listed: Bool, proposed: Int) -> Int {
        let tier = tabs.filter { $0.pin != nil && $0.listed == listed && $0.id != tab.id }
        return min(max(proposed, 0), tier.count)
    }

    /// A tab carried onto the pins and let go there (Arc's drag): pinned as
    /// Pin Tab pins it — its page, its web view and its place in history
    /// kept — then put at `slot` among the squares, or with `listed` among
    /// the pinned rows. A pin of the other kind carried there changes kind,
    /// as Show as Row does. The pin is this space's own, as Pin Tab makes
    /// it; with pins in every space on, it lands after the shared ones.
    @discardableResult
    func pinDropped(_ tab: Tab, listed: Bool, at slot: Int) -> Bool {
        if tab.pin == nil {
            guard pinsByDrag(tab) else { return false }
            pin(tab, listed: listed)
            guard tab.pin != nil else { return false }
        } else if tab.listed != listed {
            setListed(tab, listed)
        }
        // Out of its folder, to where it was let go.
        tab.folder = nil
        let at = pinSlot(tab, listed: listed, proposed: slot)
        let pins = tabs.filter { $0.pin != nil }
        var tier = pins.filter { $0.listed == listed && $0.id != tab.id }
        tier.insert(tab, at: min(at, tier.count))
        let squares = listed ? pins.filter { !$0.listed } : tier
        let rows = listed ? tier : pins.filter(\.listed)
        let row = squares + rows + tabs.filter { $0.pin == nil }
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
        writeSession(now: true)
        return true
    }

    /// A pin carried out among the tabs and let go there: unpinned as Unpin
    /// unpins it — a pin every space shows leaves them all, as it does from
    /// the menu — and put at `slot` among the tabs. The page stays as it is.
    @discardableResult
    func unpinDropped(_ tab: Tab, at slot: Int) -> Bool {
        guard tab.pin != nil, tabs.contains(where: { $0.id == tab.id }) else { return false }
        unpin(tab)
        moveDisplayedTab(tab, to: min(pinnedCount + max(0, slot), displayedTabs.count - 1))
        writeSession(now: true)
        return true
    }
}

// MARK: - pins, the same in every window

extension Browser {
    /// What makes this row's pinned tabs pins, in their order.
    func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin, !tab.shy else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            return PinDef(id: tab.pinID ?? UUID(), letter: letter,
                          home: (tab.home ?? tab.pending ?? tab.address)?.absoluteString ?? "",
                          title: tab.title, name: tab.name, listed: tab.listed ? true : nil,
                          folder: tab.listed ? tab.folder : nil)
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
        let known = Set(Pins.folders(space).map(\.id))
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
            // A folder this space doesn't know (yet): a row in none.
            let folder = def.listed == true ? def.folder.flatMap { known.contains($0) ? $0 : nil } : nil
            if tab.folder != folder { tab.folder = folder }
            tab.home = URL(string: def.home)
            out.append(tab)
        }
        for gone in pinned { gone.close() }
        // In the order they were written, which already holds it; a file
        // put together by hand, or an import, may not.
        return Folders.ordered(Browser.tiered(out), folders: Pins.folders(space)) + loose
    }

    /// Another window changed a space's pins: this window's row there follows.
    func pinsChanged(in space: UUID) {
        guard !isPopup else { return }
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
            writeRow(spaceID, session(tabs, active: activeID, splits: splits), now: false)
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
            row.splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in row.tabs.contains { $0.id == id } }
            }
            if let active = row.active, !row.tabs.contains(where: { $0.id == active }) {
                row.active = row.tabs.first { $0.pin == nil }?.id ?? row.tabs.first?.id
            }
            parked[space] = row
        }
    }

    /// Squares ahead of rows (see Browser.tiered): a drag or a Show as Row
    /// that crossed the line goes back to its side of it, where pins.json,
    /// every other window and the next launch have it.
    func keepBlocks() {
        let pinned = tabs.filter { $0.pin != nil && !$0.shy }
        let loose = tabs.filter { $0.pin == nil || $0.shy }
        let blocked = Browser.tiered(pinned)
        if !blocked.elementsEqual(pinned, by: { $0.id == $1.id }) { tabs = blocked + loose }
    }
}
