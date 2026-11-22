import AppKit
import Combine
import SystemConfiguration

// Sync with your other Macs, through a folder you choose.
//
// THE DECISION (17 Nov 2026): a folder, not iCloud's own APIs.
//   - CloudKit and NSUbiquitousKeyValueStore need an iCloud container and
//     the com.apple.developer.icloud-* / ubiquity-kvstore entitlements, tied
//     to a provisioning profile. Search.entitlements has none of them (only
//     camera, microphone, location and contacts); Search.passkeys.entitlements
//     adds only the web-browser passkey entitlement and its identifiers; and
//     build.sh signs a Developer ID build with one or the other. Taking that
//     route means a new Apple container, a new profile in every build and a
//     dependency on Apple's servers for a browser that has none of its own.
//   - The app is not sandboxed (no com.apple.security.app-sandbox), so a
//     folder chosen in an open panel is simply a path: no security-scoped
//     bookmark to keep.
//   So: Search writes small files into a folder the user picks — in iCloud
//   Drive, Dropbox, a shared disk — and whatever moves that folder between
//   Macs does the rest. No account, no server, nothing of ours in between.
//
// Off unless turned on (Settings › General › Sync with your other Macs).
//
// In the folder, "Search Sync/<scope>/<device>.json": one file per Mac per
// scope, written only by that Mac, so two Macs never write the same file.
// The scopes: "app" for the settings below, and "profile-<id>" for each
// profile's spaces, pins and bookmarks — a profile's never mixes with
// another's. Each file is the whole merged view as that Mac last had it,
// item by item with stamps and tombstones (see SyncMerge.swift for the
// rules and the format).
//
// What syncs: spaces (name, colour or gradient, icon, order, and whether a
// space has sign-ins of its own — never the sign-ins themselves, its cookies,
// tabs or downloads folder), pins (each space's and the ones every space shows,
// their letter, name, page and order, and the folder among the pinned rows
// each is in), each space's pin folders (name, which one holds which, a live
// folder's feed; whether one is folded and a live folder's posts stay on
// each Mac), bookmarks, and the settings listed in SyncSettings. What never does: history, passwords, cookies and site data,
// open tabs that aren't pinned, tab groups (they hold open tabs), private
// windows, extensions, the downloads folder, window sizes.
//
// Profiles: Personal is the same profile on every Mac. Another profile syncs
// with the profile of the same id on another Mac; one made separately on each
// Mac has a different id and stays apart (making them across Macs is still
// to come).
//
// A pass runs a moment after anything synced changes here, when a file in
// the folder changes, every half minute, and when Search comes forward. It
// reads a handful of small files and writes this Mac's only if it changed.

enum SyncSettings {
    struct Setting {
        let key: String
        let read: @MainActor (Preferences) -> String?
        let write: @MainActor (Preferences, String) -> Void
    }

    /// The settings that follow you: how Search looks and behaves, not what
    /// belongs to this Mac (folders, window sizes, passwords, extensions).
    @MainActor static let all: [Setting] = [
        raw("look", \.look),
        raw("glyph", \.glyph),
        raw("search.engine", \.engine),
        coded("search.custom", \.customEngine),
        coded("search.suggest", \.engineSuggests),
        coded("search.keywords", \.keywords),
        coded("spaces", \.usesSpaces),
        coded("pins.list", \.listsPins),
        coded("pins.home", \.pinsGoHome),
        raw("tabs.close.after", \.tabLife),
        raw("tabs.newPlace", \.newTabPlace),
        coded("tabs.shortcuts", \.showsTabShortcuts),
        coded("shield", \.shielded),
        coded("privacy.clickIDs", \.removesClickIDs),
        coded("privacy.gpc", \.sendsPrivacySignal),
        coded("bookmarks.bar", \.bookmarksBar),
        coded("bookmarks.side", \.bookmarksInSidebar),
        coded("quit.confirm", \.confirmsQuit),
    ]

