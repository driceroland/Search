import SwiftUI

// Bookmarks in the column, above the tabs, the way Arc keeps them. Off unless
// asked for in Settings › Tabs; the button at the column's foot stays either
// way, for adding a page and for the full list.
//
// A site is a row of a tab's size, 28 points with 2 between. A folder opens
// in place, its sites 14 points further in.
//
// A bookmark is a tab that has a place of its own, as in Arc: shut, it is
// only its address; opened with a click, it has a tab of its own, which is
// under the bookmark rather than among the tabs, and a second click comes
// back to it. A small dot says it is open; under the pointer the dot is a
// cross that shuts it. A tab dragged here becomes a bookmark the same way:
// it leaves the tabs and stays open, under the bookmark it now is, at the
// place it was let go. With nothing kept yet the section still stands, one
// quiet row inviting a tab. The other way, a bookmark dragged down among the
// tabs stops being one: its tab, or a new one when it was shut, joins the
// tabs where it is let go. A shut folder with an open bookmark somewhere in
// it wears the same dot, so no open tab is ever out of sight. The whole
// section folds under its heading, whose chevron shows under the pointer;
// folded, the heading takes a dropped tab at the end of the bookmarks, and
// wears the dot when one of them is open.
//
// That tab is still one of the browser's tabs, so everything a tab does —
// sleep, ⌘W, spaces — it does. The browser only remembers which bookmark it
// belongs to (Browser.shelfTabs); the column leaves it out of the tabs and
// the session leaves it out of tomorrow, when the bookmark is there, shut,
// in its place. A bookmark taken away gives its tab back to the tabs.
//
// A row is picked up the way a tab is, with the same gesture rather than the
// system's drag: a system drag carries text, and the column takes any text
// dropped on it as an address to open. A folder is carried with what is open
// under it. Nothing moves in the list until the row is let go — a line shows
// where it will land, or the folder it will go into lights up — so the list
// keeps its shape under the pointer while it is being aimed.
//
// Every piece has a fixed height, on purpose. The column works out where its
// rows stop by adding up what it drew (SideBar.rowsEnd) — the window's drag
// area under them is a real view, and it would take their clicks otherwise —
// so `Shelf.height` adds the shelf up the same way, from the same numbers,
// and `Shelf.drop` finds the row under the pointer with them too.
//
// Which folders are open is kept on the browser (Browser.shelfOpen), not in
// the view. The column is drawn twice, once plain and once scrolling, and
// ViewThatFits swaps one for the other as an opening folder makes the rows
// longer than the window: a folder open in one copy would be shut in the
// other the moment it took over.

