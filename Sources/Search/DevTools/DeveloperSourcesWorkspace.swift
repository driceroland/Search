import AppKit
import SwiftUI

// Chrome's Workspace (Sources ▸ Workspace, "Add folder to workspace"): a
// folder on disk is mapped to the inspected origin, and every file the page
// loads whose address ends the way a file's path in the folder does is
// served from the folder instead: it opens from disk, edits are saved to the
// file with ⌘S, and Styles edits to a mapped stylesheet are written there
// too. Authored files from source maps match by their own paths
// (webpack://app/./src/App.tsx is src/App.tsx). The tree marks mapped files
// with a green dot, as Chrome does.
//
// WebKit can't replace a running script (no Debugger.setScriptSource), so a
// saved script runs once the page is reloaded; the editor says so.

@MainActor
final class DeveloperWorkspace: ObservableObject {
    static let shared = DeveloperWorkspace()

    /// A folder mapped to one origin (scheme, host and port).
    struct Folder: Codable, Identifiable, Equatable {
        var origin: String
        var path: String
        var id: String { origin + "\n" + path }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// A page file served from a folder.
    struct Mapping: Equatable {
        let folder: Folder
        /// The file's path inside the folder.
        let path: String
        var file: URL { folder.url.appendingPathComponent(path) }
    }

    private static let key = "DeveloperWorkspaceFolders"
    /// Folders left out with Exclude folder, by workspace folder id: paths inside it.
    private static let excludedKey = "DeveloperWorkspaceExcludedFolders"
    /// Settings › Workspace › Folder exclude pattern.
    static let excludePatternKey = "DeveloperWorkspaceExcludePattern"
    /// Chrome's Folder exclude pattern, by default.
    static let defaultExcludePattern =
        #"/node_modules/|/bower_components/|/\.devtools|/\.git/|/\.sass-cache/|/\.hg/|/\.idea/|/\.svn/|/\.cache/|/\.project/|/Thumbs.db$|/ehthumbs.db$|/Desktop.ini$|/\$RECYCLE.BIN/"#
    static let fileLimit = 50_000
    private let defaults: UserDefaults

    @Published private(set) var folders: [Folder]
    /// Scripts and other files saved since the page loaded them, which run
    /// (or apply) only after a reload: the editor notes it.
    @Published private(set) var needsReload = Set<String>()
    /// Each folder's files, by folder id: relative paths, and by file name.
    private var files: [String: [String]] = [:]
    /// Bumped whenever a folder is listed again, for the Workspace tab.
    @Published private(set) var revision = 0
    @Published private(set) var excluded: [String: [String]]
    /// Files and folders whose paths in a folder match it are left out of
    /// the workspace; an invalid pattern is ignored, as in Chrome.
    @Published private(set) var excludePattern: String
    private var byName: [String: [String: [String]]] = [:]
    /// Lookups already made, by page origin and address.
    private var matches: [String: Mapping?] = [:]
    /// Files read from disk, by path.
    private var texts: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
        excluded = defaults.dictionary(forKey: Self.excludedKey) as? [String: [String]] ?? [:]
        excludePattern = defaults.string(forKey: Self.excludePatternKey) ?? Self.defaultExcludePattern
        for folder in folders { scan(folder) }
    }

    // MARK: Addresses and paths

    /// An address's origin as a workspace is mapped to: scheme://host:port,
    /// for http and https only.
    static func origin(of url: String) -> String? {
        guard let address = URLComponents(string: url), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = address.host?.lowercased(), !host.isEmpty else { return nil }
        return scheme + "://" + host + (address.port.map { ":\($0)" } ?? "")
    }

