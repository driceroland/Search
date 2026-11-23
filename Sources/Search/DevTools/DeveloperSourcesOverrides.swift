import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Chrome's Local Overrides (Sources ▸ Overrides): a folder on disk mirrors
// page addresses (host/path/file), "Override content" copies a page file
// there, the editor edits it and ⌘S saves it, and later loads of that
// address are answered from the file.
//
// The answering is WebKit's own: its inspector frontend (hidden behind
// Search's DevTools) has local resource overrides, which intercept the
// response for an address and replace its body. Search keeps the folder and
// hands the frontend one override per file, a pattern for the address and
// the file's content. They act while DevTools is open, as in Chrome.

@MainActor
final class DeveloperLocalOverrides: ObservableObject {
    static let shared = DeveloperLocalOverrides()

    /// A file in the overrides folder.
    struct File: Identifiable, Equatable {
        /// The path inside the folder: host/path/name.
        let path: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        /// A `.headers` file: header overrides, not a page file.
        var isHeaders: Bool { name == DeveloperHeaderOverrides.fileName }
    }

    private static let folderKey = "DeveloperLocalOverridesFolder"
    private static let enabledKey = "DeveloperLocalOverridesEnabled"
    private static let disabledKey = "DeveloperLocalOverridesDisabledFiles"
    private let defaults: UserDefaults

