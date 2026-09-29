import SwiftUI

// The bookmarks bar: the top of the bookmarks, in a thin row above the page,
// as Chrome and Safari have one. A folder opens as a menu. More than the row
// holds scrolls sideways.
//
// Off unless asked for — Settings › Tabs, or Bookmarks › Show Bookmarks Bar
// — since the page gives up a strip of its height to it. It goes with the
// tabs when they fold away (⌘S) and when a video takes the screen.

struct BookmarksBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    static let height: CGFloat = 30

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(bookmarks.roots) { node in
                    Item(node: node) {
                        if node.isFolder {
                            BookmarkMenu.shared.popUp(node)
                        } else if let text = node.url, let url = URL(string: text) {
                            browser.visit(url)
                        }
                    }
                    .overlay {
                        if let url = node.url.flatMap(URL.init(string:)) {
                            MiddleClick { browser.pickBookmark(url, inNewTab: true) }
                        }
                    }
                    .contextMenu {
                        if node.isFolder {
                            folderMenu(node)
                        } else if let url = node.url.flatMap(URL.init(string:)) {
                            bookmarkMenu(node, url)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: BookmarksBar.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Folder…") { bookmarks.askNewFolder(in: nil) }
            Divider()
            Button("Show Bookmarks…") { browser.bookmarking = true }
            Button("Hide Bookmarks Bar") {
                withAnimation(Motion.glide) { browser.prefs.bookmarksBar = false }
            }
        }
        .background(Palette.ground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func bookmarkMenu(_ node: Bookmark, _ url: URL) -> some View {
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
    private func folderMenu(_ node: Bookmark) -> some View {
        let urls = (node.children ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
        Button("Open All in New Tabs") {
            for url in urls { browser.open(url, foreground: false, atEnd: true, from: browser.active, mayWait: true) }
        }
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
    private func moveMenu(_ node: Bookmark) -> some View {
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

    private struct Item: View {
        let node: Bookmark
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                } else {
                    Mark(icon: Favicons.shared.cached(node.site ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 13)
                }
                Text(node.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if node.isFolder {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .help(node.url ?? node.title)
        }
    }
}
