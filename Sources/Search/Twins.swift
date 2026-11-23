import Foundation

// Same tabs in every window: Settings › Tabs › Windows, off unless asked for.
// Arc's sidebar is the same in every window; a user asked for it ("tabs
// reflecting across windows (like arc)").
//
// The pins have always been every window's (see Pins.swift), and the open
// tabs are done the same way: each window holds its own tab for each, its
// own page in its own view, and only what makes the tab that tab is shared —
// which one it is (its twin id), its page, its title, the name you gave it,
// its group, its place in the row. Opened, closed, moved,
// grouped or renamed in one window, so in the others.
//
// A page can only be on screen in one window, and with a view of each
// window's own it never has to be in two: the same tab picked in two windows
// is two views of the same page, as a pin picked in two windows always was.
// What follows the tab from window to window is its place in its page — a
// tab that sleeps in this window, picked here while another window has
// looked at it since, wakes with that window's history and scroll position
// (Browser.catchUp), as a tab moved to another window would arrive. And a
// tab another window took to another page, not on screen here, goes there
// too, asleep until it is looked at (Browser.follow).
//
// Nothing is written apart: each window's rows, in the session files and
// windows.json as always, hold the tabs with their twin ids, so the next
// launch matches them up again. Here in memory, the rows as the windows
// last said them, and every twin ever said this run, so that a tab missing
// from a row is told apart: closed, if a window said it before; new, from a
// window that hasn't said it yet, if not. Turned on, every window's tabs
// come together: nothing any window had is lost.
//
// Never a private tab, a bench tab, an empty one, a pin, or one of Search's
// own pages; never a pop-up window's; never synced to other Macs (Sync.swift
// keeps open tabs out).

/// An open tab as every window lists it.
struct TwinDef: Equatable {
    var id: UUID
    var url: String
    var title: String
    var name: String?
    var group: UUID?
}

@MainActor
enum Twins {
    /// The open tabs, in their order, as a window last said them; nil
    /// until one has.
    private static var list: [TwinDef]?
    /// The groups holding them.
    private static var groupList: [TabGroup] = []
    /// Every twin a window has said this run (see plan).
    private(set) static var known: Set<UUID> = []
    /// Whether the rows here are this run's since the switch last came on.
    private static var live = false

    /// The open tabs changed in one window; the others follow.
    static let changed = Notification.Name("SearchTwinsChanged")

    static func row() -> [TwinDef]? { list }
    static func groups() -> [TabGroup] { groupList }

    /// The switch on, or the first window of a launch with it on: what was
    /// said before it went off is nothing to go by.
    static func turnedOn() {
        guard !live else { return }
        live = true
        list = nil
        groupList = []
        known = []
    }

    static func turnedOff() { live = false }

    /// A window's row as it now is, passed to the other windows when it
    /// differs from what was there. Only the groups that hold one of its
    /// tabs, each open: folding a group is each window's own.
    static func set(_ defs: [TwinDef], groups: [TabGroup], from browser: Browser?) {
        known.formUnion(defs.map(\.id))
        let shared = sharedGroups(defs, given: groups, before: groupList)
        guard list != defs || groupList != shared else { return }
        list = defs
        groupList = shared
        NotificationCenter.default.post(name: changed, object: browser)
    }

    /// The groups that hold a twin, in the order given, each open; one
    /// not given, as it was before.
    nonisolated static func sharedGroups(_ defs: [TwinDef], given: [TabGroup], before: [TabGroup]) -> [TabGroup] {
        let used = Set(defs.compactMap(\.group))
        let givenIDs = Set(given.map(\.id))
        return (given + before.filter { !givenIDs.contains($0.id) })
            .filter { used.contains($0.id) }
            .map { group -> TabGroup in
                var open = group
                open.collapsed = false
                return open
            }
    }

    // MARK: - a row, worked out

    /// Where each tab of the new row comes from: one this window has, by
    /// its place in the row it had, or one made for a twin, by its place
    /// among the twins.
    enum Place: Equatable {
        case kept(Int)
        case made(Int)
    }

