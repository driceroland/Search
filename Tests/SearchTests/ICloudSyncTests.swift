import Foundation
import XCTest
import AppKit
import CloudKit
@testable import Search

/// Sync with iCloud (ICloudSync.swift), against SYNC.md in Search-iOS: the
/// JSON both apps read, latest wins, joining merges, no echo, what never
/// goes up. CloudKit itself never runs here: the engine is a stand-in that
/// keeps what would be sent and hands over what iCloud "has", and this Mac
/// is a stand-in too.
@MainActor
final class ICloudSyncTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    // MARK: - stand-ins

    /// Set while a CKSyncEngine delegate callback runs, the way CloudKit
    /// marks one: a task-local, which a Task started inside inherits and a
    /// detached one doesn't.
    enum Callback {
        @TaskLocal static var inside = false
    }

    /// iCloud, as far as one device can tell.
    final class FakeEngine: ICloudEngine {
        weak var sync: ICloudSync?
        /// What iCloud has, handed over on the next fetch.
        var cloud: [(key: String, data: Data, at: Date)] = []
        var saved: [String] = []
        var deleted: [String] = []
        var fetches = 0
        var failing = false
        var erased = false
        var state: ICloudSync.Account = .signedIn
        /// Calls CloudKit would have stopped the app for: awaited from
        /// inside a callback.
        var awaitedInside: [String] = []
        var sends = 0

        private func check(_ name: String) { if Callback.inside { awaitedInside.append(name) } }

        func save(_ keys: [String]) { saved += keys }
        func delete(_ keys: [String]) { deleted += keys }
        func fetch() async throws {
            check("fetch")
            fetches += 1
            if failing { throw URLError(.notConnectedToInternet) }
            let incoming = cloud
            cloud = []
            for record in incoming { sync?.arrived(record.key, data: record.data, at: record.at, fields: nil) }
        }
        func send() async throws { check("send"); sends += 1 }
        func eraseZone() async throws { check("eraseZone"); erased = true }
        var accountAsks = 0
        func account() async -> ICloudSync.Account { check("account"); accountAsks += 1; return state }
        func close() {}
    }

    /// This Mac: one or two spaces, their pins, bookmarks, four settings,
    /// open tabs.
    final class FakeMac: ICloudLocal {
        var deviceName = "Test Mac"
        var tabs: [DeviceTabs.Page] = []
        var spaceList: [Space] = [Space.first()]
        var pinList: [UUID: [PinDef]] = [:]
        var folderList: [UUID: [PinFolder]] = [:]
        var marks: [Bookmark] = []
        var shared = SharedSettings(engine: "google", custom: "", suggest: "", look: "system")
        var adopted: [String] = []
        var removedSpaces = false

        func openTabs() -> [DeviceTabs.Page] { tabs }
        var groupList: [DeviceTabs.Group]?
        func openGroups(for pages: [DeviceTabs.Page]) -> [DeviceTabs.Group]? { groupList }
        func spaces() -> [Space] { spaceList }
        func adopt(spaces: [Space], removing: Bool) { spaceList = spaces; removedSpaces = removing; adopted.append("spaces") }
        func pins(_ space: UUID) -> [PinDef] { pinList[space] ?? [] }
        func adopt(pins: [PinDef], space: UUID) { pinList[space] = pins; adopted.append("pins") }
        func pinFolders(_ space: UUID) -> [PinFolder] { folderList[space] ?? [] }
        func adopt(pinFolders: [PinFolder], space: UUID) { folderList[space] = PinTree.sanitized(pinFolders); adopted.append("folders") }
        func bookmarks() -> [Bookmark] { marks }
        func adopt(bookmarks: [Bookmark]) { marks = bookmarks; adopted.append("bookmarks") }
        func settings() -> SharedSettings { shared }
        func adopt(settings: SharedSettings) { shared = settings; adopted.append("settings") }
    }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "icloud-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func make(_ mac: FakeMac, _ engine: FakeEngine, available: Bool = true, defaults: UserDefaults? = nil) -> ICloudSync {
        let sync = ICloudSync(local: mac, defaults: defaults ?? self.defaults, file: nil, available: available) { owner, _ in
            engine.sync = owner
            return engine
        }
        engine.sync = sync
        return sync
    }

    /// On, and the first fetch done.
    private func joined(_ mac: FakeMac, _ engine: FakeEngine) async -> ICloudSync {
        let sync = make(mac, engine)
        sync.turnOn()
        await sync.join()
        XCTAssertTrue(sync.joined)
        return sync
    }

    private func json<T: Encodable>(_ value: T) -> Data { ICloudMerge.encode(value)! }
    private func text(_ data: Data?) -> String { data.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }

    private let first = Space.firstID
    private func pin(_ letter: String, _ home: String, id: UUID = UUID()) -> PinDef {
        PinDef(id: id, letter: letter, home: home, title: letter)
    }

    // MARK: - the shapes, as the iPhone writes and reads them

    /// The iPhone's own types (Sources/Sync.swift there), field for field.
    struct PhonePin: Codable, Equatable { var id: UUID; var letter: String; var home: String; var title: String; var name: String? }
    struct PhoneBookmark: Codable, Equatable { var id: UUID; var title: String; var url: String?; var children: [PhoneBookmark]? }
    struct PhoneSpace: Codable, Equatable { var id: UUID; var name: String; var icon: String? }

    func testTheIPhonesJSONReadsHere() throws {
        // As the iPhone writes them: sorted keys, dates as seconds since 2001.
        let pins = #"[{"home":"https://mail.example.com/","id":"6B1F3C1E-6A57-4C77-9E2B-1D6E0E7B9C01","letter":"m","name":"Mail","title":"Inbox"}]"#
        let decoded = try JSONDecoder().decode([PinDef].self, from: Data(pins.utf8))
        XCTAssertEqual(decoded.first?.home, "https://mail.example.com/")
        XCTAssertEqual(decoded.first?.name, "Mail")
        XCTAssertNil(decoded.first?.listed)
        XCTAssertNil(decoded.first?.folder)

        let marks = #"[{"children":[{"id":"0B9C3F57-36A4-4B7B-9C9F-4E0B3F1D2A11","title":"Docs","url":"https://docs.example.com/"}],"id":"3E1E5D7A-0C4B-4E2B-8F11-2A0C0F3D4B22","title":"Work"},{"id":"9D1C2B3A-4E5F-4A6B-8C7D-0E1F2A3B4C33","title":"News","url":"https://news.example.com/","extra":true}]"#
        let tree = try JSONDecoder().decode([Bookmark].self, from: Data(marks.utf8))
        XCTAssertTrue(tree[0].isFolder)
        XCTAssertEqual(tree[0].children?.first?.url, "https://docs.example.com/")
        XCTAssertEqual(tree[1].url, "https://news.example.com/", "unknown keys are ignored")

        let device = #"{"at":785000000.5,"name":"iPhone","platform":"ios","tabs":[{"title":"Example","url":"https://example.com/"}]}"#
        let tabs = try JSONDecoder().decode(DeviceTabs.self, from: Data(device.utf8))
        XCTAssertEqual(tabs.at, Date(timeIntervalSinceReferenceDate: 785000000.5))
        XCTAssertEqual(tabs.platform, "ios")
        XCTAssertEqual(tabs.tabs, [DeviceTabs.Page(url: "https://example.com/", title: "Example")])

        let settings = try JSONDecoder().decode(SharedSettings.self, from: Data(#"{"look":"dark"}"#.utf8))
        XCTAssertEqual(settings, SharedSettings(engine: nil, custom: nil, look: "dark"), "missing optional keys are nil")
    }

    func testWhatTheMacWritesReadsOnTheIPhone() throws {
        let def = PinDef(id: UUID(), letter: "g", home: "https://github.com/", title: "GitHub", name: nil)
        let back = try JSONDecoder().decode([PhonePin].self, from: json([def]))
        XCTAssertEqual(back, [PhonePin(id: def.id, letter: "g", home: "https://github.com/", title: "GitHub", name: nil)])
        XCTAssertFalse(text(json([def])).contains("listed"), "a pin with no row or folder writes neither")

        let mark = Bookmark.folder("Work", [Bookmark.site("Docs", URL(string: "https://docs.example.com/")!)])
        let phone = try JSONDecoder().decode([PhoneBookmark].self, from: json([mark]))
        XCTAssertEqual(phone.first?.children?.first?.url, "https://docs.example.com/")
        XCTAssertNil(phone.first?.url)

        var space = Space(id: UUID(), name: "Work", colour: 3, icon: "briefcase")
        space.downloads = "/Users/someone/Downloads/Work"
        let up = json([ICloudMerge.forCloud(space)])
        XCTAssertFalse(text(up).contains("downloads"), "a space's downloads folder is this Mac's")
        XCTAssertEqual(try JSONDecoder().decode([PhoneSpace].self, from: up), [PhoneSpace(id: space.id, name: "Work", icon: "briefcase")])

        let tabs = DeviceTabs(name: "Mac", platform: "macos", at: Date(timeIntervalSinceReferenceDate: 100), tabs: [])
        XCTAssertEqual(text(json(tabs)), #"{"at":100,"name":"Mac","platform":"macos","tabs":[]}"#)
        XCTAssertEqual(Space.firstID.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testOnlyTheFourSettingsGo() throws {
        let data = json(SharedSettings(engine: "duckduckgo", custom: "https://x.example/?q=%s",
                                       suggest: "https://suggest.example/complete?q=%s", look: "dark"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["custom", "engine", "look", "suggest"])
        // Values this build doesn't know are passed over, not guessed at.
        let prefs = Shared.prefs
        let engine = prefs.engine, look = prefs.look, suggest = prefs.customSuggest
        defer { prefs.customSuggest = suggest }
        ICloudMerge.apply(SharedSettings(engine: "altavista", custom: nil, suggest: "https://s.example/?q=%s",
                                         look: "sepia"), to: prefs)
        XCTAssertEqual(prefs.engine, engine)
        XCTAssertEqual(prefs.look, look)
        XCTAssertEqual(prefs.customSuggest, "https://s.example/?q=%s")
    }

    func testASuggestionsAddressComesAndGoesWithTheSettings() {
        let prefs = Shared.prefs
        let was = prefs.customSuggest
        defer { prefs.customSuggest = was }
        ICloudMerge.apply(SharedSettings(engine: nil, custom: nil, suggest: "https://s.example/?q=%s", look: nil), to: prefs)
        XCTAssertEqual(prefs.customSuggest, "https://s.example/?q=%s")
        ICloudMerge.apply(SharedSettings(engine: nil, custom: nil, suggest: "", look: nil), to: prefs)
        XCTAssertEqual(prefs.customSuggest, "", "an empty address clears it")
        prefs.customSuggest = "https://kept.example/?q=%s"
        ICloudMerge.apply(SharedSettings(engine: nil, custom: nil, suggest: nil, look: nil), to: prefs)
        XCTAssertEqual(prefs.customSuggest, "https://kept.example/?q=%s", "a record without one leaves it as it was")
    }

    // MARK: - SYNC.md's examples, as written there (its "…" ids made whole)

    private static let examples: [(key: String, json: String)] = [
        ("device.6F1C0000-0000-4000-8000-000000000001",
         #"{"at":785164000,"name":"iPhone","platform":"ios","tabs":[{"title":"Example Domain","url":"https://example.com/"}]}"#),
        ("pins.00000000-0000-0000-0000-000000000001",
         #"[{"home":"https://mail.google.com/","id":"0E4B0000-0000-4000-8000-000000000002","letter":"M","title":"Inbox"},"#
         + #"{"folder":"F0F00000-0000-4000-8000-000000000003","home":"https://github.com/","id":"7A2D0000-0000-4000-8000-000000000004","letter":"G","listed":true,"title":"GitHub"}]"#),
        ("bookmarks",
         #"[{"id":"B0000000-0000-4000-8000-000000000005","title":"Reading","children":[{"id":"B0000000-0000-4000-8000-000000000006","title":"Example","url":"https://example.com/"}]},"#
         + #"{"id":"B0000000-0000-4000-8000-000000000007","title":"Office Commun","url":"https://officecommun.com/"}]"#),
        ("spaces",
         #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Personal","colour":0,"icon":"house"},"#
         + #"{"id":"5BAC0000-0000-4000-8000-000000000008","name":"Work","colour":3,"icon":"briefcase"}]"#),
        ("settings", #"{"custom":"","engine":"duckduckgo","look":"system","suggest":""}"#),
    ]

    private func object(_ data: Data?) -> NSObject? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSObject }
    }

    /// Each example decodes into the Mac's own type, and the Mac writes it
    /// back as the same JSON: no field lost, none added, none changed.
    func testEveryExampleRoundTrips() throws {
        for (key, text) in Self.examples {
            let data = Data(text.utf8)
            let written: Data?
            switch key {
            case _ where key.hasPrefix("device."):
                written = ICloudMerge.outgoing(try JSONDecoder().decode(DeviceTabs.self, from: data), over: nil, shape: .device)
            case _ where key.hasPrefix("pins."):
                written = ICloudMerge.outgoing(try JSONDecoder().decode([PinDef].self, from: data), over: nil, shape: .pins)
            case "bookmarks":
                written = ICloudMerge.outgoing(try JSONDecoder().decode([Bookmark].self, from: data), over: nil, shape: .bookmarks)
            case "spaces":
                written = ICloudMerge.outgoing(try JSONDecoder().decode([Space].self, from: data).map(ICloudMerge.forCloud), over: nil, shape: .spaces)
            default:
                written = ICloudMerge.outgoing(try JSONDecoder().decode(SharedSettings.self, from: data), over: nil, shape: .settings)
            }
            XCTAssertNotNil(object(data), key)
            XCTAssertNotNil(object(written), key)
            XCTAssertEqual(object(written), object(data), key)
        }
    }

    /// What each example says, read by the Mac.
    func testEveryExampleReadsAsItSays() throws {
        let get = { (key: String) in Data(Self.examples.first { $0.key == key || $0.key.hasPrefix(key) }!.json.utf8) }
        let device = try JSONDecoder().decode(DeviceTabs.self, from: get("device."))
        XCTAssertEqual(device.at, Date(timeIntervalSinceReferenceDate: 785164000))
        XCTAssertEqual(device.platform, "ios")
        XCTAssertEqual(device.tabs, [DeviceTabs.Page(url: "https://example.com/", title: "Example Domain")])

        let pins = try JSONDecoder().decode([PinDef].self, from: get("pins."))
        XCTAssertEqual(pins.map(\.letter), ["M", "G"])
        XCTAssertNil(pins[0].name, "a pin with no name has no name key")
        XCTAssertNil(pins[0].listed)
        XCTAssertEqual(pins[1].listed, true)
        XCTAssertEqual(pins[1].folder, UUID(uuidString: "F0F00000-0000-4000-8000-000000000003"))

        let marks = try JSONDecoder().decode([Bookmark].self, from: get("bookmarks"))
        XCTAssertTrue(marks[0].isFolder)
        XCTAssertEqual(marks[0].children?.first?.url, "https://example.com/")
        XCTAssertEqual(marks[1].url, "https://officecommun.com/")

        let spaces = try JSONDecoder().decode([Space].self, from: get("spaces"))
        XCTAssertTrue(spaces[0].isFirst)
        XCTAssertEqual(spaces[1].colour, 3)
        XCTAssertEqual(spaces[1].icon, "briefcase")

        let settings = try JSONDecoder().decode(SharedSettings.self, from: get("settings"))
        XCTAssertEqual(settings, SharedSettings(engine: "duckduckgo", custom: "", suggest: "", look: "system"))
        XCTAssertNotNil(Engine(rawValue: settings.engine!))
        XCTAssertNotNil(Look(rawValue: settings.look!))
    }

    /// SYNC.md's engine and look values are exactly the Mac's.
    func testEngineAndLookValuesMatchTheContract() {
        XCTAssertEqual(Engine.allCases.map(\.rawValue), ["google", "duckduckgo", "bing", "ecosia", "startpage", "kagi", "brave", "qwant", "custom"])
        XCTAssertEqual(Look.allCases.map(\.rawValue), ["light", "dark", "system"])
    }

    // MARK: - fields this Mac doesn't know ride along

    /// The fields the merge treats as the Mac's own are exactly what its
    /// types write with everything set: a field added to one of them can't
    /// be mistaken for someone else's.
    func testKnownFieldsAreTheTypesOwn() throws {
        func keys<T: Encodable>(_ value: T) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: ICloudMerge.encode(value)!)
            return Set(((object as? [String: Any]) ?? [:]).keys)
        }
        let pin = PinDef(id: UUID(), letter: "a", home: "h", title: "t", name: "n", listed: true, folder: UUID(), pair: UUID())
        XCTAssertEqual(try keys(pin), ICloudMerge.known[.pins])
        let mark = Bookmark(title: "t", url: "u", children: [])
        XCTAssertEqual(try keys(mark), ICloudMerge.known[.bookmarks])
        var space = Space(id: UUID(), name: "n", colour: 1, icon: "i", sharesSignIns: true, downloads: "/d", profile: UUID())
        space.gradient = SpaceGradient(colours: ["#000000", "#FFFFFF"])
        space.strength = .vivid
        XCTAssertEqual(try keys(space), ICloudMerge.known[.spaces])
        XCTAssertEqual(try keys(SharedSettings(engine: "e", custom: "c", suggest: "s", look: "l")),
                       ICloudMerge.known[.settings])
        let folder = ICloudMerge.CloudFolder(id: UUID(), name: "n", parent: UUID(), feed: URL(string: "https://f.example/feed"))
        XCTAssertEqual(try keys(folder), ICloudMerge.known[.folders])
    }

    func testFieldsTheMacDoesntKnowSurviveItsWrite() async throws {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        let id = UUID()
        // Another device's pin, with a field from a newer Search.
        let theirs = #"[{"home":"https://a.example/","id":"\#(id.uuidString)","letter":"A","title":"A","glow":{"hue":3}}]"#
        sync.arrived("pins.\(first.uuidString)", data: Data(theirs.utf8), at: Date(), fields: nil)
        engine.saved = []
        sync.publish()
        XCTAssertEqual(engine.saved, [], "read and unchanged: nothing goes up, unknown field and all")
        // The Mac renames it: its own field changes, the other rides along.
        mac.pinList[first]![0].name = "Alpha"
        sync.publish()
        XCTAssertEqual(engine.saved, ["pins.\(first.uuidString)"])
        let sent = try XCTUnwrap(object(sync.outgoing("pins.\(first.uuidString)")?.data) as? [[String: Any]])
        XCTAssertEqual(sent.first?["name"] as? String, "Alpha")
        XCTAssertEqual((sent.first?["glow"] as? [String: Any])?["hue"] as? Int, 3)
        // A field the Mac owns, cleared here, is cleared there.
        mac.pinList[first]![0].name = nil
        sync.publish()
        let again = try XCTUnwrap(object(sync.outgoing("pins.\(first.uuidString)")?.data) as? [[String: Any]])
        XCTAssertNil(again.first?["name"])
        XCTAssertNotNil(again.first?["glow"])
    }

    func testUnknownFieldsRideAlongInBookmarksSpacesAndSettings() throws {
        let folder = UUID(), site = UUID(), space = UUID()
        let marks = #"[{"id":"\#(folder.uuidString)","title":"F","colour":"red","children":[{"id":"\#(site.uuidString)","title":"S","url":"https://s.example/","tags":["x"]}]}]"#
        var tree = try JSONDecoder().decode([Bookmark].self, from: Data(marks.utf8))
        tree[0].children![0].title = "Site"
        let outMarks = try XCTUnwrap(object(ICloudMerge.outgoing(tree, over: ICloudMerge.canonical(Data(marks.utf8)), shape: .bookmarks)) as? [[String: Any]])
        XCTAssertEqual(outMarks[0]["colour"] as? String, "red")
        let child = (outMarks[0]["children"] as? [[String: Any]])?.first
        XCTAssertEqual(child?["title"] as? String, "Site")
        XCTAssertEqual(child?["tags"] as? [String], ["x"])

        let spaces = #"[{"id":"\#(space.uuidString)","name":"W","colour":2,"wallpaper":"dunes"}]"#
        var list = try JSONDecoder().decode([Space].self, from: Data(spaces.utf8))
        list[0].name = "Work"
        let outSpaces = try XCTUnwrap(object(ICloudMerge.outgoing(list, over: ICloudMerge.canonical(Data(spaces.utf8)), shape: .spaces)) as? [[String: Any]])
        XCTAssertEqual(outSpaces[0]["name"] as? String, "Work")
        XCTAssertEqual(outSpaces[0]["wallpaper"] as? String, "dunes")

        let settings = #"{"engine":"kagi","look":"dark","zoom":1.25}"#
        let outSettings = try XCTUnwrap(object(ICloudMerge.outgoing(SharedSettings(engine: "bing", custom: "", look: "dark"),
                                                                     over: ICloudMerge.canonical(Data(settings.utf8)), shape: .settings)) as? [String: Any])
        XCTAssertEqual(outSettings["engine"] as? String, "bing")
        XCTAssertEqual(outSettings["zoom"] as? Double, 1.25)
    }

    // MARK: - open tabs

    func testPrivatePinnedAndOtherTabsNeverGo() {
        let pages = ICloudMerge.pages([
            (url: URL(string: "https://a.example/"), title: "A", shy: false, pinned: false),
            (url: URL(string: "https://secret.example/"), title: "Private", shy: true, pinned: false),
            (url: URL(string: "https://pinned.example/"), title: "Pinned", shy: false, pinned: true),
            (url: URL(string: "file:///Users/someone/notes.html"), title: "File", shy: false, pinned: false),
            (url: URL(string: "about:blank"), title: "", shy: false, pinned: false),
            (url: nil, title: "Nothing yet", shy: false, pinned: false),
            (url: URL(string: "http://b.example/"), title: "B", shy: false, pinned: false),
            (url: URL(string: "https://a.example/"), title: "A again", shy: false, pinned: false),
        ])
        XCTAssertEqual(pages, [DeviceTabs.Page(url: "https://a.example/", title: "A"),
                               DeviceTabs.Page(url: "http://b.example/", title: "B")])
    }

    func testTabsGoUpOnlyWhenTheListChanges() async {
        let mac = FakeMac(), engine = FakeEngine()
        mac.tabs = [DeviceTabs.Page(url: "https://a.example/", title: "A")]
        let sync = await joined(mac, engine)
        XCTAssertTrue(engine.saved.contains(sync.ledger.deviceKey))
        engine.saved = []
        sync.publish()
        sync.publish()
        XCTAssertEqual(engine.saved, [], "the same tabs a moment later are not a change")
        mac.tabs.append(DeviceTabs.Page(url: "https://b.example/", title: "B"))
        sync.publish()
        XCTAssertEqual(engine.saved, [sync.ledger.deviceKey])
    }

    func testOtherDevicesTabsShowAndOurOwnRecordIsNotOneOfThem() async {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        let phone = DeviceTabs(name: "iPhone", platform: "ios", at: Date(),
                               tabs: [DeviceTabs.Page(url: "https://recipes.example/soup", title: "Leek soup")])
        sync.arrived("device.PHONE-1", data: json(phone), at: Date(), fields: nil)
        sync.arrived(sync.ledger.deviceKey, data: json(DeviceTabs(name: "x", platform: "macos", at: Date(), tabs: [])), at: .distantPast, fields: nil)
        XCTAssertEqual(sync.others.keys.sorted(), ["PHONE-1"])
        XCTAssertEqual(sync.offers(for: "soup").map(\.url.absoluteString), ["https://recipes.example/soup"])
        XCTAssertEqual(sync.offers(for: "soup").first?.kind, .elsewhere)
        XCTAssertEqual(sync.offers(for: "s"), [], "one letter is too little to go looking")
        sync.removed("device.PHONE-1")
        XCTAssertTrue(sync.others.isEmpty)
    }

    // MARK: - tab groups with the open tabs (idea 1093)

    func testTabGroupsGoUpWithTheirTabsInOrder() throws {
        let work = TabGroup(id: UUID(), name: "Work", collapsed: true, colour: 3)
        let read = TabGroup(id: UUID(), name: "Read", collapsed: false)
        let unused = TabGroup(id: UUID(), name: "Empty", collapsed: false)
        let pages = ICloudMerge.pages([
            (url: URL(string: "https://b.example/"), title: "B", shy: false, pinned: false, group: read.id),
            (url: URL(string: "https://a.example/"), title: "A", shy: false, pinned: false, group: work.id),
            (url: URL(string: "https://secret.example/"), title: "Private", shy: true, pinned: false, group: work.id),
            (url: URL(string: "https://c.example/"), title: "C", shy: false, pinned: false, group: work.id),
            (url: URL(string: "https://d.example/"), title: "D", shy: false, pinned: false, group: nil),
        ])
        XCTAssertEqual(pages.map(\.group), [read.id, work.id, work.id, nil], "a private tab never goes, grouped or not")
        let groups = try XCTUnwrap(ICloudMerge.groups([work, read, unused, work], for: pages))
        XCTAssertEqual(groups, [DeviceTabs.Group(id: read.id, name: "Read", colour: nil, collapsed: nil),
                                DeviceTabs.Group(id: work.id, name: "Work", colour: 3, collapsed: true)],
                       "in the order the tabs name them, once each, none left empty")
        XCTAssertNil(ICloudMerge.groups([work], for: [DeviceTabs.Page(url: "https://x.example/", title: "X")]))
    }

    func testWithoutGroupsTheRecordIsTheJSONItAlwaysWas() throws {
        let tabs = DeviceTabs(name: "Mac", platform: "macos", at: Date(timeIntervalSinceReferenceDate: 100),
                              tabs: [DeviceTabs.Page(url: "https://a.example/", title: "A")])
        let out = text(ICloudMerge.outgoing(tabs, over: nil, shape: .device))
        XCTAssertEqual(out, #"{"at":100,"name":"Mac","platform":"macos","tabs":[{"title":"A","url":"https://a.example/"}]}"#)
    }

    /// What a Search from before groups (and the iPhone) has: the old shape.
    struct OldDeviceTabs: Codable, Equatable {
        struct Page: Codable, Equatable { var url: String; var title: String }
        var name: String; var platform: String; var at: Date; var tabs: [Page]
    }

    func testGroupsGoFromOneMacToAnotherAndAnOlderOneStillReadsTheTabs() async throws {
        // This Mac: two groups and a loose tab.
        let work = UUID(), read = UUID()
        let a = FakeMac(), cloudA = FakeEngine()
        a.deviceName = "Studio"
        a.tabs = [DeviceTabs.Page(url: "https://w1.example/", title: "W1", group: work),
                  DeviceTabs.Page(url: "https://w2.example/", title: "W2", group: work),
                  DeviceTabs.Page(url: "https://r1.example/", title: "R1", group: read),
                  DeviceTabs.Page(url: "https://loose.example/", title: "Loose")]
        a.groupList = [DeviceTabs.Group(id: work, name: "Work", colour: 2, collapsed: true),
                       DeviceTabs.Group(id: read, name: "Read")]
        let syncA = await joined(a, cloudA)
        let sent = try XCTUnwrap(syncA.outgoing(syncA.ledger.deviceKey)?.data)

        // The other Mac fetches it.
        let b = FakeMac(), cloudB = FakeEngine()
        let otherSuite = "icloud-tests-\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let syncB = make(b, cloudB, defaults: otherDefaults)
        syncB.turnOn()
        await syncB.join()
        XCTAssertTrue(syncB.joined)
        XCTAssertNotEqual(syncB.ledger.deviceKey, syncA.ledger.deviceKey, "two devices")
        let id = String(syncA.ledger.deviceKey.dropFirst("device.".count))
        syncB.arrived(syncA.ledger.deviceKey, data: sent, at: Date(), fields: nil)
        let seen = try XCTUnwrap(syncB.others[id])
        let sections = seen.sections
        XCTAssertEqual(sections.map { $0.group?.name }, ["Work", "Read", nil])
        XCTAssertEqual(sections.map { $0.pages.map(\.title) }, [["W1", "W2"], ["R1"], ["Loose"]], "each group's tabs in order")
        XCTAssertEqual(sections[0].group?.colour, 2)
        XCTAssertEqual(sections[0].group?.collapsed, true)
        XCTAssertEqual(sections[1].group?.collapsed, nil, "open")

        // A Search from before groups, or the iPhone, reads the same record:
        // every tab, in one list.
        let old = try JSONDecoder().decode(OldDeviceTabs.self, from: sent)
        XCTAssertEqual(old.tabs.map(\.title), ["W1", "W2", "R1", "Loose"])
        // And its own record, without them, reads here as tabs in no group.
        let older = try JSONEncoder().encode(OldDeviceTabs(name: "Old Mac", platform: "macos", at: Date(),
                                                           tabs: [.init(url: "https://o.example/", title: "O")]))
        syncB.arrived("device.OLD", data: older, at: Date(), fields: nil)
        XCTAssertEqual(syncB.others["OLD"]?.sections.map { $0.group?.name }, [nil])

        // A group renamed, nothing else changed: it goes up again.
        cloudA.saved = []
        a.groupList?[1].name = "Reading"
        syncA.publish()
        XCTAssertEqual(cloudA.saved, [syncA.ledger.deviceKey])
        cloudA.saved = []
        syncA.publish()
        XCTAssertEqual(cloudA.saved, [], "the same groups a moment later are not a change")
        // A page naming a group the list doesn't have is in none.
        var stray = seen
        stray.groups = nil
        XCTAssertEqual(stray.sections.map { $0.pages.count }, [4])
    }

    // MARK: - joining

    func testNothingIsWrittenOverBeforeTheFirstFetch() async {
        let mac = FakeMac(), engine = FakeEngine()
        mac.pinList[first] = [pin("a", "https://a.example/")]
        engine.failing = true
        let sync = make(mac, engine)
        sync.turnOn()
        await sync.join()
        XCTAssertFalse(sync.joined, "a failed first fetch leaves it unjoined")
        sync.publish()
        XCTAssertEqual(engine.saved, [], "nothing goes up before iCloud has been read")
        // Arriving before the join is done: kept, not applied.
        sync.arrived("pins.\(first.uuidString)", data: json([pin("z", "https://z.example/")]), at: Date(), fields: nil)
        XCTAssertEqual(mac.adopted, [])
        XCTAssertNotNil(sync.problem)
    }

    func testJoiningMergesPinsAndBookmarksAndTakesICloudsSettings() async {
        let mac = FakeMac(), engine = FakeEngine()
        let shared = UUID()
        let theirs = [pin("m", "https://mail.example/", id: shared)]
        // Ours: one new, one the same page under another id, one the same id.
        mac.pinList[first] = [pin("n", "https://notes.example/"), pin("m", "https://mail.example/"),
                              pin("m", "https://mail.example/other", id: shared)]
        let theirMark = Bookmark.site("News", URL(string: "https://news.example/")!)
        mac.marks = [Bookmark.site("Mine", URL(string: "https://mine.example/")!),
                     Bookmark.site("News too", URL(string: "https://news.example/")!),
                     Bookmark.folder("Old", [Bookmark.site("News", URL(string: "https://news.example/")!)])]
        mac.shared = SharedSettings(engine: "google", custom: "", look: "light")
        let at = Date(timeIntervalSinceNow: -60)
        engine.cloud = [("pins.\(first.uuidString)", json(theirs), at),
                        ("bookmarks", json([theirMark]), at),
                        ("settings", json(SharedSettings(engine: "kagi", custom: "", look: "dark")), at)]
        let sync = await joined(mac, engine)

        XCTAssertEqual(mac.pins(first).map(\.home), ["https://mail.example/", "https://notes.example/"],
                       "iCloud's, then ours not already there by id or by address")
        XCTAssertEqual(mac.marks.map(\.title), ["News", "Mine"], "a folder with nothing new in it doesn't come along")
        XCTAssertEqual(mac.shared.look, "dark", "iCloud's settings win")
        XCTAssertEqual(mac.shared.engine, "kagi")
        // What changed goes up; iCloud's settings, taken as they were, don't.
        XCTAssertTrue(engine.saved.contains("pins.\(first.uuidString)"))
        XCTAssertTrue(engine.saved.contains("bookmarks"))
        XCTAssertFalse(engine.saved.contains("settings"))
        XCTAssertTrue(engine.saved.contains("spaces"), "nothing in iCloud yet: this Mac's go up")
        XCTAssertTrue(engine.saved.contains(sync.ledger.deviceKey))
    }

    func testJoiningKeepsOurSpacesAndAddsTheirs() async {
        let mac = FakeMac(), engine = FakeEngine()
        let ours = Space(id: UUID(), name: "Ours", colour: 1)
        mac.spaceList = [Space.first(), ours]
        let theirs = Space(id: UUID(), name: "Theirs", colour: 2, icon: "book")
        let theirPins = [pin("r", "https://read.example/")]
        engine.cloud = [("spaces", json([Space.first(), theirs]), Date()),
                        ("pins.\(theirs.id.uuidString)", json(theirPins), Date())]
        _ = await joined(mac, engine)
        XCTAssertEqual(mac.spaceList.map(\.name), ["Personal", "Theirs", "Ours"])
        XCTAssertFalse(mac.removedSpaces, "joining takes nothing away")
        XCTAssertEqual(mac.pins(theirs.id), theirPins, "a new space's pins come with it")
    }

    // MARK: - after joining

    func testLatestWinsRecordByRecord() async {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        engine.saved = []
        mac.marks = [Bookmark.site("Ours", URL(string: "https://ours.example/")!)]
        sync.publish()
        XCTAssertEqual(engine.saved, ["bookmarks"])
        engine.saved = []
        let ourAt = sync.ledger.at["bookmarks"]!

        // Older than ours: ignored, and ours goes up again.
        sync.arrived("bookmarks", data: json([Bookmark.site("Old", URL(string: "https://old.example/")!)]),
                     at: ourAt.addingTimeInterval(-10), fields: nil)
        XCTAssertEqual(mac.marks.map(\.title), ["Ours"])
        XCTAssertEqual(engine.saved, ["bookmarks"])

        // Newer: taken.
        engine.saved = []
        sync.arrived("bookmarks", data: json([Bookmark.site("New", URL(string: "https://new.example/")!)]),
                     at: ourAt.addingTimeInterval(10), fields: nil)
        XCTAssertEqual(mac.marks.map(\.title), ["New"])
        XCTAssertEqual(engine.saved, [])
    }

    func testNoEcho() async {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        engine.saved = []
        let phone = [pin("p", "https://phone.example/")]
        // The same JSON with its keys in another order: the iPhone's.
        let reordered = Data(#"[{"title":"p","letter":"p","id":"\#(phone[0].id.uuidString)","home":"https://phone.example/"}]"#.utf8)
        sync.arrived("pins.\(first.uuidString)", data: reordered, at: Date(), fields: nil)
        sync.arrived("settings", data: json(SharedSettings(engine: "bing", custom: "", look: "dark")), at: Date(), fields: nil)
        XCTAssertEqual(mac.pins(first), phone)
        sync.publish()
        XCTAssertEqual(engine.saved, [], "what was just read is not sent back")
        sync.publish()
        XCTAssertEqual(engine.saved, [])
    }

    /// Idea 1306: every Personal space writes its own pins record, the
    /// first space deleted (#1326) or never there (an import's spaces) too,
    /// and a later change to one space's pins goes up on the next publish.
    func testEverySpaceWritesItsPinsEvenWithoutTheFirstSpace() async {
        let mac = FakeMac(), engine = FakeEngine()
        let home = Space(id: UUID(), name: "Zen home", colour: 1), work = Space(id: UUID(), name: "Work", colour: 2)
        mac.spaceList = [home, work]
        mac.pinList = [home.id: [pin("m", "https://mail.example/")], work.id: [pin("g", "https://git.example/")]]
        let sync = await joined(mac, engine)
        XCTAssertTrue(engine.saved.contains("pins.\(home.id.uuidString)"))
        XCTAssertTrue(engine.saved.contains("pins.\(work.id.uuidString)"))
        XCTAssertFalse(engine.saved.contains("pins.\(first.uuidString)"), "no record for a space this Mac doesn't have")
        let sent = try? JSONDecoder().decode([PinDef].self, from: sync.outgoing("pins.\(home.id.uuidString)")?.data ?? Data())
        XCTAssertEqual(sent?.map(\.letter), ["m"])
        engine.saved = []
        mac.pinList[work.id]?.append(pin("d", "https://docs.example/"))
        sync.publish()
        XCTAssertEqual(engine.saved, ["pins.\(work.id.uuidString)"])
    }

    func testAnotherMacDeletingASpaceDeletesItHereButNeverTheFirst() async {
        let mac = FakeMac(), engine = FakeEngine()
        let work = Space(id: UUID(), name: "Work", colour: 1)
        let play = Space(id: UUID(), name: "Play", colour: 2)
        mac.spaceList = [Space.first(), work, play]
        let sync = await joined(mac, engine)
        sync.arrived("spaces", data: json([work]), at: Date(timeIntervalSinceNow: 5), fields: nil)
        XCTAssertTrue(mac.removedSpaces)
        XCTAssertEqual(mac.spaceList.map(\.id), [Space.firstID, work.id], "Play goes, the first space stays")
    }

    func testRowsAndPinFoldersSurviveAnIPhoneChange() async {
        let mac = FakeMac(), engine = FakeEngine()
        let folder = UUID()
        var row = pin("d", "https://docs.example/")
        row.listed = true
        row.folder = folder
        mac.pinList[first] = [row]
        let sync = await joined(mac, engine)
        engine.saved = []
        // The iPhone renames it; its PinDef knows no rows or folders.
        let phone = #"[{"home":"https://docs.example/","id":"\#(row.id.uuidString)","letter":"d","name":"Docs","title":"d"}]"#
        sync.arrived("pins.\(first.uuidString)", data: Data(phone.utf8), at: Date(timeIntervalSinceNow: 5), fields: nil)
        XCTAssertEqual(mac.pins(first).first?.name, "Docs")
        XCTAssertEqual(mac.pins(first).first?.listed, true)
        XCTAssertEqual(mac.pins(first).first?.folder, folder)
        // Another Mac taking it out of its row says so, and that is taken.
        var mine = mac.pins(first)[0]
        mine.listed = false
        mine.folder = nil
        sync.arrived("pins.\(first.uuidString)", data: json([mine]), at: Date(timeIntervalSinceNow: 10), fields: nil)
        XCTAssertEqual(mac.pins(first).first?.listed, false)
        XCTAssertNil(mac.pins(first).first?.folder)
    }

    func testAConflictKeepsTheNewer() async {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        mac.shared.look = "light"
        sync.publish()
        engine.saved = []
        let ours = sync.ledger.at["settings"]!
        sync.conflict("settings", serverData: json(SharedSettings(engine: nil, custom: nil, look: "dark")),
                      serverAt: ours.addingTimeInterval(-5), fields: nil)
        XCTAssertEqual(engine.saved, ["settings"], "ours is newer: it goes up again")
        XCTAssertEqual(mac.shared.look, "light")
        engine.saved = []
        sync.conflict("settings", serverData: json(SharedSettings(engine: "google", custom: "", look: "dark")),
                      serverAt: ours.addingTimeInterval(5), fields: nil)
        XCTAssertEqual(mac.shared.look, "dark", "theirs is newer: it is taken")
        XCTAssertEqual(engine.saved, [])
    }

    // MARK: - on and off

    func testOffByDefaultAndNothingRuns() {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = make(mac, engine)
        XCTAssertFalse(sync.on)
        XCTAssertFalse(sync.isScheduled)
        sync.start()
        sync.publish()
        sync.refresh()
        XCTAssertFalse(sync.isScheduled)
        XCTAssertNil(engine.sync?.engine, "no engine made")
        XCTAssertEqual(engine.fetches, 0)
        XCTAssertEqual(engine.saved, [])
        XCTAssertNil(defaults.object(forKey: ICloudSync.onKey))
    }

    func testABuildWithoutICloudCantTurnItOn() {
        let sync = make(FakeMac(), FakeEngine(), available: false)
        sync.turnOn()
        XCTAssertFalse(sync.on)
        XCTAssertFalse(sync.isScheduled)
        XCTAssertEqual(sync.summary(folderSyncOn: false, otherwise: "x"), "Needs a build of Search signed for iCloud")
    }

    func testTurningOffTakesOnlyThisMacsTabsAway() async {
        let mac = FakeMac(), engine = FakeEngine()
        mac.tabs = [DeviceTabs.Page(url: "https://a.example/", title: "A")]
        let sync = await joined(mac, engine)
        let key = sync.ledger.deviceKey
        sync.turnOff()
        XCTAssertEqual(engine.deleted, [key])
        XCTAssertFalse(sync.on)
        XCTAssertFalse(sync.isScheduled)
        XCTAssertNil(defaults.object(forKey: ICloudSync.onKey))
        XCTAssertEqual(sync.ledger.deviceKey, key, "the same device when it comes back")
    }

    func testADeletedZoneTurnsSyncOffAndSaysWhy() async {
        let mac = FakeMac(), engine = FakeEngine()
        mac.tabs = [DeviceTabs.Page(url: "https://a.example/", title: "A")]
        engine.cloud = [("device.PHONE", json(DeviceTabs(name: "iPhone", platform: "ios", at: Date(),
                                                         tabs: [DeviceTabs.Page(url: "https://b.example/", title: "B")])), Date())]
        let sync = await joined(mac, engine)
        mac.pinList[first] = [pin("p", "https://p.example/")]
        engine.saved = []
        sync.zoneGone()
        XCTAssertFalse(sync.on)
        XCTAssertFalse(sync.isScheduled)
        XCTAssertNil(defaults.object(forKey: ICloudSync.onKey))
        XCTAssertTrue(sync.others.isEmpty, "the other devices' tabs go with it")
        XCTAssertFalse(sync.joined)
        XCTAssertEqual(sync.summary(folderSyncOn: false, otherwise: "x"), ICloudSync.deletedElsewhere)
        // Nothing goes back up, now or later.
        sync.publish()
        XCTAssertEqual(engine.saved, [])
        XCTAssertEqual(engine.deleted, [])
        XCTAssertEqual(mac.pins(first).count, 1, "what is on this Mac stays")
        // Turned on again: a device joining, and the line is its own again.
        sync.turnOn()
        XCTAssertTrue(sync.on)
        XCTAssertNil(sync.offReason)
    }

    /// Until `condition`, or two seconds.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// CloudKit's crash on a real account ("Cannot await a call into
    /// CKSyncEngine from within a delegate callback"): every path that can
    /// start from a callback, or from a button, timer or menu while one
    /// runs, awaits the engine only from a detached task.
    func testNothingAwaitsTheEngineFromInsideACallback() async {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = make(mac, engine)

        // Turned on: the first fetch.
        Callback.$inside.withValue(true) { sync.turnOn() }
        await until { sync.joined }
        XCTAssertTrue(sync.joined)

        // Signed out and in again, as CKSyncEngine says it: a join, so a fetch.
        let before = engine.fetches
        Callback.$inside.withValue(true) {
            sync.accountChanged(.signedOut)
            sync.accountChanged(.signedIn)
        }
        await until { sync.joined && engine.fetches > before }
        XCTAssertTrue(sync.joined, "joined again after signing in")

        // Back in front, the timer: a fetch.
        let again = engine.fetches
        Callback.$inside.withValue(true) { sync.refresh() }
        await until { engine.fetches > again }
        XCTAssertGreaterThan(engine.fetches, again)

        // Turned off: this Mac's tabs deleted and sent.
        Callback.$inside.withValue(true) { sync.turnOff() }
        await until { engine.sends > 0 }
        XCTAssertEqual(engine.sends, 1)

        // On again, then Delete Search's data from iCloud.
        Callback.$inside.withValue(true) { sync.turnOn() }
        await until { sync.joined }
        Callback.$inside.withValue(true) { sync.erase() }
        await until { engine.erased }
        XCTAssertTrue(engine.erased)

        // On again, then the zone deleted elsewhere: off, nothing awaited.
        Callback.$inside.withValue(true) { sync.turnOn() }
        await until { sync.joined }
        Callback.$inside.withValue(true) { sync.zoneGone() }
        XCTAssertFalse(sync.on)

        XCTAssertEqual(engine.awaitedInside, [], "awaited from inside a callback: CloudKit would stop the app")
    }

    func testSigningOutForgetsTheLastAccount() async {
        let mac = FakeMac(), engine = FakeEngine()
        engine.cloud = [("device.PHONE", json(DeviceTabs(name: "iPhone", platform: "ios", at: Date(),
                                                         tabs: [DeviceTabs.Page(url: "https://a.example/", title: "A")])), Date())]
        let sync = await joined(mac, engine)
        XCTAssertFalse(sync.others.isEmpty)
        sync.accountChanged(.signedOut)
        XCTAssertTrue(sync.others.isEmpty)
        XCTAssertFalse(sync.joined)
        XCTAssertTrue(sync.ledger.values.isEmpty)
    }

    // MARK: - pin folders, between two Macs (idea 903)

    /// What one Mac sent, handed to the other as iCloud would on its next
    /// fetch: `only`, the records whose names start so, the rest held back.
    private func relay(_ from: ICloudSync, _ sent: FakeEngine, to engine: FakeEngine, only: String? = nil,
                       at: Date = Date()) async throws {
        let keys = Array(NSOrderedSet(array: sent.saved)) as! [String]
        var held: [String] = []
        for key in keys {
            if let only, !key.hasPrefix(only) { held.append(key); continue }
            guard let out = from.outgoing(key) else { continue }
            engine.cloud.append((key, out.data, max(out.at, at)))
        }
        sent.saved = held
        try await engine.fetch()
    }

    private func row(_ letter: String, in folder: UUID?) -> PinDef {
        var def = pin(letter, "https://\(letter).example/")
        def.listed = true
        def.folder = folder
        return def
    }

    private func names(_ mac: FakeMac) -> [String] { mac.pinFolders(first).map(\.name) }
    private func folderOf(_ mac: FakeMac, _ letter: String) -> String? {
        guard let id = mac.pins(first).first(where: { $0.letter == letter })?.folder else { return nil }
        return mac.pinFolders(first).first { $0.id == id }?.name ?? "unknown"
    }

    /// Two Macs on the same iCloud, both joined, A's folder Work holding pin
    /// w and a loose pin l.
    private func twoMacs() async throws -> (a: FakeMac, ea: FakeEngine, sa: ICloudSync, b: FakeMac, eb: FakeEngine, sb: ICloudSync, work: UUID) {
        let a = FakeMac(), ea = FakeEngine(), b = FakeMac(), eb = FakeEngine()
        let work = UUID()
        a.folderList[first] = [PinFolder(id: work, name: "Work")]
        a.pinList[first] = [row("w", in: work), row("l", in: nil)]
        let sa = await joined(a, ea)
        // The other Mac's own settings.
        let other = "\(suite!)-b"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: other) }
        let sb = make(b, eb, defaults: UserDefaults(suiteName: other))
        sb.turnOn()
        for key in Array(NSOrderedSet(array: ea.saved)) as! [String] {
            if let out = sa.outgoing(key) { eb.cloud.append((key, out.data, out.at)) }
        }
        ea.saved = []
        await sb.join()
        XCTAssertTrue(sb.joined)
        eb.saved = []
        return (a, ea, sa, b, eb, sb, work)
    }

    func testAFolderOfPinsMadeOnOneMacIsAFolderOnTheOther() async throws {
        let m = try await twoMacs()
        XCTAssertEqual(names(m.b), ["Work"], "the folder came")
        XCTAssertEqual(m.b.pinFolders(first).first?.id, m.work)
        XCTAssertEqual(folderOf(m.b, "w"), "Work", "its pin is in it")
        XCTAssertNil(folderOf(m.b, "l"), "the loose pin is loose")
        // The record: what the folder is, never how a Mac shows it.
        let sent = try XCTUnwrap(object(m.sa.outgoing(ICloudMerge.foldersKey(first))?.data) as? [[String: Any]])
        XCTAssertEqual(Set(sent[0].keys), ["id", "name"])
    }

    func testRenamedNestedAndDeletedFoldersFollow() async throws {
        let m = try await twoMacs()
        // Renamed on A.
        m.a.folderList[first]![0].name = "Office"
        m.sa.publish()
        XCTAssertEqual(m.ea.saved, [ICloudMerge.foldersKey(first)], "a rename is the folders record alone")
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(names(m.b), ["Office"])
        // A folder made inside it, a pin moved into that, on A.
        let inner = UUID()
        m.a.folderList[first]!.append(PinFolder(id: inner, name: "Docs", parent: m.work))
        m.a.pinList[first]![1].folder = inner
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(m.b.pinFolders(first).first { $0.id == inner }?.parent, m.work, "nested as on A")
        XCTAssertEqual(folderOf(m.b, "l"), "Docs", "a pin moved into a folder")
        // Docs taken out to the top.
        m.a.folderList[first]![1].parent = nil
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertNil(m.b.pinFolders(first).first { $0.id == inner }?.parent)
        // A pin moved out of its folder.
        m.a.pinList[first]![0].folder = nil
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertNil(folderOf(m.b, "w"), "a pin moved out of a folder")
        // Docs deleted on A: what it held goes up to the top, as Delete Folder does.
        let gone = PinTree.removing(inner, folders: m.a.folderList[first]!, pins: m.a.pinList[first]!)
        m.a.folderList[first] = gone.folders
        m.a.pinList[first] = gone.pins
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(names(m.b), ["Office"])
        XCTAssertEqual(m.b.pins(first).count, 2, "no pin lost")
        XCTAssertNil(folderOf(m.b, "l"))
        // The last folder deleted: the record says none.
        m.a.folderList[first] = []
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(names(m.b), [])
        // And B's own change goes the other way.
        m.b.folderList[first] = [PinFolder(id: UUID(), name: "From B")]
        m.sb.publish()
        try await relay(m.sb, m.eb, to: m.ea)
        XCTAssertEqual(names(m.a), ["From B"])
    }

    func testPinsThatComeBeforeTheirFolderWaitForIt() async throws {
        let m = try await twoMacs()
        let later = UUID()
        m.a.folderList[first]!.append(PinFolder(id: later, name: "Later"))
        m.a.pinList[first]!.append(row("x", in: later))
        m.sa.publish()
        // The pins first, the folder held back.
        try await relay(m.sa, m.ea, to: m.eb, only: "pins.")
        XCTAssertEqual(m.b.pins(first).map(\.letter), ["w", "l", "x"], "the pin is here, not lost")
        XCTAssertEqual(m.b.pins(first).last?.folder, later, "and keeps its folder's id")
        XCTAssertEqual(folderOf(m.b, "x"), "unknown", "a folder not here yet: drawn at the top")
        // B writes its pins meanwhile: the folder's id goes with them.
        m.b.pinList[first]![0].name = "Renamed on B"
        m.sb.publish()
        let up = try XCTUnwrap(object(m.sb.outgoing("pins.\(first.uuidString)")?.data) as? [[String: Any]])
        XCTAssertEqual(up.last?["folder"] as? String, later.uuidString, "never stripped for a folder B doesn't have")
        XCTAssertFalse(m.eb.saved.contains(ICloudMerge.foldersKey(first)), "B doesn't write A's folders over")
        // The folder comes: the pin is in it.
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(folderOf(m.b, "x"), "Later")
        XCTAssertEqual(names(m.b), ["Work", "Later"])
    }

    func testFoldingStaysOnEachMac() async throws {
        let m = try await twoMacs()
        m.a.folderList[first]![0].collapsed = true
        m.sa.publish()
        XCTAssertEqual(m.ea.saved, [], "folding a folder sends nothing")
        m.b.folderList[first]![0].collapsed = true
        m.a.folderList[first]![0].name = "Renamed"
        m.sa.publish()
        try await relay(m.sa, m.ea, to: m.eb)
        XCTAssertEqual(m.b.pinFolders(first).first?.name, "Renamed")
        XCTAssertEqual(m.b.pinFolders(first).first?.collapsed, true, "B's fold kept through A's rename")
    }

    func testAMacJoiningWithFoldersOfItsOwnKeepsThem() async throws {
        let mac = FakeMac(), engine = FakeEngine()
        let mine = UUID(), theirs = UUID()
        mac.folderList[first] = [PinFolder(id: mine, name: "Mine")]
        mac.pinList[first] = [row("m", in: mine)]
        engine.cloud = [(ICloudMerge.foldersKey(first), json([ICloudMerge.CloudFolder(id: theirs, name: "Theirs")]), Date()),
                        ("pins.\(first.uuidString)", json([row("t", in: theirs)]), Date())]
        let sync = await joined(mac, engine)
        XCTAssertEqual(names(mac), ["Theirs", "Mine"])
        XCTAssertEqual(folderOf(mac, "t"), "Theirs")
        XCTAssertEqual(folderOf(mac, "m"), "Mine")
        XCTAssertTrue(engine.saved.contains(ICloudMerge.foldersKey(first)), "the union goes up")
        _ = sync
    }

    func testASpaceWithNoFoldersWritesNoFolderRecord() async {
        let mac = FakeMac(), engine = FakeEngine()
        mac.pinList[first] = [pin("a", "https://a.example/")]
        let sync = await joined(mac, engine)
        XCTAssertFalse(engine.saved.contains(ICloudMerge.foldersKey(first)))
        XCTAssertNil(sync.outgoing(ICloudMerge.foldersKey(first)))
    }

    /// A Mac still on 1.0.16 kept the pinfolders record it couldn't read
    /// (canonical: "kept, never applied"). Updated, it merges it in on its
    /// first launch, before anything goes up: neither its own folders nor
    /// the other Mac's are written over.
    func testAMacUpdatedFrom1016TakesTheFoldersItSetAside() async throws {
        let theirs = UUID(), mine = UUID()
        var old = ICloudLedger()
        old.joined = true
        old.folders = nil
        let record = json([ICloudMerge.CloudFolder(id: theirs, name: "From A")])
        old.values[ICloudMerge.foldersKey(first)] = ICloudMerge.canonical(record)
        old.at[ICloudMerge.foldersKey(first)] = Date(timeIntervalSinceNow: -60)
        // As 1.0.16 wrote it: no "folders" key at all.
        var written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(written["folders"])
        written["folders"] = nil
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: written).write(to: file)

        let mac = FakeMac(), engine = FakeEngine()
        mac.folderList[first] = [PinFolder(id: mine, name: "Mine")]
        defaults.set(true, forKey: ICloudSync.onKey)
        let sync = ICloudSync(local: mac, defaults: defaults, file: file, available: true) { owner, _ in
            engine.sync = owner
            return engine
        }
        sync.start()
        await until { sync.ledger.folders == true }
        XCTAssertTrue(sync.joined, "an old ledger still reads")
        XCTAssertEqual(names(mac), ["From A", "Mine"])
        await until { engine.saved.contains(ICloudMerge.foldersKey(first)) }
        let up = try XCTUnwrap(object(sync.outgoing(ICloudMerge.foldersKey(first))?.data) as? [[String: Any]])
        XCTAssertEqual(up.compactMap { $0["name"] as? String }, ["From A", "Mine"])
        sync.turnOff()
    }

    /// What a Mac on 1.0.16 does with the new record, as its code reads it:
    /// a record name it doesn't know is kept as it came, never applied,
    /// never written; its pins, folder ids and all, read as before.
    func testARecordNameABuildDoesntKnowIsKeptAndLeftAlone() async throws {
        let mac = FakeMac(), engine = FakeEngine()
        let sync = await joined(mac, engine)
        engine.saved = []
        let data = Data(#"[{"id":"\#(UUID().uuidString)","name":"X"}]"#.utf8)
        sync.arrived("somethingnew.\(first.uuidString)", data: data, at: Date(), fields: nil)
        XCTAssertEqual(sync.ledger.values["somethingnew.\(first.uuidString)"], data)
        XCTAssertEqual(mac.adopted, [])
        sync.publish()
        XCTAssertEqual(engine.saved, [])
        // And a pins record whose folder ids point nowhere reads whole.
        let defs = try JSONDecoder().decode([PinDef].self, from: json([row("a", in: UUID())]))
        XCTAssertNotNil(defs.first?.folder)
    }

    // MARK: - a Mac set up from another (Migration Assistant)

    func testALedgerFromAnotherMacStartsAgainAsANewDevice() {
        var kept = ICloudLedger(mac: "aaaa")
        kept.joined = true
        kept.values["spaces"] = Data("[]".utf8)
        kept.state = Data("engine".utf8)
        XCTAssertEqual(kept.claimed(by: "aaaa"), kept, "the same Mac keeps everything")
        var older = kept
        older.mac = nil
        XCTAssertEqual(older.claimed(by: "bbbb").device, kept.device, "a ledger from before the fingerprint is this Mac's")
        XCTAssertEqual(older.claimed(by: "bbbb").mac, "bbbb")
        XCTAssertEqual(kept.claimed(by: nil), kept, "no fingerprint, nothing to tell")
        let copied = kept.claimed(by: "bbbb")
        XCTAssertNotEqual(copied.device, kept.device, "a copy gets an id of its own")
        XCTAssertFalse(copied.joined, "and joins again")
        XCTAssertNil(copied.state, "with an engine of its own")
        XCTAssertEqual(copied.mac, "bbbb")
        XCTAssertEqual(copied.folders, true)
        XCTAssertEqual(copied.fresh().mac, "bbbb", "turned off and on, it stays this Mac's")
        XCTAssertNotEqual(ThisMac.hash("X"), "X")
        XCTAssertEqual(ThisMac.hash("X").count, 16)
        XCTAssertNotNil(ThisMac.fingerprint, "IOKit tells this Mac")
    }

    func testTwoMacsWithTheSameCopiedLedgerSeeEachOther() async throws {
        // Mac A's ledger, joined, as Migration Assistant copies it to Mac B.
        let other = UUID()
        var old = ICloudLedger(mac: "mac-a")
        old.joined = true
        old.values["device.\(old.device)"] = json(DeviceTabs(name: "A", platform: "mac", at: Date(), tabs: []))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(old).write(to: file)

        // Mac B, launched with sync on: a new id, joining; B's own pins stay.
        let mac = FakeMac(), engine = FakeEngine()
        mac.pinList[first] = [pin("n", "https://notes.example/", id: other)]
        defaults.set(true, forKey: ICloudSync.onKey)
        let sync = ICloudSync(local: mac, defaults: defaults, file: file, available: true, mac: "mac-b") { owner, _ in
            engine.sync = owner
            return engine
        }
        sync.start()
        XCTAssertNotEqual(sync.ledger.device, old.device)
        XCTAssertEqual(sync.ledger.mac, "mac-b")
        XCTAssertNotNil(sync.others[old.device], "A's tabs are another Mac's, not B's own")
        await until { sync.joined }
        XCTAssertEqual(mac.pins(first).map(\.id), [other], "this Mac's pins stay")
        await until { engine.saved.contains(sync.ledger.deviceKey) }
        XCTAssertFalse(engine.deleted.contains("device.\(old.device)"), "Mac A's tabs are left alone")
        // Kept on disk, so the next launch is B again.
        await until { (try? JSONDecoder().decode(ICloudLedger.self, from: Data(contentsOf: file)))?.device == sync.ledger.device }
        sync.turnOff()

        // Mac A itself keeps its id.
        let fileA = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileA) }
        try JSONEncoder().encode(old).write(to: fileA)
        defaults.set(true, forKey: ICloudSync.onKey)
        let a = ICloudSync(local: FakeMac(), defaults: defaults, file: fileA, available: true, mac: "mac-a") { owner, _ in
            engine.sync = owner
            return engine
        }
        a.start()
        XCTAssertEqual(a.ledger.device, old.device)
        XCTAssertTrue(a.joined)
        a.turnOff()
        // A pair cloned before the fingerprint parts with off and on.
        a.turnOn()
        XCTAssertNotEqual(a.ledger.device, old.device)
        XCTAssertEqual(a.ledger.mac, "mac-a")
        a.turnOff()
    }

    func testTheFolderSyncsIdIsThisMacsOwnToo() {
        let first = Sync.device(in: defaults, mac: "mac-a")
        XCTAssertEqual(Sync.device(in: defaults, mac: "mac-a"), first)
        XCTAssertEqual(Sync.device(in: defaults, mac: nil), first)
        let copied = Sync.device(in: defaults, mac: "mac-b")
        XCTAssertNotEqual(copied, first, "settings copied to another Mac: an id of its own")
        XCTAssertEqual(Sync.device(in: defaults, mac: "mac-b"), copied)
        defaults.removeObject(forKey: Sync.deviceMacKey)
        XCTAssertEqual(Sync.device(in: defaults, mac: "mac-c"), copied, "an id from before the fingerprint stays")
        XCTAssertEqual(defaults.string(forKey: Sync.deviceMacKey), "mac-c")
    }

    // MARK: - every account answer says why (idea 1330)

    func testCloudKitStatusesMapToTheirAccount() {
        XCTAssertEqual(ICloudSync.account(.available, signedInToICloud: true), .signedIn)
        XCTAssertEqual(ICloudSync.account(.noAccount, signedInToICloud: false), .signedOut)
        XCTAssertEqual(ICloudSync.account(.noAccount, signedInToICloud: true), .offForSearch)
        XCTAssertEqual(ICloudSync.account(.restricted, signedInToICloud: false), .restricted)
        XCTAssertEqual(ICloudSync.account(.temporarilyUnavailable, signedInToICloud: false), .needsAttention)
        XCTAssertEqual(ICloudSync.account(.couldNotDetermine, signedInToICloud: false), .unreachable)
        XCTAssertEqual(ICloudSync.account(nil, signedInToICloud: false), .unreachable, "asking failed")
    }

    func testEveryAccountAnswerSaysWhyUnderTheSwitch() async {
        let expected: [(ICloudSync.Account, String)] = [
            (.signedOut, "Sign in to iCloud in System Settings"),
            (.offForSearch, "Turn on iCloud for Search in System Settings › Apple Account › iCloud"),
            (.restricted, "iCloud is restricted on this Mac"),
            (.needsAttention, "Your Apple Account needs attention in System Settings"),
            (.unreachable, "Couldn't reach iCloud. Trying again."),
        ]
        for (state, line) in expected {
            let engine = FakeEngine()
            engine.state = state
            let sync = make(FakeMac(), engine)
            sync.retryScale = 1000 // no second try during this test
            sync.turnOn()
            await sync.join()
            await until { sync.account == state }
            XCTAssertFalse(sync.joined, "\(state)")
            XCTAssertEqual(engine.fetches, 0, "\(state): nothing fetched or written before signing in")
            XCTAssertEqual(sync.problem, line, "\(state)")
            XCTAssertEqual(sync.summary(folderSyncOn: false, otherwise: "off"), line, "\(state)")
            sync.turnOff()
        }
    }

    func testCouldNotReachTriesAgainGentlyThenJoins() async {
        let engine = FakeEngine()
        engine.state = .unreachable
        let sync = make(FakeMac(), engine)
        sync.retryScale = 0.001 // 30 ms, 60 ms, 120 ms…
        sync.turnOn()
        await until { sync.retries >= 1 }
        XCTAssertEqual(sync.problem, "Couldn't reach iCloud. Trying again.")
        await until { sync.retries >= 3 }
        XCTAssertEqual(sync.retryDelay, 120, "each wait longer than the last")
        XCTAssertEqual(ICloudSync.backoff(0), 30)
        XCTAssertEqual(ICloudSync.backoff(20), 900, "never more than 15 minutes")
        // Never a tight loop: one ask per wait.
        XCTAssertLessThanOrEqual(engine.accountAsks, sync.retries + 1)
        XCTAssertEqual(engine.fetches, 0)

        engine.state = .signedIn
        await until { sync.joined }
        XCTAssertTrue(sync.joined, "reached on a later try")
        XCTAssertNil(sync.problem)
        XCTAssertEqual(sync.retries, 0)
        XCTAssertNil(sync.retryDelay)
        let asks = engine.accountAsks
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.accountAsks, asks, "no more tries once joined")
        sync.turnOff()
    }

    func testAccountChangedAndComingBackToTheFrontJoin() async {
        let engine = FakeEngine()
        engine.state = .offForSearch
        let sync = make(FakeMac(), engine)
        sync.turnOn()
        await until { sync.account == .offForSearch }
        XCTAssertFalse(sync.joined)

        // iCloud turned on for Search in System Settings.
        engine.state = .signedIn
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        await until { sync.joined }
        XCTAssertTrue(sync.joined, "joined on CKAccountChanged")
        XCTAssertNil(sync.problem)
        sync.turnOff()

        // The Apple Account needed attention, sorted out while away.
        let other = FakeEngine()
        other.state = .needsAttention
        let again = make(FakeMac(), other)
        again.turnOn()
        await until { again.account == .needsAttention }
        XCTAssertEqual(again.problem, "Your Apple Account needs attention in System Settings")
        other.state = .signedIn
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await until { again.joined }
        XCTAssertTrue(again.joined, "joined when the app came back to the front")
        again.turnOff()
    }

    func testBothSyncsOnSaysWhyICloudIsNotRunning() {
        defaults.set(true, forKey: ICloudSync.onKey)
        let sync = make(FakeMac(), FakeEngine())
        // `start` refuses while the folder sync is on: no engine.
        XCTAssertTrue(sync.on)
        XCTAssertNil(sync.engine)
        XCTAssertEqual(sync.summary(folderSyncOn: true, otherwise: "off"),
                       "Not syncing while Sync Macs through a folder is on. Turn that off")
        XCTAssertEqual(sync.summary(folderSyncOn: false, otherwise: "off"), "Checking iCloud…")
    }

    func testTheRowSaysWhichProfileSyncs() {
        XCTAssertNil(ICloudSync.profileLine(several: false, name: "Personal", elsewhere: false), "one profile: nothing about profiles")
        XCTAssertEqual(ICloudSync.profileLine(several: true, name: "Personal", elsewhere: false), "Syncs the Personal profile")
        XCTAssertEqual(ICloudSync.profileLine(several: true, name: "Me", elsewhere: true),
                       "Syncs the Me profile · Switch to Me to sync")
    }
}
