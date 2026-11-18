import AppKit
import CloudKit
import Combine

// Sync with iCloud: the same open tabs, pins, spaces, bookmarks and a few
// settings on this Mac, Search on the iPhone, and other Macs, through the
// person's own iCloud. Off until turned on (Settings › General › Sync with
// iCloud). The rules are SYNC.md in the Search-iOS repository, followed to
// the letter: change it there and here, or not at all.
//
//   - CloudKit container iCloud.com.officecommun.search, the private
//     database, one zone "Search", one record type "Item". CKSyncEngine.
//   - A record's name says what it holds: device.<uuid> (one device's open
//     tabs), pins.<space>, spaces, bookmarks, settings. Its JSON goes in
//     encryptedValues["data"]; "at" is when the device that wrote it changed
//     it. No other field, ever.
//   - The latest write wins, record by record. Joining merges: the first
//     fetch comes before anything goes up, pins and bookmarks here are added
//     to iCloud's, and iCloud's settings win. Nothing is sent that is the
//     same JSON as the last one written or read (no echo).
//   - A record is written again over the last version read: this Mac's own
//     fields as it has them, anyone else's riding along untouched.
//   - Search's zone deleted (Delete Search's data from iCloud, anywhere):
//     sync turns off here and says why; nothing is put back.
//
// Only the Personal profile syncs: its spaces, each space's own pins, its
// bookmarks; the pins every space shows (Settings › Spaces & Pins) stay on
// this Mac. Open tabs go up as one list, every window's of every space,
// never a private tab, never a pinned one (pins travel as pins). History,
// passwords, cookies and site data never sync.
//
// The folder sync (Sync.swift, "Sync with your other Macs") is the other way
// to do part of this. The two are never on together: each switch is off
// limits while the other is on, so they can't take turns undoing each
// other's changes.
//
// CloudKit needs the iCloud entitlements, which need a provisioning profile
// that carries the container. build.sh signs with them only when the
// profile does; a build without them says so in Settings and never touches
// CloudKit (creating a CKContainer there would end the app). Test runs
// (SEARCH_PROBE) never do either.

// MARK: - the shapes SYNC.md adds to the Mac's own (PinDef, Bookmark, Space)

/// One device's open tabs, as the other devices see them.
struct DeviceTabs: Codable, Equatable {
    struct Page: Codable, Equatable, Hashable {
        var url: String
        var title: String
    }

    var name: String
    /// "ios" or "macos".
    var platform: String
    var at: Date
    var tabs: [Page]
}

/// The settings every device shares, and only these.
struct SharedSettings: Codable, Equatable {
    /// Engine's raw value.
    var engine: String?
    /// The custom engine's template.
    var custom: String?
    /// Look's raw value.
    var look: String?
}

// MARK: - what is kept between launches

/// What sync remembers: when each record last changed, its last JSON (in
/// this app's canonical encoding), the server's fields for each record, and
/// the engine's place. Pure: the rules live here and are tested here.
struct ICloudLedger: Codable, Equatable {
    var device = UUID().uuidString
    /// The first full fetch is done: from then on, what changes here goes up.
    var joined = false
    var at: [String: Date] = [:]
    var values: [String: Data] = [:]
    /// Each record's system fields, archived (CKRecord.encodeSystemFields),
    /// so a save isn't taken for a stranger's.
    var fields: [String: Data] = [:]
    /// CKSyncEngine.State.Serialization, encoded.
    var state: Data?

    var deviceKey: String { "device." + device }

    /// Something here, offered: true when it differs from the last JSON
    /// written or read, and is now stamped and due to go up. Nothing before
    /// the first fetch.
    mutating func offer(_ key: String, _ data: Data, now: Date) -> Bool {
        guard joined, values[key] != data else { return false }
        values[key] = data
        at[key] = now
        return true
    }

    enum Arrival: Equatable {
        /// Ours is newer: ignored, and ours goes up again.
        case stale
        /// Taken: kept, and applied here.
        case taken
    }

    /// A record from iCloud. `canonical` is its JSON as this app writes it.
    mutating func arrive(_ key: String, canonical: Data, at stamp: Date) -> Arrival {
        if let ours = at[key], ours > stamp, values[key] != nil { return .stale }
        values[key] = canonical
        at[key] = stamp
        return .taken
    }

    /// A save refused because the server has another version: true when
    /// ours is the newer one and goes up again over it.
    func oursWins(_ key: String, serverAt: Date) -> Bool {
        guard let ours = at[key], values[key] != nil else { return false }
        return ours > serverAt
    }

    mutating func removed(_ key: String) {
        values[key] = nil
        at[key] = nil
        fields[key] = nil
    }

    /// Everything forgotten but which device this is.
    func fresh() -> ICloudLedger { ICloudLedger(device: device) }
}

