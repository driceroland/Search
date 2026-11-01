import SwiftUI
import WebKit
import Combine

// A tab to another window, the tabs picked together, and stepping through them.
extension Browser {
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
    func arrangeFolders() {
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
}
