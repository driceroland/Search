import AppKit
import SwiftUI

/// The full list, for putting it in order, finding one, or bringing more in.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var expanded: Set<Bookmark.ID> = []
    @State private var query = ""
    @FocusState private var hunting: Bool
    /// The row just shown from a search, washed for a moment so the eye
    /// lands on it.
    @State private var shown: Bookmark.ID?

    var body: some View {
        Plate("Bookmarks", width: 600, close: { browser.bookmarking = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $query, prompt: "Search bookmarks", focus: $hunting)
                    .onSubmit(openFirst)

                if bookmarks.isEmpty {
                    Card { Nothing("Nothing kept yet. Add this page with ⇧⌘B, or bring yours in below.") }
                } else if !query.isEmpty {
                    found
                } else {
                    ScrollViewReader { scroller in
                        ScrollView(showsIndicators: false) {
                            Card {
                                BookmarkOutline(bookmarks: bookmarks, expanded: $expanded, shown: shown) { url in
                                    browser.pickBookmark(url)
                                } openInNewTab: { url in
                                    browser.pickBookmark(url, inNewTab: true)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                            }
                            .padding(.bottom, 2)
                        }
                        .listHeight(440)
                        // A bookmark found is shown where it lives, which
                        // may be below what shows. This list is only made
                        // as the search is cleared for it, with the row to
                        // show already set, so it is read as it appears too.
                        .onChange(of: shown, initial: true) { _, id in
                            guard let id else { return }
                            DispatchQueue.main.async {
                                withAnimation(Motion.settle) { scroller.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Pill("Bring in…") { browser.importFile() }
                Pill("File…") { browser.importFile() }
                Spacer()
                Pill("New Folder…") { bookmarks.askNewFolder(in: nil) }
                Text(bookmarks.count == 1 ? "1 bookmark" : "\(bookmarks.count) bookmarks")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .animation(Motion.settle, value: query.isEmpty)
        .onAppear { hunting = true }
    }

    /// What the search finds, flat, each with the folders it is in. Nothing
    /// here is dragged: it is put in order in the tree.
    @ViewBuilder
    private var found: some View {
        let hits = bookmarks.matches(query)
        if hits.isEmpty {
            Card { Nothing("Nothing matches.") }
        } else {
            ScrollView(showsIndicators: false) {
                Card {
                    ForEach(Array(hits.enumerated()), id: \.element.node.id) { index, hit in
                        if index > 0 { Rule(inset: 40) }
                        Found(
                            node: hit.node,
                            profile: bookmarks.profile,
                            path: hit.path,
                            open: hit.node.url.flatMap(URL.init(string:)).map { url in { browser.pickBookmark(url) } },
                            show: { show(hit.node) }
                        )
                    }
                }
                .padding(.bottom, 2)
            }
            .listHeight(440)
        }
    }

    /// Return in the field: the first site found.
    private func openFirst() {
        guard let url = bookmarks.matches(query).lazy.compactMap({ $0.node.url.flatMap(URL.init(string:)) }).first
        else { return }
        browser.pickBookmark(url)
    }

    /// Back to the tree, opened down to it, and it washed a moment. A
    /// folder is shown open.
    private func show(_ node: Bookmark) {
        query = ""
        expanded.formUnion((bookmarks.path(to: node.id) ?? []).map(\.id))
        if node.isFolder { expanded.insert(node.id) }
        shown = node.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if shown == node.id { withAnimation(Motion.settle) { shown = nil } }
        }
    }

    /// One line of what was found: its title, then where it is.
    private struct Found: View {
        let node: Bookmark
        /// Whose bookmarks, and so whose icons.
        let profile: UUID
        let path: [String]
        /// Nil for a folder, which is shown in the tree instead.
        let open: (() -> Void)?
        let show: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                if node.isFolder {
                    Mark(icon: nil, size: 16)
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 9.5)).foregroundStyle(Palette.muted))
                } else {
                    Mark(icon: Favicons.of(profile).cached(for: node.address), size: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.label)
                        .font(.system(size: 13))
                        .foregroundStyle(node.unnamed ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                    Text(whereabouts)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Show in Folder", act: show)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { open?() ?? show() }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open { Button("Open", action: open) }
                Button("Show in Folder", action: show)
            }
            .animation(Motion.quick, value: hovering)
        }

        /// The folders it is in, then the site.
        private var whereabouts: String {
            let folders = path.isEmpty ? "Top level" : path.joined(separator: " \u{203A} ")
            guard let host = node.host else { return folders }
            return folders + "  \u{00B7}  " + host
        }
    }
}