// MARK: - the rules, worked out

enum ICloudMerge {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data? { try? encoder.encode(value) }

    /// What a record holds, for passing through what this Mac doesn't know.
    enum Shape {
        case device, pins, bookmarks, spaces, settings
    }

    /// The fields each shape's Mac type writes: its own, which it sets or
    /// clears. Any other field in a record is someone else's and rides
    /// along untouched (SYNC.md, "Fields a device doesn't know ride along").
    /// ICloudSyncTests checks these against the types themselves.
    static let known: [Shape: Set<String>] = [
        .pins: ["id", "letter", "home", "title", "name", "listed", "folder"],
        .bookmarks: ["id", "title", "url", "children"],
        .spaces: ["id", "name", "colour", "icon", "sharesSignIns", "downloads", "profile", "gradient", "strength"],
        .settings: ["engine", "custom", "look"],
    ]

    /// JSON as both apps compare it: sorted keys, by one writer, so what was
    /// read and what goes up are alike byte for byte when they say the same.
    static func canonical(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    /// This Mac's value as it goes up: its own fields as it has them, laid
    /// over the last version written or read, so fields it doesn't know
    /// stay as they were. A pin, a bookmark or a space is matched by id;
    /// a bookmark wherever it now is in the tree.
    static func outgoing<T: Encodable>(_ value: T, over last: Data?, shape: Shape) -> Data? {
        guard let data = encode(value) else { return nil }
        guard shape != .device, let keys = known[shape], let last,
              let before = try? JSONSerialization.jsonObject(with: last),
              let mine = try? JSONSerialization.jsonObject(with: data)
        else { return canonical(data) }

        func keep(_ mine: [String: Any], _ before: [String: Any]?) -> [String: Any] {
            var out = mine
            for (key, value) in before ?? [:] where !keys.contains(key) { out[key] = value }
            return out
        }
        func byID(_ list: Any?) -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            func walk(_ nodes: [[String: Any]]) {
                for node in nodes {
                    if let id = node["id"] as? String { out[id] = node }
                    if shape == .bookmarks, let children = node["children"] as? [[String: Any]] { walk(children) }
                }
            }
            walk(list as? [[String: Any]] ?? [])
            return out
        }
        let merged: Any
        switch shape {
        case .settings:
            merged = keep(mine as? [String: Any] ?? [:], before as? [String: Any])
        case .pins, .spaces, .bookmarks:
            let old = byID(before)
            func each(_ nodes: [[String: Any]]) -> [[String: Any]] {
                nodes.map { node in
                    var out = keep(node, (node["id"] as? String).flatMap { old[$0] })
                    if shape == .bookmarks, let children = node["children"] as? [[String: Any]] { out["children"] = each(children) }
                    return out
                }
            }
            merged = each(mine as? [[String: Any]] ?? [])
        case .device:
            merged = mine
        }
        guard let out = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return canonical(data) }
        return out
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }

    /// The tabs that go up: ordinary web pages, no pin, never a private tab,
    /// each address once.
    static func pages(_ tabs: [(url: URL?, title: String, shy: Bool, pinned: Bool)]) -> [DeviceTabs.Page] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard !tab.shy, !tab.pinned, let url = tab.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted
            else { return nil }
            return DeviceTabs.Page(url: url.absoluteString, title: tab.title)
        }
    }

    /// Joining: iCloud's pins, then each of ours not already there by id or
    /// by address.
    static func union(pins theirs: [PinDef], _ ours: [PinDef]) -> [PinDef] {
        theirs + ours.filter { mine in !theirs.contains { $0.id == mine.id || $0.home == mine.home } }
    }

    /// Joining: iCloud's bookmarks, then ours that aren't there by id or by
    /// address. A folder of ours that isn't there comes with only what in
    /// it isn't there either, and not at all once that is nothing.
    static func union(bookmarks theirs: [Bookmark], _ ours: [Bookmark]) -> [Bookmark] {
        func flat(_ nodes: [Bookmark]) -> [Bookmark] { nodes.flatMap { [$0] + flat($0.children ?? []) } }
        let known = flat(theirs)
        let ids = Set(known.map(\.id))
        let urls = Set(known.compactMap(\.url))
        func missing(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                guard !ids.contains(node.id) else { return nil }
                if let url = node.url { return urls.contains(url) ? nil : node }
                var folder = node
                folder.children = missing(node.children ?? [])
                return (folder.children ?? []).isEmpty && !(node.children ?? []).isEmpty ? nil : folder
            }
        }
        return theirs + missing(ours)
    }

    /// Joining: iCloud's spaces, then ours it doesn't have.
    static func union(spaces theirs: [Space], _ ours: [Space]) -> [Space] {
        theirs + ours.filter { mine in !theirs.contains { $0.id == mine.id } }
    }

    /// A space as it goes up: nothing only this Mac's (its downloads folder)
    /// and no profile (only Personal's go).
    static func forCloud(_ space: Space) -> Space {
        var space = space
        space.downloads = nil
        space.profile = nil
        return space
    }

    /// The spaces iCloud has, made this Mac's: each one's downloads folder,
    /// and whether it has sign-ins of its own (fixed once it is made: a
    /// store can't change under its open tabs), kept from here; the first
    /// space never taken away.
    static func adopt(spaces theirs: [Space], local: [Space]) -> [Space] {
        var out = theirs.map { space -> Space in
            var space = forCloud(space)
            if let mine = local.first(where: { $0.id == space.id }) {
                space.downloads = mine.downloads
                space.sharesSignIns = mine.sharesSignIns
            }
            return space
        }
        if !out.contains(where: \.isFirst) {
            out.insert(local.first(where: \.isFirst) ?? Space.first(), at: 0)
        }
        return out
    }

    /// Pins from a device that doesn't know rows or pin folders (the
    /// iPhone's PinDef has neither): the ones here keep theirs, so a change
    /// made there doesn't undo how this Mac shows them. Only when nothing in
    /// what came says either.
    static func carryRows(_ incoming: [PinDef], raw: Data, local: [PinDef]) -> [PinDef] {
        guard let list = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]],
              !list.contains(where: { $0["listed"] != nil || $0["folder"] != nil })
        else { return incoming }
        return incoming.map { def in
            guard let mine = local.first(where: { $0.id == def.id }) else { return def }
            var def = def
            def.listed = mine.listed
            def.folder = mine.folder
            return def
        }
    }

    @MainActor static func settings(_ prefs: Preferences) -> SharedSettings {
        SharedSettings(engine: prefs.engine.rawValue, custom: prefs.customEngine, look: prefs.look.rawValue)
    }

    /// iCloud's settings here: only the three, and only values this build
    /// knows.
    @MainActor static func apply(_ settings: SharedSettings, to prefs: Preferences) {
        if let raw = settings.engine, let engine = Engine(rawValue: raw), engine != prefs.engine { prefs.engine = engine }
        if let custom = settings.custom, custom != prefs.customEngine { prefs.customEngine = custom }
        if let raw = settings.look, let look = Look(rawValue: raw), look != prefs.look { prefs.look = look }
    }
}

