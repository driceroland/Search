import AppKit
import SwiftUI

// MARK: - the tree, drawn

/// The list itself: folders that open in place rather than to the side, each
/// row draggable above or below another, or into a folder, each row good
/// for a right-click too. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way.
struct BookmarkOutline: View {
    @ObservedObject var bookmarks: Bookmarks
    /// The folders open, kept by whoever shows the outline, so the manager
    /// can open the way down to one it was asked to show.
    @Binding var expanded: Set<Bookmark.ID>
    /// A row to wash for a moment, after a search showed where it is.
    var shown: Bookmark.ID? = nil
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void

    @State private var dragging: Bookmark.ID?
    /// Where the drag under way would land, drawn as a line or a wash.
    @State private var aimed: Aim?
    /// A closed folder held over opens after a moment, so a bookmark can go
    /// deep without being dropped on the way.
    @State private var spring: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows(bookmarks.roots, depth: 0, parent: nil)
            // Past the last row: the end of the top level, which "after" on
            // an open folder at the bottom can't reach. Only there while a
            // row is carried, or it is an empty band under the list (#391).
            if dragging != nil {
                Color.clear
                    .frame(height: 10)
                    .overlay(alignment: .top) { if aimed == Aim(id: nil, zone: .after) { Line(depth: 0) } }
                    .modifier(Landing(
                        isFolder: false,
                        allowed: { true },
                        aim: { aim($0.map { _ in Aim(id: nil, zone: .after) }) },
                        land: { _, providers in drop(providers) { bookmarks.move($0, into: nil) } }
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int, parent: Bookmark.ID?) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            let isOpen = node.isFolder && expanded.contains(node.id)
            Row(
                node: node,
                profile: bookmarks.profile,
                depth: depth,
                // A folder's arrow has a place in front of every row, so the
                // icons line up; with no folder at all, it is only a gap.
                arrows: bookmarks.roots.contains(where: \.isFolder),
                // An extension can write an address that does not parse,
                // and the menu below already unwraps this the same way.
                open: node.isFolder ? nil : { if let text = node.url, let url = URL(string: text) { open(url) } },
                isOpen: isOpen,
                dragging: dragging == node.id,
                aim: aimed?.id == node.id ? aimed?.zone : nil,
                shown: shown == node.id,
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                moveTargets: Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) },
                moveTo: { bookmarks.move(node.id, into: $0) },
                rename: { bookmarks.askRename(node) },
                newFolder: node.isFolder ? {
                    bookmarks.askNewFolder(in: node.id) { _ in expanded.insert(node.id) }
                } : nil,
                remove: { bookmarks.askRemove(node) }
            )
            .id(node.id)
            .overlay {
                if let url = node.url.flatMap(URL.init(string:)) {
                    MiddleClick { openInNewTab(url) }
                }
            }
            .onDrag {
                dragging = node.id
                settleWhenLetGo()
                return NSItemProvider(object: node.id.uuidString as NSString)
            }
            .modifier(Landing(
                isFolder: node.isFolder,
                allowed: { allows(node.id) },
                aim: { aim($0.map { Aim(id: node.id, zone: $0) }) },
                land: { zone, providers in
                    drop(providers) { id in
                        switch zone {
                        case .before: bookmarks.move(id, into: parent, at: index)
                        // Below an open folder's row is above its first
                        // child, so that is where it goes.
                        case .after where isOpen: bookmarks.move(id, into: node.id, at: 0)
                        case .after: bookmarks.move(id, into: parent, at: index + 1)
                        case .into: bookmarks.move(id, into: node.id)
                        }
                    }
                }
            ))

