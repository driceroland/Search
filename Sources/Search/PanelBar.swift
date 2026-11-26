import AppKit
import SwiftUI

// The panel bar down the window's far edge, as Vivaldi has one (Settings ›
// Appearance › Tabs › Panel bar, off unless turned on): Bookmarks,
// Downloads, History and the site panel, each opening the side panel on
// itself, and pressed again closing it. With it on, ⌘Y and ⇧⌘J open History
// and Downloads there too; off, they open as they always did. The bar can be
// put away with its switch still on (View › Side Panel › Hide Panel Bar);
// a panel's key then brings it out with its panel, and closing that panel
// puts it away again, unless Hide the panel bar again is off.

extension Browser {
    /// Whether the panel keys go to the bar's panels in this window: the
    /// switch on, and not a popup window, which has no side panel.
    var panelBarTakes: Bool { prefs.panelBarOn && !isPopup }

    /// ⌘Y and History › Show History…: the bar's History panel with the
    /// bar on, the History page as always otherwise.
    func showHistory() {
        if panelBarTakes { togglePanel(.history) } else { recalling = true }
    }

    /// ⇧⌘J and History › Downloads…: the bar's Downloads panel with the bar
    /// on, wherever Settings › Downloads › Open Downloads says otherwise.
    func showDownloadsFromKey() {
        if panelBarTakes { togglePanel(.downloads) } else { showDownloads() }
    }

    /// The side panel on `content`; the same again, and it closes. Whatever
    /// page was there is let go, as another site replacing it would be.
    func togglePanel(_ content: SidePanelContent) {
        guard panelBarTakes else { return }
        if sidePanelShown, sidePanel == content { return closeSidePanel() }
        borrowBar()
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.drop(in: self)
        sidePanel = content
        sidePanelShown = true
    }

    /// The globe on the bar, and View › Side Panel › Show Side Panel with
    /// the bar on: the site last there, or the first offered; again, and
    /// the panel closes. Only a site's panel: another panel open is
    /// replaced, not closed, as the bar's other buttons do.
    func toggleBarSite() {
        guard panelBarTakes else { return }
        if sidePanelShown, case .site = sidePanel { return closeSidePanel() }
        borrowBar()
        let last = URL(string: prefs.panelSite).flatMap { PanelSites.allowed($0) ? $0 : nil }
        showSiteInPanel(last ?? PanelSites.offered[0].url)
    }

    /// View › Side Panel › Hide Panel Bar: the bar alone, put away or
    /// brought back; put away, a panel open goes with it.
    func togglePanelBar() {
        guard prefs.panelBarOn else { return }
        prefs.panelBarBorrowed = false
        if prefs.panelBarHidden {
            prefs.panelBarHidden = false
        } else {
            prefs.panelBarHidden = true
            if sidePanelShown { closeSidePanel() }
        }
    }

    /// The bar out for a panel: if it was put away, kept in mind, to put it
    /// away again when that panel closes.
    private func borrowBar() {
        guard prefs.panelBarHidden else { return }
        prefs.panelBarHidden = false
        prefs.panelBarBorrowed = true
    }

    /// The side panel closed, whichever way (closeSidePanel): a bar that came
    /// out only for it goes back to how it was.
    func barPanelClosed() {
        guard prefs.panelBarBorrowed else { return }
        prefs.panelBarBorrowed = false
        if prefs.panelBarRestores { prefs.panelBarHidden = true }
    }
}

/// The bar itself: a narrow column of buttons at the window's far edge.
struct PanelBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// With the page as a card: on the window's ground beside it, as the
    /// column is, with no ground or edge of its own.
    var onFrame = false

    static let width: CGFloat = 40

    var body: some View {
        VStack(spacing: 4) {
            Door(icon: "bookmark", on: shown(.bookmarks), help: "Bookmarks",
                 shortcut: "view.bookmarksPanel") { browser.togglePanel(.bookmarks) }
            Door(icon: "arrow.down.circle", on: shown(.downloads), help: "Downloads",
                 shortcut: "history.downloads") { browser.togglePanel(.downloads) }
            Door(icon: "clock", on: shown(.history), help: "History",
                 shortcut: "history.show") { browser.togglePanel(.history) }
            if prefs.sitesInPanel {
                Rectangle().fill(Palette.hairline).frame(width: 18, height: 1).padding(.vertical, 4)
                Door(icon: "globe", on: siteShown, help: siteName,
                     shortcut: "view.sitePanel") { browser.toggleBarSite() }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: PanelBar.width)
        .frame(maxHeight: .infinity)
        .background { if !onFrame && !browser.glassy { Palette.ground } }
        .overlay(alignment: .leading) { if !onFrame { Rectangle().fill(Palette.hairline).frame(width: 1) } }
    }

    private func shown(_ content: SidePanelContent) -> Bool {
        browser.sidePanelShown && browser.sidePanel == content
    }

    private var siteShown: Bool {
        guard browser.sidePanelShown, case .site = browser.sidePanel else { return false }
        return true
    }

    private var siteName: String {
        URL(string: prefs.panelSite)?.host().map(Address.withoutWWW) ?? "Website"
    }
}