    /// Their keys, readable anywhere (SyncItems.understood).
    static let known: Set<String> = [
        "look", "glyph", "search.engine", "search.custom", "search.suggest", "search.keywords", "spaces",
        "pins.list", "pins.home", "tabs.close.after", "tabs.newPlace", "tabs.shortcuts", "shield",
        "privacy.clickIDs", "privacy.gpc", "bookmarks.bar", "quit.confirm",
    ]

    private static func coded<T: Codable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, T>) -> Setting {
        Setting(key: key, read: { SyncMerge.text($0[keyPath: path]) }, write: { prefs, text in
            guard let value = SyncMerge.value(T.self, text), prefs[keyPath: path] != value else { return }
            prefs[keyPath: path] = value
        })
    }

    private static func raw<T: RawRepresentable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, T>) -> Setting
        where T.RawValue: Codable {
        Setting(key: key, read: { SyncMerge.text($0[keyPath: path].rawValue) }, write: { prefs, text in
            guard let raw = SyncMerge.value(T.RawValue.self, text), let value = T(rawValue: raw),
                  prefs[keyPath: path] != value else { return }
            prefs[keyPath: path] = value
        })
    }

    @MainActor static func items(_ prefs: Preferences) -> [String: String] {
        var out: [String: String] = [:]
        for setting in all { out["set:" + setting.key] = setting.read(prefs) }
        return out
    }

    @MainActor static func apply(_ live: [String: String], to prefs: Preferences) {
        for setting in all {
            if let text = live["set:" + setting.key] { setting.write(prefs, text) }
        }
    }
}

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    /// The folder chosen; nil while sync is off.
    @Published private(set) var folder: URL?
    @Published private(set) var lastSynced: Date?
    /// Why the last pass couldn't run, for Settings.
    @Published private(set) var problem: String?
    /// The other Macs whose files were read, by name.
    @Published private(set) var others: [String] = []

    var on: Bool { folder != nil }

    nonisolated static let folderKey = "sync.folder"
    nonisolated static let deviceKey = "sync.device"
    /// The folder Search makes inside the one chosen.
    nonisolated static let inside = "Search Sync"

    /// This Mac's id in the folder: made once, kept with the settings, so
    /// each test world (SEARCH_PROBE=<name>) is a Mac of its own.
    let device: String = {
        if let kept = Store.settings.string(forKey: Sync.deviceKey), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        Store.settings.set(made, forKey: Sync.deviceKey)
        return made
    }()

    private var bag: Set<AnyCancellable> = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var running = false

    private init() {}

    // MARK: - on and off

    /// At launch: carries on if it was on.
    func start() {
        guard folder == nil, let path = Store.settings.string(forKey: Sync.folderKey), !path.isEmpty else { return }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        begin()
    }

    /// The switch turned on: a folder asked for, then the first pass.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder your Macs share, in iCloud Drive or Dropbox for example. Turn on sync with the same folder in Search on each Mac."
        panel.prompt = "Sync Here"
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: drive.path) { panel.directoryURL = drive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        turnOn(url)
    }

    func turnOn(_ url: URL) {
        stop()
        // Always as a Mac joining: what it agreed with another folder, or
        // with this one long ago, says nothing about what is there now.
        for scope in scopes { try? FileManager.default.removeItem(at: Sync.stateFile(scope)) }
        Store.settings.set(url.path, forKey: Sync.folderKey)
        folder = url
        begin()
    }

    /// Off: this Mac's files leave the folder and what it had agreed is
    /// forgotten, so turning it on again starts as a Mac joining. What is in
    /// the browser stays as it is.
    func turnOff() {
        if let root {
            for scope in scopes {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(scope).appendingPathComponent(device + ".json"))
            }
        }
        for scope in scopes { try? FileManager.default.removeItem(at: Sync.stateFile(scope)) }
        stop()
        Store.settings.removeObject(forKey: Sync.folderKey)
        folder = nil
        lastSynced = nil
        problem = nil
        others = []
    }

    private func begin() {
        let poke: (Notification) -> Void = { [weak self] _ in self?.schedule() }
        for name in [Spaces.changed, Pins.changed, Bookmarks.saved, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink(receiveValue: poke).store(in: &bag)
        }
        Shared.prefs.objectWillChange.sink { [weak self] in self?.schedule() }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pass() }
        }
        schedule(after: 1)
    }

    private func stop() {
        bag.removeAll()
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        for watcher in watchers.values { watcher.cancel() }
        watchers = [:]
    }

    /// A pass a moment from now; anything else that changes meanwhile joins it.
    private func schedule(after delay: TimeInterval = 2) {
        guard on, !running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pass() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - where

    private var root: URL? { folder?.appendingPathComponent(Sync.inside, isDirectory: true) }

    private var scopes: [String] { ["app"] + Profiles.shared.list.map { Sync.scope($0.id) } }

    nonisolated static func scope(_ profile: UUID) -> String { "profile-" + profile.uuidString }

    /// What this Mac last agreed with the folder, per scope: in Search's own
    /// folder, never in the shared one.
    nonisolated static func stateFile(_ scope: String) -> URL { Store.file("sync-\(scope).json") }

    // MARK: - a pass

    func pass() {
        guard let folder, let root, !running else { return }
        pending?.cancel()
        pending = nil
        // A folder not there — a disk not plugged in, Dropbox not running —
        // is no reason to think everything was deleted: nothing happens.
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            problem = "The folder isn\u{2019}t there"
            return
        }
        running = true
        defer { running = false }
        var seen = Set<String>()
        let prefs = Shared.prefs
        seen.formUnion(run(scope: "app", in: root, current: { _ in SyncSettings.items(prefs) }, apply: { live in
            SyncSettings.apply(live, to: prefs)
        }))
        for profile in Profiles.shared.list {
            seen.formUnion(run(scope: Sync.scope(profile.id), in: root,
                               current: { Sync.items(of: profile.id, base: $0) },
                               apply: { Sync.apply($0, to: profile) }))
        }
        others = seen.sorted()
        if problem == nil { lastSynced = Date() }
    }

    /// One scope: stamped, merged with the other Macs' files, applied, and
    /// written. The names of the other Macs read.
    private func run(scope: String, in root: URL, current: ([String: String]) -> [String: String],
                     apply: ([String: String]) -> Void) -> [String] {
        let files = FileManager.default
        let folder = root.appendingPathComponent(scope, isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            problem = "Search can\u{2019}t write in that folder"
            return []
        }
        problem = nil
        watch(folder, scope: scope)
        let stateURL = Sync.stateFile(scope)
        let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: SyncEntry].self, from: $0) }
        let base = state ?? [:]
        let now = Date().timeIntervalSince1970
        var theirs: [[String: SyncEntry]] = []
        var names: [String] = []
        let own = folder.appendingPathComponent(device + ".json")
        for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            // iCloud Drive keeps a file it has let go of as ".<name>.icloud",
            // or as a file with nothing in it yet: asked for, it is there
            // for a later pass. Read now, the read would wait for it.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                try? files.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard name.hasSuffix(".json"), url != own else { continue }
            if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
               status != .current {
                try? files.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url), data.count < 32 << 20,
                  let file = SyncMerge.decode(data, scope: scope), file.device != device
            else { continue }
            theirs.append(file.items)
            names.append(file.name ?? "Another Mac")
        }

        // A Mac joining a folder other Macs already use takes what they
        // agreed where both have something; the first Mac there sets it.
        let here = current(SyncMerge.live(base))
        let merged = SyncMerge.pass(current: here, base: state, theirs: theirs, device: device, now: now,
                                    understood: SyncItems.understood)
        let live = SyncMerge.live(merged)
        if live != here { apply(live) }
        if merged != base, let data = try? JSONEncoder().encode(merged) {
            try? files.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
        // This Mac's file, only when it says something new.
        let written = (try? Data(contentsOf: own)).flatMap { SyncMerge.decode($0, scope: scope) }
        if written?.items != merged || written?.name != Sync.macName {
            let file = SyncFile(format: SyncMerge.format, device: device, name: Sync.macName, scope: scope, written: now, items: merged)
            if let data = SyncMerge.encode(file) { try? data.write(to: own, options: .atomic) }
        }
        return names
    }

    /// A file of another Mac arriving or changing: a pass soon.
    private func watch(_ folder: URL, scope: String) {
        guard watchers[scope] == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[scope] = source
    }

    nonisolated static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: - a profile's things

    /// A profile's spaces, pins and bookmarks as items.
    static func items(of profile: UUID, base: [String: String]) -> [String: String] {
        let spaces = Spaces.read(profile: profile)
        var bySpace: [UUID: [PinDef]] = [:]
        var folders: [UUID: [PinFolder]] = [:]
        for space in spaces {
            let defs = Pins.defs(space.id)
            if !defs.isEmpty { bySpace[space.id] = defs }
            let kept = PinFolders.folders(space.id)
            if !kept.isEmpty { folders[space.id] = kept }
        }
        var out = SyncItems.spaces(spaces, base: base)
        out.merge(SyncItems.pins(bySpace: bySpace, shared: Pins.shared(profile), base: base)) { a, _ in a }
        out.merge(SyncItems.pinFolders(folders)) { a, _ in a }
        out.merge(SyncItems.bookmarks(Profiles.bookmarks(profile).roots)) { a, _ in a }
        return out
    }

    /// The merged items made so: spaces first, so pins have their space;
    /// then each space's folders, so pins land in theirs at once.
    static func apply(_ live: [String: String], to profile: Profile) {
        let id = profile.id
        let home = profile.home
        let local = Spaces.read(profile: id)
        let spaces = SyncItems.applySpaces(live, to: local, profile: id, home: home)
        for gone in local where !spaces.contains(where: { $0.id == gone.id }) {
            removeSpace(gone, profile: id)
        }
        if spaces != Spaces.read(profile: id) {
            // The order is the one merged, wherever the home is in it.
            Store.settings.set(true, forKey: "spaces.orderKept")
            Spaces.write(spaces, profile: id)
        }

        for space in spaces {
            let local = PinFolders.folders(space.id)
            let folders = PinTree.sanitized(SyncItems.applyPinFolders(live, space: space.id, local: local))
            if folders != local { PinFolders.set(space.id, folders, from: nil) }
        }

        var localPins: [UUID: [PinDef]] = [:]
        for space in spaces { localPins[space.id] = Pins.defs(space.id) }
        let pins = SyncItems.applyPins(live, spaces: spaces.map(\.id), local: localPins, localShared: Pins.shared(id))
        Pins.adopt(pins.bySpace, in: spaces.map(\.id), shared: pins.shared, profile: id)

        Profiles.bookmarks(id).adopt(SyncItems.applyBookmarks(live))
    }

    /// A space deleted on another Mac: as Delete Space does here — its tabs,
    /// its pins, and, for one with sign-ins of its own, those too.
    private static func removeSpace(_ space: Space, profile: UUID) {
        if let window = Browsers.all.first(where: { $0.profileID == profile && !$0.isPopup && $0.spaces.contains { $0.id == space.id } }) {
            window.deleteSpace(space.id)
            return
        }
        Spaces.write(Spaces.read(profile: profile).filter { $0.id != space.id }, profile: profile)
        Session.erase(space: space.id)
        Pins.forget(space.id)
        if space.sharesSignIns != true { Spaces.erase(space.id) }
    }

    // MARK: - for Settings

    /// Where, and when last, in a line.
    var summary: String {
        guard let folder else { return "" }
        var place = folder.path
        let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        if place.hasPrefix(drive) { place = "iCloud Drive" + place.dropFirst(drive.count) }
        place = place.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if let problem { return "\(place): \(problem.lowercased())" }
        guard let lastSynced else { return place }
        let when = RelativeDateTimeFormatter().localizedString(for: lastSynced, relativeTo: Date())
        let with = others.isEmpty ? "no other Mac yet" : others.joined(separator: ", ")
        return "\(place) · \(with) · \(when)"
    }
}