struct Shelf: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var dragging: Bookmark.ID?
    @State private var travel: CGFloat = 0
    @State private var landing: Drop?

    static let row: CGFloat = 28
    static let gap: CGFloat = 2
    static let heading: CGFloat = 26
    static let indent: CGFloat = 14

    /// One row as it is drawn: a site or a folder, the folder it is in, and
    /// how deep that is.
    struct Line {
        let node: Bookmark
        let parent: Bookmark.ID?
        let depth: Int
    }

    /// The tree as rows, top to bottom — an open folder's sites under it,
    /// a shut folder's nowhere.
    static func lines(_ nodes: [Bookmark], open: Set<Bookmark.ID>, parent: Bookmark.ID? = nil, depth: Int = 0) -> [Line] {
        nodes.flatMap { node -> [Line] in
            let line = Line(node: node, parent: parent, depth: depth)
            guard node.isFolder, open.contains(node.id) else { return [line] }
            return [line] + lines(node.children ?? [], open: open, parent: node.id, depth: depth + 1)
        }
    }

    /// What the shelf takes of the column: its two headings and its rows,
    /// with a gap under each — one row when empty, the one inviting a tab.
    /// Folded, the two headings alone.
    static func height(for browser: Browser) -> CGFloat {
        let rows = browser.prefs.sideBookmarksFolded
            ? 0 : CGFloat(max(1, lines(browser.bookmarks.roots, open: browser.shelfOpen).count))
        return 2 * heading + rows * row + (rows + 1) * gap
    }

    /// Where the row or tab being held would land.
    private var aim: Drop? { landing ?? browser.shelfAim }

    var body: some View {
        let lines = Shelf.lines(bookmarks.roots, open: browser.shelfOpen)
        let carried = Shelf.carried(dragging, in: lines)
        let open = Set(browser.tabs.compactMap { browser.shelfTabs[$0.id] })
        let folded = browser.prefs.sideBookmarksFolded
        VStack(alignment: .leading, spacing: Shelf.gap) {
            Top(folded: folded, lit: folded && aim != nil, holdsOpen: folded && Shelf.holds(any: open, bookmarks.roots)) {
                withAnimation(Motion.settle) { browser.prefs.sideBookmarksFolded.toggle() }
            }
            if !folded {
                if lines.isEmpty { Empty(lit: aim != nil) }
                ForEach(Array(lines.enumerated()), id: \.element.node.id) { index, line in
                    let held = carried.contains(index)
                    let tab = browser.shelfTab(for: line.node.id)
                    ShelfRow(browser: browser, node: line.node, depth: line.depth,
                             isOpen: browser.shelfOpen.contains(line.node.id),
                             target: aim?.into == line.node.id,
                             tab: tab, live: tab != nil && tab?.id == browser.activeID,
                             hides: line.node.isFolder && !browser.shelfOpen.contains(line.node.id)
                                && Shelf.holds(any: open, line.node.children ?? []))
                        .offset(y: held ? travel : 0)
                        // Under the hand exactly, as a tab is (see SideBar.loose).
                        .transaction { if held { $0.animation = nil } }
                        .zIndex(held ? 1 : 0)
                        .shadow(color: .black.opacity(held && index == carried.lowerBound ? 0.14 : 0), radius: 12, y: 4)
                        .gesture(pick(line, lines: lines))
                }
            }
            // The tabs' own heading, so the two lists read as two.
            Heading(title: "Tabs")
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 10)
                }
        }
        .overlay(alignment: .topLeading) { if !lines.isEmpty, !folded { mark(rows: lines.count) } }
        .coordinateSpace(name: "shelf")
    }

    /// The line between two rows where the one held will land — the
    /// bookmarks' rows, or the tabs' under them.
    @ViewBuilder
    private func mark(rows: Int) -> some View {
        if let landing = aim, landing.into == nil {
            let slot = Shelf.row + Shelf.gap
            let y = landing.tabs.map { Shelf.heading * 2 + Shelf.gap + CGFloat(rows + $0) * slot - 1 }
                ?? Shelf.heading + CGFloat(landing.line) * slot
            Capsule()
                .fill(Palette.muted)
                .frame(height: 2)
                .padding(.leading, 10 + CGFloat(landing.depth) * Shelf.indent)
                .padding(.trailing, 10)
                // Across the gap above that row, which is the line's own height.
                .offset(y: y)
                .allowsHitTesting(false)
        }
    }

    private func pick(_ line: Line, lines: [Line]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("shelf"))
            .onChanged { value in
                if dragging != line.node.id { dragging = line.node.id }
                travel = value.translation.height
                landing = Shelf.drop(at: value.location.y, lines: lines, carrying: line.node.id)
            }
            .onEnded { value in
                // Where it is let go, which may be past the last move.
                if let landing = Shelf.drop(at: value.location.y, lines: lines, carrying: line.node.id) {
                    browser.land(line.node, landing)
                }
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                    landing = nil
                }
            }
    }

    // MARK: - where a row lands

    /// Where a row let go lands: in a folder (`parent`, nil for the top),
    /// just before one of its rows or at its end; and where to draw that.
    struct Drop: Equatable {
        var parent: Bookmark.ID?
        var before: Bookmark.ID?
        /// A folder the row goes into, lit rather than marked with a line.
        var into: Bookmark.ID?
        /// The row the line is drawn above, and how far in.
        var line = 0
        var depth = 0
        /// Down among the tabs instead, before the one at this place.
        var tabs: Int?
    }

    /// `id` is somewhere in `nodes`, however deep.
    static func holds(_ id: Bookmark.ID, _ nodes: [Bookmark]) -> Bool {
        nodes.contains { $0.id == id || holds(id, $0.children ?? []) }
    }

    /// One of `ids` is somewhere in `nodes`, however deep.
    static func holds(any ids: Set<Bookmark.ID>, _ nodes: [Bookmark]) -> Bool {
        nodes.contains { ids.contains($0.id) || holds(any: ids, $0.children ?? []) }
    }

    /// The rows a held one takes along: itself, and what is open under it.
    static func carried(_ id: Bookmark.ID?, in lines: [Line]) -> Range<Int> {
        guard let id, let first = lines.firstIndex(where: { $0.node.id == id }) else { return 0..<0 }
        var end = first + 1
        while end < lines.count, lines[end].depth > lines[first].depth { end += 1 }
        return first..<end
    }

    /// The pointer at `y`, in the shelf's own space: the middle half of a
    /// folder is that folder, the top half of any other row is just above
    /// it, the bottom half just below it. Past the last row is the end of
    /// the list. Nil over the rows being carried, which can't go inside
    /// themselves.
    static func drop(at y: CGFloat, lines: [Line], carrying id: Bookmark.ID?) -> Drop? {
        let slot = row + gap
        let span = carried(id, in: lines)
        let at = y - heading - gap
        guard !lines.isEmpty else { return Drop() }
        // Past the tabs' heading is the tabs: a site dropped there leaves the
        // bookmarks, a folder has nowhere to go. The tabs' rows are a tab's
        // size, the same as a bookmark's (see SideBar.row).
        let tabsTop = heading + CGFloat(lines.count) * slot + heading + gap
        if y >= tabsTop {
            guard let id, let held = lines.first(where: { $0.node.id == id }), !held.node.isFolder else { return nil }
            return Drop(tabs: max(0, Int(((y - tabsTop) / slot).rounded())))
        }
        if at >= CGFloat(lines.count) * slot {
            return Drop(parent: nil, before: nil, line: lines.count, depth: 0)
        }
        let index = max(0, Int(at / slot))
        guard !span.contains(index) else { return nil }
        let line = lines[index]
        let part = (at - CGFloat(index) * slot) / row
        if line.node.isFolder, part > 0.25, part < 0.75 {
            return Drop(parent: line.node.id, into: line.node.id, line: index, depth: line.depth + 1)
        }
        if part < 0.5 {
            return Drop(parent: line.parent, before: line.node.id, line: index, depth: line.depth)
        }
        // Below an open folder is the top of what is in it.
        if index + 1 < lines.count, lines[index + 1].parent == line.node.id {
            let first = lines[index + 1].node.id
            return first == id ? nil
                : Drop(parent: line.node.id, before: first, line: index + 1, depth: line.depth + 1)
        }
        let next = lines[(index + 1)...].first { $0.depth <= line.depth }
        let sibling = next?.parent == line.parent ? next?.node.id : nil
        // Just before itself is where it already is.
        if let sibling, sibling == id { return nil }
        return Drop(parent: line.parent, before: sibling, line: index + 1, depth: line.depth)
    }

    /// The one row of an empty shelf, lit while a tab is held over it.
    private struct Empty: View {
        let lit: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text("Drag a tab here")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.leading, 10)
            .frame(height: Shelf.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(lit ? Palette.wash : .clear)
            )
            .animation(Motion.quick, value: lit)
        }
    }

    /// The bookmarks' heading, which folds them: its chevron shows under the
    /// pointer, the dot while folded over an open bookmark.
    private struct Top: View {
        let folded: Bool
        let lit: Bool
        let holdsOpen: Bool
        let toggle: () -> Void

        @State private var hovering = false

        var body: some View {
            // Set as the tabs' heading is, so the two read alike; what folds
            // it sits over its end.
            Text("Bookmarks")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .padding(.leading, 10)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(height: Shelf.heading)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        if holdsOpen {
                            Circle()
                                .fill(Palette.muted)
                                .frame(width: 5, height: 5)
                                .frame(width: 15, height: 15)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(folded ? -90 : 0))
                            .frame(width: 15, height: 15)
                            .opacity(hovering ? 1 : 0)
                    }
                    .padding(.trailing, 7)
                    .padding(.bottom, 3)
                }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(lit ? Palette.wash : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: lit)
        }
    }

    private struct Heading: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 10)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(height: Shelf.heading)
        }
    }
}

