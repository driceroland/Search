import AppKit
import UniformTypeIdentifiers

// Every space saved to a file: File › Export Spaces… and Settings › Bring
// Things Over. Two kinds of file.
//
//  - A bookmarks page (.html), the Netscape format every browser imports
//    (see BookmarksFile.swift): a folder per space, in each profile's order,
//    holding its pins — its folders of rows nested as they are — then its
//    open tabs in a folder of their own, their tab groups as folders in it.
//    The pins every space shows go in a folder of their own, first.
//  - Search's own (.json): the same and what a bookmarks page can't hold —
//    each space's colour, icon and gradient, which pins are rows and which
//    are squares, its profile. File… in Bring Things Over reads it back
//    (see SpacesExport.sidebar and Browser.takeArc).
//
// Nothing secret is in either: addresses and names, no cookies, no
// passwords, no history.

enum SpacesExport {
    /// What the .json says it is, to be told from any other JSON file.
    static let format = "search-spaces"
    static let version = 1

    struct Bundle: Codable, Equatable {
        var format = SpacesExport.format
        var version = SpacesExport.version
        var exported: Date = Date()
        var profiles: [Profile]
    }

    struct Profile: Codable, Equatable {
        var name: String
        /// The pins every space of the profile shows.
        var everySpace: [Pin] = []
        var spaces: [Space]
    }

    struct Space: Codable, Equatable {
        var name: String
        var colour: Int = 0
        var icon: String?
        var gradient: SpaceGradient?
        var pins: [Pin] = []
        var folders: [Folder] = []
        var tabs: [Tab] = []
        var groups: [Group] = []
    }

    struct Pin: Codable, Equatable {
        var title: String
        var url: String
        /// A row under the pins, rather than a square.
        var listed: Bool = false
        /// The folder of rows it is in (Folder.id).
        var folder: String?
    }

    struct Folder: Codable, Equatable {
        var id: String
        var name: String
        var parent: String?
        /// A live folder's feed, and its posts as last fetched.
        var feed: String?
        var items: [Link]?
    }

    struct Link: Codable, Equatable {
        var title: String
        var url: String
    }

    struct Tab: Codable, Equatable {
        var title: String
        var url: String
        /// Its tab group (Group.id).
        var group: String?
    }

    struct Group: Codable, Equatable {
        var id: String
        var name: String
    }

    // MARK: - gathering

    /// Every profile's spaces as they are now, every window's tabs written
    /// first so the rows read are the ones on screen.
    @MainActor
    static func gather() -> Bundle {
        for browser in Browsers.all where !browser.isPopup { browser.writeSession(now: true) }
        // Each window's rows; a space no window holds, from its session file.
        var rows: [String: Session.Shape] = [:]
        for browser in Browsers.all where !browser.isPopup {
            for (space, row) in browser.allRows() where rows[space] == nil { rows[space] = row }
        }
        let profiles = Profiles.shared.list.map { profile in
            Profile(name: profile.name,
                    everySpace: Pins.shared(profile.id).map(pin),
                    spaces: Spaces.read(profile: profile.id).map { space in
                        gather(space, row: rows[space.id.uuidString] ?? Session.read(space: space.id))
                    })
        }
        return Bundle(profiles: profiles.filter { !$0.spaces.isEmpty || !$0.everySpace.isEmpty })
    }

    @MainActor
    static func gather(_ space: SearchSpace, row: Session.Shape) -> Space {
        let folders = PinFolders.folders(space.id).map { folder in
            Folder(id: folder.id.uuidString, name: folder.name, parent: folder.parent?.uuidString,
                   feed: folder.feed?.absoluteString,
                   items: folder.feed == nil ? nil : (folder.items ?? []).map { Link(title: $0.title, url: $0.link.absoluteString) })
        }
        let known = Set(folders.map(\.id))
        let pins = Pins.defs(space.id).map { def -> Pin in
            var out = pin(def)
            if let folder = def.folder?.uuidString, known.contains(folder) { out.folder = folder }
            return out
        }
        let groups = (row.groups ?? []).map { Group(id: $0.id.uuidString, name: $0.name) }
        let grouped = Set(groups.map(\.id))
        let tabs = row.tabs.compactMap { entry -> Tab? in
            guard entry.pin == nil, kept(entry.url) else { return nil }
            let group = entry.groupID?.uuidString
            return Tab(title: entry.name ?? entry.title, url: entry.url, group: group.flatMap { grouped.contains($0) ? $0 : nil })
        }
        let used = Set(tabs.compactMap(\.group))
        return Space(name: space.name, colour: space.colour, icon: space.icon, gradient: space.gradient,
                     pins: pins, folders: folders, tabs: tabs, groups: groups.filter { used.contains($0.id) })
    }