    /// A window's open tabs, by their twins (nil for one that is the
    /// window's alone: empty, private, or not said yet), set against the
    /// twins as they now are. The twins come in their order, each the
    /// window's own tab for it or one made; a tab whose twin was said and
    /// is gone goes; the window's own tabs, and twins never said, stay,
    /// each after the tab it followed. `gone`: places in `current`.
    nonisolated static func plan(_ current: [UUID?], twins: [UUID], known: Set<UUID>) -> (order: [Place], gone: [Int]) {
        var position: [UUID: Int] = [:]
        for (index, id) in twins.enumerated() where position[id] == nil { position[id] = index }
        var held: [Int: Int] = [:]
        // The window's own tabs, by the twin they came after (-1: first).
        var after: [Int: [Int]] = [:]
        var gone: [Int] = []
        var last = -1
        for (index, id) in current.enumerated() {
            if let id, let at = position[id] {
                // One tab for each twin: a second one goes.
                guard held[at] == nil else {
                    gone.append(index)
                    continue
                }
                held[at] = index
                last = at
            } else if let id, known.contains(id) {
                gone.append(index)
            } else {
                after[last, default: []].append(index)
            }
        }
        var order = (after[-1] ?? []).map(Place.kept)
        for at in twins.indices {
            order.append(held[at].map(Place.kept) ?? .made(at))
            order += (after[at] ?? []).map(Place.kept)
        }
        return (order, gone)
    }