/// One bookmark, as a line in the column.
private struct ShelfRow: View {
    @ObservedObject var browser: Browser
    let node: Bookmark
    let depth: Int
    let isOpen: Bool
    /// A row being carried will go into this folder if let go now.
    let target: Bool
    /// The bookmark's own tab, while it is open; `live` while it is on screen.
    let tab: Tab?
    let live: Bool
    /// A shut folder with an open bookmark somewhere in it.
    let hides: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if node.isFolder {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
            } else {
                Mark(icon: Favicons.shared.cached(node.host ?? ""),
                     letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 15)
            }
            Text(node.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(live ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
            Spacer(minLength: 2)
            if let tab { dot(tab) }
            if hides {
                Circle()
                    .fill(Palette.muted)
                    .frame(width: 5, height: 5)
                    .frame(width: 15, height: 15)
            }
            if node.isFolder {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    .frame(width: 15, height: 15)
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * Shelf.indent)
        .padding(.trailing, 7)
        .frame(height: Shelf.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(target || live ? Palette.wash : (hovering ? Palette.hover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: press)
        .onHover { hovering = $0 }
        .contextMenu {
            if let tab {
                Button("Close Tab") { browser.close(tab) }
                Divider()
            }
            Button("Manage Bookmarks…") { browser.bookmarking = true }
            Divider()
            Button("Remove", role: .destructive) { browser.bookmarks.remove(node.id) }
        }
        .help(node.url ?? node.title)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: target)
    }

    private func press() {
        if node.isFolder {
            withAnimation(Motion.settle) {
                if isOpen { browser.shelfOpen.remove(node.id) } else { browser.shelfOpen.insert(node.id) }
            }
        } else {
            browser.openShelf(node)
        }
    }

    /// The dot of an open bookmark, a cross under the pointer that shuts it.
    private func dot(_ tab: Tab) -> some View {
        ZStack {
            if hovering {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Palette.ink.opacity(0.07), in: Circle())
                    .transition(.opacity)
            } else {
                Circle()
                    .fill(Palette.muted)
                    .frame(width: 5, height: 5)
                    .transition(.opacity)
            }
        }
        .frame(width: 15, height: 15)
        .overlay {
            Color.clear
                .frame(width: 30, height: Shelf.row)
                .contentShape(Rectangle())
                .onTapGesture { if hovering { browser.close(tab) } else { press() } }
        }
    }
}

extension Browser {
    /// A tab held `y` points down the column's rows, negative above them
    /// (see SideBar.reorder). Over the bookmarks it is aimed at them, and
    /// this says so; anywhere else it is aimed at nothing here.
    func aimShelf(at y: CGFloat) -> Bool {
        let lines = Shelf.lines(bookmarks.roots, open: shelfOpen)
        // The shelf sits right above the rows, so its bottom is their top.
        let at = Shelf.height(for: self) + y
        let folded = prefs.sideBookmarksFolded
        let bottom = Shelf.heading + (folded ? 0 : CGFloat(max(1, lines.count)) * (Shelf.row + Shelf.gap))
        guard prefs.sideBookmarks, at < bottom else {
            if shelfAim != nil { shelfAim = nil }
            return false
        }
        // Folded, the heading takes it at the end of the bookmarks.
        let aim = folded ? Shelf.Drop() : Shelf.drop(at: at, lines: lines, carrying: nil)
        if shelfAim != aim { shelfAim = aim }
        return true
    }