    /// The path an address names, as parts: a page file's path (a folder's
    /// own page as `index.html`), an authored file's path below its origin
    /// (webpack://app/./src/App.tsx is src, App.tsx). No query or fragment.
    static func components(of url: String) -> [String] {
        if let address = URLComponents(string: url), let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            var parts = address.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            if address.percentEncodedPath.isEmpty || address.percentEncodedPath.hasSuffix("/") { parts.append("index.html") }
            return parts.filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        }
        var path = Substring(url)
        if let scheme = url.range(of: "://") {
            let afterScheme = url[scheme.upperBound...]
            path = afterScheme[(afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex)...]
        }
        path = path.prefix { $0 != "?" && $0 != "#" }
        return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    /// The folder's file an address is served from: one with the same name
    /// whose path ends the most the way the address's does; between equals,
    /// the shortest path. `files` are the folder's paths with that name.
    static func match(_ parts: [String], among files: [String]) -> String? {
        guard let name = parts.last else { return nil }
        var best: (path: String, shared: Int, depth: Int)?
        for path in files {
            let own = path.split(separator: "/").map(String.init)
            guard own.last == name else { continue }
            var shared = 0
            while shared < min(own.count, parts.count), own[own.count - 1 - shared] == parts[parts.count - 1 - shared] { shared += 1 }
            if let current = best, current.shared > shared || (current.shared == shared && (current.depth, current.path) <= (own.count, path)) {
                continue
            }
            best = (path, shared, own.count)
        }
        return best?.path
    }

    // MARK: Lookups

    /// Where an address is served from in the workspace. A page file goes
    /// by its own origin; an authored file (not on the web) by the page's.
    func mapping(for url: String, page: String?) -> Mapping? {
        guard !folders.isEmpty, !url.isEmpty else { return nil }
        let origin: String
        if let own = Self.origin(of: url) { origin = own } else if let page, let own = Self.origin(of: page),
                                                                   url.contains("://"), !url.lowercased().hasPrefix("file:") {
            origin = own
        } else {
            return nil
        }
        let key = origin + "\n" + url
        if let found = matches[key] { return found }
        let parts = Self.components(of: url)
        var found: Mapping?
        if let name = parts.last {
            for folder in folders where folder.origin == origin {
                if let path = Self.match(parts, among: byName[folder.id]?[name] ?? []) {
                    found = Mapping(folder: folder, path: path)
                    break
                }
            }
        }
        // .some, so a miss is kept too rather than clearing the entry.
        matches[key] = .some(found)
        return found
    }

    func isMapped(_ url: String, page: String?) -> Bool { mapping(for: url, page: page) != nil }

    /// The mapped file's text, read from disk once and kept until saved or rescanned.
    func content(for url: String, page: String?) -> String? {
        guard let mapping = mapping(for: url, page: page) else { return nil }
        let path = mapping.file.path
        if let text = texts[path] { return text }
        guard let data = try? Data(contentsOf: mapping.file), let text = String(data: data, encoding: .utf8) else { return nil }
        texts[path] = text
        return text
    }

    /// The folders mapped to the page's origin.
    func folders(for page: String?) -> [Folder] {
        guard let origin = page.flatMap(Self.origin(of:)) else { return [] }
        return folders.filter { $0.origin == origin }
    }

    // MARK: Saving

    /// ⌘S on a mapped file: its text written to the file in the folder.
    /// A script (or anything but a stylesheet edited in Styles) runs only
    /// after the page reloads.
    func save(url: String, page: String?, content: String, needsReload reload: Bool = true) throws {
        guard let mapping = mapping(for: url, page: page) else {
            throw DeveloperLocalOverrides.OverrideError("This file isn’t mapped to a workspace folder.")
        }
        try DeveloperLocalOverrides.writeText(content, to: mapping.file)
        texts[mapping.file.path] = content
        if reload { needsReload.insert(url) }
    }

    /// The Styles pane edited a style sheet: a mapped one's whole text is
    /// written to its file, and an open, unedited editor tab shows it.
    func styleSheetEdited(url: String, text: String, session: DeveloperToolsSession) {
        let page = session.address?.absoluteString
        guard isMapped(url, page: page) else { return }
        do {
            try save(url: url, page: page, content: text, needsReload: false)
            let tabs = DeveloperSourceTabs.of(session)
            if !tabs.unsaved.contains(url) { tabs.reload(url) }
        } catch {
            session.message = error.localizedDescription
        }
    }

    func dismissReloadNote(_ url: String) { needsReload.remove(url) }

