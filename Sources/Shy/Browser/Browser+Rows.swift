import SwiftUI
import WebKit
import Combine

// A space's row of tabs: loaded, restored, and where a new tab goes.
extension Browser {
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

    func restoreRow(_ saved: Session.Shape, space: UUID) -> Parked {
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
}

extension Browser {
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
}
