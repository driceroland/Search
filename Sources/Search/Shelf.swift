import SwiftUI

// Bookmarks in the column, above the tabs, the way Arc keeps them. Off unless
// asked for in Settings › Tabs; the button at the column's foot stays either
// way, for adding a page and for the full list.
//
// A site is a row of a tab's size, 28 points with 2 between, and opens where
// a bookmark always has (see Browser.visit). A folder opens in place, its
// sites 14 points further in. With nothing kept yet the section still
// stands, one quiet row inviting a tab: it is where a tab is dragged to
// become a bookmark, at the place it is let go, and the tab stays open.
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
    static func height(for browser: Browser) -> CGFloat {
        let rows = CGFloat(max(1, lines(browser.bookmarks.roots, open: browser.shelfOpen).count))
        return 2 * heading + rows * row + (rows + 1) * gap
    }

    /// Where the row or tab being held would land.
    private var aim: Drop? { landing ?? browser.shelfAim }

    var body: some View {
        let lines = Shelf.lines(bookmarks.roots, open: browser.shelfOpen)
        let carried = Shelf.carried(dragging, in: lines)
        VStack(alignment: .leading, spacing: Shelf.gap) {
            Heading(title: "Bookmarks")
            if lines.isEmpty { Empty(lit: aim != nil) }
            ForEach(Array(lines.enumerated()), id: \.element.node.id) { index, line in
                let held = carried.contains(index)
                ShelfRow(browser: browser, node: line.node, depth: line.depth,
                         isOpen: browser.shelfOpen.contains(line.node.id),
                         target: aim?.into == line.node.id)
                    .offset(y: held ? travel : 0)
                    // Under the hand exactly, as a tab is (see SideBar.loose).
                    .transaction { if held { $0.animation = nil } }
                    .zIndex(held ? 1 : 0)
                    .shadow(color: .black.opacity(held && index == carried.lowerBound ? 0.14 : 0), radius: 12, y: 4)
                    .gesture(pick(line, lines: lines))
            }
            // The tabs' own heading, so the two lists read as two.
            Heading(title: "Tabs")
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 10)
                }
        }
        .overlay(alignment: .topLeading) { if !lines.isEmpty { mark } }
        .coordinateSpace(name: "shelf")
    }

    /// The line between two rows where the one held will land.
    @ViewBuilder
    private var mark: some View {
        if let landing = aim, landing.into == nil {
            Capsule()
                .fill(Palette.muted)
                .frame(height: 2)
                .padding(.leading, 10 + CGFloat(landing.depth) * Shelf.indent)
                .padding(.trailing, 10)
                // Across the gap above that row, which is the line's own height.
                .offset(y: Shelf.heading + CGFloat(landing.line) * (Shelf.row + Shelf.gap))
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
                    bookmarks.move(line.node.id, into: landing.parent, before: landing.before)
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

    @State private var hovering = false

    private var url: URL? { node.url.flatMap(URL.init(string:)) }

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
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            Spacer(minLength: 2)
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
                .fill(target ? Palette.wash : (hovering ? Palette.hover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: press)
        .onHover { hovering = $0 }
        .contextMenu {
            if let url {
                Button("Open in New Tab") { _ = browser.open(url, foreground: true) }
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
        } else if let url {
            browser.visit(url)
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
        let bottom = Shelf.heading + CGFloat(max(1, lines.count)) * (Shelf.row + Shelf.gap)
        guard prefs.sideBookmarks, at < bottom else {
            if shelfAim != nil { shelfAim = nil }
            return false
        }
        let aim = Shelf.drop(at: at, lines: lines, carrying: nil)
        if shelfAim != aim { shelfAim = aim }
        return true
    }

    /// The tab let go: kept where it was aimed, if it was aimed here. The
    /// tab itself stays open where it was.
    func dropOnShelf(_ tab: Tab) {
        guard let aim = shelfAim else { return }
        shelfAim = nil
        guard let url = tab.address else { return }
        guard !bookmarks.contains(url) else {
            announce("Already a bookmark")
            return
        }
        let node = bookmarks.insert(.site(tab.title, url), into: aim.parent)
        bookmarks.move(node.id, into: aim.parent, before: aim.before)
        announce("Bookmarked")
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
        var landed: [String: Any] = [:]
        if let title = request["drop"] as? String, let y = request["y"] as? Double {
            guard Store.testing else { return ["error": "shelf drop only works on a --test run"] }
            let before = lines(browser.bookmarks.roots, open: browser.shelfOpen)
            guard let line = before.first(where: { $0.node.title == title }) else { return ["error": "no row called \(title)"] }
            if let drop = drop(at: y, lines: before, carrying: line.node.id) {
                browser.bookmarks.move(line.node.id, into: drop.parent, before: drop.before)
                landed = ["line": drop.line, "depth": drop.depth, "into": drop.into != nil]
            } else {
                landed = ["nowhere": true]
            }
        }
        let rows = lines(browser.bookmarks.roots, open: browser.shelfOpen).map { line -> [String: Any] in
            ["title": line.node.title, "depth": line.depth, "folder": line.node.isFolder,
             "open": browser.shelfOpen.contains(line.node.id)]
        }
        return ["on": browser.prefs.sideBookmarks, "rows": rows, "height": Double(height(for: browser)), "landed": landed]
    }
}
