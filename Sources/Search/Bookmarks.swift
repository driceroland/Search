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
    @Published private(set) var roots: [Bookmark] = []

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

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked: the title is the
    /// page's, and filing it into a folder is a drag or a right-click away.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        roots.append(.site(title, url))
        save()
    }

    func contains(_ url: URL) -> Bool {
        func walk(_ nodes: [Bookmark]) -> Bool {
            nodes.contains { $0.url == url.absoluteString || walk($0.children ?? []) }
        }
        return walk(roots)
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
    /// and puts it at the end of another folder's children — or back at the
    /// top level when `folderID` is nil. Moving a folder into its own
    /// children is refused rather than allowed to erase it by looping it
    /// inside itself; moving it onto itself is simply nothing to do.
    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?) {
        guard id != folderID else { return }
        var working = roots
        guard let node = Bookmarks.detach(id, from: &working) else { return }
        if let folderID {
            guard !Bookmarks.holds(folderID, node) else { return }
            guard Bookmarks.insert(node, into: folderID, nodes: &working) else { return }
        } else {
            working.append(node)
        }
        roots = working
        save()
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

    @discardableResult
    private static func insert(_ node: Bookmark, into id: Bookmark.ID, nodes: inout [Bookmark]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                nodes[i].children = (nodes[i].children ?? []) + [node]
                return true
            }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if insert(node, into: id, nodes: &kids) {
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

    /// A page or a folder filed under `parent`, or at the top level for nil
    /// or a folder that isn't there. What chrome.bookmarks.create does.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?) -> Bookmark {
        if let parent {
            var nodes = roots
            if Bookmarks.insert(node, into: parent, nodes: &nodes) {
                roots = nodes
                save()
                return node
            }
        }
        roots.append(node)
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
/// row draggable into another folder or back out to the top, each row good
/// for a right-click too. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way.
struct BookmarkOutline: View {
    @ObservedObject var bookmarks: Bookmarks
    let open: (URL) -> Void

    @State private var expanded: Set<Bookmark.ID> = []
    @State private var dragging: Bookmark.ID?
    @State private var overRoot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows(bookmarks.roots, depth: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(overRoot ? Palette.wash : .clear)
        .onDrop(of: [.text], isTargeted: $overRoot) { providers in drop(providers, into: nil) }
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int) -> some View {
        ForEach(nodes) { node in
            Row(
                node: node,
                depth: depth,
                open: node.isFolder ? nil : { open(URL(string: node.url!)!) },
                isOpen: expanded.contains(node.id),
                dragging: dragging == node.id,
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                moveTargets: Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) },
                moveTo: { bookmarks.move(node.id, into: $0) },
                remove: { bookmarks.remove(node.id) }
            )
            .onDrag {
                dragging = node.id
                return NSItemProvider(object: node.id.uuidString as NSString)
            }
            .modifier(DropOnto(active: node.isFolder) { providers in drop(providers, into: node.id) })

            if node.isFolder, expanded.contains(node.id) {
                if let kids = node.children, !kids.isEmpty {
                    // Type-erased: a view that calls itself can't let Swift
                    // infer its own opaque return type from its own body.
                    AnyView(rows(kids, depth: depth + 1))
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

    private func drop(_ providers: [NSItemProvider], into folderID: Bookmark.ID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                self.bookmarks.move(id, into: folderID)
                self.dragging = nil
            }
        }
        return true
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    /// Lets a row's own onDrop only run for folders — a bookmark isn't a
    /// place to file something else into — while every row still fires the
    /// same one onDrag above.
    private struct DropOnto: ViewModifier {
        let active: Bool
        let action: ([NSItemProvider]) -> Bool
        @State private var targeted = false

        func body(content: Content) -> some View {
            if active {
                content
                    .background(targeted ? Palette.hover : .clear)
                    .onDrop(of: [.text], isTargeted: $targeted, perform: action)
            } else {
                content
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
        let toggle: (() -> Void)?
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
                Text(node.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .opacity(dragging ? 0.35 : 1)
            .onTapGesture { open?() ?? toggle?() }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open {
                    Button("Open", action: open)
                    Divider()
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
        }
    }
}

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks) { url in
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

    var body: some View {
        Plate("Bookmarks", width: 600, close: { browser.bookmarking = false }) {
            if bookmarks.isEmpty {
                Card { Nothing("Nothing kept yet. Add this page with ⇧⌘B, or bring yours in below.") }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        BookmarkOutline(bookmarks: bookmarks) { url in
                            browser.pickBookmark(url)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 440)
            }
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