    /// The tab let go: if it was aimed here, a bookmark where it was aimed,
    /// and that bookmark's own tab from now on. A new bookmark every time,
    /// even for an address kept already: each tab has a row of its own to
    /// be found under, never one it would share and be lost behind.
    func dropOnShelf(_ tab: Tab) {
        guard let aim = shelfAim else { return }
        shelfAim = nil
        guard let url = tab.address else { return }
        let node = bookmarks.insert(.site(tab.title, url), into: aim.parent)
        bookmarks.move(node.id, into: aim.parent, before: aim.before)
        shelfTabs[tab.id] = node.id
    }

    /// A bookmark let go where it was aimed: somewhere else among the
    /// bookmarks, or down among the tabs, where it stops being one.
    func land(_ node: Bookmark, _ drop: Shelf.Drop) {
        guard let place = drop.tabs else {
            bookmarks.move(node.id, into: drop.parent, before: drop.before)
            return
        }
        // The tabs as the column shows them, before this one joins them.
        let loose = tabs.filter { $0.pin == nil && !onShelf($0) }
        let tab: Tab
        if let open = shelfTab(for: node.id) {
            tab = open
        } else if let url = node.url.flatMap(URL.init(string:)) {
            tab = open(url, foreground: true)
        } else {
            return
        }
        shelfTabs[tab.id] = nil
        bookmarks.remove(node.id)
        // Before the tab at that place, or after the last; `move` wants the
        // index the tab ends up at, counted with the tab still where it is.
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }), let last = loose.last,
              let anchor = tabs.firstIndex(where: { $0.id == (place < loose.count ? loose[place] : last).id })
        else { return }
        let after = place >= loose.count
        move(tab, to: here < anchor ? (after ? anchor : anchor - 1) : (after ? anchor + 1 : anchor))
    }

    /// A bookmark's own tab, in the space on screen, while it is open.
    func shelfTab(for id: Bookmark.ID) -> Tab? {
        tabs.first { shelfTabs[$0.id] == id }
    }

    /// A tab that is a bookmark's own, and so shown under it rather than
    /// among the tabs — while the bookmarks are in the column and that
    /// bookmark is still kept.
    func onShelf(_ tab: Tab) -> Bool {
        guard prefs.sideBookmarks, let id = shelfTabs[tab.id] else { return false }
        return Shelf.holds(id, bookmarks.roots)
    }

    /// A click on a bookmark: back to its tab, or into a new one of its own.
    func openShelf(_ node: Bookmark) {
        if let tab = shelfTab(for: node.id) {
            select(tab)
            return
        }
        guard let url = node.url.flatMap(URL.init(string:)) else { return }
        let tab = open(url, foreground: true)
        shelfTabs[tab.id] = node.id
    }

    /// Where the `index`th of the tabs shown in the column sits in `tabs`,
    /// with the pinned ones before them and bookmarks' own among them.
    func place(of index: Int, among loose: [Tab]) -> Int {
        guard loose.indices.contains(index), let at = tabs.firstIndex(where: { $0.id == loose[index].id })
        else { return pinnedCount + index }
        return at
    }
}