/// The title line each of the bar's own panels starts with.
private struct PanelHead: View {
    let title: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Close", act: close)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

/// A search field over a panel's list.
private struct PanelHunt: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.hover))
        .padding(10)
    }
}

/// One line of a panel's list: a mark, a title, a line under it.
private struct PanelRow: View {
    let mark: AnyView
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    var depth = 0
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            mark.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: act)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}

// MARK: - history

/// Where you have been, newest first under each day, as the History page
/// lists it. A click goes there in the tab on screen; with ⌘, a tab behind.
struct HistorySide: View {
    @ObservedObject var browser: Browser
    @State private var hunt = ""
    @State private var lines: [Line] = []

    struct Line: Identifiable {
        let id: String
        let day: String?
        let trace: History.Trace?
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHead(title: "History") { browser.closeSidePanel() }
            PanelHunt(text: $hunt, prompt: "Search history")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        if let day = line.day {
                            Text(day)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        } else if let trace = line.trace {
                            PanelRow(
                                mark: AnyView(Mark(icon: Favicons.shared.cached(for: trace.url),
                                                   letter: trace.address.first.map { String($0).uppercased() } ?? "•")),
                                title: trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title,
                                detail: Address.withoutWWW(trace.address),
                                trailing: When.clock(trace.last)
                            ) {
                                if NSEvent.modifierFlags.contains(.command) {
                                    browser.open(trace.url, foreground: false)
                                } else {
                                    browser.active?.go(to: trace.url)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear(perform: refresh)
        .onChange(of: hunt) { _, _ in refresh() }
        .onChange(of: browser.spaceID) { _, _ in refresh() }
    }

    private func refresh() {
        let calendar = Calendar.current
        let days = Dictionary(grouping: browser.history.everything(matching: hunt)) { calendar.startOfDay(for: $0.last) }
        var made: [Line] = []
        for (day, traces) in days.sorted(by: { $0.key > $1.key }) {
            made.append(Line(id: "day " + day.description, day: When.day(day), trace: nil))
            for trace in traces.sorted(by: { $0.last > $1.last }) {
                made.append(Line(id: trace.id, day: nil, trace: trace))
            }
        }
        lines = made
    }
}

// MARK: - bookmarks

/// The bookmarks as a tree, folders opened in place; with a search, every
/// bookmark that matches, flat.
struct BookmarksSide: View {
    @ObservedObject var browser: Browser
    @State private var hunt = ""
    @State private var open: Set<Bookmark.ID> = []

    private struct Line: Identifiable {
        let node: Bookmark
        let depth: Int
        var id: Bookmark.ID { node.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHead(title: "Bookmarks") { browser.closeSidePanel() }
            PanelHunt(text: $hunt, prompt: "Search bookmarks")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        let node = line.node
                        if node.isFolder {
                            PanelRow(
                                mark: AnyView(Image(systemName: open.contains(node.id) ? "folder.fill" : "folder")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.muted)),
                                title: node.label,
                                depth: line.depth
                            ) {
                                if open.contains(node.id) { open.remove(node.id) } else { open.insert(node.id) }
                            }
                        } else if let text = node.url, let url = URL(string: text) {
                            PanelRow(
                                mark: AnyView(Mark(icon: Favicons.shared.cached(for: url),
                                                   letter: node.label.first.map { String($0).uppercased() } ?? "•")),
                                title: node.label,
                                depth: line.depth
                            ) {
                                browser.openBookmark(url)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var lines: [Line] {
        let roots = browser.bookmarks.roots
        let typed = hunt.trimmingCharacters(in: .whitespaces).lowercased()
        var made: [Line] = []
        if !typed.isEmpty {
            func find(_ nodes: [Bookmark]) {
                for node in nodes {
                    if node.isFolder { find(node.children ?? []) }
                    else if node.label.lowercased().contains(typed) || (node.url ?? "").lowercased().contains(typed) {
                        made.append(Line(node: node, depth: 0))
                    }
                }
            }
            find(roots)
            return made
        }
        func walk(_ nodes: [Bookmark], depth: Int) {
            for node in nodes {
                made.append(Line(node: node, depth: depth))
                if node.isFolder, open.contains(node.id) { walk(node.children ?? [], depth: depth + 1) }
            }
        }
        walk(roots, depth: 0)
        return made
    }
}
