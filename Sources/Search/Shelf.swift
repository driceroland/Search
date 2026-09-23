import SwiftUI

// Bookmarks in the column, above the tabs, the way Arc keeps them. Off unless
// asked for in Settings › Tabs; the button at the column's foot stays either
// way, for adding a page and for the full list.
//
// A site is a row of a tab's size, 28 points with 2 between, and opens where
// a bookmark always has (see Browser.visit). A folder opens in place, its
// sites 14 points further in. Nothing here is dragged: filing things away is
// the manager's job, one right-click off.
//
// Every piece has a fixed height, on purpose. The column works out where its
// rows stop by adding up what it drew (SideBar.rowsEnd) — the window's drag
// area under them is a real view, and it would take their clicks otherwise —
// so `Shelf.height` adds the shelf up the same way, from the same numbers.
//
// Which folders are open is kept on the browser (Browser.shelfOpen), not in
// the view. The column is drawn twice, once plain and once scrolling, and
// ViewThatFits swaps one for the other as an opening folder makes the rows
// longer than the window: a folder open in one copy would be shut in the
// other the moment it took over.

struct Shelf: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    static let row: CGFloat = 28
    static let gap: CGFloat = 2
    static let heading: CGFloat = 26
    static let indent: CGFloat = 14

    /// One row as it is drawn: a site or a folder, and how deep it sits.
    struct Line {
        let node: Bookmark
        let depth: Int
    }

    /// The tree as rows, top to bottom — an open folder's sites under it,
    /// a shut folder's nowhere.
    static func lines(_ nodes: [Bookmark], open: Set<Bookmark.ID>, depth: Int = 0) -> [Line] {
        nodes.flatMap { node -> [Line] in
            let line = Line(node: node, depth: depth)
            guard node.isFolder, open.contains(node.id) else { return [line] }
            return [line] + lines(node.children ?? [], open: open, depth: depth + 1)
        }
    }

    /// What the shelf takes of the column: nothing without a bookmark, and
    /// otherwise its two headings and its rows, with a gap under each.
    static func height(for browser: Browser) -> CGFloat {
        guard !browser.bookmarks.isEmpty else { return 0 }
        let rows = CGFloat(lines(browser.bookmarks.roots, open: browser.shelfOpen).count)
        return 2 * heading + rows * row + (rows + 1) * gap
    }

    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: Shelf.gap) {
                Heading(title: "Bookmarks")
                ForEach(Shelf.lines(bookmarks.roots, open: browser.shelfOpen), id: \.node.id) { line in
                    ShelfRow(browser: browser, node: line.node, depth: line.depth,
                             isOpen: browser.shelfOpen.contains(line.node.id))
                }
                // The tabs' own heading, so the two lists read as two.
                Heading(title: "Tabs")
                    .overlay(alignment: .top) {
                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 10)
                    }
            }
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
                .fill(hovering ? Palette.hover : .clear)
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

extension Shelf {
    /// `./bench shelf`: the rows as drawn, after filling the list with a few
    /// sites and a folder (`seed`, test runs only) or opening or shutting a
    /// folder by its title.
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
        let rows = lines(browser.bookmarks.roots, open: browser.shelfOpen).map { line -> [String: Any] in
            ["title": line.node.title, "depth": line.depth, "folder": line.node.isFolder,
             "open": browser.shelfOpen.contains(line.node.id)]
        }
        return ["on": browser.prefs.sideBookmarks, "rows": rows, "height": Double(height(for: browser))]
    }
}