extension Shelf {
    /// `./bench shelf`: the rows as drawn, after filling the list with a few
    /// sites and a folder (`seed`, test runs only), opening or shutting a
    /// folder by its title, or letting a row go at a height in the shelf
    /// (`drop`, the same reckoning as a drag's).
    static func bench(_ request: [String: Any], browser: Browser) -> [String: Any] {
        if request["seed"] as? Bool == true {
            guard Store.testing else { return ["error": "shelf seed only works on a --test run"] }
            func site(_ title: String, _ address: String) -> Bookmark {
                Bookmark(title: title, url: address, children: nil)
            }
            browser.bookmarks.take([
                site("WebKit", "https://webkit.org/"),
                site("Swift", "https://www.swift.org/"),
                .folder("Reading", [
                    site("Example", "https://example.com/"),
                    .folder("Deeper", [site("Apple", "https://www.apple.com/")]),
                ]),
            ], from: "Bench")
        }
        let folders = Bookmarks.folders(browser.bookmarks.roots).map(\.node)
        if let title = request["open"] as? String, let folder = folders.first(where: { $0.title == title }) {
            browser.shelfOpen.insert(folder.id)
        }
        if let title = request["close"] as? String, let folder = folders.first(where: { $0.title == title }) {
            browser.shelfOpen.remove(folder.id)
        }
        if let fold = request["fold"] as? Bool { browser.prefs.sideBookmarksFolded = fold }
        var landed: [String: Any] = [:]
        if let title = request["drop"] as? String, let y = request["y"] as? Double {
            guard Store.testing else { return ["error": "shelf drop only works on a --test run"] }
            let before = lines(browser.bookmarks.roots, open: browser.shelfOpen)
            guard let line = before.first(where: { $0.node.title == title }) else { return ["error": "no row called \(title)"] }
            if let drop = drop(at: y, lines: before, carrying: line.node.id) {
                browser.land(line.node, drop)
                landed = ["line": drop.line, "depth": drop.depth, "into": drop.into != nil, "tabs": drop.tabs ?? -1]
            } else {
                landed = ["nowhere": true]
            }
        }
        let rows = lines(browser.bookmarks.roots, open: browser.shelfOpen).map { line -> [String: Any] in
            ["title": line.node.title, "depth": line.depth, "folder": line.node.isFolder,
             "open": browser.shelfOpen.contains(line.node.id),
             "tab": browser.shelfTab(for: line.node.id) != nil,
             "live": browser.shelfTab(for: line.node.id)?.id == browser.activeID]
        }
        return ["on": browser.prefs.sideBookmarks, "folded": browser.prefs.sideBookmarksFolded, "rows": rows, "height": Double(height(for: browser)), "landed": landed]
    }
}
