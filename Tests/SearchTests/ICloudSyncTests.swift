import Foundation
import XCTest
@testable import Search

/// Sync with iCloud (ICloudSync.swift), against SYNC.md in Search-iOS: the
/// JSON both apps read, latest wins, joining merges, no echo, what never
/// goes up. CloudKit itself never runs here: the engine is a stand-in that
/// keeps what would be sent and hands over what iCloud "has", and this Mac
/// is a stand-in too.
@MainActor
final class ICloudSyncTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "icloud-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - stand-ins

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

        func save(_ keys: [String]) { saved += keys }
        func delete(_ keys: [String]) { deleted += keys }
        func fetch() async throws {
            fetches += 1
            if failing { throw URLError(.notConnectedToInternet) }
            let incoming = cloud
            cloud = []
            for record in incoming { sync?.arrived(record.key, data: record.data, at: record.at, fields: nil) }
        }
        func send() async throws {}
        func eraseZone() async throws { erased = true }
        func account() async -> ICloudSync.Account { state }
        func close() {}
    }

    /// This Mac: one or two spaces, their pins, bookmarks, three settings,
    /// open tabs.
    final class FakeMac: ICloudLocal {
        var deviceName = "Test Mac"
        var tabs: [DeviceTabs.Page] = []
        var spaceList: [Space] = [Space.first()]
        var pinList: [UUID: [PinDef]] = [:]
        var marks: [Bookmark] = []
        var shared = SharedSettings(engine: "google", custom: "", look: "system")
        var adopted: [String] = []
        var removedSpaces = false

        func openTabs() -> [DeviceTabs.Page] { tabs }
        func spaces() -> [Space] { spaceList }
        func adopt(spaces: [Space], removing: Bool) { spaceList = spaces; removedSpaces = removing; adopted.append("spaces") }
        func pins(_ space: UUID) -> [PinDef] { pinList[space] ?? [] }
        func adopt(pins: [PinDef], space: UUID) { pinList[space] = pins; adopted.append("pins") }
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

    private func make(_ mac: FakeMac, _ engine: FakeEngine, available: Bool = true) -> ICloudSync {
        let sync = ICloudSync(local: mac, defaults: defaults, file: nil, available: available) { owner, _ in
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

    func testOnlyTheThreeSettingsGo() throws {
        let data = json(SharedSettings(engine: "duckduckgo", custom: "https://x.example/?q=%s", look: "dark"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["custom", "engine", "look"])
        // Values this build doesn't know are passed over, not guessed at.
        let prefs = Shared.prefs
        let engine = prefs.engine, look = prefs.look
        ICloudMerge.apply(SharedSettings(engine: "altavista", custom: nil, look: "sepia"), to: prefs)
        XCTAssertEqual(prefs.engine, engine)
        XCTAssertEqual(prefs.look, look)
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
        ("settings", #"{"custom":"","engine":"duckduckgo","look":"system"}"#),
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
        XCTAssertEqual(settings, SharedSettings(engine: "duckduckgo", custom: "", look: "system"))
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
        let pin = PinDef(id: UUID(), letter: "a", home: "h", title: "t", name: "n", listed: true, folder: UUID())
        XCTAssertEqual(try keys(pin), ICloudMerge.known[.pins])
        let mark = Bookmark(title: "t", url: "u", children: [])
        XCTAssertEqual(try keys(mark), ICloudMerge.known[.bookmarks])
        var space = Space(id: UUID(), name: "n", colour: 1, icon: "i", sharesSignIns: true, downloads: "/d", profile: UUID())
        space.gradient = SpaceGradient(colours: ["#000000", "#FFFFFF"])
        space.strength = .vivid
        XCTAssertEqual(try keys(space), ICloudMerge.known[.spaces])
        XCTAssertEqual(try keys(SharedSettings(engine: "e", custom: "c", look: "l")), ICloudMerge.known[.settings])
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
}