    /// A style sheet saved in Sources applies to the page at once, as in
    /// Chrome: every sheet the page loaded from that address gets the text.
    static func applyStyleSheet(url: String, text: String, session: DeveloperToolsSession) {
        session.run { session in
            let result = try await session.command("CSS.getAllStyleSheets")
            let headers = result["headers"] as? [[String: Any]] ?? []
            for header in headers where header["sourceURL"] as? String == url {
                guard let sheet = header["styleSheetId"] as? String else { continue }
                _ = try await session.command("CSS.setStyleSheetText", ["styleSheetId": sheet, "text": text])
            }
            if let selected = session.selectedNode { session.selectNode(selected) }
        }
    }

    /// The page loaded again: the saved files are the ones running.
    func pageNavigated() {
        if !needsReload.isEmpty { needsReload = [] }
    }

    // MARK: Folders

    /// Chrome's "Add folder to workspace": a folder mapped to the page's origin.
    func chooseFolder(for page: String?, session: DeveloperToolsSession? = nil) {
        guard let origin = page.flatMap(Self.origin(of:)) else {
            session?.message = "Only http and https pages can have a workspace."
            return
        }
        DeveloperLocalOverrides.pickFolder(message: "Add folder to workspace for \(origin)", prompt: "Add") { [weak self] url in
            self?.add(url, origin: origin)
        }
    }

    func add(_ folder: URL, origin: String) {
        let item = Folder(origin: origin, path: folder.standardizedFileURL.path)
        guard !folders.contains(item) else { return }
        folders.append(item)
        persist()
        scan(item)
        changed()
    }

    /// Chrome's "Remove folder from workspace" (the files stay).
    func remove(_ folder: Folder) {
        folders.removeAll { $0 == folder }
        files[folder.id] = nil
        byName[folder.id] = nil
        if excluded.removeValue(forKey: folder.id) != nil { persistExcluded() }
        persist()
        changed()
    }

    /// Lists every folder's files again, and forgets what was read.
    func rescan() {
        for folder in folders { scan(folder) }
        changed()
    }

    /// A page file a folder serves, as the Workspace tab lists it.
    struct MappedFile: Identifiable {
        let resource: SourceResource
        let path: String
        var id: String { resource.id }
    }