    @Published private(set) var folder: URL?
    /// Chrome's "Enable Local Overrides".
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            applyAll()
        }
    }
    @Published private(set) var files: [File] = []
    /// Files turned off by their checkbox.
    @Published private(set) var disabledFiles: Set<String>
    /// What WebKit said when the overrides were last handed over.
    @Published private(set) var status: String?
    /// The checked `.headers` files' rules (DeveloperHeaderOverrides).
    @Published private(set) var headerFiles: [DeveloperHeaderOverrides.File] = []
    /// Why a `.headers` file was skipped, by its path.
    @Published private(set) var headerErrors: [String: String] = [:]
    /// The text of each file, read when listed or saved.
    private var contents: [String: String] = [:]
    private var sessions: [Weak] = []

    private struct Weak { weak var session: DeveloperToolsSession? }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        disabledFiles = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        scan()
    }

    // MARK: Addresses and paths

    /// The characters a file name can't hold, written %XX as Chrome does.
    private static let unsafe = CharacterSet(charactersIn: "%:?*\"<>|\\").union(.controlCharacters)

    static func escape(_ part: String) -> String {
        if part == "." { return "%2E" }
        if part == ".." { return "%2E%2E" }
        var out = ""
        for scalar in part.unicodeScalars {
            if unsafe.contains(scalar) { out += String(format: "%%%02X", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    /// Where an address is kept in the folder: `host/path/name`, a folder's
    /// own page as `index.html`, a query on the name (`app.js%3Fv=2`).
    /// Nil for anything but http and https.
    static func relativePath(for url: String) -> String? {
        guard let address = URLComponents(string: url), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = address.host, !host.isEmpty else { return nil }
        if let port = address.port { host += ":\(port)" }
        var parts = address.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        if address.percentEncodedPath.isEmpty || address.percentEncodedPath.hasSuffix("/") { parts.append("index.html") }
        if let query = address.percentEncodedQuery, !query.isEmpty { parts[parts.count - 1] += "?" + query }
        return ([host] + parts).map(escape).joined(separator: "/")
    }

    /// The addresses a file in the folder answers, as a regular expression
    /// for WebKit: either scheme, the path as the page writes it, and for
    /// `index.html` the folder's own address too.
    static func urlPattern(forRelativePath path: String) -> String {
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let host = parts.first else { return "^$" }
        var names = Array(parts.dropFirst())
        var query: String?
        if let last = names.last, let mark = last.firstIndex(of: "?") {
            query = String(last[last.index(after: mark)...])
            names[names.count - 1] = String(last[..<mark])
        }
        let encoded = names.map {
            NSRegularExpression.escapedPattern(for: $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0)
        }
        var pattern = "^https?://" + NSRegularExpression.escapedPattern(for: host) + "/"
        if names.last == "index.html" {
            pattern += encoded.dropLast().map { $0 + "/" }.joined() + "(index\\.html)?"
        } else {
            pattern += encoded.joined(separator: "/")
        }
        if let query { pattern += "\\?" + NSRegularExpression.escapedPattern(for: query) }
        return pattern + "(#.*)?$"
    }

    /// Whether the editor shows this address from the folder, editable.
    func isOverridden(_ url: String) -> Bool { activeContent(for: url) != nil }

    /// The saved text an address is answered with, when overrides are on
    /// and its file is listed and checked.
    func activeContent(for url: String) -> String? {
        guard enabled, folder != nil, let path = Self.relativePath(for: url), !disabledFiles.contains(path),
              (path as NSString).lastPathComponent != DeveloperHeaderOverrides.fileName else { return nil }
        return contents[path]
    }

    // MARK: Header overrides

    /// The headers the `.headers` files set for an address, when overrides are on.
    func headerOverrides(for url: String) -> [DeveloperHeaderOverrides.Header] {
        guard enabled, folder != nil else { return [] }
        return DeveloperHeaderOverrides.overrides(for: url, in: headerFiles)
    }

    /// Where "Override headers" writes an address's rule, inside the folder.
    static func headersPath(for url: String) -> (path: String, applyTo: String)? {
        guard let location = DeveloperHeaderOverrides.location(for: url) else { return nil }
        let folder = location.directory.split(separator: "/").map { escape(String($0)) }.joined(separator: "/")
        return ((folder.isEmpty ? "" : folder + "/") + DeveloperHeaderOverrides.fileName, location.applyTo)
    }

    /// The headers the address's own rule sets (not wildcard rules).
    func ruleHeaders(for url: String) -> [DeveloperHeaderOverrides.Header] {
        guard let place = Self.headersPath(for: url), let text = contents[place.path],
              let rules = try? DeveloperHeaderOverrides.parse(text) else { return [] }
        return DeveloperHeaderOverrides.headers(applyTo: place.applyTo, in: rules)
    }

    /// Saves the address's own rule in its folder's `.headers` file; no
    /// headers removes the rule, and the file (to the Trash) once it has none.
    func saveHeaders(url: String, headers: [DeveloperHeaderOverrides.Header]) throws {
        guard let folder else { throw OverrideError("Select a folder for overrides first.") }
        guard let place = Self.headersPath(for: url) else { throw OverrideError("Only http and https responses can be overridden.") }
        var rules: [DeveloperHeaderOverrides.Rule] = []
        if let text = contents[place.path] {
            do { rules = try DeveloperHeaderOverrides.parse(text) } catch {
                throw OverrideError("Fix \(place.path) first: \(error.localizedDescription)")
            }
        }
        rules = DeveloperHeaderOverrides.setting(headers, applyTo: place.applyTo, in: rules)
        if rules.isEmpty {
            if let file = files.first(where: { $0.path == place.path }) { delete(file) }
            return
        }
        try write(DeveloperHeaderOverrides.encode(rules), to: place.path, in: folder)
    }

    /// Saves a `.headers` file edited as text, once it parses.
    func saveHeadersFile(_ file: File, text: String) throws {
        guard let folder else { throw OverrideError("Select a folder for overrides first.") }
        _ = try DeveloperHeaderOverrides.parse(text)
        try write(text, to: file.path, in: folder)
    }

    /// The text of a listed file, as last read or saved.
    func text(of file: File) -> String? { contents[file.path] }

    /// Chrome's "Override headers": the editor for an address's response
    /// headers, the folder chosen first when there is none.
    func overrideHeaders(url: String, response: [DeveloperHeaderOverrides.Header], session: DeveloperToolsSession?) {
        let open = { [weak self, weak session] in
            guard let self else { return }
            DeveloperHeaderOverridesEditor.present(url: url, response: response, overrides: self, session: session)
        }
        if folder == nil { chooseFolder(then: open) } else { open() }
    }

    /// Parses the checked `.headers` files.
    private func readHeaders() {
        var found: [DeveloperHeaderOverrides.File] = []
        var errors: [String: String] = [:]
        for file in files where file.isHeaders && !disabledFiles.contains(file.path) {
            guard let text = contents[file.path] else { continue }
            do {
                let rules = try DeveloperHeaderOverrides.parse(text)
                let directory = (file.path as NSString).deletingLastPathComponent.split(separator: "/")
                    .map { String($0).removingPercentEncoding ?? String($0) }.joined(separator: "/")
                found.append(.init(directory: directory, rules: rules))
            } catch {
                errors[file.path] = error.localizedDescription
            }
        }
        headerFiles = found
        headerErrors = errors
    }

    // MARK: The folder

    /// Chrome's "Select folder for overrides".
    func chooseFolder(then done: (() -> Void)? = nil) {
        Self.pickFolder(message: "Select folder for overrides") { [weak self] url in
            self?.setFolder(url)
            done?()
        }
    }

    /// The folder panel Overrides and Workspace (DeveloperWorkspace) share.
    static func pickFolder(message: String, prompt: String = "Select", then done: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { done(url) }
        }
    }

    /// Writes a text file atomically, making its folders first.
    static func writeText(_ content: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file, options: .atomic)
    }

    func setFolder(_ url: URL?) {
        folder = url
        if let url { defaults.set(url.path, forKey: Self.folderKey) } else { defaults.removeObject(forKey: Self.folderKey) }
        scan()
        applyAll()
    }

    /// Chrome's "Clear configuration": forget the folder (its files stay).
    func clearConfiguration() { setFolder(nil) }

    /// Lists the folder's files and reads them.
    func scan() {
        guard let folder else { files = []; contents = [:]; readHeaders(); return }
        var found: [File] = []
        var read: [String: String] = [:]
        let root = folder.standardizedFileURL.path
        // Hidden files are skipped, but for `.headers` (header overrides).
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                                                       options: []) {
            for case let url as URL in walker {
                guard found.count < 1_000 else { break }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if url.lastPathComponent.hasPrefix("."), url.lastPathComponent != DeveloperHeaderOverrides.fileName {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 20_000_000 else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(root + "/") else { continue }
                let path = String(full.dropFirst(root.count + 1))
                // host/…, nothing at the top but a .headers for every host
                guard path.contains("/") || path == DeveloperHeaderOverrides.fileName else { continue }
                found.append(File(path: path))
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) { read[path] = text }
            }
        }
        files = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        contents = read
        readHeaders()
    }

    func fileURL(_ file: File) -> URL? { folder?.appendingPathComponent(file.path) }

    // MARK: Saving

    /// Writes an address's text to its file in the folder (⌘S, Override
    /// content), and answers the address with it from then on.
    func save(url: String, content: String) throws {
        guard let folder else { throw OverrideError("Select a folder for overrides first.") }
        guard let path = Self.relativePath(for: url) else { throw OverrideError("Only http and https files can be overridden.") }
        try write(content, to: path, in: folder)
    }

    /// Writes a file in the folder, lists and checks it, and hands WebKit the change.
    private func write(_ content: String, to path: String, in folder: URL) throws {
        try Self.writeText(content, to: folder.appendingPathComponent(path))
        contents[path] = content
        if !files.contains(where: { $0.path == path }) {
            files = (files + [File(path: path)]).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        if disabledFiles.remove(path) != nil { saveDisabled() }
        readHeaders()
        if !enabled { enabled = true } else { applyAll() }
    }

    /// Chrome's "Override content": the file as the page has it, copied to
    /// the folder (chosen first when there is none).
    func overrideContent(url: String, content: String, session: DeveloperToolsSession?) {
        let write = { [weak self, weak session] in
            guard let self else { return }
            do { try self.save(url: url, content: content) } catch { session?.message = error.localizedDescription }
        }
        if folder == nil { chooseFolder(then: write) } else { write() }
    }

    /// The navigator's "Override content": the page's copy is fetched, saved,
    /// and the file opened to edit.
    func overrideContent(of resource: SourceResource, session: DeveloperToolsSession) {
        Task { [weak self, weak session] in
            guard let session else { return }
            do {
                let content = try await session.evaluateInFrontend("""
                    const result = await perchInspector.command("Page.getResourceContent", resource);
                    return result.base64Encoded ? null : (result.content ?? "");
                    """, ["resource": ["frameId": resource.frame, "url": resource.url]]) as? String
                guard let content else { throw OverrideError("Only text files can be overridden here.") }
                self?.overrideContent(url: resource.url, content: content, session: session)
                session.openSource(resource)
            } catch {
                session.message = error.localizedDescription
            }
        }
    }

    func setEnabled(_ file: File, _ on: Bool) {
        if on { disabledFiles.remove(file.path) } else { disabledFiles.insert(file.path) }
        saveDisabled()
        readHeaders()
        applyAll()
    }

    /// Moves a file to the Trash, as Chrome's Delete does.
    func delete(_ file: File) {
        if let url = fileURL(file) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        files.removeAll { $0 == file }
        contents[file.path] = nil
        readHeaders()
        applyAll()
    }

    private func saveDisabled() { defaults.set(Array(disabledFiles).sorted(), forKey: Self.disabledKey) }

    // MARK: WebKit

    /// A session that connected: it gets the overrides, and every change after.
    func attach(_ session: DeveloperToolsSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
        sessions.append(Weak(session: session))
        apply(to: session)
    }

    private func applyAll() {
        for item in sessions { if let session = item.session { apply(to: session) } }
    }

    /// What WebKit is handed: each checked file's pattern, type and body.
    private var overrides: [[String: Any]] {
        guard enabled, let folder else { return [] }
        return files.filter { !disabledFiles.contains($0.path) && !$0.isHeaders }.compactMap { file in
            let type = UTType(filenameExtension: (file.path as NSString).pathExtension.components(separatedBy: "%").first ?? "")
            let mime = type?.preferredMIMEType ?? "text/plain"
            // Content and header overrides together: the file's body, with
            // the `.headers` rules for its address on top.
            let added = DeveloperHeaderOverrides.overrides(for: Self.target(forRelativePath: file.path), in: headerFiles)
            let headers = DeveloperHeaderOverrides.merge([.init(name: "Content-Type", value: mime)], added)
            var item: [String: Any] = ["pattern": Self.urlPattern(forRelativePath: file.path), "mimeType": mime,
                                       "headers": DeveloperHeaderOverrides.object(headers)]
            if let text = contents[file.path] {
                item["content"] = text
                item["base64"] = false
            } else if let data = try? Data(contentsOf: folder.appendingPathComponent(file.path)) {
                item["content"] = data.base64EncodedString()
                item["base64"] = true
            } else {
                return nil
            }
            return item
        }
    }

    /// The address a file in the folder stands for, as header rules match it.
    static func target(forRelativePath path: String) -> (path: String, query: String?) {
        let decoded = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.joined(separator: "/")
        guard let mark = decoded.firstIndex(of: "?") else { return (decoded, nil) }
        return (String(decoded[..<mark]), String(decoded[decoded.index(after: mark)...]))
    }

    /// The header rules the network bridge answers responses with, in order.
    private var headerRules: [[String: Any]] {
        guard enabled, folder != nil else { return [] }
        return DeveloperHeaderOverrides.compiled(headerFiles).map { rule in
            ["pattern": rule.pattern, "headers": rule.headers.map { ["name": $0.name, "value": $0.value] }]
        }
    }

    private func apply(to session: DeveloperToolsSession) {
        guard session.ready else { return }
        let items = overrides
        let rules = headerRules
        let headerCount = enabled && folder != nil ? headerFiles.count : 0
        Task { [weak self] in
            var notes: [String] = []
            do {
                let result = try await session.evaluateInFrontend(Self.script, ["items": items]) as? [String: Any]
                if let reason = result?["reason"] as? String {
                    notes.append(reason)
                } else if let count = result?["count"] as? Int, count > 0 {
                    notes.append("\(count) file\(count == 1 ? "" : "s") overridden")
                }
            } catch {
                notes.append(error.localizedDescription)
            }
            // Header overrides are answered by DeveloperNetworkBridgeScript.
            do {
                let result = try await session.evaluateInFrontend("""
                    if (typeof globalThis.perchNetwork?.setHeaderOverrides !== "function")
                        return rules.length ? {reason: "This version of WebKit can’t override response headers."} : {active: false};
                    return await perchNetwork.setHeaderOverrides(rules);
                    """, ["rules": rules]) as? [String: Any]
                if let reason = result?["reason"] as? String {
                    notes.append(reason)
                } else if headerCount > 0 {
                    notes.append("headers from \(headerCount) .headers file\(headerCount == 1 ? "" : "s")")
                }
            } catch {
                if !rules.isEmpty { notes.append(error.localizedDescription) }
            }
            self?.status = notes.isEmpty ? nil : notes.joined(separator: ", ")
        }
    }

    /// Replaces the frontend's local overrides with Search's. The hidden
    /// frontend is Search's alone, so every override in it is one of ours.
    private static let script = """
        const manager = WI.networkManager;
        const Override = WI.LocalResourceOverride;
        if (!manager || !Override || typeof manager.addLocalResourceOverride !== "function")
            return {reason: "This version of WebKit can’t override page files."};
        for (const item of Array.from(manager.localResourceOverrides ?? [])) {
            try { manager.removeLocalResourceOverride(item); } catch {}
        }
        if (!items.length)
            return {count: 0};
        if (manager.interceptionEnabled === false)
            manager.interceptionEnabled = true;
        let count = 0;
        for (const item of items) {
            const headers = item.headers ?? {"Content-Type": item.mimeType};
            const types = Override.InterceptType;
            const override = types
                ? Override.create(item.pattern, types.Response, {
                    responseMIMEType: item.mimeType, responseContent: item.content,
                    responseBase64Encoded: item.base64, responseStatusCode: 200, responseStatusText: "OK",
                    responseHeaders: headers, isCaseSensitive: true, isRegex: true, disabled: false,
                })
                : Override.create({
                    url: item.pattern, mimeType: item.mimeType, content: item.content, base64Encoded: item.base64,
                    statusCode: 200, statusText: "OK", headers, isCaseSensitive: true, isRegex: true, disabled: false,
                });
            manager.addLocalResourceOverride(override);
            count += 1;
        }
        return {count};
        """

    struct OverrideError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

// MARK: Navigator tab

/// Sources ▸ Overrides: the folder, Enable Local Overrides, and the files
/// in it, each with a checkbox.
struct DeveloperOverridesNavigator: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var overrides = DeveloperLocalOverrides.shared
    let filter: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder = overrides.folder {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Toggle("Enable Local Overrides", isOn: $overrides.enabled).toggleStyle(.developerCheckbox)
                    Spacer(minLength: 0)
                    DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh", size: 18) { overrides.scan() }
                    DeveloperPanelIcon(symbol: "nosign", title: "Clear configuration", size: 18) { overrides.clearConfiguration() }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight + 4)
                Divider()
                Label(folder.lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
                    .help(folder.path)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        Button("Select another folder…") { overrides.chooseFolder() }
                    }
                let shown = overrides.files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
                if shown.isEmpty {
                    Text("Use “Override content” on a page file, or “Override headers” on a request, to add it here.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DeveloperToolsStyle.gutter + 14).padding(.vertical, 6)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { file in row(file) }
                    }
                }
                if let status = overrides.status {
                    Divider()
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Override page assets with files from a local folder.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Select folder for overrides") { overrides.chooseFolder() }
                }
                .padding(DeveloperToolsStyle.gutter + 2)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The page file a saved one stands for, when the page loaded it.
    private func resource(for file: DeveloperLocalOverrides.File) -> SourceResource? {
        session.resources.first { DeveloperLocalOverrides.relativePath(for: $0.url) == file.path }
    }

    private func row(_ file: DeveloperLocalOverrides.File) -> some View {
        let loaded = resource(for: file)
        let open = loaded != nil && session.sourceResource == loaded
        return HStack(spacing: 4) {
            Toggle("", isOn: Binding(get: { !overrides.disabledFiles.contains(file.path) },
                                     set: { overrides.setEnabled(file, $0) }))
                .toggleStyle(.developerCheckbox).labelsHidden()
                .accessibilityLabel("Override \(file.name)")
            Image(systemName: file.isHeaders ? "list.bullet.rectangle" : "doc")
                .foregroundStyle(file.isHeaders ? Color.purple : Color.secondary).frame(width: 15)
            Text(file.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(overrides.headerErrors[file.path] == nil ? Palette.ink : Color.red)
            Text((file.path as NSString).deletingLastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { openFile(file) }
        .help(overrides.headerErrors[file.path] ?? overrides.fileURL(file)?.path ?? file.path)
        .contextMenu {
            Button("Open") { openFile(file) }
            Button("Reveal in Finder") {
                if let url = overrides.fileURL(file) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(overrides.fileURL(file)?.path ?? file.path, forType: .string)
            }
            Divider()
            Button("Delete") { overrides.delete(file) }
        }
    }

    /// Opens the page's file in the editor; one the page didn't load is
    /// shown in Finder instead.
    private func openFile(_ file: DeveloperLocalOverrides.File) {
        if file.isHeaders {
            DeveloperHeadersFileEditor.present(file, overrides: overrides)
        } else if let resource = resource(for: file) {
            session.openSource(resource)
        } else if let url = overrides.fileURL(file) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
