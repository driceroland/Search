import AppKit
import SwiftUI

// The Sources panel's navigator, after Chrome's: tabs for Page, Content
// scripts and Snippets; Page a tree of frames ("top" first), then the
// origins each frame loaded from, then folders (single-child chains run
// together, "a/b/c"), then files, "(index)" for a folder's own document.

typealias SourceResource = DeveloperToolsSession.Resource

struct SourceTreeNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case frame
        case origin
        case folder
        case file(SourceResource)
    }

    var id: String
    var name: String
    var kind: Kind
    var children: [SourceTreeNode] = []

    var isFile: Bool { if case .file = kind { return true } else { return false } }
}

enum SourceTree {
    static func build(_ resources: [SourceResource], frames: [DeveloperToolsSession.ResourceFrame]) -> [SourceTreeNode] {
        var frames = frames
        // Without the frame tree (not read yet), each frame id the
        // resources name stands on its own, the first as top.
        if frames.isEmpty {
            var seen = Set<String>()
            for resource in resources where seen.insert(resource.frame).inserted {
                frames.append(.init(id: resource.frame, parent: frames.first?.id, url: "", name: ""))
            }
        }
        let byFrame = Dictionary(grouping: resources, by: \.frame)
        let known = Set(frames.map(\.id))

        func frameNode(_ frame: DeveloperToolsSession.ResourceFrame) -> SourceTreeNode {
            let name: String
            if frame.parent == nil || !known.contains(frame.parent!) {
                name = "top"
            } else if !frame.name.isEmpty {
                name = frame.name
            } else {
                let address = URL(string: frame.url)
                name = address.map { $0.lastPathComponent.isEmpty || $0.lastPathComponent == "/" ? ($0.host() ?? frame.url) : $0.lastPathComponent } ?? frame.url
            }
            var children = origins(byFrame[frame.id] ?? [], under: "f:" + frame.id)
            children += frames.filter { $0.parent == frame.id }.map(frameNode)
            return SourceTreeNode(id: "f:" + frame.id, name: name, kind: .frame, children: children)
        }
        return frames.filter { $0.parent == nil || !known.contains($0.parent!) }.map(frameNode)
    }

    /// Chrome's name for where a URL is from: its host (and port), or
    /// "(no domain)" for data:, blob: and the like.
    static func origin(of url: String) -> String {
        guard let address = URL(string: url), let host = address.host(), !host.isEmpty else { return "(no domain)" }
        return address.port.map { "\(host):\($0)" } ?? host
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [SourceResource] = []
    }