// MARK: - the two sides it stands between

/// CloudKit, or a stand-in for it in the tests.
@MainActor
protocol ICloudEngine: AnyObject {
    func save(_ keys: [String])
    func delete(_ keys: [String])
    /// Everything new in iCloud: arrives through ICloudSync.arrived.
    func fetch() async throws
    func send() async throws
    /// Search's zone, gone from iCloud for every device.
    func eraseZone() async throws
    func account() async -> ICloudSync.Account
    func close()
}

/// What sync reads and changes on this Mac, or a stand-in in the tests.
@MainActor
protocol ICloudLocal: AnyObject {
    var deviceName: String { get }
    func openTabs() -> [DeviceTabs.Page]
    func spaces() -> [Space]
    /// `removing`: spaces here and not in `spaces` are deleted, as Delete
    /// Space does.
    func adopt(spaces: [Space], removing: Bool)
    func pins(_ space: UUID) -> [PinDef]
    func adopt(pins: [PinDef], space: UUID)
    func bookmarks() -> [Bookmark]
    func adopt(bookmarks: [Bookmark])
    func settings() -> SharedSettings
    func adopt(settings: SharedSettings)
}

// MARK: - sync

@MainActor
final class ICloudSync: ObservableObject {
    static let shared = ICloudSync(
        local: MacSide(),
        defaults: Store.settings,
        file: Store.file("icloud.json"),
        // Never in a test run, and only in a build signed for it.
        available: !Store.testing && ICloudSync.entitled,
        makeEngine: { owner, state in CloudKitEngine(owner: owner, state: state) }
    )

    nonisolated static let containerID = "iCloud.com.officecommun.search"
    nonisolated static let zoneName = "Search"
    nonisolated static let recordType = "Item"
    nonisolated static let onKey = "icloud.sync"
    /// Why sync turned itself off, for the setting's line until it is
    /// turned on again.
    nonisolated static let offKey = "icloud.off"

    enum Account: Equatable {
        case unknown, signedIn, signedOut, restricted
    }

    /// Turned on in Settings.
    @Published private(set) var on: Bool
    /// The other devices' open tabs, by device id.
    @Published private(set) var others: [String: DeviceTabs] = [:]
    @Published private(set) var lastSynced: Date?
    @Published private(set) var problem: String?
    @Published private(set) var account: Account = .unknown

    /// This build can: signed with the iCloud entitlements, not a test run.
    let available: Bool

