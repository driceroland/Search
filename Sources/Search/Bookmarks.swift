import AppKit
import SwiftUI

// Bookmarks: folders and sites, kept in a small file.
//
// Shown as the app's own kind of list rather than a system menu, on purpose:
// a menu can't be dragged into, and can't be asked a second thing by
// right-clicking it. A folder you actually keep things in wants both.

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var roots: [Bookmark] = [] {
        didSet { kept = Set(Bookmarks.urls(roots).map(\.absoluteString)) }
    }

    /// Every address kept, for `contains` — asked on every redraw of the
    /// button, which fills in on a page that is kept.
    private var kept: Set<String> = []

    init() { load() }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// Every folder in the tree, each with how deep it sits — for "move to
    /// folder" lists, where a folder three deep should look like it.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    /// Every site and folder whose title or address holds all the words,
    /// with the folders it sits in — the same rule chrome.bookmarks.search
    /// keeps (see ExtensionShims.swift).
    func matches(_ text: String) -> [(node: Bookmark, path: [String])] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func walk(_ nodes: [Bookmark], _ path: [String]) -> [(node: Bookmark, path: [String])] {
            nodes.flatMap { node -> [(node: Bookmark, path: [String])] in
                let hay = (node.title + " " + (node.url ?? "")).lowercased()
                let hit = words.allSatisfy { hay.contains($0) } ? [(node: node, path: path)] : []
                return hit + walk(node.children ?? [], path + [node.title])
            }
        }
        return walk(roots, [])
    }

    /// The folders `id` sits in, outermost first; empty at the top level,
    /// nil when it isn't here at all.
    func path(to id: Bookmark.ID) -> [Bookmark]? {
        func walk(_ nodes: [Bookmark], _ above: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == id { return above }
                if let kids = node.children, let found = walk(kids, above + [node]) { return found }
            }
            return nil
        }
        return walk(roots, [])
    }

    /// The folder `id` sits in, nil at the top level.
    func parent(of id: Bookmark.ID) -> Bookmark.ID? {
        path(to: id)?.last?.id
    }

    /// The one kept for this address, wherever it is filed.
    func bookmark(for url: URL) -> Bookmark? {
        func walk(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if node.url == url.absoluteString { return node }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots)
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked first: the title
    /// is the page's, and the card that opens after (see BookmarkCard) is
    /// where it gets another name or a folder.
    @discardableResult
    func add(_ url: URL, title: String) -> Bookmark? {
        guard !contains(url) else { return nil }
        let made = Bookmark.site(title, url)
        roots.append(made)
        save()
        return made
    }

    func contains(_ url: URL) -> Bool {
        kept.contains(url.absoluteString)
    }

    func remove(_ id: Bookmark.ID) {
        roots = Bookmarks.prune(id, from: roots)
        save()
    }

    private static func prune(_ id: Bookmark.ID, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            if node.id == id { return nil }
            var copy = node
            if let kids = node.children { copy.children = prune(id, from: kids) }
            return copy
        }
    }

    /// Takes a bookmark or a whole folder out of wherever it currently sits
    /// and puts it in another folder — or at the top level when `folderID`
    /// is nil — at `index` among what is there, or at the end. The index is
    /// counted as the list reads before the move, so dropping a row just
    /// below itself leaves it where it was. Moving a folder into its own
    /// children is refused rather than allowed to erase it by looping it
    /// inside itself; moving it onto itself is simply nothing to do.
    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?, at index: Int? = nil) {
        guard id != folderID else { return }
        var index = index
        if let at = index, let from = siblings(of: folderID).firstIndex(where: { $0.id == id }), from < at {
            // It leaves a gap above the place it goes to.
            index = at - 1
        }
        var working = roots
        guard let node = Bookmarks.detach(id, from: &working) else { return }
        if let folderID, Bookmarks.holds(folderID, node) { return }
        guard Bookmarks.place(node, in: folderID, at: index, nodes: &working) else { return }
        roots = working
        save()
    }

    /// What a folder holds, or the top level for nil.
    private func siblings(of folderID: Bookmark.ID?) -> [Bookmark] {
        guard let folderID else { return roots }
        func walk(_ nodes: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == folderID { return node.children ?? [] }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots) ?? []
    }

    private static func detach(_ id: Bookmark.ID, from nodes: inout [Bookmark]) -> Bookmark? {
        for i in nodes.indices {
            if nodes[i].id == id { return nodes.remove(at: i) }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if let found = detach(id, from: &kids) {
                nodes[i].children = kids
                return found
            }
        }
        return nil
    }

    /// `node` into the folder `id` (the top level for nil) at `index`,
    /// clamped to what is there, or at the end. False when there is no such
    /// folder.
    @discardableResult
    private static func place(_ node: Bookmark, in id: Bookmark.ID?, at index: Int?, nodes: inout [Bookmark]) -> Bool {
        guard let id else {
            nodes.insert(node, at: min(max(index ?? nodes.count, 0), nodes.count))
            return true
        }
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                var kids = nodes[i].children ?? []
                kids.insert(node, at: min(max(index ?? kids.count, 0), kids.count))
                nodes[i].children = kids
                return true
            }
            guard var kids = nodes[i].children else { continue }
            if place(node, in: id, at: index, nodes: &kids) {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// `id` is `node` itself, or somewhere inside it — also used by the
    /// outline to keep a folder out of its own "move to" list.
    fileprivate static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// Another browser's, kept apart in a folder of that browser's name
    /// unless there was nothing here yet.
    func take(_ nodes: [Bookmark], from name: String) {
        guard !nodes.isEmpty else { return }
        if roots.isEmpty {
            roots = nodes
        } else {
            roots.removeAll { $0.isFolder && $0.title == name }
            roots.append(.folder(name, nodes))
        }
        save()
    }

    // MARK: - the file

    private static var file: URL { Store.file("bookmarks.json") }

    // MARK: - for extensions

    /// A page or a folder filed under `parent` at `index`, or at the top
    /// level for nil or a folder that isn't there. What
    /// chrome.bookmarks.create does, and New Folder.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?, at index: Int? = nil) -> Bookmark {
        var nodes = roots
        if !Bookmarks.place(node, in: parent, at: index, nodes: &nodes) {
            Bookmarks.place(node, in: nil, at: index, nodes: &nodes)
        }
        roots = nodes
        save()
        return node
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update.
    func update(_ id: Bookmark.ID, title: String?, url: String?) {
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    if let title { nodes[i].title = title }
                    if let url, !nodes[i].isFolder { nodes[i].url = url }
                    return true
                }
                guard var kids = nodes[i].children else { continue }
                if walk(&kids) {
                    nodes[i].children = kids
                    return true
                }
            }
            return false
        }
        var nodes = roots
        if walk(&nodes) {
            roots = nodes
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Bookmarks.file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(Bookmarks.file)
            return
        }
        roots = list
    }

    private func save() {
        let snapshot = roots
        let file = Bookmarks.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

// MARK: - the tree, drawn

/// The list itself: folders that open in place rather than to the side, each
/// row draggable above or below another, or into a folder, each row good
/// for a right-click too, and renamed where it stands. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way.
struct BookmarkOutline: View {
    @ObservedObject var bookmarks: Bookmarks
    /// The folders open, kept by whoever shows the outline, so the manager
    /// can open the way down to one it was asked to show.
    @Binding var expanded: Set<Bookmark.ID>
    /// The row being renamed, its title a field in place; nil again when
    /// Escape puts the old name back, and nothing typed is kept then.
    @Binding var editing: Bookmark.ID?
    let open: (URL) -> Void

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
            // an open folder at the bottom can't reach.
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int, parent: Bookmark.ID?) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            let isOpen = node.isFolder && expanded.contains(node.id)
            Row(
                node: node,
                depth: depth,
                open: node.isFolder ? nil : { node.url.flatMap(URL.init(string:)).map(open) },
                isOpen: isOpen,
                dragging: dragging == node.id,
                aim: aimed?.id == node.id ? aimed?.zone : nil,
                editing: editing == node.id,
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                edit: { editing = node.id },
                save: { title, address in save(node, title: title, address: address) },
                newFolder: node.isFolder ? { newFolder(in: node.id) } : nil,
                moveTargets: Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) },
                moveTo: { bookmarks.move(node.id, into: $0) },
                remove: { remove(node) }
            )
            .id(node.id)
            .onDrag {
                dragging = node.id
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
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, indent(depth + 1) + 26)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    private func toggle(_ id: Bookmark.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// A name left empty, or an address that isn't one, keeps what was there.
    private func save(_ node: Bookmark, title: String, address: String?) {
        guard editing == node.id else { return }
        editing = nil
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = address.flatMap(Address.url(from:))?.absoluteString
        bookmarks.update(node.id, title: title.isEmpty || title == node.title ? nil : title,
                         url: url == node.url ? nil : url)
    }

    private func newFolder(in parent: Bookmark.ID) {
        let made = bookmarks.insert(.folder("New Folder", []), into: parent)
        expanded.insert(parent)
        editing = made.id
    }

    /// A folder with bookmarks in it asks first: they all go with it, and
    /// there is no taking it back.
    private func remove(_ node: Bookmark) {
        guard node.isFolder, let kids = node.children, !kids.isEmpty else {
            bookmarks.remove(node.id)
            return
        }
        let count = Bookmarks.count(kids)
        let detail = switch count {
        case 0: "The empty folders in it go too."
        case 1: "The bookmark in it goes too."
        default: "The \(count) bookmarks in it go too."
        }
        Ask.sure("Remove \u{201C}\(node.title)\u{201D}?", detail: detail, confirm: "Remove") {
            bookmarks.remove(node.id)
        }
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

    /// A click anywhere else keeps the name being typed. AppKit leaves a
    /// field its keyboard when the click lands on nothing that takes one,
    /// so the field is let go of here, and that keeps it (see Editor).
    static func settle() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

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
        let depth: Int
        /// Nil for a folder — folders open in place, not out to a page.
        let open: (() -> Void)?
        let isOpen: Bool
        let dragging: Bool
        /// Where a drag over this row would land, if one is.
        let aim: Zone?
        let editing: Bool
        let toggle: (() -> Void)?
        let edit: () -> Void
        let save: (String, String?) -> Void
        /// Nil for a site.
        let newFolder: (() -> Void)?
        let moveTargets: [(node: Bookmark, depth: Int)]
        let moveTo: (Bookmark.ID?) -> Void
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
                    Mark(icon: nil, letter: "", size: 15)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        )
                } else {
                    Spacer().frame(width: 10)
                    Mark(icon: Favicons.shared.cached(node.host ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 15)
                }
                if editing {
                    Editor(node: node, save: save)
                } else {
                    Text(node.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !editing, node.isFolder, let kids = node.children, !kids.isEmpty {
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
            .onTapGesture {
                guard !editing else { return }
                BookmarkOutline.settle()
                open?() ?? toggle?()
            }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open {
                    Button("Open", action: open)
                    Divider()
                }
                Button(node.isFolder ? "Rename" : "Edit\u{2026}", action: edit)
                if let newFolder {
                    Button("New Folder Inside", action: newFolder)
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
        }

        private var wash: Color {
            if aim == .into { return Palette.hover }
            return hovering || editing ? Palette.wash : .clear
        }
    }

    /// A row's title as a field, and a site's address under it. Return, or
    /// clicking anywhere else, keeps what was typed; Escape doesn't.
    private struct Editor: View {
        let node: Bookmark
        let save: (String, String?) -> Void

        @State private var title = ""
        @State private var address = ""
        @State private var done = false
        @FocusState private var focus: Field?

        enum Field { case title, address }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                field($title, .title, size: 12.5, tint: Palette.ink)
                if !node.isFolder {
                    field($address, .address, size: 11.5, tint: Palette.muted)
                }
            }
            .onAppear {
                title = node.title
                address = node.url ?? ""
                focus = .title
            }
            // Tab from the name to the address lets go of one before the
            // other takes the keyboard; only a field still let go of a turn
            // later has been left.
            .onChange(of: focus) { _, now in
                guard now == nil else { return }
                DispatchQueue.main.async { if focus == nil { keep() } }
            }
            // The list closing under it keeps what was typed too.
            .onDisappear(perform: keep)
        }

        private func field(_ text: Binding<String>, _ which: Field, size: CGFloat, tint: Color) -> some View {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .focused($focus, equals: which)
                .onSubmit(keep)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }

        private func keep() {
            guard !done else { return }
            done = true
            save(title, node.isFolder ? nil : address)
        }
    }
}

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var expanded: Set<Bookmark.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks, expanded: $expanded, editing: $browser.editingBookmark) { url in
                        browser.pickBookmark(url)
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("bookmark", "Add This Page") { browser.bookmarkCurrent() }
                Foot(nil, "Manage Bookmarks…") { browser.bookmarking = true }
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
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

/// The full list, for taking things out of it or bringing more in.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var expanded: Set<Bookmark.ID> = []

    var body: some View {
        Plate("Bookmarks", width: 600, close: { browser.bookmarking = false }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Pill("New Folder", action: newFolder)
                }

                if bookmarks.isEmpty {
                    Card { Nothing("Nothing kept yet. Add this page with ⇧⌘B, make a folder for what comes, or bring yours in below.") }
                } else {
                    ScrollViewReader { scroller in
                        ScrollView(showsIndicators: false) {
                            Card {
                                BookmarkOutline(bookmarks: bookmarks, expanded: $expanded, editing: $browser.editingBookmark) { url in
                                    browser.pickBookmark(url)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                            }
                            .padding(.bottom, 2)
                        }
                        .frame(maxHeight: 440)
                        // A folder just made is named where it lands, which
                        // may be below what shows.
                        .onChange(of: browser.editingBookmark) { _, id in
                            guard let id else { return }
                            withAnimation(Motion.settle) { scroller.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: BookmarkOutline.settle)
        } foot: {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                ForEach(Chromium.installed()) { source in
                    Pill(source.name) { browser.takeBookmarks(from: source) }
                }
                Spacer()
                Text(bookmarks.count == 1 ? "1 bookmark" : "\(bookmarks.count) bookmarks")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// At the end of the top level, named as it appears.
    private func newFolder() {
        browser.editingBookmark = bookmarks.insert(.folder("New Folder", []), into: nil).id
    }
}

/// The bookmarks in the menu bar's Bookmarks menu, made by AppKit rather
/// than SwiftUI. SwiftUI makes a menu bar's items all at once, folders
/// and all, before the app has finished launching: 1,500 bookmarks, as a
/// Chrome import brings, held the window back by 230 ms at every launch.
/// Here the top of the list is made as the menu opens, and a folder's
/// items as that folder opens.
///
/// SwiftUI keeps its own two items, and its own delegate, which lays the
/// menu out afresh each time it opens — anything added beside them was
/// gone by then. So its delegate is wrapped: SwiftUI does its update,
/// then the bookmarks go in after it. SwiftUI puts its delegate back on
/// every update, so the wrapping is put back too (see `start`).
@MainActor
final class BookmarkMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarkMenu()

    private weak var browser: Browser?
    private var watch: [Any] = []
    private let relay = Relay()
    /// What each folder's submenu holds, until it opens.
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]
    /// The items put in here, among SwiftUI's own.
    fileprivate static let mark = 0x5EAC

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        relay.after = { [weak self] menu in self?.fill(menu) }
        // SwiftUI puts its own delegate back whenever it updates the menu
        // bar, which is whenever anything in the window changes. So: after
        // each event, and as the menu bar starts to be used, before any of
        // its menus opens.
        let centre = NotificationCenter.default
        watch = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrap() }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.wrap()
                }
            },
        ]
        wrap()
    }

    private func wrap() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu,
              menu.delegate !== relay
        else { return }
        relay.inner = menu.delegate
        menu.delegate = relay
    }

    /// How many items this has put in the menu, for the bench.
    var count: Int {
        NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu?.items.filter { $0.tag == Self.mark }.count ?? 0
    }

    /// The top of the list, after SwiftUI's items, in place of any left
    /// from the last time.
    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.mark { menu.removeItem(item) }
        folders = [:]
        guard let roots = browser?.bookmarks.roots, !roots.isEmpty else { return }
        let line = NSMenuItem.separator()
        line.tag = Self.mark
        menu.addItem(line)
        for item in items(for: roots) { menu.addItem(item) }
    }

    /// A folder of the bookmarks bar, opened as a menu at the pointer: the
    /// same items as the menu bar's, folders opening as they are reached.
    func popUp(_ folder: Bookmark) {
        let menu = NSMenu(title: folder.title)
        let made = items(for: folder.children ?? [])
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func items(for nodes: [Bookmark]) -> [NSMenuItem] {
        nodes.compactMap { node in
            let item: NSMenuItem
            if node.isFolder {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: node.title)
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
            } else if let text = node.url, let url = URL(string: text) {
                item = NSMenuItem(title: node.title, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
            } else {
                return nil
            }
            item.tag = Self.mark
            return item
        }
    }

    /// A folder, opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        let made = items(for: kids)
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        browser?.visit(url)
    }

    /// SwiftUI's delegate, with the bookmarks put in after its update.
    /// Everything else it answers goes straight to it.
    private final class Relay: NSObject, NSMenuDelegate {
        weak var inner: NSMenuDelegate?
        var after: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            inner?.menuNeedsUpdate?(menu)
            MainActor.assumeIsolated { after?(menu) }
        }

        func menuDidClose(_ menu: NSMenu) { inner?.menuDidClose?(menu) }

        /// Only for its own items: the bookmarks aren't SwiftUI's to know.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard item?.tag != BookmarkMenu.mark else { return }
            inner?.menu?(menu, willHighlight: item)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }
    }
}