    private static func origins(_ resources: [SourceResource], under parent: String) -> [SourceTreeNode] {
        let grouped = Dictionary(grouping: resources) { origin(of: $0.url) }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let root = Folder()
            for resource in grouped[name]! {
                var folder = root
                for component in folders(of: resource.url) {
                    if let next = folder.folders[component] { folder = next } else {
                        let next = Folder()
                        folder.folders[component] = next
                        folder = next
                    }
                }
                folder.files.append(resource)
            }
            let id = parent + "|o:" + name
            return SourceTreeNode(id: id, name: name, kind: .origin, children: contents(root, id: id))
        }
    }

    /// Authored files from source maps, grouped as Chrome groups them under
    /// the top frame: by their own origin (webpack://app, a host), then
    /// folders, ./ dropped.
    static func authored(_ resources: [SourceResource]) -> [SourceTreeNode] {
        let grouped = Dictionary(grouping: resources) { DeveloperSourceMapURL.origin(of: $0.url) }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let root = Folder()
            for resource in grouped[name]! {
                var folder = root
                for component in DeveloperSourceMapURL.folders(of: resource.url) {
                    if let next = folder.folders[component] { folder = next } else {
                        let next = Folder()
                        folder.folders[component] = next
                        folder = next
                    }
                }
                folder.files.append(resource)
            }
            let id = "authored|o:" + name
            return SourceTreeNode(id: id, name: name, kind: .origin, children: contents(root, id: id))
        }
    }

    /// Chrome's worker nodes beside "top": each dedicated worker (a gear),
    /// with the scripts it loaded beneath, by origin and folder.
    static func workers(_ workers: [DeveloperWorker], scripts: [SourceResource]) -> [SourceTreeNode] {
        workers.compactMap { worker in
            let own = scripts.filter { DeveloperWorker.parse(resourceFrame: $0.frame)?.target == worker.id }
            guard !own.isEmpty else { return nil }
            let id = workerPrefix + worker.id
            return SourceTreeNode(id: id, name: worker.title, kind: .frame, children: origins(own, under: id))
        }
    }

    /// A worker node's id starts so.
    static let workerPrefix = "w:"

    /// The page's tree with the authored files in its top frame, first.
    static func build(_ resources: [SourceResource], frames: [DeveloperToolsSession.ResourceFrame],
                      authored: [SourceResource]) -> [SourceTreeNode] {
        var nodes = build(resources, frames: frames)
        let groups = self.authored(authored)
        guard !groups.isEmpty else { return nodes }
        if nodes.isEmpty { return groups }
        // An authored file from the page's own host (src/app.js beside
        // app.min.js) goes under that host's node, as in Chrome, not a
        // second node of the same name.
        var separate: [SourceTreeNode] = []
        for group in groups {
            if let index = nodes[0].children.firstIndex(where: { $0.kind == .origin && $0.name == group.name }) {
                nodes[0].children[index].children = merged(nodes[0].children[index].children, group.children)
            } else {
                separate.append(group)
            }
        }
        nodes[0].children = separate + nodes[0].children
        return nodes
    }

    /// Two folders' contents as one: same-named folders merged, folders
    /// before files, each by name.
    private static func merged(_ first: [SourceTreeNode], _ second: [SourceTreeNode]) -> [SourceTreeNode] {
        var folders = first.filter { $0.kind == .folder }
        var files = first.filter(\.isFile)
        for node in second {
            if node.kind == .folder, let index = folders.firstIndex(where: { $0.name == node.name }) {
                folders[index].children = merged(folders[index].children, node.children)
            } else if node.kind == .folder {
                folders.append(node)
            } else {
                files.append(node)
            }
        }
        let byName = { (a: SourceTreeNode, b: SourceTreeNode) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    private static func folders(of url: String) -> [String] {
        guard let address = URL(string: url), address.host() != nil else { return [] }
        return address.path.split(separator: "/", omittingEmptySubsequences: true).dropLast(address.path.hasSuffix("/") ? 0 : 1).map(String.init)
    }

    /// A file's name as the tree shows it: its last part with its query, or
    /// "(index)" for a folder's own page.
    static func fileName(_ url: String) -> String {
        guard let address = URL(string: url), address.host() != nil else {
            // An authored file with no host (webpack:///src/App.tsx): its last part.
            if url.contains(":///"), !url.lowercased().hasPrefix("file:"),
               let last = url.prefix(while: { $0 != "?" && $0 != "#" }).split(separator: "/").last {
                return String(last)
            }
            return url.count > 60 ? String(url.prefix(57)) + "…" : url
        }
        let last = address.path.hasSuffix("/") ? "" : address.lastPathComponent
        let name = last.isEmpty ? "(index)" : last
        return address.query.map { name + "?" + $0 } ?? name
    }

    private static func contents(_ folder: Folder, id: String) -> [SourceTreeNode] {
        let sortedFolders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var nodes: [SourceTreeNode] = sortedFolders.map { name in
            var name = name
            var current = folder.folders[name]!
            // a/b/c when a holds only b, and b only c.
            while current.files.isEmpty, current.folders.count == 1, let (child, next) = current.folders.first {
                name += "/" + child
                current = next
            }
            let nodeID = id + "/" + name
            return SourceTreeNode(id: nodeID, name: name, kind: .folder, children: contents(current, id: nodeID))
        }
        nodes += folder.files
            .sorted { fileName($0.url).localizedStandardCompare(fileName($1.url)) == .orderedAscending }
            .map { SourceTreeNode(id: $0.id, name: fileName($0.url), kind: .file($0)) }
        return nodes
    }

    /// The frames, origins and folders above a node, outermost first; nil
    /// when the node isn't in the tree.
    static func ancestors(of id: String, in nodes: [SourceTreeNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [] }
            if !node.isFile, let below = ancestors(of: id, in: node.children) { return [node.id] + below }
        }
        return nil
    }

    enum Key { case up, down, left, right }

    /// Chrome's tree keys: ↑ and ↓ move; → opens a folder, or goes to its
    /// first child once open; ← closes it, or goes to the parent.
    static func move(_ key: Key, from selected: String?, rows: [(node: SourceTreeNode, depth: Int)],
                     collapsed: Set<String>) -> (selection: String?, collapsed: Set<String>) {
        guard !rows.isEmpty else { return (nil, collapsed) }
        guard let index = rows.firstIndex(where: { $0.node.id == selected }) else {
            return (key == .up ? rows[rows.count - 1].node.id : rows[0].node.id, collapsed)
        }
        let row = rows[index]
        var collapsed = collapsed
        switch key {
        case .down: return (rows[min(index + 1, rows.count - 1)].node.id, collapsed)
        case .up: return (rows[max(index - 1, 0)].node.id, collapsed)
        case .right:
            guard !row.node.isFile else { return (row.node.id, collapsed) }
            if collapsed.contains(row.node.id) {
                collapsed.remove(row.node.id)
                return (row.node.id, collapsed)
            }
            if index + 1 < rows.count, rows[index + 1].depth > row.depth { return (rows[index + 1].node.id, collapsed) }
            return (row.node.id, collapsed)
        case .left:
            if !row.node.isFile, !collapsed.contains(row.node.id), !row.node.children.isEmpty {
                collapsed.insert(row.node.id)
                return (row.node.id, collapsed)
            }
            let parent = rows[..<index].last { $0.depth < row.depth }
            return (parent?.node.id ?? row.node.id, collapsed)
        }
    }

    /// The rows on screen: every node, with its depth, under open parents.
    static func rows(_ nodes: [SourceTreeNode], collapsed: Set<String>, depth: Int = 0) -> [(node: SourceTreeNode, depth: Int)] {
        var rows: [(SourceTreeNode, Int)] = []
        for node in nodes {
            rows.append((node, depth))
            if !node.isFile, !collapsed.contains(node.id) { rows += self.rows(node.children, collapsed: collapsed, depth: depth + 1) }
        }
        return rows
    }
}