            if isOpen {
                if let kids = node.children, !kids.isEmpty {
                    // Type-erased: a view that calls itself can't let Swift
                    // infer its own opaque return type from its own body.
                    AnyView(rows(kids, depth: depth + 1, parent: node.id))
                } else {
                    // Where its first bookmark would be, so a drop here goes
                    // in, shown as the folder's own lower edge shows it.
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, indent(depth + 1) + 26)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .modifier(Landing(
                            isFolder: false,
                            allowed: { allows(node.id) },
                            aim: { aim($0.map { _ in Aim(id: node.id, zone: .after) }) },
                            land: { _, providers in drop(providers) { bookmarks.move($0, into: node.id) } }
                        ))
                }
            }
        }
    }

    private func toggle(_ id: Bookmark.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// A folder can't go above, below or into anything inside itself.
    private func allows(_ target: Bookmark.ID) -> Bool {
        guard let dragging else { return true }
        return target != dragging && !(bookmarks.path(to: target) ?? []).contains { $0.id == dragging }
    }

    private func aim(_ target: Aim?) {
        guard target != aimed else { return }
        aimed = target
        spring?.cancel()
        spring = nil
        guard let target, target.zone == .into, let id = target.id, !expanded.contains(id) else { return }
        let expanded = $expanded
        let work = DispatchWorkItem { withAnimation(Motion.settle) { _ = expanded.wrappedValue.insert(id) } }
        spring = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// SwiftUI says when a row lands on the list, not when it is let go
    /// anywhere else or the drag is called off, which left the line where
    /// it was last aimed and the row faded (#391). The button coming up says
    /// it: looked at a few times a second, which a drag's own loop holds
    /// back until it is over.
    private func settleWhenLetGo() {
        let aimed = $aimed, dragging = $dragging, spring = $spring
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                spring.wrappedValue?.cancel()
                spring.wrappedValue = nil
                aimed.wrappedValue = nil
                dragging.wrappedValue = nil
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], then move: @escaping (Bookmark.ID) -> Void) -> Bool {
        aim(nil)
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                withAnimation(Motion.settle) { move(id) }
                self.dragging = nil
            }
        }
        return true
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    enum Zone { case before, into, after }

    /// A row and where on it; no row is the end of the list.
    struct Aim: Equatable {
        let id: Bookmark.ID?
        let zone: Zone
    }

    /// The line where a dragged row would go.
    private struct Line: View {
        let depth: Int
        var body: some View {
            Capsule()
                .fill(Palette.ink.opacity(0.55))
                .frame(height: 2)
                .padding(.leading, CGFloat(depth) * 18 + 10)
                .padding(.trailing, 10)
        }
    }

    /// Every row takes a drop: the top of it means above, the bottom below,
    /// and the middle of a folder means into it. Which part the pointer is
    /// over is only known against the row's height, so it is measured.
    private struct Landing: ViewModifier {
        let isFolder: Bool
        let allowed: () -> Bool
        let aim: (Zone?) -> Void
        let land: (Zone, [NSItemProvider]) -> Bool

        @State private var height: CGFloat = 1

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = max($0, 1) }
                .onDrop(of: [.text], delegate: Spot(landing: self))
        }

        func zone(at y: CGFloat) -> Zone {
            let part = y / height
            guard isFolder else { return part < 0.5 ? .before : .after }
            return part < 0.25 ? .before : part > 0.75 ? .after : .into
        }

        private struct Spot: DropDelegate {
            let landing: Landing

            func dropUpdated(info: DropInfo) -> DropProposal? {
                guard landing.allowed() else {
                    landing.aim(nil)
                    return DropProposal(operation: .forbidden)
                }
                landing.aim(landing.zone(at: info.location.y))
                return DropProposal(operation: .move)
            }

            func dropExited(info: DropInfo) { landing.aim(nil) }

            func performDrop(info: DropInfo) -> Bool {
                guard landing.allowed() else { return false }
                return landing.land(landing.zone(at: info.location.y), info.itemProviders(for: [.text]))
            }
        }
    }

    private struct Row: View {
        let node: Bookmark
        /// Whose bookmarks, and so whose icons.
        let profile: UUID
        let depth: Int
        let arrows: Bool
        /// Nil for a folder — folders open in place, not out to a page.
        let open: (() -> Void)?
        let isOpen: Bool
        let dragging: Bool
        /// Where a drag over this row would land, if one is.
        let aim: Zone?
        let shown: Bool
        let toggle: (() -> Void)?
        let moveTargets: [(node: Bookmark, depth: Int)]
        let moveTo: (Bookmark.ID?) -> Void
        let rename: () -> Void
        /// A folder in this one: only on a folder.
        let newFolder: (() -> Void)?
        let remove: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Mark(icon: nil, size: 15)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        )
                } else {
                    if arrows { Spacer().frame(width: 10) }
                    Mark(icon: Favicons.of(profile).cached(for: node.address), size: 15)
                }
                // One without a name reads as its address, a shade lighter.
                Text(node.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(node.unnamed ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if node.isFolder, let kids = node.children, !kids.isEmpty {
                    Text("\(Bookmarks.count(kids))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.leading, CGFloat(depth) * 18 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(wash))
            .overlay(alignment: aim == .before ? .top : .bottom) {
                if aim == .before || aim == .after {
                    // Below an open folder is its first child's place.
                    Line(depth: aim == .after && isOpen ? depth + 1 : depth)
                        .offset(y: aim == .before ? -1.5 : 1.5)
                }
            }
            .contentShape(Rectangle())
            .opacity(dragging ? 0.35 : 1)
            .onTapGesture { open?() ?? toggle?() }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open {
                    Button("Open", action: open)
                    Divider()
                }
                Button("Rename…", action: rename)
                if let newFolder {
                    Button("New Folder Inside…", action: newFolder)
                }
                Menu("Move to") {
                    Button("Top Level", action: { moveTo(nil) })
                    if !moveTargets.isEmpty {
                        Divider()
                        ForEach(moveTargets, id: \.node.id) { target in
                            Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                                moveTo(target.node.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Remove", role: .destructive, action: remove)
            }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: dragging)
            .animation(Motion.quick, value: aim)
            .animation(Motion.settle, value: shown)
        }

        private var wash: Color {
            if aim == .into || shown { return Palette.hover }
            return hovering ? Palette.wash : .clear
        }
    }
}

/// The bookmark button, in the row or at the foot of the column: filled on
/// a page that is kept, and what hangs off it — the card for one bookmark
/// when ⇧⌘B opened it, the list otherwise.
struct BookmarkDoor: View {
    @ObservedObject var browser: Browser
    let arrowEdge: Edge

    var body: some View {
        Group {
            if let tab = browser.active {
                Kept(browser: browser, bookmarks: browser.bookmarks, tab: tab)
            } else {
                BookmarkDoor.door(browser, kept: false)
            }
        }
        .popover(isPresented: $browser.bookmarksOpen, arrowEdge: arrowEdge) {
            if let id = browser.bookmarkCard {
                BookmarkCard(browser: browser, bookmarks: browser.bookmarks, id: id)
            } else {
                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
            }
        }
    }

    fileprivate static func door(_ browser: Browser, kept: Bool) -> some View {
        Door(icon: kept ? "bookmark.fill" : "bookmark", help: "Bookmarks") { browser.toggleBookmarks() }
    }

    /// Watches the tab for where it goes and the bookmarks for what is
    /// kept, so the button fills and empties with either.
    private struct Kept: View {
        let browser: Browser
        @ObservedObject var bookmarks: Bookmarks
        @ObservedObject var tab: Tab

        var body: some View {
            BookmarkDoor.door(browser, kept: tab.address.map(bookmarks.contains) ?? false)
        }
    }
}

/// What ⇧⌘B opens off the button: the page just kept, or kept before, with
/// its name to change and a folder to file it in. Each change is kept as it
/// is made, so Done, Return, Escape and a click elsewhere all only close it.
struct BookmarkCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    let id: Bookmark.ID

    @State private var title = ""
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)

            VStack(spacing: 8) {
                line("Name") {
                    // Emptied, the field shows what the lists will read.
                    TextField(bookmarks.bookmark(id)?.url.flatMap(URL.init(string:)).map(Address.pretty) ?? "", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .focused($naming)
                        .onSubmit(close)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onChange(of: title) { _, typed in rename(typed) }
                }
                line("Folder") { folder }
            }

            HStack(spacing: 8) {
                Quick("Remove", tint: .red.opacity(0.75)) {
                    close()
                    bookmarks.remove(id)
                }
                Spacer(minLength: 0)
                Pill("Done", filled: true, action: close)
            }
        }
        .padding(14)
        .frame(width: 280)
        .popoverGround(card: true)
        .onAppear {
            title = bookmarks.bookmark(id)?.title ?? ""
            // The popover's window takes the keyboard only after this, and
            // gives it to the first button it finds unless told otherwise.
            DispatchQueue.main.async { naming = true }
        }
    }

    /// Where it is filed, and every other folder to file it in.
    private var folder: some View {
        let here = bookmarks.path(to: id)?.last
        return Menu {
            Button("Top Level") { bookmarks.move(id, into: nil) }
            let folders = Bookmarks.folders(bookmarks.roots)
            if !folders.isEmpty {
                Divider()
                ForEach(folders, id: \.node.id) { target in
                    Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                        bookmarks.move(id, into: target.node.id)
                    }
                }
            }
            Divider()
            Button("New Folder\u{2026}") {
                Ask.name("New Folder", placeholder: "Name", confirm: "Create") { name in
                    let made = bookmarks.insert(.folder(name, []), into: nil)
                    bookmarks.move(id, into: made.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                Text(here?.title ?? "Top Level")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func line(_ name: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 42, alignment: .leading)
            control()
        }
    }

    /// An empty name is kept as empty: the bookmarks bar then shows the
    /// bookmark's icon alone, as Chrome's and Safari's do.
    private func rename(_ typed: String) {
        BookmarkCard.rename(id, typed, in: bookmarks)
    }

    /// The same, for the bench.
    static func rename(_ id: Bookmark.ID, _ typed: String, in bookmarks: Bookmarks) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != bookmarks.bookmark(id)?.title else { return }
        bookmarks.update(id, title: name, url: nil)
    }

    private func close() {
        browser.bookmarksOpen = false
    }
}