    private(set) var ledger = ICloudLedger()
    private(set) var engine: ICloudEngine?
    private let local: ICloudLocal
    private let defaults: UserDefaults
    private let file: URL?
    private let makeEngine: (ICloudSync, Data?) -> ICloudEngine
    private var bag: Set<AnyCancellable> = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var joining = false
    private var ticks = 0

    init(local: ICloudLocal, defaults: UserDefaults, file: URL?, available: Bool,
         makeEngine: @escaping (ICloudSync, Data?) -> ICloudEngine) {
        self.local = local
        self.defaults = defaults
        self.file = file
        self.available = available
        self.makeEngine = makeEngine
        on = defaults.bool(forKey: ICloudSync.onKey)
    }

    /// Anything running, waiting or listening: nothing while it's off.
    var isScheduled: Bool { engine != nil || timer != nil || pending != nil || !bag.isEmpty }

    var joined: Bool { ledger.joined }

    /// The running process's own signature, as for passkeys
    /// (Preferences.entitledToPasskeys): the container, with CloudKit.
    nonisolated static var entitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return ((containers as? [String]) ?? []).contains(containerID)
            && ((services as? [String]) ?? []).contains("CloudKit")
    }

    // MARK: on and off

    /// At launch: carries on if it was on.
    func start() {
        guard on, available, engine == nil, !Sync.shared.on else { return }
        ledger = load() ?? ledger.fresh()
        begin()
    }

    /// The switch turned on: always as a device joining.
    func turnOn() {
        guard available, !on, !Sync.shared.on else { return }
        on = true
        defaults.set(true, forKey: ICloudSync.onKey)
        defaults.removeObject(forKey: ICloudSync.offKey)
        ledger = ledger.fresh()
        save()
        begin()
    }

    /// Off: this device's tabs leave the others; everything else stays, in
    /// iCloud and here.
    func turnOff() {
        guard on else { return }
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        let engine = self.engine
        stop()
        if let engine, ledger.joined {
            engine.delete([ledger.deviceKey])
            Task { try? await engine.send(); engine.close() }
        } else {
            engine?.close()
        }
        ledger = ledger.fresh()
        save()
        others = [:]
        lastSynced = nil
        problem = nil
    }

    /// Everything Search keeps in iCloud, gone, for every device; sync off
    /// here. What is on each device stays.
    func erase() {
        guard let engine else { return }
        stop()
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        Task {
            do { try await engine.eraseZone() } catch { self.problem = ICloudSync.say(error) }
            engine.close()
        }
        ledger = ledger.fresh()
        save()
        others = [:]
        lastSynced = nil
    }

    private func begin() {
        engine = makeEngine(self, ledger.state)
        let poke: (Notification) -> Void = { [weak self] _ in self?.schedule() }
        for name in [Spaces.changed, Pins.changed, Bookmarks.saved] {
            NotificationCenter.default.publisher(for: name).sink(receiveValue: poke).store(in: &bag)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        Shared.prefs.objectWillChange.sink { [weak self] in self?.schedule() }.store(in: &bag)
        // Tabs open and close without telling anyone: looked at every half
        // minute, sent only when the list differs. iCloud asked again every
        // five.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                if self.ticks % 10 == 0 { self.refresh() } else { self.publish() }
            }
        }
        // Joined before (a relaunch): what changed meanwhile, both ways.
        // Otherwise the first fetch, then the merge.
        Task {
            if self.ledger.joined {
                self.account = await self.engine?.account() ?? .unknown
                self.refresh()
                self.publish()
            } else {
                await self.join()
            }
        }
    }

    private func stop() {
        bag.removeAll()
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        engine = nil
        joining = false
    }

    private func schedule(after delay: TimeInterval = 2) {
        guard engine != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.publish()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Back in front, or now and then: anything new from the other devices.
    func refresh() {
        guard let engine else { return }
        guard ledger.joined else { Task { await join() }; return }
        Task {
            do {
                try await engine.fetch()
                self.synced()
            } catch {
                self.problem = ICloudSync.say(error)
            }
        }
    }

    /// The first fetch, then what is here goes up, merged. A fetch that
    /// fails leaves it unjoined, to try again: nothing is written over
    /// before iCloud has been read.
    func join() async {
        guard let engine, !ledger.joined, !joining else { return }
        joining = true
        defer { joining = false }
        account = await engine.account()
        guard account == .signedIn else {
            problem = account == .restricted ? "iCloud is restricted on this Mac" : nil
            return
        }
        do {
            try await engine.fetch()
        } catch {
            problem = ICloudSync.say(error)
            return
        }
        guard self.engine === engine else { return }
        // What came, merged with what is here: spaces first, so pins have
        // their space.
        let keys = ledger.values.keys.sorted { order($0) < order($1) }
        for key in keys { apply(key, joining: true) }
        ledger.joined = true
        problem = nil
        synced()
        save()
        publish()
    }

    private func order(_ key: String) -> Int {
        key == "spaces" ? 0 : key.hasPrefix("pins.") ? 1 : 2
    }

    // MARK: what changes here

    /// Everything this Mac has, offered: only what differs goes up.
    func publish() {
        guard engine != nil, ledger.joined else { return }
        let now = Date()
        var due: [String] = []
        // The tabs, stamped only when the list itself changed: the stamp in
        // the JSON would otherwise make every look a change.
        let pages = local.openTabs()
        let last = ledger.values[ledger.deviceKey].flatMap { ICloudMerge.decode(DeviceTabs.self, $0) }
        if last?.tabs != pages || last?.name != local.deviceName || last?.platform != "macos",
           let data = ICloudMerge.outgoing(DeviceTabs(name: local.deviceName, platform: "macos", at: now, tabs: pages),
                                           over: nil, shape: .device),
           ledger.offer(ledger.deviceKey, data, now: now) {
            due.append(ledger.deviceKey)
        }
        let spaces = local.spaces()
        func put<T: Encodable>(_ key: String, _ value: T, _ shape: ICloudMerge.Shape) {
            if let data = ICloudMerge.outgoing(value, over: ledger.values[key], shape: shape),
               ledger.offer(key, data, now: now) { due.append(key) }
        }
        put("spaces", spaces.map(ICloudMerge.forCloud), .spaces)
        for space in spaces { put("pins." + space.id.uuidString, local.pins(space.id), .pins) }
        put("bookmarks", local.bookmarks(), .bookmarks)
        put("settings", local.settings(), .settings)
        guard !due.isEmpty else { return }
        save()
        engine?.save(due)
    }

    // MARK: what comes in

    /// A record fetched from iCloud, by the engine.
    func arrived(_ key: String, data: Data, at stamp: Date, fields: Data?) {
        if let fields { ledger.fields[key] = fields }
        guard let canonical = canonical(key, data) else { save(); return }
        guard ledger.joined else {
            // Before the first fetch is over: kept, merged when it is.
            ledger.values[key] = canonical
            ledger.at[key] = stamp
            raw[key] = data
            save()
            return
        }
        switch ledger.arrive(key, canonical: canonical, at: stamp) {
        case .stale:
            engine?.save([key])
        case .taken:
            raw[key] = data
            apply(key, joining: false)
        }
        save()
    }

    /// What came, as it came, until it is applied: the pins' rows are read
    /// from it (ICloudMerge.carryRows).
    private var raw: [String: Data] = [:]

    /// The JSON as both apps compare it, fields this Mac doesn't know and
    /// all (they ride along when it writes the record again), or nil for a
    /// record it can't read.
    private func canonical(_ key: String, _ data: Data) -> Data? {
        let readable: Bool
        if key.hasPrefix("device.") {
            readable = ICloudMerge.decode(DeviceTabs.self, data) != nil
        } else if key.hasPrefix("pins.") {
            readable = ICloudMerge.decode([PinDef].self, data) != nil
        } else if key == "spaces" {
            readable = ICloudMerge.decode([Space].self, data) != nil
        } else if key == "bookmarks" {
            readable = ICloudMerge.decode([Bookmark].self, data) != nil
        } else if key == "settings" {
            readable = ICloudMerge.decode(SharedSettings.self, data) != nil
        } else {
            // A record a newer Search writes: kept, never applied.
            return data
        }
        return readable ? ICloudMerge.canonical(data) : nil
    }

    /// The value kept for a key, made this Mac's.
    private func apply(_ key: String, joining: Bool) {
        guard let data = ledger.values[key] else { return }
        let came = raw.removeValue(forKey: key) ?? data
        if key.hasPrefix("device.") {
            let id = String(key.dropFirst("device.".count))
            guard id != ledger.device, let tabs = ICloudMerge.decode(DeviceTabs.self, data) else { return }
            others[id] = tabs
        } else if key.hasPrefix("pins."), let space = UUID(uuidString: String(key.dropFirst("pins.".count))) {
            guard local.spaces().contains(where: { $0.id == space }),
                  var defs = ICloudMerge.decode([PinDef].self, data) else { return }
            let mine = local.pins(space)
            defs = ICloudMerge.carryRows(defs, raw: came, local: mine)
            if joining { defs = ICloudMerge.union(pins: defs, mine) }
            if defs != mine { local.adopt(pins: defs, space: space) }
        } else if key == "spaces" {
            guard let theirs = ICloudMerge.decode([Space].self, data) else { return }
            let before = local.spaces()
            let list = ICloudMerge.adopt(spaces: joining ? ICloudMerge.union(spaces: theirs, before) : theirs, local: before)
            if list != before { local.adopt(spaces: list, removing: !joining) }
            // Pins that came before their space did.
            for space in list where !before.contains(where: { $0.id == space.id }) {
                if ledger.values["pins." + space.id.uuidString] != nil { apply("pins." + space.id.uuidString, joining: joining) }
            }
        } else if key == "bookmarks" {
            guard var roots = ICloudMerge.decode([Bookmark].self, data) else { return }
            let mine = local.bookmarks()
            if joining { roots = ICloudMerge.union(bookmarks: roots, mine) }
            if roots != mine { local.adopt(bookmarks: roots) }
        } else if key == "settings" {
            // iCloud's win, joining or not.
            if let settings = ICloudMerge.decode(SharedSettings.self, data), settings != local.settings() {
                local.adopt(settings: settings)
            }
        }
    }

    /// A record gone from iCloud.
    func removed(_ key: String) {
        ledger.removed(key)
        if key.hasPrefix("device.") { others[String(key.dropFirst("device.".count))] = nil }
        save()
    }

    /// The engine's record for a key, to send: its JSON and its stamp.
    func outgoing(_ key: String) -> (data: Data, at: Date, fields: Data?)? {
        guard let data = ledger.values[key] else { return nil }
        return (data, ledger.at[key] ?? Date(), ledger.fields[key])
    }

    /// Saved in iCloud: the server's fields for next time.
    func saved(_ key: String, fields: Data?) {
        ledger.fields[key] = fields
        save()
    }

    /// A save refused for another version on the server: the newer stays.
    func conflict(_ key: String, serverData: Data?, serverAt: Date, fields: Data?) {
        ledger.fields[key] = fields
        if ledger.oursWins(key, serverAt: serverAt) {
            engine?.save([key])
            save()
        } else if let serverData {
            ledger.at[key] = nil
            arrived(key, data: serverData, at: serverAt, fields: fields)
        }
    }

    /// The record's fields are stale (it was deleted on the server): sent
    /// again as new.
    func forgetFields(_ key: String) {
        ledger.fields[key] = nil
        engine?.save([key])
        save()
    }

    func engineState(_ state: Data?) {
        ledger.state = state
        save()
    }

    func synced() {
        lastSynced = Date()
    }

    func failed(_ message: String) {
        problem = message
    }

    /// Signed in, out, or as someone else.
    func accountChanged(_ now: Account) {
        account = now
        switch now {
        case .signedIn:
            problem = nil
            Task { await join() }
        case .signedOut, .restricted:
            // Another person's iCloud, or none: nothing of the last one stays.
            ledger = ledger.fresh()
            others = [:]
            save()
        case .unknown:
            break
        }
    }

    /// Search's zone deleted from another device: everything starts again,
    /// as a device joining.
    /// Search's zone deleted, from another device (Delete Search's data
    /// from iCloud) or in iCloud's settings: sync turns off here and says
    /// why. The zone isn't made again and nothing goes back up; what is on
    /// this Mac stays (SYNC.md).
    func zoneGone() {
        guard on else { return }
        engine?.close()
        stop()
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        defaults.set(ICloudSync.deletedElsewhere, forKey: ICloudSync.offKey)
        ledger = ledger.fresh()
        save()
        others = [:]
        lastSynced = nil
        problem = nil
    }

    static let deletedElsewhere = "Off: Search's data was deleted from iCloud, on another device. Turn on to start again"

    /// Why it is off, when it turned itself off.
    var offReason: String? { on ? nil : defaults.string(forKey: ICloudSync.offKey) }

    // MARK: kept on disk

    private var saving = false

    private func save() {
        guard let file, !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saving = false
                guard let data = try? JSONEncoder().encode(self.ledger) else { return }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func load() -> ICloudLedger? {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(ICloudLedger.self, from: data) else { return nil }
        for (key, value) in saved.values where key.hasPrefix("device.") && key != saved.deviceKey {
            if let tabs = ICloudMerge.decode(DeviceTabs.self, value) { others[String(key.dropFirst("device.".count))] = tabs }
        }
        return saved
    }

    // MARK: for Settings and the menus

    /// The other devices with something open, newest first.
    var devices: [(id: String, tabs: DeviceTabs)] {
        others.filter { !$0.value.tabs.isEmpty }
            .sorted { $0.value.at > $1.value.at }
            .map { ($0.key, $0.value) }
    }

    static func title(_ device: DeviceTabs) -> String {
        device.name.isEmpty ? (device.platform == "ios" ? "iPhone" : "Mac") : device.name
    }

    /// Tabs open on the other devices that match what was typed, for the
    /// address field.
    func offers(for typed: String, limit: Int = 2) -> [Suggestion] {
        let words = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard on, words.count >= 2 else { return [] }
        var out: [Suggestion] = []
        for (_, device) in devices {
            for page in device.tabs where page.title.lowercased().contains(words) || page.url.lowercased().contains(words) {
                guard let url = URL(string: page.url) else { continue }
                out.append(Suggestion(key: Address.editable(url), title: "On \(ICloudSync.title(device))", url: url, kind: .elsewhere))
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// The line under the switch.
    func summary(folderSyncOn: Bool, otherwise: String) -> String {
        guard available else {
            // A signed build in a test run is a build that could: it says so.
            return Store.testing && ICloudSync.entitled ? "Off in a test run" : "Needs a build of Search signed for iCloud"
        }
        if folderSyncOn && !on { return "Turn off Sync with your other Macs first" }
        guard on else { return offReason ?? otherwise }
        switch account {
        case .signedOut: return "Not signed in to iCloud: System Settings › Apple Account"
        case .restricted: return "iCloud is restricted on this Mac"
        case .unknown: return problem ?? "Checking iCloud…"
        case .signedIn:
            if let problem { return "Signed in to iCloud · \(problem)" }
            guard let lastSynced else { return "Signed in to iCloud · syncing…" }
            let when = RelativeDateTimeFormatter().localizedString(for: lastSynced, relativeTo: Date())
            let count = devices.count
            let with = count == 0 ? "" : count == 1 ? " · 1 other device" : " · \(count) other devices"
            return "Signed in to iCloud · synced \(when)\(with)"
        }
    }

    static func say(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return "Sign in to iCloud in System Settings to sync"
        case .quotaExceeded: return "Your iCloud is full"
        case .networkFailure, .networkUnavailable: return "Offline. Sync carries on when you're back"
        default: return error.localizedDescription
        }
    }
}

// MARK: - this Mac

/// The Personal profile's spaces, pins and bookmarks, the shared settings,
/// and every ordinary window's open tabs.
@MainActor
final class MacSide: ICloudLocal {
    var deviceName: String { Sync.macName }

    func openTabs() -> [DeviceTabs.Page] {
        let windows = Browsers.all.filter { $0.profileID == Profile.personalID && !$0.isPopup }
        return ICloudMerge.pages(windows.flatMap { browser in
            (browser.tabs + browser.parkedTabs).filter { !$0.bench }.map { tab in
                (url: tab.address, title: tab.title, shy: tab.shy, pinned: tab.pin != nil)
            }
        })
    }

    func spaces() -> [Space] { Spaces.read(profile: Profile.personalID) }

    func adopt(spaces list: [Space], removing: Bool) {
        let before = spaces()
        if removing {
            for gone in before where !gone.isFirst && !list.contains(where: { $0.id == gone.id }) {
                remove(gone)
            }
        }
        // The order is iCloud's, wherever the home is in it.
        Store.settings.set(true, forKey: "spaces.orderKept")
        Spaces.write(list, profile: Profile.personalID)
    }

    /// A space deleted on another Mac: as Delete Space does here (and as
    /// the folder sync does, Sync.removeSpace).
    private func remove(_ space: Space) {
        let profile = Profile.personalID
        if let window = Browsers.all.first(where: { $0.profileID == profile && !$0.isPopup && $0.spaces.contains { $0.id == space.id } }) {
            window.deleteSpace(space.id)
            return
        }
        Spaces.write(Spaces.read(profile: profile).filter { $0.id != space.id }, profile: profile)
        Session.erase(space: space.id)
        Pins.forget(space.id)
        if space.sharesSignIns != true { Spaces.erase(space.id) }
    }

    func pins(_ space: UUID) -> [PinDef] { Pins.defs(space) }

    func adopt(pins defs: [PinDef], space: UUID) {
        Pins.adopt([space: defs], in: [space], shared: Pins.shared(Profile.personalID), profile: Profile.personalID)
    }

    func bookmarks() -> [Bookmark] { Profiles.bookmarks(Profile.personalID).roots }

    func adopt(bookmarks roots: [Bookmark]) { Profiles.bookmarks(Profile.personalID).adopt(roots) }

    func settings() -> SharedSettings { ICloudMerge.settings(Shared.prefs) }

    func adopt(settings: SharedSettings) { ICloudMerge.apply(settings, to: Shared.prefs) }
}

// MARK: - CloudKit

/// CKSyncEngine on the private database, handing everything to ICloudSync.
/// Made only by a build signed for iCloud, with the switch on; never in a
/// test run.
final class CloudKitEngine: ICloudEngine, CKSyncEngineDelegate, @unchecked Sendable {
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: ICloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    // Read from CKSyncEngine's own queue as well as the main thread; set
    // once, and cleared only by close().
    nonisolated(unsafe) private weak var owner: ICloudSync?
    nonisolated(unsafe) private var container: CKContainer
    nonisolated(unsafe) private var engine: CKSyncEngine!

    @MainActor
    init(owner: ICloudSync, state: Data?) {
        self.owner = owner
        container = CKContainer(identifier: ICloudSync.containerID)
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialization, delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitEngine.zoneID))])
        }
        // CloudKit's pushes, so a change elsewhere arrives without waiting.
        NSApp.registerForRemoteNotifications()
    }

    nonisolated private static func id(_ key: String) -> CKRecord.ID { CKRecord.ID(recordName: key, zoneID: zoneID) }

    func save(_ keys: [String]) {
        engine.state.add(pendingRecordZoneChanges: keys.map { .saveRecord(CloudKitEngine.id($0)) })
    }

    func delete(_ keys: [String]) {
        engine.state.add(pendingRecordZoneChanges: keys.map { .deleteRecord(CloudKitEngine.id($0)) })
    }

    func fetch() async throws { try await engine.fetchChanges() }

    func send() async throws { try await engine.sendChanges() }

    func eraseZone() async throws {
        engine.state.add(pendingDatabaseChanges: [.deleteZone(CloudKitEngine.zoneID)])
        try await engine.sendChanges()
    }

    func account() async -> ICloudSync.Account {
        guard let status = try? await container.accountStatus() else { return .unknown }
        switch status {
        case .available: return .signedIn
        case .noAccount: return .signedOut
        case .restricted: return .restricted
        default: return .unknown
        }
    }

    func close() { owner = nil }

    // MARK: records

    nonisolated private static func fields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    nonisolated private static func record(fields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    nonisolated private static func contents(_ record: CKRecord) -> (data: Data, at: Date)? {
        guard let data = record.encryptedValues["data"] as? Data else { return nil }
        return (data, record["at"] as? Date ?? record.modificationDate ?? .distantPast)
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let owner else { return }
        switch event {
        case .stateUpdate(let update):
            let data = try? JSONEncoder().encode(update.stateSerialization)
            await MainActor.run { owner.engineState(data) }
        case .accountChange(let change):
            let now: ICloudSync.Account
            switch change.changeType {
            case .signIn: now = .signedIn
            case .signOut, .switchAccounts: now = .signedOut
            @unknown default: now = .unknown
            }
            await MainActor.run { owner.accountChanged(now) }
            // Someone else's iCloud now: theirs, from the start.
            if case .switchAccounts = change.changeType { await MainActor.run { owner.accountChanged(.signedIn) } }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudKitEngine.zoneID }) {
                await MainActor.run { owner.zoneGone() }
            }
        case .fetchedRecordZoneChanges(let changes):
            let arrivals = changes.modifications.compactMap { modification -> (String, Data, Date, Data)? in
                let record = modification.record
                guard let found = CloudKitEngine.contents(record) else { return nil }
                return (record.recordID.recordName, found.data, found.at, CloudKitEngine.fields(of: record))
            }
            let gone = changes.deletions.map(\.recordID.recordName)
            await MainActor.run {
                for (key, data, at, fields) in arrivals { owner.arrived(key, data: data, at: at, fields: fields) }
                for key in gone { owner.removed(key) }
                owner.synced()
            }
        case .sentRecordZoneChanges(let changes):
            let saved = changes.savedRecords.map { ($0.recordID.recordName, CloudKitEngine.fields(of: $0)) }
            var problems: [String] = []
            var actions: [@MainActor () -> Void] = []
            for failure in changes.failedRecordSaves {
                let key = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let theirs = failure.error.serverRecord {
                        let found = CloudKitEngine.contents(theirs)
                        let fields = CloudKitEngine.fields(of: theirs)
                        actions.append { owner.conflict(key, serverData: found?.data, serverAt: found?.at ?? .distantPast, fields: fields) }
                    }
                case .zoneNotFound:
                    // Deleted while this Mac had something to send: it
                    // turns off, and the zone isn't made again (SYNC.md).
                    actions.append { owner.zoneGone() }
                case .unknownItem:
                    actions.append { owner.forgetFields(key) }
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    break // the engine tries again by itself
                default:
                    problems.append(ICloudSync.say(failure.error))
                }
            }
            await MainActor.run {
                for (key, fields) in saved { owner.saved(key, fields: fields) }
                for action in actions { action() }
                if let problem = problems.first { owner.failed(problem) } else if !saved.isEmpty { owner.synced() }
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let owner = self?.owner else { return nil }
            guard let out = await MainActor.run(body: { owner.outgoing(id.recordName) }) else {
                // Nothing to send for it any more.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            let record = out.fields.flatMap { CloudKitEngine.record(fields: $0) }
                ?? CKRecord(recordType: ICloudSync.recordType, recordID: id)
            record.encryptedValues["data"] = out.data as NSData
            record["at"] = out.at as NSDate
            return record
        }
    }
}
