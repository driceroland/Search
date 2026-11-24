import SwiftUI

// The bookmarks bar: the top of the bookmarks, in a thin row above the page,
// as Chrome and Safari have one. A folder opens as a menu. What the row can't
// hold goes into a » at its end, a menu of the rest, as in Chrome and Safari
// (idea 958): the row once scrolled sideways, with nothing to show it did,
// and only a trackpad could scroll it.
//
// Off unless asked for — Settings › Tabs, or Bookmarks › Show Bookmarks Bar
// — since the page gives up a strip of its height to it. It goes with the
// tabs when they fold away (⌘S) and when a video takes the screen.
//
// Icons only (idea 980), also off unless asked for: every bookmark as its
// icon alone, its name on hover, as Edge's "Show icons only" and Vivaldi's
// "Icon only" do, rather than emptying each one's name (idea 334). Folders
// keep their names: every folder has the same icon, so a row of them would
// be a row of guesses, where a site's icon tells one from another.

struct BookmarksBar: View {
    @ObservedObject var browser: Browser
    let bookmarks: Bookmarks
    /// On the window's ground, above the page's card, with the tabs down the
    /// side: the ground's colour and no line of its own, the card's edge
    /// being the line (see CardEdge).
    var onFrame = false

    static let height: CGFloat = 30
    /// The space between two on the bar, and the air at its ends.
    static let gap: CGFloat = 2
    static let air: CGFloat = 10
    /// The » at the end, and the space before it.
    static let more: CGFloat = 22 + 4

    /// Each one's width as laid out, by id.
    @State private var widths: [Bookmark.ID: CGFloat] = [:]
    /// The bar's own width.
    @State private var room: CGFloat = 0

    /// How many, from the first, the bar holds in `room`, given their
    /// widths: all of them if they fit, or as many as fit beside the ».
    static func fit(_ widths: [CGFloat], room: CGFloat) -> Int {
        let open = room - 2 * air
        let all = widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
        guard all > open else { return widths.count }
        var end: CGFloat = 0
        for (index, width) in widths.enumerated() {
            end += (index == 0 ? 0 : gap) + width
            if end > open - more { return index }
        }
        return widths.count
    }

