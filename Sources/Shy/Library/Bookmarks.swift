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

    /// A bookmark whose name was emptied, as in Chrome and Safari: on the
    /// bar it is its icon alone. There is no setting; emptying it is the
    /// choice. A folder always has a name.
    var unnamed: Bool {
        !isFolder && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a list reads it as: its name, or for one without, its address
    /// as the address field shows it, so the list is still readable.
    var label: String {
        guard unnamed else { return title }
        return url.flatMap { URL(string: $0) }.map(Address.pretty) ?? url ?? ""
    }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    var address: URL? {
        url.flatMap { URL(string: $0) }
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
        didSet {
            revision &+= 1
            kept = preparedKept ?? Set(Bookmarks.urls(roots).map(\.absoluteString))
            preparedKept = nil
        }
    }
    private var revision = 0
    private var preparedKept: Set<String>?

    /// Every address kept, for `contains` — asked on every redraw of the
    /// button, which fills in on a page that is kept.
    private var kept: Set<String> = []

    /// Its file: bookmarks.json for Personal, one of its own for each other
    /// profile (see Profiles.swift).
    private let fileName: String
    /// Its profile deleted: nothing more is written.
    private var retired = false

    /// The profile it is (see Profiles.swift): what shows it shows that
    /// profile's icons.
    let profile: UUID

    init(file: String = "bookmarks.json", profile: UUID = Profile.personalID) {
        fileName = file
        self.profile = profile
        load()
    }

    /// Its profile deleted: its file removed, and nothing written again.
    func retire() {
        retired = true
        Disk.remove(file)
    }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    nonisolated static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    nonisolated static func urls(_ nodes: [Bookmark]) -> [URL] {
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
        first { $0.url == url.absoluteString }
    }

    func bookmark(_ id: Bookmark.ID) -> Bookmark? {
        first { $0.id == id }
    }

    private func first(where test: (Bookmark) -> Bool) -> Bookmark? {
        func walk(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if test(node) { return node }
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
    static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// Prepare a potentially large file merge away from the UI thread. A live
    /// edit wins: if bookmarks changed while preparing, merge a fresh snapshot.
    func takeFile(_ incoming: [Bookmark], from name: String, control: ImportFile.Control) async throws -> (added: Int, already: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        while true {
            try control.checkCancellation()
            let snapshot = roots
            let version = revision
            let top = Store.settings.string(forKey: Bookmarks.topKey)
            let prepared: (roots: [Bookmark], kept: Set<String>, added: Int, already: Int, top: Bool) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try control.checkCancellation()
                        var output = snapshot
                        var added = 0, already = 0
                        var setTop = false
                        if snapshot.isEmpty {
                            output = incoming
                            added = try Bookmarks.fileCount(incoming, control: control)
                            setTop = true
                        } else {
                            let intoTop: Bool
                            if let top { intoTop = top == name }
                            else {
                                let theirs = try Bookmarks.fileURLs(incoming, control: control)
                                let ours = Set(try Bookmarks.fileURLs(snapshot, control: control))
                                intoTop = !theirs.isEmpty && theirs.filter { ours.contains($0) }.count * 2 >= theirs.count
                                setTop = intoTop
                            }
                            if intoTop {
                                try Bookmarks.mergeFile(incoming, into: &output, added: &added, already: &already, control: control)
                            } else {
                                var kids = output.first { $0.isFolder && $0.title == name }?.children ?? []
                                try Bookmarks.mergeFile(incoming, into: &kids, added: &added, already: &already, control: control)
                                if let at = output.firstIndex(where: { $0.isFolder && $0.title == name }) {
                                    output[at].children = kids
                                } else {
                                    output.append(.folder(name, kids))
                                }
                            }
                        }
                        try control.checkCancellation()
                        continuation.resume(returning: (output, Set(try Bookmarks.fileURLs(output, control: control)), added, already, setTop))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try control.checkCancellation()
            guard revision == version, Store.settings.string(forKey: Bookmarks.topKey) == top else { continue }
            preparedKept = prepared.kept
            roots = prepared.roots
            if prepared.top { Store.settings.set(name, forKey: Bookmarks.topKey) }
            save()
            return (prepared.added, prepared.already)
        }
    }

    nonisolated private static func fileURLs(_ nodes: [Bookmark], control: ImportFile.Control) throws -> [String] {
        var urls: [String] = []
        var pending = nodes
        var scanned = 0
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 {
                try control.checkCancellation()
            }
            if let url = node.url, let canonical = URL(string: url)?.absoluteString { urls.append(canonical) }
            if let children = node.children { pending.append(contentsOf: children) }
        }
        try control.checkCancellation()
        return urls
    }

    nonisolated private static func fileCount(_ nodes: [Bookmark], control: ImportFile.Control) throws -> Int {
        var count = 0
        var scanned = 0
        var pending = nodes
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { pending.append(contentsOf: node.children ?? []) }
            else { count += 1 }
        }
        try control.checkCancellation()
        return count
    }

    nonisolated private static func mergeFile(_ incoming: [Bookmark], into nodes: inout [Bookmark], added: inout Int, already: inout Int, control: ImportFile.Control) throws {
        var folders: [String: Int] = [:]
        var pages = Set<String>()
        for (index, node) in nodes.enumerated() {
            if index % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { if folders[node.title] == nil { folders[node.title] = index } }
            else if let url = node.url { pages.insert(url) }
        }
        for (index, node) in incoming.enumerated() {
            if index % 256 == 0 {
                try control.checkCancellation()
            }
            if node.isFolder {
                if let at = folders[node.title] {
                    var kids = nodes[at].children ?? []
                    try mergeFile(node.children ?? [], into: &kids, added: &added, already: &already, control: control)
                    nodes[at].children = kids
                } else {
                    folders[node.title] = nodes.count
                    nodes.append(node)
                    added += try Bookmarks.fileCount([node], control: control)
                }
            } else if pages.contains(node.url ?? "") {
                already += 1
            } else {
                if let url = node.url { pages.insert(url) }
                nodes.append(node)
                added += 1
            }
        }
    }

    /// Which browser filled the empty top level, the first time.
    private static let topKey = "bookmarks.top"

    // MARK: - the file

    private var file: URL { Store.file(fileName) }

    // MARK: - for extensions

    /// A page or a folder filed under `parent` at `index`, or at the top
    /// level for nil or a folder that isn't there. What
    /// chrome.bookmarks.create does.
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

    /// A folder of your own, its name asked for as a rename's is: inside
    /// `parent`, or at the top level for nil. An empty name makes none.
    func askNewFolder(in parent: Bookmark.ID?, made: @escaping (Bookmark.ID) -> Void = { _ in }) {
        Ask.name("New Folder", placeholder: "Folder name", confirm: "Make") { name in
            made(self.insert(.folder(name, []), into: parent).id)
        }
    }

    /// A folder with bookmarks in it asks first: they all go with it, and
    /// there is no taking it back. Anything else goes at once.
    func askRemove(_ node: Bookmark) {
        guard node.isFolder, let kids = node.children, !kids.isEmpty else { return remove(node.id) }
        let count = Bookmarks.count(kids)
        let detail = switch count {
        case 0: "The empty folders in it go too."
        case 1: "The bookmark in it goes too."
        default: "The \(count) bookmarks in it go too."
        }
        Ask.sure("Remove \u{201C}\(node.title)\u{201D}?", detail: detail, confirm: "Remove") {
            self.remove(node.id)
        }
    }

    /// A name of your own for a bookmark or a folder, asked for the way a
    /// space's is: the page's title is what a bookmark starts with, and a
    /// folder brought in from another browser is called after it. The name
    /// it has arrives in the field. An empty one changes nothing for a
    /// folder; a bookmark left without one is its icon alone on the bar.
    func askRename(_ node: Bookmark) {
        if node.isFolder {
            Ask.name("Rename Folder", placeholder: node.title, initial: node.title, confirm: "Rename") {
                self.update(node.id, title: $0, url: nil)
            }
        } else {
            Ask.name("Rename Bookmark", detail: "Without a name, the bookmarks bar shows its icon alone.",
                     placeholder: node.label, initial: node.title, confirm: "Rename", empty: true) {
                self.update(node.id, title: $0, url: nil)
            }
        }
    }

    /// A bookmark's address, changed by hand and read the way the address
    /// field reads what is typed. What that refuses, a bookmarklet or a
    /// word, isn't saved: the question comes back with it in the field and a
    /// line on why, and Cancel keeps the address the bookmark had.
    func askAddress(_ node: Bookmark, typed: String? = nil) {
        guard let current = node.url else { return }
        let detail = typed.map { "Shy can\u{2019}t open \u{201C}\($0)\u{201D} as a page. Cancel keeps the address the bookmark has." }
        Ask.name("Edit Address", detail: detail, placeholder: "https://example.com", initial: typed ?? current, confirm: "Save") { typed in
            guard let url = Address.url(from: typed) else {
                DispatchQueue.main.async { self.askAddress(node, typed: typed) }
                return
            }
            self.update(node.id, title: nil, url: url.absoluteString)
        }
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update,
    /// and Rename… in the list's right-click menu.
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
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(file)
            return
        }
        roots = list
    }

    private func save() {
        guard !retired else { return }
        let snapshot = roots
        // One after another, the newest last (see Disk).
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}