    private static func pin(_ def: PinDef) -> Pin {
        let name = def.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Pin(title: name.flatMap { $0.isEmpty ? nil : $0 } ?? def.title, url: def.home, listed: def.listed == true)
    }

    /// An address worth a bookmark: one with a scheme, not an empty tab.
    private static func kept(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return !["about", "javascript", "data", "blob"].contains(scheme)
    }

    // MARK: - the bookmarks page

    /// The Netscape bookmarks page: a folder per space, the shared pins in
    /// one of their own before them.
    static func html(_ bundle: Bundle) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Spaces</H1>
        <DL><p>

        """
        let several = bundle.profiles.count > 1
        func line(_ depth: Int, _ text: String) { out += String(repeating: "    ", count: depth) + text + "\n" }
        func link(_ depth: Int, _ title: String, _ url: String) {
            line(depth, "<DT><A HREF=\"\(escape(url))\">\(escape(title.isEmpty ? url : title))</A>")
        }
        func folder(_ depth: Int, _ name: String, _ body: () -> Void) {
            line(depth, "<DT><H3>\(escape(name))</H3>")
            line(depth, "<DL><p>")
            body()
            line(depth, "</DL><p>")
        }
        for profile in bundle.profiles where !profile.everySpace.isEmpty {
            folder(1, several ? "Every Space (\(profile.name))" : "Every Space") {
                for pin in profile.everySpace { link(2, pin.title, pin.url) }
            }
        }
        for profile in bundle.profiles {
            for space in profile.spaces {
                folder(1, space.name) {
                    // The squares first, as they sit above the rows.
                    for pin in space.pins where !pin.listed { link(2, pin.title, pin.url) }
                    // The rows, folders first in each as they are drawn.
                    func rows(in parent: String?, depth: Int, seen: Set<String>) {
                        for inner in space.folders where inner.parent == parent && !seen.contains(inner.id) {
                            folder(depth, inner.name) {
                                rows(in: inner.id, depth: depth + 1, seen: seen.union([inner.id]))
                                for item in inner.items ?? [] { link(depth + 1, item.title, item.url) }
                            }
                        }
                        for pin in space.pins where pin.listed && pin.folder == parent { link(depth, pin.title, pin.url) }
                    }
                    let known = Set(space.folders.map(\.id))
                    // A folder whose parent is gone sits at the top, as PinTree has it.
                    let tops = space.folders.filter { $0.parent.map { !known.contains($0) } ?? true }
                    for top in tops {
                        folder(2, top.name) {
                            rows(in: top.id, depth: 3, seen: [top.id])
                            for item in top.items ?? [] { link(3, item.title, item.url) }
                        }
                    }
                    for pin in space.pins where pin.listed && (pin.folder.map { !known.contains($0) } ?? true) {
                        link(2, pin.title, pin.url)
                    }
                    if !space.tabs.isEmpty {
                        folder(2, "Open Tabs") {
                            for group in space.groups {
                                folder(3, group.name) {
                                    for tab in space.tabs where tab.group == group.id { link(4, tab.title, tab.url) }
                                }
                            }
                            for tab in space.tabs where tab.group == nil { link(3, tab.title, tab.url) }
                        }
                    }
                }
            }
        }
        out += "</DL><p>\n"
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Search's own file

    static func json(_ bundle: Bundle) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(bundle)) ?? Data()
    }

    /// A Search spaces file, or nil for any other JSON.
    static func bundle(_ data: Data) -> Bundle? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(Bundle.self, from: data), bundle.format == format else { return nil }
        return bundle
    }

    /// The file read back, in the shape every spaces import takes (see
    /// Browser.takeArc): the first profile's spaces into this window's
    /// profile, another's into the profile of its name; each space's
    /// squares its own pins, its rows and folders its pinned list, its
    /// open tabs asleep in it; the pins every space showed shared again.
    static func sidebar(_ bundle: Bundle) -> ArcSidebar {
        var spaces: [ArcSidebar.Space] = []
        var names: [String: String] = [:]
        var everySpace: [ArcSidebar.Item] = []
        for (index, profile) in bundle.profiles.enumerated() {
            let key = index == 0 ? "Default" : "Profile \(index)"
            names[key] = profile.name
            let shared = profile.everySpace.compactMap(item)
            if index == 0 { everySpace = shared }
            for space in profile.spaces {
                var made = ArcSidebar.Space(
                    name: space.name, emoji: nil,
                    symbol: space.icon.flatMap { Spaces.icons.contains($0) ? $0 : nil } ?? Arc.symbol(emoji: nil, name: space.name),
                    profile: key, pinned: tree(space), colour: Spaces.colours.indices.contains(space.colour) ? space.colour : 0,
                    gradient: space.gradient)
                // Another profile's shared pins, as pins of each of its spaces.
                made.favorites = (index == 0 ? [] : shared) + space.pins.filter { !$0.listed }.compactMap(item)
                made.open = space.tabs.compactMap { tab in
                    item(tab.title, tab.url).map { ArcSidebar.Open(item: $0, group: space.groups.first { $0.id == tab.group }?.name) }
                }
                spaces.append(made)
            }
        }
        var sidebar = ArcSidebar(favorites: [], favoritesByProfile: [:], spaces: spaces)
        sidebar.profileNames = names
        sidebar.everySpace = everySpace
        return sidebar
    }

    /// A space's rows as a pinned list: folders first in each, then rows.
    private static func tree(_ space: Space) -> [ArcSidebar.Node] {
        let known = Set(space.folders.map(\.id))
        func nodes(in parent: String?, seen: Set<String>) -> [ArcSidebar.Node] {
            let folders = space.folders.filter { folder in
                !seen.contains(folder.id) && (parent == nil ? folder.parent.map { !known.contains($0) } ?? true : folder.parent == parent)
            }
            let inner: [ArcSidebar.Node] = folders.compactMap { folder in
                guard seen.count < 64 else { return nil }
                let items = nodes(in: folder.id, seen: seen.union([folder.id]))
                    + (folder.items ?? []).compactMap { item($0.title, $0.url) }.map(ArcSidebar.Node.item)
                return items.isEmpty ? nil : .folder(.init(title: folder.name, items: items))
            }
            let rows = space.pins.filter { pin in
                pin.listed && (parent == nil ? pin.folder.map { !known.contains($0) } ?? true : pin.folder == parent)
            }
            return inner + rows.compactMap(item).map(ArcSidebar.Node.item)
        }
        return nodes(in: nil, seen: [])
    }

    private static func item(_ pin: Pin) -> ArcSidebar.Item? { item(pin.title, pin.url) }

    private static func item(_ title: String, _ url: String) -> ArcSidebar.Item? {
        guard let page = Arc.page(url) else { return nil }
        return ArcSidebar.Item(title: Arc.named(title) ?? page.host() ?? url, url: page)
    }

    /// The size no spaces file comes near.
    static let limit = 32 << 20
}

typealias SearchSpace = Space

extension Browser {
    /// File › Export Spaces…: a bookmarks page any browser takes, or
    /// Search's own file, chosen in the save panel.
    func exportSpaces() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = downloadsFolder
        panel.nameFieldStringValue = "Search Spaces.html"
        panel.allowedContentTypes = [.html]
        panel.message = "Every space, with its pins, folders and open tabs."
        let kinds = NSPopUpButton(frame: .zero, pullsDown: false)
        kinds.addItems(withTitles: ["Bookmarks file (HTML) — for any browser", "Search spaces file (JSON) — keeps colours and icons"])
        let chooser = SpacesExportChooser(panel: panel)
        kinds.target = chooser
        kinds.action = #selector(SpacesExportChooser.chose(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, kinds])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            withExtendedLifetime(chooser) {}
            guard answer == .OK, let file = panel.url, let self else { return }
            let said = self.exportSpaces(to: file)
            self.announce(said, file: file)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    /// Writes the file, as .json when its name says so, else as a
    /// bookmarks page. Says what it wrote.
    @discardableResult
    func exportSpaces(to file: URL) -> String {
        let bundle = SpacesExport.gather()
        let data = file.pathExtension.lowercased() == "json"
            ? SpacesExport.json(bundle) : Data(SpacesExport.html(bundle).utf8)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return "Couldn't save the spaces: \(error.localizedDescription)"
        }
        let count = bundle.profiles.reduce(0) { $0 + $1.spaces.count }
        return count == 1 ? "1 space exported" : "\(count) spaces exported"
    }

    /// File… in Bring Things Over, given a Search spaces file: its spaces
    /// come in as another browser's do. Nil for any other file.
    func takeSpacesFile(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "json",
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= SpacesExport.limit,
              let data = try? Data(contentsOf: url), let bundle = SpacesExport.bundle(data)
        else { return nil }
        let (spaces, pins, tabs) = takeArc(SpacesExport.sidebar(bundle))
        func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
        return spaces + pins + tabs == 0 ? "Those spaces were all here already"
            : "\(count(spaces, "new space")), \(count(pins, "pin")), \(count(tabs, "tab"))"
    }
}

/// The save panel's format menu: the file's ending follows it.
@MainActor
final class SpacesExportChooser: NSObject {
    private weak var panel: NSSavePanel?

    init(panel: NSSavePanel) { self.panel = panel }

    @objc func chose(_ sender: NSPopUpButton) {
        guard let panel else { return }
        let json = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [json ? .json : .html]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = stem + (json ? ".json" : ".html")
    }
}
