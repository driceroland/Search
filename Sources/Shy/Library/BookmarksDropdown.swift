import AppKit
import SwiftUI

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var expanded: Set<Bookmark.ID>

    init(browser: Browser, bookmarks: Bookmarks) {
        self.browser = browser
        self.bookmarks = bookmarks
        _expanded = State(initialValue: Self.opening(bookmarks.roots))
    }

    /// Open as the list opens: a top level that is one folder and nothing
    /// else, as bringing bookmarks in from another browser often leaves
    /// ("Dia", "Imported from Chrome"). Closed, it was one row in a list
    /// sized for all it holds (see listHeight).
    static func opening(_ roots: [Bookmark]) -> Set<Bookmark.ID> {
        guard roots.count == 1, let only = roots.first, only.isFolder else { return [] }
        return [only.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks, expanded: $expanded) { url in
                        browser.pickBookmark(url)
                    } openInNewTab: { url in
                        browser.pickBookmark(url, inNewTab: true)
                    }
                    .padding(6)
                }
                .frame(height: listHeight)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot(browser.pageKept ? "bookmark.fill" : "bookmark", browser.pageKept ? "Edit This Bookmark\u{2026}" : "Add This Page") {
                    browser.bookmarkCurrent()
                }
                Foot(nil, "Manage Bookmarks…") { browser.bookmarking = true }
            }
            .padding(6)
        }
        .frame(width: 280)
        .popoverGround(card: true)
    }

    /// The list as tall as the whole tree would be with every folder open,
    /// up to 360 points. The popover takes its height once, from what the
    /// list holds as it opens, and doesn't grow with a folder opened in it:
    /// a list of one closed folder was one row high, and the folder opened
    /// into a sliver above Add This Page.
    var listHeight: CGFloat {
        let most: CGFloat = 360
        var lines = 0
        Self.count(bookmarks.roots, into: &lines, upTo: Int(most / Self.line) + 1)
        return min(most, CGFloat(lines) * Self.line + 12)
    }

    /// A row's height and the gap under it (see BookmarkOutline.Row).
    private static let line: CGFloat = 28

    /// Every row with every folder open, an empty one's "Empty" included,
    /// counted only as far as the list can be tall.
    private static func count(_ nodes: [Bookmark], into lines: inout Int, upTo limit: Int) {
        for node in nodes {
            guard lines < limit else { return }
            lines += 1
            guard node.isFolder else { continue }
            if let kids = node.children, !kids.isEmpty { count(kids, into: &lines, upTo: limit) } else { lines += 1 }
        }
    }

    private struct Foot: View {
        let symbol: String?
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String?, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}