    /// The mapped files of a folder the page loaded, for the Workspace tab.
    func mapped(_ resources: [SourceResource], in folder: Folder, page: String?) -> [MappedFile] {
        resources.compactMap { resource in
            guard let found = mapping(for: resource.url, page: page), found.folder == folder else { return nil }
            return MappedFile(resource: resource, path: found.path)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Self.key) }
    }

    private func persistExcluded() {
        defaults.set(excluded, forKey: Self.excludedKey)
    }

    // MARK: Automatic workspace folders

    /// Settings › Workspace › Automatic workspace folders (on by default, as in Chrome).
    static let automaticFoldersKey = "DeveloperWorkspaceAutomaticFolders"

    /// A folder a localhost server names in its devtools.json, offered
    /// with Connect until the user connects it.
    struct AutomaticFolder: Equatable {
        let origin: String
        let root: String
        let uuid: String
        var name: String { (root as NSString).lastPathComponent }
    }

    /// What a server's `/.well-known/appspecific/com.chrome.devtools.json` says.
    struct DevToolsJSON: Equatable {
        let root: String
        let uuid: String
    }

    /// The folders offered, by page origin.
    @Published private(set) var automaticFolders: [String: AutomaticFolder] = [:]

    var automaticFoldersEnabled: Bool {
        defaults.object(forKey: Self.automaticFoldersKey) as? Bool ?? true
    }

    /// Only pages served from this machine are asked, as in Chrome.
    static func allowsAutomaticFolders(_ page: String?) -> Bool {
        guard let page, let address = URLComponents(string: page), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = address.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// Where a localhost page's server says which folder it serves.
    static func devToolsJSONURL(for page: String?) -> URL? {
        guard allowsAutomaticFolders(page), let origin = page.flatMap(origin(of:)) else { return nil }
        return URL(string: origin + "/.well-known/appspecific/com.chrome.devtools.json")
    }

    /// The `workspace` of a devtools.json: an absolute `root` and a `uuid`;
    /// nil for anything else.
    static func devToolsJSON(_ data: Data) -> DevToolsJSON? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let workspace = object["workspace"] as? [String: Any],
              let root = workspace["root"] as? String, let uuid = workspace["uuid"] as? String else { return nil }
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), UUID(uuidString: uuid) != nil else { return nil }
        return DevToolsJSON(root: URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path,
                            uuid: uuid.lowercased())
    }

    /// The folder a devtools.json offers, if it names one that exists.
    static func automaticFolder(from data: Data, origin: String,
                                exists: (String) -> Bool = DeveloperWorkspace.folderExists) -> AutomaticFolder? {
        guard let found = devToolsJSON(data), exists(found.root) else { return nil }
        return AutomaticFolder(origin: origin, root: found.root, uuid: found.uuid)
    }

    /// Whether a folder is there; nothing in it is read.
    nonisolated static func folderExists(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The folder offered for the page, unless it is already in the workspace
    /// or Automatic workspace folders is off.
    func automaticFolder(for page: String?) -> AutomaticFolder? {
        guard automaticFoldersEnabled, let origin = page.flatMap(Self.origin(of:)),
              let offered = automaticFolders[origin] else { return nil }
        return folders.contains { $0.origin == origin && $0.path == offered.root } ? nil : offered
    }

    /// Asks a localhost page's server for its devtools.json (same origin);
    /// any failure just offers nothing.
    func checkAutomaticFolder(for page: String?) async {
        guard automaticFoldersEnabled, let url = Self.devToolsJSONURL(for: page),
              let origin = page.flatMap(Self.origin(of:)) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let offered: AutomaticFolder?
        if let result = try? await DeveloperResourceRequest.data(for: request, sameOriginRedirects: true),
           let response = result.1 as? HTTPURLResponse, response.statusCode == 200 {
            offered = Self.automaticFolder(from: result.0, origin: origin)
        } else {
            offered = nil
        }
        if automaticFolders[origin] != offered { automaticFolders[origin] = offered }
    }

    /// Connect: the offered folder added to the workspace for its origin.
    func connect(_ folder: AutomaticFolder) {
        guard Self.folderExists(folder.root) else { return }
        add(URL(fileURLWithPath: folder.root, isDirectory: true), origin: folder.origin)
    }

    /// Records an offer, as a fetch would (for the tests).
    func offer(_ folder: AutomaticFolder) { automaticFolders[folder.origin] = folder }

    // MARK: Files in a folder (the Workspace tab's menus)

    /// A folder's files, as last listed: paths inside it.
    func files(in folder: Folder) -> [String] { files[folder.id] ?? [] }

    /// A path inside a folder with `.`, `..` and empty parts taken out.
    static func clean(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
    }

    static func isExcluded(_ path: String, by excluded: [String]) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Chrome's "Exclude folder": the folder and everything in it left out
    /// of the workspace, its files no longer served from it.
    func exclude(_ path: String, in folder: Folder) {
        let path = Self.clean(path)
        guard !path.isEmpty else { return }
        var list = excluded[folder.id] ?? []
        guard !Self.isExcluded(path, by: list) else { return }
        list.removeAll { $0.hasPrefix(path + "/") }
        list.append(path)
        excluded[folder.id] = list
        persistExcluded()
        scan(folder)
    }

    /// The exclude pattern as a regular expression: nil when it is empty
    /// or not a valid one, so nothing is left out by it.
    static func excludeExpression(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern)
    }

    /// An empty pattern is valid too: it leaves nothing out.
    static func isValidExcludePattern(_ pattern: String) -> Bool {
        pattern.isEmpty || excludeExpression(pattern) != nil
    }

    /// Whether the pattern leaves a path in the folder out, tested as
    /// Chrome tests it: with a leading slash, and a folder's with a
    /// trailing one too (`/node_modules/`).
    static func matchesExcludePattern(_ path: String, isFolder: Bool, expression: NSRegularExpression?) -> Bool {
        guard let expression else { return false }
        let tested = "/" + clean(path) + (isFolder ? "/" : "")
        return expression.firstMatch(in: tested, range: NSRange(tested.startIndex..., in: tested)) != nil
    }

    /// Settings › Workspace › Folder exclude pattern changed: every folder
    /// listed again with it.
    func setExcludePattern(_ pattern: String) {
        guard pattern != excludePattern else { return }
        excludePattern = pattern
        defaults.set(pattern, forKey: Self.excludePatternKey)
        rescan()
    }

    /// Chrome's name for a new file: NewFile, then NewFile1, NewFile2….
    static func newFileName(existing: Set<String>) -> String {
        guard existing.contains("NewFile") else { return "NewFile" }
        var number = 1
        while existing.contains("NewFile\(number)") { number += 1 }
        return "NewFile\(number)"
    }

    /// Chrome's "New file": an empty file in one of the folder's folders
    /// ("" for the folder itself); its path in the folder.
    @discardableResult
    func createFile(in directory: String, of folder: Folder) throws -> String {
        let directory = Self.clean(directory)
        let base = directory.isEmpty ? folder.url : folder.url.appendingPathComponent(directory, isDirectory: true)
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
        let name = Self.newFileName(existing: names)
        try DeveloperLocalOverrides.writeText("", to: base.appendingPathComponent(name))
        scan(folder)
        return directory.isEmpty ? name : directory + "/" + name
    }

    /// Rename…: a file or folder in the folder given a new name; its new path.
    @discardableResult
    func rename(_ path: String, in folder: Folder, to name: String) throws -> String {
        let path = Self.clean(path)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw DeveloperLocalOverrides.OverrideError("That name can’t be used.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let renamed = parent.isEmpty ? name : parent + "/" + name
        guard renamed != path else { return path }
        let destination = folder.url.appendingPathComponent(renamed)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DeveloperLocalOverrides.OverrideError("“\(name)” already exists.")
        }
        try FileManager.default.moveItem(at: folder.url.appendingPathComponent(path), to: destination)
        scan(folder)
        return renamed
    }

    /// Delete: a file or folder in the folder, moved to the Trash.
    func delete(_ path: String, in folder: Folder) throws {
        let path = Self.clean(path)
        guard !path.isEmpty else { throw DeveloperLocalOverrides.OverrideError("The workspace folder itself can’t be deleted here.") }
        try FileManager.default.trashItem(at: folder.url.appendingPathComponent(path), resultingItemURL: nil)
        scan(folder)
    }

    /// One row of a folder's tree in the Workspace tab.
    struct Row: Equatable {
        let path: String
        let name: String
        let isFolder: Bool
        /// 0 for what is in the workspace folder itself.
        let depth: Int
    }

    private final class Directory {
        var folders: [String: Directory] = [:]
        var files: [String] = []
    }

    /// A folder's files as a tree, folders first, each sorted as Finder
    /// sorts; a folder's contents only when it is in `expanded`.
    static func rows(_ paths: [String], expanded: Set<String>) -> [Row] {
        let root = Directory()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            var directory = root
            for part in parts.dropLast() {
                if let next = directory.folders[part] { directory = next } else {
                    let next = Directory()
                    directory.folders[part] = next
                    directory = next
                }
            }
            directory.files.append(name)
        }
        var rows: [Row] = []
        func walk(_ directory: Directory, prefix: String, depth: Int) {
            for name in directory.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = prefix + name
                rows.append(Row(path: path, name: name, isFolder: true, depth: depth))
                if expanded.contains(path), let next = directory.folders[name] { walk(next, prefix: path + "/", depth: depth + 1) }
            }
            for name in directory.files.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                rows.append(Row(path: prefix + name, name: name, isFolder: false, depth: depth))
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
    }

    /// Every folder the paths are in, for a filtered tree shown open.
    static func directories(of paths: [String]) -> Set<String> {
        var found = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, found.insert(parent).inserted { parent = (parent as NSString).deletingLastPathComponent }
        }
        return found
    }

    private func changed() {
        matches = [:]
        texts = [:]
    }

    /// Lists a folder's files: hidden ones, excluded folders and what the
    /// exclude pattern matches left out.
    private func scan(_ folder: Folder) {
        var found: [String] = []
        let root = folder.url.standardizedFileURL.path
        let expression = Self.excludeExpression(excludePattern)
        if let walker = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                       options: [.skipsPackageDescendants]) {
            for case let url as URL in walker {
                guard found.count < Self.fileLimit else { break }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let name = url.lastPathComponent
                let full = url.standardizedFileURL.path
                let relative = full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : name
                let isFolder = values?.isDirectory == true
                if name.hasPrefix(".") || Self.matchesExcludePattern(relative, isFolder: isFolder, expression: expression)
                    || (isFolder && Self.isExcluded(relative, by: excluded[folder.id] ?? [])) {
                    if isFolder { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard full.hasPrefix(root + "/") else { continue }
                found.append(relative)
            }
        }
        files[folder.id] = found
        var names: [String: [String]] = [:]
        for path in found { names[(path as NSString).lastPathComponent, default: []].append(path) }
        byName[folder.id] = names
        matches = [:]
        texts = [:]
        revision += 1
    }
}