    var body: some View {
        let _ = Bench.count("bar")
        let roots = bookmarks.roots
        let shown = room > 0 ? BookmarksBar.fit(roots.map { widths[$0.id] ?? 0 }, room: room) : roots.count
        let hidden = Array(roots.dropFirst(shown))
        let _ = Bench.barHides(browser, hidden)
        // The row over the bar rather than in it: a row longer than the
        // window leaves the bar as wide as the window, held at its start.
        Color.clear.overlay(alignment: .leading) {
            HStack(spacing: BookmarksBar.gap) {
                ForEach(Array(roots.enumerated()), id: \.element.id) { index, node in
                    Item(node: node, iconsOnly: browser.prefs.bookmarksIconsOnly) {
                        if node.isFolder {
                            BookmarkMenu.shared.popUp(node)
                        } else if let text = node.url, let url = URL(string: text) {
                            browser.openBookmark(url)
                        }
                    }
                    .overlay {
                        // A middle-click: a bookmark in a new tab behind, a
                        // folder's bookmarks each in one (idea 959), as Brave
                        // and Firefox do; a folder's ⌘-click too, as Chrome
                        // does. A plain click still opens its menu, and a
                        // bookmark's ⌘-click is its own (openBookmark).
                        if let url = node.url.flatMap(URL.init(string:)) {
                            MiddleClick { browser.pickBookmark(url, inNewTab: true) }
                        } else if node.isFolder {
                            MiddleClick(command: true) { browser.openAll(node) }
                        }
                    }
                    .contextMenu { BookmarkActions(browser: browser, bookmarks: bookmarks, node: node) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                        widths[node.id] = $0.width
                        Bench.barLaid(node.id, $0)
                    }
                    .opacity(index < shown ? 1 : 0)
                    .allowsHitTesting(index < shown)
                    .accessibilityHidden(index >= shown)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, BookmarksBar.air)
        }
        .clipped()
        .overlay(alignment: .trailing) {
            if !hidden.isEmpty {
                More { BookmarkMenu.shared.popUp(hidden, title: "More Bookmarks") }
                    .padding(.trailing, BookmarksBar.air - 4)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { room = $0 }
        .frame(height: BookmarksBar.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Folder…") { bookmarks.askNewFolder(in: nil) }
            Divider()
            Toggle("Show Icons Only", isOn: Binding(
                get: { browser.prefs.bookmarksIconsOnly },
                set: { browser.prefs.bookmarksIconsOnly = $0 }))
            Button("Show Bookmarks…") { browser.bookmarking = true }
            Button("Hide Bookmarks Bar") {
                withAnimation(Motion.glide) { browser.prefs.bookmarksBar = false }
            }
        }
        .background {
            ZStack {
                // On glass the window's ground, colour and all, shows
                // through (Glass.swift).
                if !browser.glassy { onFrame ? Palette.frame : Palette.ground }
                // The tabs' wash carried on under them, or the colour
                // stopped at the bar's edge.
                if !browser.glassy { SpaceWash(look: browser.wash) }
            }
        }
        .overlay(alignment: .bottom) {
            if !onFrame { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }

    /// The » at the bar's end, when some don't fit: a menu of those.
    struct More: View {
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
                .onTapGesture(perform: act)
                .onHover { hovering = $0 }
                .help("More bookmarks")
                .accessibilityLabel("More Bookmarks")
                .accessibilityAddTraits(.isButton)
        }
    }

    /// One on the bar. A bookmark without a name is its icon alone, in a
    /// square as tall as the others, its address on hover; with icons only
    /// (idea 980) every bookmark is, its name on hover.
    struct Item: View {
        let node: Bookmark
        var iconsOnly = false
        let act: () -> Void
        @State private var hovering = false

        /// Its icon alone: renamed to nothing, or every bookmark with icons
        /// only. A folder keeps its name.
        static func bare(_ node: Bookmark, iconsOnly: Bool) -> Bool {
            node.unnamed || (iconsOnly && !node.isFolder)
        }

        /// What hovering it says: with icons only its name (or, without one,
        /// its address); otherwise its address, as before.
        static func tip(_ node: Bookmark, iconsOnly: Bool) -> String {
            iconsOnly && !node.isFolder ? node.label : (node.url ?? node.title)
        }

        var body: some View {
            let bare = Item.bare(node, iconsOnly: iconsOnly)
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                } else {
                    Mark(icon: Favicons.shared.cached(for: node.address), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 13)
                }
                if !bare {
                    Text(node.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if node.isFolder {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, bare ? 0 : 8)
            .frame(minWidth: bare ? 22 : nil)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .help(Item.tip(node, iconsOnly: iconsOnly))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.label)
            .accessibilityAddTraits(node.isFolder ? .isButton : .isLink)
        }
    }
}

/// What a right-click on a bookmark or a folder offers, on the bar above the
/// page and in the column alike (SideBookmarks).
struct BookmarkActions: View {
    let browser: Browser
    let bookmarks: Bookmarks
    let node: Bookmark

    var body: some View {
        if node.isFolder {
            folderMenu(node)
        } else if let url = node.url.flatMap(URL.init(string:)) {
            bookmarkMenu(node, url)
        }
    }

    @ViewBuilder
    func bookmarkMenu(_ node: Bookmark, _ url: URL) -> some View {
        Button("Open in New Tab") { browser.pickBookmark(url, inNewTab: true) }
        Button("Open in New Window") { browser.openInNewWindow([url]) }
        if browser.prefs.splitView {
            Button("Open in Split View") { browser.openInSplit(url) }
        }
        Button("Open in Private Tab") { browser.openShy(url) }
        Divider()
        Button("Rename…") { bookmarks.askRename(node) }
        Button("Edit Address…") { bookmarks.askAddress(node) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        Divider()
        moveMenu(node)
        Button("Remove", role: .destructive) { bookmarks.askRemove(node) }
    }

    @ViewBuilder
    func folderMenu(_ node: Bookmark) -> some View {
        let urls = (node.children ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
        Button("Open All in New Tabs") { browser.openAll(node) }
        .disabled(urls.isEmpty)
        Button("Open All in New Window") { browser.openInNewWindow(urls) }
            .disabled(urls.isEmpty)
        if browser.prefs.usesTabGroups {
            Button("Open All in Tab Group") { browser.openInTabGroup(urls, named: node.title) }
                .disabled(urls.isEmpty)
        }
        Divider()
        Button("Rename…") { bookmarks.askRename(node) }
        Button("New Folder Inside…") { bookmarks.askNewFolder(in: node.id) }
        Divider()
        moveMenu(node)
        Button("Remove", role: .destructive) { bookmarks.askRemove(node) }
    }

    @ViewBuilder
    func moveMenu(_ node: Bookmark) -> some View {
        let targets = Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) }
        if !targets.isEmpty {
            Menu("Move to") {
                ForEach(targets, id: \.node.id) { target in
                    Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                        bookmarks.move(node.id, into: target.node.id)
                    }
                }
            }
        }
    }
}

/// The bookmarks bar at the top of the column (Settings › Appearance › Tabs
/// › Show the bookmarks bar in the sidebar), in every space, before the pinned rows:
/// a row for each bookmark and folder on the bar, and a line under them.
/// A bookmark opens as it does from the bar; a folder opens as the bar's
/// menu. With icons only, each is a tile, its name the tooltip.
struct SideBookmarks: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    let bookmarks: Bookmarks
    var compact = false

    private static let gap: CGFloat = 2
    /// The line under them, and the air either side of it.
    private static let line: CGFloat = 1 + 2 * 6

    /// How tall it is drawn, for the column's sums (SideBar.rowsEnd), which
    /// can't wait for a measurement.
    static func height(_ count: Int, row: CGFloat) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * row + CGFloat(count - 1) * gap + line
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: compact ? .center : .leading, spacing: SideBookmarks.gap) {
                ForEach(bookmarks.roots) { node in
                    Row(browser: browser, prefs: prefs, bookmarks: bookmarks, node: node, compact: compact)
                }
            }
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                // As wide as the column's own lines (KeepLine).
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private struct Row: View {
        @Environment(\.greys) private var greys
        let browser: Browser
        @ObservedObject var prefs: Preferences
        let bookmarks: Bookmarks
        let node: Bookmark
        let compact: Bool
        @State private var hovering = false

        private var url: URL? { node.url.flatMap(URL.init(string:)) }
        private var title: String { node.unnamed ? (node.host ?? node.title) : node.title }

        var body: some View {
            Group {
                if compact {
                    mark.frame(width: Metrics.iconTile, height: Metrics.iconTile)
                } else {
                    HStack(spacing: 8) {
                        mark.frame(width: 15)
                        Text(title)
                            .font(.system(size: prefs.sideTitle))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if node.isFolder {
                            // Opens as a menu, as on the bar: not a folder
                            // that folds open in place, as the pinned ones do.
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: prefs.sideRow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(prefs.highContrastText || hovering ? Palette.ink : Palette.ink.opacity(0.75))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? greys.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture {
                if node.isFolder {
                    BookmarkMenu.shared.popUp(node)
                } else if let url {
                    browser.openBookmark(url)
                }
            }
            .overlay {
                if let url {
                    MiddleClick { browser.pickBookmark(url, inNewTab: true) }
                } else if node.isFolder {
                    MiddleClick(command: true) { browser.openAll(node) }
                }
            }
            .onHover { hovering = $0 }
            .contextMenu { BookmarkActions(browser: browser, bookmarks: bookmarks, node: node) }
            .help(compact ? title : (node.url ?? node.title))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(node.isFolder ? .isButton : .isLink)
        }

        @ViewBuilder
        private var mark: some View {
            if node.isFolder {
                Image(systemName: "folder")
                    .font(.system(size: compact ? 12 : 11))
                    .foregroundStyle(Palette.muted)
            } else {
                // Letters or icons, as the tabs show them.
                Mark(icon: prefs.glyph == .icons ? Favicons.shared.cached(for: node.address) : nil,
                     letter: String((node.host ?? "•").prefix(1)).uppercased(), size: compact ? 16 : 15)
            }
        }
    }
}