    /// The twins' groups, each folded as this window had it, then the
    /// window's own groups that still hold a tab of its own.
    nonisolated static func merge(_ theirs: [TabGroup], into ours: [TabGroup], holding local: Set<UUID>) -> [TabGroup] {
        let mine = Dictionary(ours.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = theirs.map { group -> TabGroup in
            var kept = group
            if let own = mine[group.id] { kept.collapsed = own.collapsed }
            return kept
        }
        let shared = Set(out.map(\.id))
        out += ours.filter { !shared.contains($0.id) && local.contains($0.id) }
        return out
    }

    /// A row read from its file, as the twins now have it (see plan): the
    /// pins as they were, then the open tabs in the twins' order, each
    /// twin's page, name and group from the twin. The tab in front, gone,
    /// gives way to the one after it; pairs keep only what stays.
    nonisolated static func apply(_ shape: Session.Shape, twins defs: [TwinDef], groups: [TabGroup], known: Set<UUID>) -> Session.Shape {
        let pinned = shape.tabs.indices.filter { shape.tabs[$0].pin != nil }
        let loose = shape.tabs.indices.filter { shape.tabs[$0].pin == nil }
        let plan = plan(loose.map { shape.tabs[$0].twinID }, twins: defs.map(\.id), known: known)
        let byID = Dictionary(defs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tabs: [Session.Entry] = []
        var places: [Int: Int] = [:]
        for index in pinned {
            places[index] = tabs.count
            tabs.append(shape.tabs[index])
        }
        var local = Set<UUID>()
        for place in plan.order {
            switch place {
            case .kept(let at):
                let index = loose[at]
                var entry = shape.tabs[index]
                if let def = entry.twinID.flatMap({ byID[$0] }) {
                    if entry.url != def.url {
                        entry.url = def.url
                        entry.title = def.title
                    } else if !def.title.isEmpty {
                        entry.title = def.title
                    }
                    entry.name = def.name
                    entry.groupID = def.group
                } else if let group = entry.groupID {
                    local.insert(group)
                }
                places[index] = tabs.count
                tabs.append(entry)
            case .made(let at):
                let def = defs[at]
                tabs.append(Session.Entry(url: def.url, title: def.title, pin: nil, name: def.name,
                                          home: nil, groupID: def.group, twinID: def.id))
            }
        }
        // The tab in front, or the nearest that stays after it, or before.
        var active = -1
        if shape.active >= 0 {
            let after = (shape.active..<shape.tabs.count).first { places[$0] != nil }
            let before = (0..<min(shape.active, shape.tabs.count)).reversed().first { places[$0] != nil }
            active = (after ?? before).flatMap { places[$0] } ?? -1
        }
        let splits = shape.splits.compactMap { pair -> Session.Split? in
            let moved = pair.tabs.compactMap { places[$0] }
            guard moved.count == pair.tabs.count else { return nil }
            var kept = pair
            kept.tabs = moved
            kept.focused = pair.focused.flatMap { places[$0] }
            return kept
        }
        // No groups and none before: none written, as before.
        let merged = merge(groups, into: shape.groups ?? [], holding: local)
        return Session.Shape(tabs: tabs, active: active, groups: merged.isEmpty && shape.groups == nil ? nil : merged,
                             splits: splits)
    }
}

// MARK: - a window's part

extension Browser {
    /// Whether this window lists the same open tabs as the others.
    var mirrors: Bool { prefs.mirrorsTabs && !isPopup && !retired }

    /// Whether a tab is one every window lists: what the session keeps of
    /// an open tab (see kept), never a pin, nor one of Search's own pages —
    /// Settings or History, called up in one window, is that window's.
    func twinnable(_ tab: Tab) -> Bool { tab.pin == nil && tab.page == nil && kept(tab) }

    /// What makes a row's open tabs those tabs, in their order. A tab not
    /// yet one of the twins is given its id here.
    func twinDefs(_ row: [Tab]) -> [TwinDef] {
        row.compactMap { tab -> TwinDef? in
            guard twinnable(tab), let url = tab.pending ?? tab.address ?? tab.page?.url else { return nil }
            let id = tab.twinID ?? UUID()
            tab.twinID = id
            return TwinDef(id: id, url: url.absoluteString, title: tab.title, name: tab.name, group: tab.groupID)
        }
    }

    /// This window's row as it is, for the other windows. Not before the
    /// window has taken the twins in (joinTwins): a new window's empty row
    /// would close every other window's tabs.
    func publishTwins() {
        guard mirrors, twinsJoined else { return }
        Twins.set(twinDefs(tabs), groups: tabGroups, from: self)
    }

    /// Once this turn of the run loop is over, so that a change made in
    /// several steps is passed on once, whole.
    func twinsSoon() {
        guard mirrors, twinsJoined, !twinsDue else { return }
        twinsDue = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            twinsDue = false
            publishTwins()
        }
    }

    /// The window takes the twins in: a turn after it is made, once it is
    /// known for a pop-up or not, or as the switch comes on. Its row
    /// follows them; then it says its own, which adds the tabs only it had.
    func joinTwins() {
        guard mirrors else { return }
        Twins.turnedOn()
        twinsJoined = true
        twinsChanged()
        publishTwins()
    }

    /// The switch off: what this window has stays as it is.
    func leaveTwins() {
        twinsJoined = false
        Twins.turnedOff()
    }

    /// A row read from its file, as the twins have it (see Twins.apply).
    func twinned(_ shape: Session.Shape) -> Session.Shape {
        guard mirrors, twinsJoined, let defs = Twins.row() else { return shape }
        return Twins.apply(shape, twins: defs, groups: Twins.groups(), known: Twins.known)
    }

    /// Another window changed the open tabs: this window's row follows. A
    /// tab closed there is closed here, quietly — ⇧⌘T is the other
    /// window's — and one opened there is here asleep, at its page.
    func twinsChanged() {
        guard mirrors, let defs = Twins.row() else { return }
        let old = tabs
        let done = twinRow(tabs, twins: defs, groups: tabGroups, visible: visibleTabIDs)
        guard done.changed else { return }
        for tab in done.gone { letGoOfTwin(tab) }
        if tabGroups != done.groups { tabGroups = done.groups }
        showRow(done.row, active: activeID, splits: splits.filter { Browser.holds($0, in: done.row) })
        if !tabs.contains(where: { $0.id == activeID }) {
            let at = old.firstIndex { $0.id == activeID } ?? old.count
            let stays: (Tab) -> Bool = { tab in tab.pin == nil && self.tabs.contains { $0 === tab } }
            let next = old[min(at + 1, old.count)...].first(where: stays) ?? old[..<min(at, old.count)].last(where: stays)
            if let next {
                select(next, floatPrevious: false)
            } else {
                activeID = nil
                frontBlank()
            }
        }
        for tab in done.gone { tab.close() }
        writeRow(session(tabs, active: activeID, groups: tabGroups, splits: splits), now: false)
        if done.fresh { twinsSoon() }
    }

    /// A row of this window's tabs as the twins have it: its pins, then its
    /// open tabs in their order (see Twins.plan), each following its twin.
    /// `fresh`: it holds tabs the twins don't have yet, to be said.
    private func twinRow(_ row: [Tab], twins defs: [TwinDef], groups ours: [TabGroup],
                         visible: Set<Tab.ID>) -> (row: [Tab], gone: [Tab], groups: [TabGroup], changed: Bool, fresh: Bool) {
        let pinned = row.filter { $0.pin != nil }
        let loose = row.filter { $0.pin == nil }
        let current = loose.map { twinnable($0) ? $0.twinID : nil }
        let plan = Twins.plan(current, twins: defs.map(\.id), known: Twins.known)
        let byID = Dictionary(defs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = pinned
        var changed = !plan.gone.isEmpty
        var fresh = false
        var local = Set<UUID>()
        for place in plan.order {
            switch place {
            case .kept(let at):
                let tab = loose[at]
                if let def = current[at].flatMap({ byID[$0] }) {
                    if follow(tab, def, visible: visible) { changed = true }
                } else {
                    if twinnable(tab) { fresh = true }
                    if let group = tab.groupID { local.insert(group) }
                }
                out.append(tab)
            case .made(let at):
                out.append(makeTwin(defs[at]))
                changed = true
            }
        }
        if !out.elementsEqual(row, by: { $0 === $1 }) { changed = true }
        let groups = Twins.merge(Twins.groups(), into: ours, holding: local)
        if groups != ours { changed = true }
        return (out, plan.gone.map { loose[$0] }, groups, changed, fresh)
    }

    /// This window's tab for a twin, made asleep at its page.
    private func makeTwin(_ def: TwinDef) -> Tab {
        let tab = Tab(configuration: Web.configuration())
        prepare(tab)
        tab.restore(url: URL(string: def.url) ?? URL(string: "about:blank")!, title: def.title, name: def.name)
        tab.twinID = def.id
        tab.groupID = def.group
        return tab
    }

    /// This window's tab takes its twin's name, group and page. A page
    /// asleep here goes to the twin's at once; one awake here, out of
    /// sight and not playing, is let go and sleeps at the twin's page; one
    /// on screen, or playing, is this window's own until it is left.
    private func follow(_ tab: Tab, _ def: TwinDef, visible: Set<Tab.ID>) -> Bool {
        var changed = false
        if tab.name != def.name {
            tab.name = def.name
            changed = true
        }
        if tab.groupID != def.group {
            tab.groupID = def.group
            changed = true
        }
        guard let to = URL(string: def.url) else { return changed }
        let here = (tab.pending ?? tab.address ?? tab.page?.url)?.absoluteString
        if tab.built == nil {
            if here != def.url {
                tab.restore(url: to, title: def.title, name: tab.name)
                changed = true
            } else if !def.title.isEmpty, tab.title != def.title, tab.page == nil {
                // The same page, named since: its own history kept.
                tab.restore(url: to, title: def.title, name: tab.name, state: tab.keepsake)
                changed = true
            }
        } else if here != def.url, !visible.contains(tab.id), !tab.noisy {
            tab.rest()
            tab.restore(url: to, title: def.title, name: tab.name)
            changed = true
        }
        return changed
    }

    /// A tab closed in another window, before it goes here: what hangs on
    /// it here goes first, as when it is closed here.
    private func letGoOfTwin(_ tab: Tab) {
        if peekFrom == tab.id { closePeek() }
        if editingTab == tab.id { cancelTabEdit() }
        if floating == tab.id { land(covering: false) }
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)
        dropCertificateAsks(for: tab.id)
        leaveSplit(tab)
    }

    /// Every other window's tab for a twin.
    func twins(of id: UUID) -> [(browser: Browser, tab: Tab)] {
        Browsers.all.filter { $0 !== self && !$0.isPopup && !$0.retired }
            .flatMap { browser in (browser.tabs).filter { $0.twinID == id }.map { (browser, $0) } }
    }

    /// A tab asleep here, picked: when another window has looked at its
    /// page since — or has it on screen now — it wakes where that window
    /// is, with its history and its place on the page, rather than where
    /// this window last left it.
    func catchUp(_ tab: Tab) {
        guard mirrors, twinsJoined, tab.asleep, let id = tab.twinID else { return }
        var best: (tab: Tab, live: Bool)?
        for (browser, twin) in twins(of: id) {
            let live = browser.isOpen && browser.visibleTabIDs.contains(twin.id)
            guard live || twin.touched > tab.touched, twin.address != nil, twin.keepsake != nil else { continue }
            if let chosen = best, chosen.live && !live || chosen.live == live && chosen.tab.touched >= twin.touched { continue }
            best = (twin, live)
        }
        guard let twin = best?.tab, let url = twin.address, let state = twin.keepsake else { return }
        tab.restore(url: url, title: twin.title, name: tab.name, state: state)
    }

    /// When a tab every window lists was last left, in any window: a tab
    /// left alone here and read in another isn't left alone (Closing.swift).
    func lastLeft(_ tab: Tab) -> Date {
        guard mirrors, let id = tab.twinID else { return tab.leftSince }
        return twins(of: id).reduce(tab.leftSince) { max($0, $1.tab.leftSince) }
    }

    /// Whether another window has this tab's twin on screen.
    func twinOnScreen(_ tab: Tab) -> Bool {
        guard mirrors, let id = tab.twinID else { return false }
        return twins(of: id).contains { $0.browser.isOpen && $0.browser.visibleTabIDs.contains($0.tab.id) }
    }

    /// Move to Window with every window listing the tab: it is there
    /// already, so that window goes to its own tab for it, and this one
    /// keeps it. False for a tab the windows don't
    /// share, which moves as it always did.
    func showTwin(_ tab: Tab, in destination: Browser) -> Bool {
        guard mirrors, twinsJoined, twinnable(tab), destination.prefs.mirrorsTabs else { return false }
        publishTwins()
        guard let id = tab.twinID else { return false }
        if !destination.twinsJoined { destination.joinTwins() }
        destination.twinsChanged()
        guard let twin = destination.tabs.first(where: { $0.twinID == id }) else { return false }
        destination.select(twin, floatPrevious: false)
        return true
    }
}