// MARK: Snippets

/// Sources › Snippets: scripts kept across launches, run in the page.
@MainActor
final class DeveloperSnippets: ObservableObject {
    struct Snippet: Codable, Identifiable, Equatable {
        var name: String
        var text: String
        var id: String { name }
    }

    static let shared = DeveloperSnippets()
    private static let key = "DeveloperToolsSnippets"
    private let defaults: UserDefaults

    @Published private(set) var snippets: [Snippet]

    init(defaults: UserDefaults = DevDefaults.store) {
        self.defaults = defaults
        snippets = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: Self.key) }
    }

    func snippet(named name: String) -> Snippet? { snippets.first { $0.name == name } }

    /// A new, empty snippet, named as Chrome names them: "Script snippet #1".
    @discardableResult
    func create() -> Snippet {
        var number = 1
        while snippet(named: "Script snippet #\(number)") != nil { number += 1 }
        let snippet = Snippet(name: "Script snippet #\(number)", text: "")
        snippets.append(snippet)
        save()
        return snippet
    }

    /// False if the name is empty or another snippet has it.
    @discardableResult
    func rename(_ name: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new == name || snippet(named: new) == nil, let index = snippets.firstIndex(where: { $0.name == name }) else { return false }
        snippets[index].name = new
        save()
        return true
    }

    func update(_ name: String, text: String) {
        guard let index = snippets.firstIndex(where: { $0.name == name }), snippets[index].text != text else { return }
        snippets[index].text = text
        save()
    }

    func remove(_ name: String) {
        snippets.removeAll { $0.name == name }
        save()
    }
}

// MARK: Navigator

/// A script's "Add script to ignore list" or "Remove from ignore list", as
/// Chrome's navigator and editor menus have them.
struct DeveloperIgnoreListMenuItems: View {
    @ObservedObject var debugger: DeveloperDebugger
    let url: String