// MARK: Navigator tab

/// Sources ▸ Workspace: the folders mapped to the page's origin, and the
/// page's files each one serves.
struct DeveloperWorkspaceNavigator: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var workspace = DeveloperWorkspace.shared
    let filter: String
    /// The open folders of each workspace folder, by its id.
    @State private var expanded: [String: Set<String>] = [:]
    /// The row being renamed: its folder's id, a line break, its path.
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    @State private var deleting: PendingDelete?
    /// Settings › Workspace › Automatic workspace folders.
    @AppStorage(DeveloperWorkspace.automaticFoldersKey) private var automaticFoldersOn = true

    private struct PendingDelete {
        let folder: DeveloperWorkspace.Folder
        let path: String
        let isFolder: Bool
        var name: String { (path as NSString).lastPathComponent }
    }

    private var page: String? { session.address?.absoluteString }

    var body: some View {
        let shown = workspace.folders(for: page)
        VStack(alignment: .leading, spacing: 0) {
            if automaticFoldersOn, let offered = workspace.automaticFolder(for: page) {
                automaticFolderRow(offered)
                Divider()
            }
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up workspace to sync edits directly to the sources you develop")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add folder to workspace") { workspace.chooseFolder(for: page, session: session) }
                }
                .padding(DeveloperToolsStyle.gutter + 2)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Button("Add folder") { workspace.chooseFolder(for: page, session: session) }
                        .buttonStyle(.link)
                        .help("Add folder to workspace")
                    Spacer(minLength: 0)
                    DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh", size: 18) { workspace.rescan() }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight + 4)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { folder in folderRows(folder) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A localhost page's server may name its folder in devtools.json.
        .task(id: (page ?? "") + (automaticFoldersOn ? "\non" : "")) {
            if automaticFoldersOn { await workspace.checkAutomaticFolder(for: page) }
        }
        .alert(deleting?.isFolder == true ? "Delete folder?" : "Delete file?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { item in
            Button("Delete", role: .destructive) {
                do { try workspace.delete(item.path, in: item.folder) } catch { session.message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.isFolder
                 ? "Are you sure you want to delete the folder “\(item.name)” and everything in it? It goes to the Trash."
                 : "Are you sure you want to delete “\(item.name)”? It goes to the Trash.")
        }
    }

    /// Chrome's automatic workspace folder: the folder the server named,
    /// connected only when the user says so.
    private func automaticFolderRow(_ offered: DeveloperWorkspace.AutomaticFolder) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: "folder.badge.plus").foregroundStyle(DeveloperToolsStyle.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(offered.name).lineLimit(1).truncationMode(.middle)
                Text(offered.root).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            Button("Connect") { workspace.connect(offered) }
                .help("Connect the workspace folder \(offered.root) for \(offered.origin)")
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 6)
        .help("This folder was found automatically in the server’s com.chrome.devtools.json")
        .accessibilityElement(children: .combine)
    }

    private func key(_ folder: DeveloperWorkspace.Folder, _ path: String) -> String { folder.id + "\n" + path }

    private func startRenaming(_ folder: DeveloperWorkspace.Folder, _ path: String) {
        newName = (path as NSString).lastPathComponent
        renaming = key(folder, path)
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming(_ folder: DeveloperWorkspace.Folder, _ path: String) {
        guard renaming == key(folder, path) else { return }
        renaming = nil
        do {
            let renamed = try workspace.rename(path, in: folder, to: newName)
            if expanded[folder.id]?.remove(path) != nil { expanded[folder.id]?.insert(renamed) }
        } catch {
            session.message = error.localizedDescription
        }
    }

    /// New file, in a folder of the workspace folder ("" for itself), named
    /// at once, as in Chrome.
    private func newFile(in directory: String, of folder: DeveloperWorkspace.Folder) {
        do {
            let path = try workspace.createFile(in: directory, of: folder)
            if !directory.isEmpty { expanded[folder.id, default: []].insert(directory) }
            startRenaming(folder, path)
        } catch {
            session.message = error.localizedDescription
        }
    }

    private func toggle(_ path: String, in folder: DeveloperWorkspace.Folder) {
        if expanded[folder.id]?.contains(path) == true { expanded[folder.id]?.remove(path) }
        else { expanded[folder.id, default: []].insert(path) }
    }

    @ViewBuilder private func folderRows(_ folder: DeveloperWorkspace.Folder) -> some View {
        Label(folder.name, systemImage: "folder")
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(folder.path)
            .contextMenu {
                Button("New file") { newFile(in: "", of: folder) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                Divider()
                Button("Remove folder from workspace") { workspace.remove(folder) }
            }
        // The page's files the folder serves open in the editor, with Chrome's green dot.
        let mapped = Dictionary(workspace.mapped(session.resources + session.sourceMaps.authoredResources, in: folder, page: page)
            .map { ($0.path, $0.resource) }, uniquingKeysWith: { first, _ in first })
        let all = workspace.files(in: folder)
        let files = filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
        let open = filter.isEmpty ? expanded[folder.id] ?? [] : DeveloperWorkspace.directories(of: files)
        if mapped.isEmpty {
            Text("No files the page loaded are in this folder.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DeveloperToolsStyle.gutter + 18).padding(.vertical, 4)
        }
        ForEach(DeveloperWorkspace.rows(files, expanded: open), id: \.path) { row in
            entryRow(row, folder: folder, resource: mapped[row.path], open: open.contains(row.path))
        }
    }

    private func entryRow(_ row: DeveloperWorkspace.Row, folder: DeveloperWorkspace.Folder, resource: SourceResource?,
                          open: Bool) -> some View {
        let file = folder.url.appendingPathComponent(row.path)
        return HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(row.isFolder ? 1 : 0)
                .frame(width: 10)
            if row.isFolder {
                Image(systemName: "folder").foregroundStyle(DeveloperToolsStyle.tint).frame(width: 15)
            } else {
                DeveloperWorkspaceDot(symbol: "doc", mapped: resource != nil)
            }
            if renaming == key(folder, row.path) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { finishRenaming(folder, row.path) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, focused in if !focused { finishRenaming(folder, row.path) } }
            } else {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(row.isFolder || resource != nil ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, DeveloperToolsStyle.gutter + 4 + CGFloat(row.depth + 1) * 12)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resource != nil && session.sourceResource == resource ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isFolder { toggle(row.path, in: folder) } else if let resource { session.openSource(resource) }
        }
        .help(file.path)
        .contextMenu {
            if row.isFolder {
                Button("New file") { newFile(in: row.path, of: folder) }
                Button("Exclude folder") { workspace.exclude(row.path, in: folder) }
                Divider()
            } else if let resource {
                Button("Open") { session.openSource(resource) }
                Divider()
            }
            Button("Rename…") { startRenaming(folder, row.path) }
            Button("Delete") { deleting = PendingDelete(folder: folder, path: row.path, isFolder: row.isFolder) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }
}

/// A file's icon with Chrome's green dot: served from a workspace folder.
struct DeveloperWorkspaceDot: View {
    let symbol: String
    var mapped = true

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: 15)
            .overlay(alignment: .bottomTrailing) {
                if mapped {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1))
                        .offset(x: 1, y: 1)
                        .accessibilityLabel("Mapped to the workspace")
                }
            }
    }
}
