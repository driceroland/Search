import Foundation
import Darwin
import UniformTypeIdentifiers

// What another browser exported to a file, brought in: the way in from a
// browser Search can't read directly, from another Mac, or from Safari,
// whose own files macOS keeps from other apps.
//
// One chooser takes all of it. A bookmarks page (.html), a passwords file
// (.csv), or Safari's own export — File › Export Browsing Data, a ZIP with
// its bookmarks, its passwords and a history file per profile. The files in
// that ZIP are named in the Mac's language, so they are told apart by what
// they hold, not by their names.

enum ImportFile {
    /// A folder of its own for what an import unpacks or copies (a Safari
    /// export's Passwords.csv in the clear, another browser's databases),
    /// named for this process so another copy of Search running beside it
    /// never takes it for a leftover.
    nonisolated static func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    }

    /// At launch: what an import left behind when Search stopped in the
    /// middle of it (a crash, a force quit) — folders of a process that is
    /// gone, or from before they were named for one and a day old.
    nonisolated static func sweepScratch() {
        let files = FileManager.default
        let temp = files.temporaryDirectory
        guard let names = try? files.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix("office-import-") {
            let parts = name.dropFirst("office-import-".count).split(separator: "-", maxSplits: 1)
            let folder = temp.appendingPathComponent(name, isDirectory: true)
            if let pid = parts.first.flatMap({ Int32($0) }), parts.count == 2 {
                // Still running — this Search, or another beside it: its own.
                // (Not ours to signal still means it is there.)
                if pid == getpid() || kill(pid, 0) == 0 || errno == EPERM { continue }
            } else {
                let made = (try? files.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date) ?? .distantPast
                guard Date().timeIntervalSince(made) > 86_400 else { continue }
            }
            try? files.removeItem(at: folder)
        }
    }

    struct Progress: Sendable {
        let message: String
        let completed: Int
        let total: Int?

        init(message: String, completed: Int = 0, total: Int? = nil) {
            self.message = message
            self.completed = max(0, completed)
            self.total = total.map { max(0, $0) }
        }
    }

    /// A cancellation flag shared with the worker. The callback is invoked
    /// outside the state lock so it may safely cancel the import itself.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private let callbackLock = NSRecursiveLock()
        private let progress: (Progress) -> Void
        private var cancelled = false
        private var greatestCompleted = 0
        private var lastMessage: String?
        private var lastEmission: TimeInterval = 0
        private var hasEmitted = false

        init(progress: @escaping (Progress) -> Void = { _ in }) {
            self.progress = progress
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func checkCancellation() throws {
            if isCancelled { throw CancellationError() }
        }

        /// Reports at most about ten updates a second across all messages.
        /// Counts reset when the message changes and stay monotonic within a
        /// phase; a new phase waits for the next throttle window.
        func report(_ progress: Progress) {
            emit(progress, force: false)
        }

        fileprivate func reportFinal(_ progress: Progress) {
            emit(progress, force: true)
        }

        private func emit(_ progress: Progress, force: Bool) {
            callbackLock.lock()
            defer { callbackLock.unlock() }

            lock.lock()
            let phaseChanged = lastMessage != progress.message
            if phaseChanged {
                lastMessage = progress.message
                greatestCompleted = progress.completed
            } else {
                greatestCompleted = max(greatestCompleted, progress.completed)
            }
            let completed = greatestCompleted
            let normalized = Progress(
                message: progress.message,
                completed: completed,
                total: progress.total.map { max($0, completed) }
            )
            let now = ProcessInfo.processInfo.systemUptime
            let enoughTime = now - lastEmission >= 0.1
            let shouldEmit = !cancelled && (force || !hasEmitted || enoughTime)
            if shouldEmit {
                lastEmission = now
                hasEmitted = true
            }
            lock.unlock()

            if shouldEmit { progressCallback(normalized) }
        }

        private func progressCallback(_ value: Progress) {
            progress(value)
        }
    }

    struct Found {
        var bookmarks: [Bookmark] = []
        var places: [Chromium.Place] = []
        /// A passwords file's text, for Vault.take(csv:).
        var passwords: [String] = []
        /// Safari's export holds passwords in the clear; said once brought in.
        /// Known by its history file, which only Safari's export has.
        var fromSafari = false

        var isEmpty: Bool { bookmarks.isEmpty && places.isEmpty && passwords.isEmpty }
        fileprivate var safariHistory = false
    }

    private final class ProgressCounter {
        private(set) var value = 0

        @discardableResult
        func advance(_ amount: Int = 1) -> Int {
            guard amount > 0 else { return value }
            let (sum, overflow) = value.addingReportingOverflow(amount)
            value = overflow ? Int.max : sum
            return value
        }
    }

    /// Everything in the file or folder: one file, a folder of them, or a
    /// ZIP, opened into a folder of its own and gone afterwards.
    static func read(_ url: URL, control: Control = Control()) throws -> Found {
        let counter = ProgressCounter()
        var found = Found()
        try control.checkCancellation()

        let isZIP = url.pathExtension.lowercased() == "zip"
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return found
        } else if isZIP {
            if let folder = try unzip(url, control: control, counter: counter) {
                defer { try? FileManager.default.removeItem(at: folder) }
                try collect(in: folder, into: &found, control: control, counter: counter)
            }
        } else if values?.isDirectory == true {
            try collect(in: url, into: &found, control: control, counter: counter)
        } else if values?.isRegularFile == true {
            try take(url, relativeTo: nil, into: &found, control: control, counter: counter)
        }

        if isZIP { found.fromSafari = found.safariHistory }
        control.reportFinal(Progress(message: "\(url.lastPathComponent): Files read", completed: counter.value))
        try control.checkCancellation()
        return found
    }

    /// Files directly in the folder and in its immediate child folders.
    /// Each directory listing is one level only, so deeper folders are never
    /// visited.
    private static func collect(in folder: URL, into found: inout Found, control: Control, counter: ProgressCounter) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let root = folder.standardizedFileURL
        guard let rootValues = try? root.resourceValues(forKeys: keys),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true
        else { return }

        control.report(Progress(message: "\(root.lastPathComponent): Scanning folders", completed: counter.value))
        var files: [URL] = []
        let rootItems = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        try control.checkCancellation()
        for item in rootItems {
            try control.checkCancellation()
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            guard values.isHidden != true, values.isSymbolicLink != true,
                  item.lastPathComponent.hasPrefix(".") == false else { continue }
            if values.isDirectory == true {
                let children = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
                try control.checkCancellation()
                for child in children {
                    try control.checkCancellation()
                    guard let childValues = try? child.resourceValues(forKeys: keys),
                          childValues.isHidden != true, childValues.isSymbolicLink != true,
                          child.lastPathComponent.hasPrefix(".") == false,
                          childValues.isRegularFile == true, isImportFile(child)
                    else { continue }
                    files.append(child)
                }
                continue
            }
            if values.isRegularFile == true, isImportFile(item) { files.append(item) }
        }

        files.sort { lhs, rhs in lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) }
        for file in files {
            try control.checkCancellation()
            do {
                try take(file, relativeTo: root, into: &found, control: control, counter: counter)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A damaged or unreadable member shouldn't hide other files
                // from a folder export.
                continue
            }
        }
    }

    private static func relativePath(of file: URL, under root: URL) -> String? {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    private static func isImportFile(_ file: URL) -> Bool {
        ["html", "htm", "csv", "json"].contains(file.pathExtension.lowercased())
    }

    private static func label(for file: URL, relativeTo root: URL?) -> String {
        guard let root, let relative = relativePath(of: file, under: root) else { return file.lastPathComponent }
        return relative
    }

    private static func take(_ file: URL, relativeTo root: URL?, into found: inout Found, control: Control, counter: ProgressCounter) throws {
        try control.checkCancellation()
        let label = label(for: file, relativeTo: root)
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            if let marks = try BookmarksFile.read(file, control: control, progress: { stage, completed, total in
                control.report(Progress(message: "\(label): \(stage)", completed: completed, total: total))
            }) {
                found.bookmarks += marks
            }
        case "csv":
            let data = try readData(file, control: control) { completed, total in
                control.report(Progress(message: "\(label): Reading CSV", completed: completed, total: total))
            }
            try control.checkCancellation()
            if let text = String(data: data, encoding: .utf8) { found.passwords.append(text) }
        case "json":
            if let places = try history(in: file, control: control, counter: counter, label: label) {
                found.safariHistory = true
                found.places += places
            }
        default:
            break
        }
        counter.advance()
        control.report(Progress(message: "\(label): File complete", completed: counter.value))
    }

    /// Safari's history file: an object with "metadata" (its "data_type"
    /// says "history") and "history", one entry per page — its address, its
    /// title, when it was last seen in microseconds since 1970, and how
    /// often. The first steps of a redirect, and pages that failed to load,
    /// are left out: they aren't places anyone meant to go.
    /// Nil for a file that isn't Safari's history at all.
    private static func history(in file: URL, control: Control, counter: ProgressCounter, label: String) throws -> [Chromium.Place]? {
        let data = try readData(file, control: control) { completed, total in
            control.report(Progress(message: "\(label): Reading history", completed: completed, total: total))
        }
        try control.checkCancellation()
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (top["metadata"] as? [String: Any])?["data_type"] as? String == "history",
              let entries = top["history"] as? [[String: Any]]
        else { return nil }
        try control.checkCancellation()

        var places: [Chromium.Place] = []
        places.reserveCapacity(entries.count)
        control.report(Progress(message: "\(label): Parsing history", completed: 0, total: entries.count))
        for (index, entry) in entries.enumerated() {
            try control.checkCancellation()
            if entry["destination_url"] == nil,
               entry["latest_visit_was_load_failure"] as? Bool != true,
               let text = entry["url"] as? String, let url = URL(string: text),
               url.scheme == "http" || url.scheme == "https" {
                let stamp = (entry["time_usec"] as? NSNumber)?.doubleValue ?? 0
                let last = stamp > 0 ? Date(timeIntervalSince1970: stamp / 1_000_000) : Date()
                let count = (entry["visits_count"] as? NSNumber)?.intValue ?? 1
                places.append(Chromium.Place(url: url, title: entry["title"] as? String ?? "", count: max(1, count), last: last))
            }
            if index % 64 == 63 || index == entries.count - 1 {
                control.report(Progress(message: "\(label): Parsing history", completed: index + 1, total: entries.count))
            }
        }
        try control.checkCancellation()
        return places
    }

    /// Reads a file in bounded chunks. The caller receives byte-count progress
    /// and cancellation is checked between every read.
    static func readData(_ file: URL, control: Control, didRead: (Int, Int?) -> Void) throws -> Data {
        try control.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        var completed = 0
        let total = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        didRead(0, total)
        let chunkSize = 64 * 1024
        while true {
            try control.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            data.append(chunk)
            completed += chunk.count
            didRead(completed, total)
        }
        try control.checkCancellation()
        return data
    }

    /// The ZIP opened into a folder of its own, by the Mac's own ditto.
    /// Its child is stopped if the import is cancelled, and the temporary
    /// folder is removed on every unsuccessful path.
    private static func unzip(_ zip: URL, control: Control, counter: ProgressCounter) throws -> URL? {
        let folder = ImportFile.scratchFolder()
        var keepFolder = false
        defer {
            if !keepFolder { try? FileManager.default.removeItem(at: folder) }
        }

        try control.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        do {
            while process.isRunning {
                try control.checkCancellation()
                control.report(Progress(message: "\(zip.lastPathComponent): Extracting ZIP", completed: counter.value))
                Thread.sleep(forTimeInterval: 0.025)
            }
            process.waitUntilExit()
            try control.checkCancellation()
        } catch {
            terminate(process)
            throw error
        }
        guard process.terminationStatus == 0 else { return nil }
        keepFolder = true
        control.report(Progress(message: "\(zip.lastPathComponent): ZIP extracted", completed: counter.value))
        return folder
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    // MARK: - a Search profile, coming back in

    // Part B's half of one-click profile migration: telling a profile export
    // apart, peeking into a ZIP for one, and reading its flat folder into one
    // payload for takeSearchProfile. The format itself — manifest, prefs
    // allowlist, history rows — stays part A's (see SearchProfile); what
    // comes over and where it lands is decided there, only read here.
    nonisolated static let searchProfileExtension = "searchprofile"

    /// The panel type for the export's extension: a stand-in of Search's own,
    /// since no system type covers it.
    nonisolated static var searchProfileType: UTType {
        UTType(filenameExtension: searchProfileExtension) ?? UTType(exportedAs: "app.search.profile")
    }

    nonisolated static func isSearchProfile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == searchProfileExtension
    }

    /// Whether a .zip is a profile export rather than Safari's: a manifest
    /// with the profile's scope and format, read from a scratch folder that's
    /// gone before this returns. Runs wherever called; the caller keeps it
    /// off the main thread. Decides which reader takes the file.
    nonisolated static func isProfileZip(_ url: URL) -> Bool {
        guard let folder = try? SearchProfile.unzip(url) else { return false }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(SearchProfileManifest.self, from: data)
        else { return false }
        return manifest.scope == "profile" && manifest.format == SearchProfile.format
    }

    /// What another copy may honour, asked the same way part A asks: the rows
    /// Settings shows, plus per-site shield pauses. A file never sets what
    /// isn't here — nothing identifying this Mac, its state or its accounts.
    nonisolated static func profilePrefAllowlist() -> Set<String> {
        let indexed = Set(SettingsIndex.items.flatMap { $0.keys })
        guard !indexed.isEmpty else { return fallbackProfilePrefs }
        return indexed.union(["shield.paused"])
    }

    /// Stand-in when the index isn't there to ask, mirroring part A's: the
    /// keys this migration was scoped to.
    nonisolated static let fallbackProfilePrefs: Set<String> = [
        "search.engine", "search.custom", "search.keywords", "search.suggest",
        "tabs.newPlace", "tabs.newAfterLast", "tabs.closeGoesBack", "tabs.lazy",
        "tabs.popupWindows", "tabs.sleep", "tabs.sleep.pace", "tabs.close.after",
        "tabs.shortcuts", "tabs.address", "tabs.reading", "tabs.give", "tabs.awakeSites",
        "sidebar", "sidebar.position", "sidebar.icons", "sidebar.hides", "sidebar.roomy", "sidebar.width",
        "layout.cards",
        "shield", "shield.paused",
        "privacy.gpc", "privacy.clickIDs", "privacy.popupSites",
        "commandbar", "newtab.floating",
    ]

    /// Everything one file holds, keyed as the flat folder holds it: sessions
    /// by their old space ("session" for the first), bookmarks and history
    /// by "personal" or their old profile, pins under the keys pins.json
    /// keeps. A missing profiles.json is Personal standing alone (see
    /// SearchProfile), which needs no entry to map to.
    struct IncomingProfile {
        var manifest: SearchProfileManifest?
        var profiles: [Profile] = []
        var spaces: [Space] = []
        var sessions: [String: Session.Shape] = [:]
        var pinsBySpace: [String: [PinDef]] = [:]
        var pinsShared: [String: [PinDef]] = [:]
        var bookmarks: [String: [Bookmark]] = [:]
        var histories: [String: [History.Entry]] = [:]
        var prefs: [String: AnyCodable] = [:]
        var extensions: [String] = []
    }

    /// The folder's files into a payload, section by section: one unreadable
    /// section never hides the rest.
    nonisolated static func readIncomingProfile(in folder: URL) -> IncomingProfile {
        func data(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(name)) }
        func decode<T: Decodable>(_ name: String) -> T? { data(name).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        var out = IncomingProfile()
        out.manifest = decode("manifest.json")
        if let profiles: [Profile] = decode("profiles.json") { out.profiles = profiles }
        if let spaces: [Space] = decode("spaces.json") { out.spaces = spaces }
        if let raw = data("pins.json") {
            if let decoded = Pins.decode(raw) {
                for (id, defs) in decoded.bySpace { out.pinsBySpace[id.uuidString] = defs }
            }
            for (id, defs) in Pins.sharedLists(raw) {
                out.pinsShared[id == Profile.personalID ? Pins.sharedKey : Pins.sharedKey + ":" + id.uuidString] = defs
            }
        }
        if let prefs: [String: AnyCodable] = decode("prefs.json") { out.prefs = prefs }
        if let ids: [String] = decode("installed.json") { out.extensions = ids }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return out }
        for name in names where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            if stem == "session" {
                if let shape: Session.Shape = decode(name) { out.sessions[Space.firstID.uuidString] = shape }
            } else if stem.hasPrefix("session-"), UUID(uuidString: String(stem.dropFirst(8))) != nil {
                if let shape: Session.Shape = decode(name) { out.sessions[String(stem.dropFirst(8))] = shape }
            } else if stem == "bookmarks" {
                if let nodes: [Bookmark] = decode(name) { out.bookmarks["personal"] = nodes }
            } else if stem.hasPrefix("bookmarks-"), UUID(uuidString: String(stem.dropFirst(10))) != nil {
                if let nodes: [Bookmark] = decode(name) { out.bookmarks[String(stem.dropFirst(10))] = nodes }
            } else if stem == "history" {
                if let rows: [History.Entry] = decode(name) { out.histories["personal"] = rows }
            } else if stem.hasPrefix("history-"), UUID(uuidString: String(stem.dropFirst(8))) != nil {
                if let rows: [History.Entry] = decode(name) { out.histories[String(stem.dropFirst(8))] = rows }
            }
        }
        return out
    }

    // (packing is part A's: SearchProfile.zip over collectCurrentProfile)
}