    var body: some View {
        if debugger.isListed(url) {
            Button("Remove from ignore list") { debugger.setIgnored(url, false) }
        } else if debugger.isIgnored(url) {
            // A rule or a source map's ignore list, kept in Settings.
            Button("Remove from ignore list") {}.disabled(true)
        } else {
            Button("Add script to ignore list") { debugger.setIgnored(url, true) }
        }
    }
}

enum SourcesNavigatorTab: String, CaseIterable, Identifiable {
    case page = "Page"
    case workspace = "Workspace"
    case contentScripts = "Content scripts"
    case snippets = "Snippets"
    case overrides = "Overrides"
    var id: Self { self }
}

struct DeveloperSourcesNavigator: View {
    /// Posted with the session: the open file revealed in the navigator.
    static let revealRequest = Notification.Name("DeveloperSourcesNavigatorRevealRequest")

    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var snippets = DeveloperSnippets.shared
    @ObservedObject private var workspace = DeveloperWorkspace.shared
    let filter: String
    @State private var tab = SourcesNavigatorTab.page
    @AppStorage(DeveloperSourcesPreferences.autoRevealKey, store: DevDefaults.store) private var autoReveal = true
    @State private var collapsed = Set<String>()
    /// The keyboard's row in the tree, and whether the tree has the keys.
    @State private var selection: String?
    @FocusState private var treeFocused: Bool
    @State private var revealSerial = 0
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
            switch tab {
            case .page: page
            case .contentScripts: contentScripts
            case .snippets: snippetList
            case .workspace: DeveloperWorkspaceNavigator(session: session, filter: filter)
            case .overrides: DeveloperOverridesNavigator(session: session, filter: filter)
            }
        }
        // Settings › Preferences › Sources › Automatically reveal files in sidebar.
        .onChange(of: session.sourceResource) { _, resource in if autoReveal { reveal(resource) } }
        .onAppear { if autoReveal { reveal(session.sourceResource) } }
        // The editor's Reveal in sidebar.
        .onReceive(NotificationCenter.default.publisher(for: Self.revealRequest)) { note in
            if (note.object as? DeveloperToolsSession) === session { reveal(session.sourceResource) }
        }
        .onChange(of: javaScriptSourceMaps) { _, _ in session.sourceMaps.settingsChanged() }
        .onChange(of: cssSourceMaps) { _, _ in session.sourceMaps.settingsChanged() }
    }

    /// Chrome reveals the open file in the navigator: its tab in front,
    /// the folders above it open, the row selected and scrolled to.
    private func reveal(_ resource: SourceResource?) {
        guard let resource else { return }
        let nodes: [SourceTreeNode]
        switch resource.type {
        case "Snippet":
            tab = .snippets
            return
        case "ContentScript" where DeveloperToolsSession.anonymousScriptID(resource.url) != nil:
            // An eval or console script: listed nowhere, as in Chrome's Page tree.
            return
        case "ContentScript":
            tab = .contentScripts
            nodes = contentScriptNodes
        case DeveloperSourceMaps.authoredType, DeveloperWorker.scriptType:
            tab = .page
            nodes = pageNodes
        default:
            guard session.resources.contains(resource) else { return }
            tab = .page
            nodes = pageNodes
        }
        guard let above = SourceTree.ancestors(of: resource.id, in: nodes) else { return }
        collapsed.subtract(above)
        selection = resource.id
        revealSerial += 1
    }

    private var pageNodes: [SourceTreeNode] {
        let resources = session.resources.filter { matches($0.url) }
        let authored = sourceMapsOn ? session.sourceMaps.authoredResources.filter { matches($0.url) } : []
        let workers = SourceTree.workers(session.workers, scripts: session.workerScripts.filter { matches($0.url) })
        if groupByAuthored { return SourceTree.grouped(resources, frames: session.resourceFrames, authored: authored) + workers }
        return SourceTree.build(resources, frames: session.resourceFrames, authored: authored) + workers
    }

    /// The ⋮ menu's Group by Authored/Deployed (DeveloperSourcesGrouping.swift).
    @AppStorage(SourceTree.groupByAuthoredKey, store: DevDefaults.store) private var groupByAuthored = false

    /// Settings › Sources › source maps; the navigator redraws as they change.
    @AppStorage(DeveloperSourceMaps.javaScriptKey, store: DevDefaults.store) private var javaScriptSourceMaps = true
    @AppStorage(DeveloperSourceMaps.cssKey, store: DevDefaults.store) private var cssSourceMaps = true
    private var sourceMapsOn: Bool { javaScriptSourceMaps || cssSourceMaps }

    private var contentScriptNodes: [SourceTreeNode] {
        // No frame for an extension's scripts.
        SourceTree.build(session.contentScripts.filter { matches($0.url) }, frames: []).flatMap(\.children)
    }

    private var tabs: some View {
        DeveloperTabBar(SourcesNavigatorTab.allCases, selection: $tab, title: \.rawValue) {
            if tab == .page {
                Menu {
                    Toggle("Group by Authored/Deployed", isOn: $groupByAuthored)
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, DeveloperToolsStyle.gutter)
                .help("More options")
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func matches(_ text: String) -> Bool { filter.isEmpty || text.localizedCaseInsensitiveContains(filter) }

    private var page: some View {
        tree(SourceTree.rows(pageNodes, collapsed: filter.isEmpty ? collapsed : []))
    }

    /// A tree that takes the arrow keys and Return once clicked.
    private func tree(_ rows: [(node: SourceTreeNode, depth: Int)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.node.id) { row in treeRow(row.node, depth: row.depth).id(row.node.id) }
                }
            }
            .focusable()
            .focused($treeFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                key(press.key, rows: rows)
                return .handled
            }
            .onChange(of: selection) { _, selected in
                if let selected, treeFocused { proxy.scrollTo(selected) }
            }
            .onChange(of: revealSerial) { _, _ in
                guard let selection else { return }
                DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
            }
            .onAppear {
                // A tab just brought forward by a reveal.
                guard let selection else { return }
                DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private func key(_ key: KeyEquivalent, rows: [(node: SourceTreeNode, depth: Int)]) {
        let move: SourceTree.Key
        switch key {
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        default:
            // Return opens a file, or opens and closes a folder.
            guard let node = rows.first(where: { $0.node.id == selection })?.node else { return }
            activate(node)
            return
        }
        let moved = SourceTree.move(move, from: selection, rows: rows, collapsed: collapsed)
        selection = moved.selection
        collapsed = moved.collapsed
    }

    private func activate(_ node: SourceTreeNode) {
        switch node.kind {
        case let .file(resource): session.openSource(resource)
        default:
            if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
        }
    }

    private func icon(for node: SourceTreeNode) -> String {
        switch node.kind {
        case .frame: return node.id.hasPrefix(SourceTree.workerPrefix) ? "gearshape" : "macwindow"
        case .origin: return "cloud"
        case .folder: return "folder"
        case let .file(resource):
            switch resource.type {
            case "Script", "ContentScript", DeveloperWorker.scriptType: return "curlybraces"
            case "Stylesheet": return "paintbrush"
            case "Document": return "doc.richtext"
            case DeveloperSourceMaps.authoredType: return DeveloperSourceMaps.icon(for: resource.url)
            default: return "doc"
            }
        }
    }

    private func mapped(_ node: SourceTreeNode) -> Bool {
        guard case let .file(resource) = node.kind, resource.type != "ContentScript" else { return false }
        return workspace.isMapped(resource.url, page: session.address?.absoluteString)
    }

    private func treeRow(_ node: SourceTreeNode, depth: Int) -> some View {
        let open: Bool = { if case let .file(resource) = node.kind { return session.sourceResource == resource } else { return false } }()
        let selected = selection == nil ? open : selection == node.id
        return HStack(spacing: 4) {
            Image(systemName: node.isFile ? "chevron.right" : collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(node.isFile ? 0 : 1)
                .frame(width: 10)
            Image(systemName: icon(for: node))
                .foregroundStyle(node.kind == .origin || node.kind == .frame ? Color.secondary : node.isFile ? Color.secondary : DeveloperToolsStyle.tint)
                .frame(width: 15)
                .overlay(alignment: .bottomTrailing) {
                    // Chrome's green dot: served from a workspace folder.
                    if mapped(node) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1))
                            .offset(x: 1, y: 1)
                            .accessibilityLabel("Mapped to the workspace")
                    }
                }
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(depth) * 12)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? (treeFocused ? DeveloperToolsStyle.tint.opacity(0.22) : DeveloperToolsStyle.selected) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = node.id
            treeFocused = true
            activate(node)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help({ if case let .file(resource) = node.kind { return resource.url } else { return node.name } }())
        .contextMenu {
            if case let .file(resource) = node.kind {
                Button("Open in new tab") { if let url = URL(string: resource.url) { DevHost.open(url) } }
                Button("Copy link address") { copy(resource.url) }
                Button("Copy file name") { copy(SourceTree.fileName(resource.url)) }
                if resource.type != DeveloperSourceMaps.authoredType, resource.type != DeveloperWorker.scriptType,
                   DeveloperLocalOverrides.relativePath(for: resource.url) != nil {
                    Divider()
                    Button("Override content") {
                        DeveloperLocalOverrides.shared.overrideContent(of: resource, session: session)
                    }
                }
                if resource.type == "Script" || resource.type == "ContentScript" || resource.type == DeveloperWorker.scriptType
                    || (resource.type == DeveloperSourceMaps.authoredType && session.sourceMaps.isAuthoredScript(resource.url)) {
                    Divider()
                    DeveloperIgnoreListMenuItems(debugger: session.debugger, url: resource.url)
                }
            } else {
                Button(collapsed.contains(node.id) ? "Expand" : "Collapse") {
                    if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                }
                Button("Expand recursively") { collapsed.subtract(allIDs(node)) }
                Button("Collapse all") { collapsed.formUnion(allIDs(node)) }
            }
        }
    }

    private func allIDs(_ node: SourceTreeNode) -> Set<String> {
        node.isFile ? [] : node.children.reduce(into: [node.id]) { $0.formUnion(allIDs($1)) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var contentScripts: some View {
        Group {
            if session.contentScripts.filter({ matches($0.url) }).isEmpty {
                Text("No content scripts in this page")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tree(SourceTree.rows(contentScriptNodes, collapsed: collapsed))
            }
        }
    }

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let snippet = snippets.create()
                session.openSnippet(snippet.name, text: snippet.text)
                startRenaming(snippet.name)
            } label: {
                Label("New snippet", systemImage: "plus")
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snippets.snippets.filter { matches($0.name) }) { snippet in snippetRow(snippet) }
                }
            }
        }
    }

    private func isOpen(_ snippet: DeveloperSnippets.Snippet) -> Bool {
        session.sourceResource?.type == "Snippet" && session.sourceResource?.url == "snippet:///" + snippet.name
    }

    private func startRenaming(_ name: String) {
        newName = name
        renaming = name
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard let old = renaming else { return }
        renaming = nil
        let wasOpen = session.sourceResource?.url == "snippet:///" + old
        if snippets.rename(old, to: newName), wasOpen, let snippet = snippets.snippet(named: newName.trimmingCharacters(in: .whitespacesAndNewlines)) {
            session.openSnippet(snippet.name, text: snippet.text)
        }
    }

    @ViewBuilder private func snippetRow(_ snippet: DeveloperSnippets.Snippet) -> some View {
        if renaming == snippet.name {
            TextField("Snippet name", text: $newName)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit(finishRenaming)
                .onExitCommand { renaming = nil }
                .onChange(of: nameFocused) { _, focused in if !focused { finishRenaming() } }
                .padding(.leading, DeveloperToolsStyle.gutter + 19)
                .frame(height: DeveloperToolsStyle.rowHeight)
        } else {
            Button { session.openSnippet(snippet.name, text: snippet.text) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 15)
                    Text(snippet.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isOpen(snippet) ? DeveloperToolsStyle.selected : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(snippet.name) })
            .contextMenu {
                Button("Run") { session.evaluate(snippets.snippet(named: snippet.name)?.text ?? snippet.text) }
                Button("Rename…") { startRenaming(snippet.name) }
                Button("Remove") {
                    if isOpen(snippet) { session.closeSource() }
                    snippets.remove(snippet.name)
                }
            }
        }
    }
}
