import Foundation
import XCTest
import SQLite3
@testable import Search

/// Zen's spaces, pins, folders and Essentials, and a Gecko browser's open
/// tabs, read from files written here by hand in each shape Zen and Firefox
/// have kept them (see ImportZen.swift). Only synthetic files in a scratch
/// folder: no real browser's profile is read.
final class ZenImportTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-zen-test-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratch = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - mozLz4

    /// A .jsonlz4 the simplest valid way: one LZ4 block of literals only.
    static func mozlz4(_ plain: Data) -> Data {
        var out = Data(MozLz4.magic)
        let n = plain.count
        out.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)])
        if n < 15 {
            out.append(UInt8(n << 4))
        } else {
            out.append(0xF0)
            var rest = n - 15
            while rest >= 255 { out.append(255); rest -= 255 }
            out.append(UInt8(rest))
        }
        out.append(plain)
        return out
    }

    static func mozlz4(json: Any) throws -> Data {
        mozlz4(try JSONSerialization.data(withJSONObject: json))
    }

    func testMozLz4UnpacksLiteralsAndMatches() throws {
        let text = Data(String(repeating: "zen spaces ", count: 100).utf8)
        XCTAssertEqual(MozLz4.decode(Self.mozlz4(text)), text)

        // "abcd", then eight bytes copied from four back, then five literals.
        var packed = Data(MozLz4.magic) + Data([17, 0, 0, 0])
        packed += Data([0x44]) + Data("abcd".utf8) + Data([4, 0])
        packed += Data([0x50]) + Data("XYZWV".utf8)
        XCTAssertEqual(MozLz4.decode(packed).map { String(decoding: $0, as: UTF8.self) }, "abcdabcdabcdXYZWV")
    }

    func testMozLz4RefusesWhatIsNotOne() {
        let good = Self.mozlz4(Data("{\"spaces\":[]}".utf8))
        XCTAssertNil(MozLz4.decode(Data("not a session".utf8)))
        XCTAssertNil(MozLz4.decode(Data("mozLz40\0".utf8)), "a header alone")
        XCTAssertNil(MozLz4.decode(good.prefix(good.count - 3)), "torn at the end")
        var lying = good
        lying[8] = 0xFF; lying[9] = 0xFF; lying[10] = 0xFF; lying[11] = 0x7F
        XCTAssertNil(MozLz4.decode(lying), "a size far past any session")
        var short = good
        short[8] = short[8] &+ 4
        XCTAssertNil(MozLz4.decode(short), "unpacks to less than it says")
    }

    // MARK: - Zen since window sync

    static func sidebarFixture() -> [String: Any] {
        func tab(_ url: String, title: String, space: String? = nil, pinned: Bool = true, essential: Bool = false,
                 group: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
            var out: [String: Any] = ["entries": [["url": url, "title": title]], "index": 1,
                                      "pinned": pinned, "zenEssential": essential]
            if let space { out["zenWorkspace"] = space }
            if let group { out["groupId"] = group }
            for (key, value) in extra { out[key] = value }
            return out
        }
        return [
            "lastCollected": 1_763_000_000_000,
            "spaces": [
                ["uuid": "{work}", "name": "Work", "icon": "💼", "containerTabId": 0,
                 "theme": ["type": "gradient", "opacity": 0.5, "texture": 0,
                           "gradientColors": [["c": [66, 133, 244], "isPrimary": true, "isCustom": false],
                                              ["c": [240, 160, 60], "isPrimary": false, "isCustom": false]]]],
                ["uuid": "{play}", "name": "Weekend", "icon": "chrome://browser/skin/zen-icons/selectable/game-controller.svg",
                 "theme": ["type": "gradient", "gradientColors": [["c": "#D04050", "isCustom": true, "isPrimary": true]]]],
                ["uuid": "{bare}", "name": "  ", "icon": ""],
            ],
            "folders": [
                ["id": "f-outer", "name": "Research", "pinned": true, "parentId": NSNull(), "workspaceId": "{work}"],
                ["id": "f-inner", "name": "Papers", "pinned": true, "parentId": "f-outer", "workspaceId": "{work}"],
                ["id": "f-split", "name": "", "splitViewGroup": true, "parentId": "f-outer"],
                ["id": "f-live", "name": "Feed", "isLiveFolder": true, "workspaceId": "{work}"],
            ],
            "groups": [["id": "g-open", "name": "Reading", "collapsed": true, "pinned": false]],
            "tabs": [
                tab("https://mail.example/", title: "Mail", essential: true),
                tab("https://calendar.example/", title: "Calendar", essential: true),
                // The pin's own page, not wherever the tab went since; a
                // name the person gave it; a password in the address dropped.
                tab("https://docs.example/now/elsewhere", title: "Elsewhere", space: "{work}",
                    extra: ["_zenPinnedInitialState": ["entry": ["url": "https://user:secret@docs.example/home", "title": "Docs"]],
                            "zenStaticLabel": "My docs"]),
                tab("https://paper-one.example/", title: "Paper one", space: "{work}", group: "f-inner"),
                tab("https://notes.example/", title: "Notes", space: "{work}", group: "f-outer"),
                tab("https://left.example/", title: "Left", space: "{work}", group: "f-split"),
                tab("https://paper-two.example/", title: "Paper two", space: "{work}", group: "f-inner"),
                tab("https://feed-item.example/", title: "Feed item", space: "{work}", group: "f-live",
                    extra: ["zenLiveFolderItemId": "item-1"]),
                tab("https://game.example/", title: "Game", space: "{play}"),
                tab("javascript:alert(1)", title: "Script", space: "{play}"),
                tab("https://glance.example/", title: "Glance", space: "{play}", extra: ["zenIsGlance": true]),
                tab("https://nowhere.example/", title: "Lost", space: "{gone}"),
                // An open tab, not a pin: left for Open tabs.
                tab("https://open.example/", title: "Open", space: "{work}", pinned: false, group: "g-open"),
            ],
        ]
    }

    func testZenSessionFileBringsSpacesPinsFoldersAndEssentials() throws {
        let sidebar = try XCTUnwrap(Zen.parse(Self.sidebarFixture()))
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Work", "Weekend", "Space"])
        XCTAssertEqual(sidebar.favorites.map(\.url.absoluteString), ["https://mail.example/", "https://calendar.example/"])
        XCTAssertEqual(sidebar.favoritesByProfile["Default"]?.count, 2)

        let work = sidebar.spaces[0]
        XCTAssertEqual(work.emoji, "💼")
        XCTAssertEqual(work.symbol, "briefcase")
        XCTAssertEqual(work.colour, 1, "the primary dot is blue")
        XCTAssertEqual(work.gradient?.colours, ["#4285F4", "#F0A03C"])
        XCTAssertEqual(work.profile, "Default")
        // Docs first; then Research, where its first page stood, holding
        // Papers (two pages), Notes, and the split view's page; then the
        // pin whose space is gone, in the first space rather than nowhere.
        XCTAssertEqual(work.pinned.count, 3)
        guard case .item(let docs) = work.pinned[0], case .folder(let research) = work.pinned[1] else {
            return XCTFail("pins out of order: \(work.pinned)")
        }
        XCTAssertEqual(docs.url.absoluteString, "https://docs.example/home")
        XCTAssertEqual(docs.title, "My docs")
        XCTAssertEqual(research.title, "Research")
        guard research.items.count == 3, case .folder(let papers) = research.items[0],
              case .item(let notes) = research.items[1], case .item(let left) = research.items[2] else {
            return XCTFail("Research isn't as Zen nests it: \(research.items)")
        }
        XCTAssertEqual(papers.title, "Papers")
        XCTAssertEqual(papers.items.count, 2)
        XCTAssertEqual(notes.title, "Notes")
        XCTAssertEqual(left.url.absoluteString, "https://left.example/")
        XCTAssertEqual(Arc.count(work.pinned), 6, "the live folder's page and the open tab stay behind")

        let weekend = sidebar.spaces[1]
        XCTAssertEqual(weekend.symbol, "gamecontroller")
        XCTAssertEqual(weekend.colour, 4, "red")
        XCTAssertNil(weekend.gradient, "one colour is a colour, not a gradient")
        XCTAssertEqual(weekend.pinned.count, 1, "no script, no glance")

        XCTAssertEqual(sidebar.spaces[2].pinned.count, 0)
        XCTAssertEqual(sidebar.spaces[2].symbol, "briefcase")
        XCTAssertEqual(sidebar.pinnedCount, 7)
    }

    func testZenProfileReadsTheFileThenItsBackups() throws {
        let profile = scratch.appendingPathComponent("abc.Default (release)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("zen-sessions-backup"), withIntermediateDirectories: true)
        // A torn main file: the clean copy is read instead.
        try Data("mozLz40\0garbage".utf8).write(to: profile.appendingPathComponent("zen-sessions.jsonlz4"))
        try Self.mozlz4(json: Self.sidebarFixture()).write(to: profile.appendingPathComponent("zen-sessions-backup/clean.jsonlz4"))
        let sidebar = try XCTUnwrap(Zen.sidebar(inProfile: profile))
        XCTAssertEqual(sidebar.spaces.count, 3)
        XCTAssertEqual(sidebar.favorites.count, 2)
    }

    func testZenProfileRefusesALinkOutOfIt() throws {
        let profile = scratch.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let outside = scratch.appendingPathComponent("elsewhere.jsonlz4")
        try Self.mozlz4(json: Self.sidebarFixture()).write(to: outside)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("zen-sessions.jsonlz4"), withDestinationURL: outside)
        XCTAssertNil(Zen.sidebar(inProfile: profile), "a session file that is a link is never followed")
    }

    // MARK: - Zen before window sync: places.sqlite

    func testZenPlacesTablesBringSpacesPinsFoldersAndEssentials() throws {
        let file = scratch.appendingPathComponent("places.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE zen_workspaces (id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, name TEXT NOT NULL, icon TEXT,
          container_id INTEGER, position INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          theme_type TEXT, theme_colors TEXT, theme_opacity REAL, theme_rotation INTEGER, theme_texture REAL);
        CREATE TABLE zen_pins (id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT,
          container_id INTEGER, workspace_uuid TEXT, position INTEGER NOT NULL DEFAULT 0, is_essential BOOLEAN NOT NULL DEFAULT 0,
          is_group BOOLEAN NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          edited_title BOOLEAN NOT NULL DEFAULT 0, is_folder_collapsed BOOLEAN NOT NULL DEFAULT 0,
          folder_icon TEXT DEFAULT NULL, folder_parent_uuid TEXT DEFAULT NULL);
        INSERT INTO zen_workspaces VALUES (1, '{b}', 'Studies', '🎓', 0, 1, 2, 2, 'gradient', '[{"c":[60,180,110],"isPrimary":true}]', 0.5, 45, 0);
        INSERT INTO zen_workspaces VALUES (2, '{a}', 'Home', '🏠', 0, 0, 1, 1, NULL, NULL, NULL, NULL, NULL);
        INSERT INTO zen_pins VALUES (1, 'e1', 'Mail', 'https://mail.example/', 0, NULL, 0, 1, 0, 1, 1, 0, 0, NULL, NULL);
        INSERT INTO zen_pins VALUES (2, 'f1', 'Courses', NULL, 0, '{b}', 1, 0, 1, 1, 1, 0, 0, NULL, NULL);
        INSERT INTO zen_pins VALUES (3, 'p1', 'Lecture', 'https://lecture.example/', 0, '{b}', 2, 0, 0, 1, 1, 0, 0, NULL, 'f1');
        INSERT INTO zen_pins VALUES (4, 'p2', 'Recipes', 'https://recipes.example/', 0, '{a}', 3, 0, 0, 1, 1, 0, 0, NULL, NULL);
        INSERT INTO zen_pins VALUES (5, 'p3', 'Bad', 'file:///etc/passwd', 0, '{a}', 4, 0, 0, 1, 1, 0, 0, NULL, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let sidebar = try XCTUnwrap(Zen.fromPlaces(file))
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Home", "Studies"], "in Zen's order, by position")
        XCTAssertEqual(sidebar.spaces[1].symbol, "graduationcap")
        XCTAssertEqual(sidebar.spaces[1].colour, 2, "green")
        XCTAssertEqual(sidebar.favorites.map(\.title), ["Mail"])
        XCTAssertEqual(sidebar.spaces[0].pinned, [.item(.init(title: "Recipes", url: URL(string: "https://recipes.example/")!))])
        guard case .folder(let courses) = sidebar.spaces[1].pinned.first else { return XCTFail("no Courses folder") }
        XCTAssertEqual(courses.title, "Courses")
        XCTAssertEqual(courses.items.count, 1)
    }

    // MARK: - Zen's oldest: the session window and zen-workspaces.json

    func testOldestZenReadsTheSessionWindowAndWorkspacesFile() throws {
        let profile = scratch.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let workspaces: [String: Any] = ["workspaces": [["uuid": "{w}", "name": "Code", "icon": "🛠", "default": true]]]
        try JSONSerialization.data(withJSONObject: workspaces).write(to: profile.appendingPathComponent("zen-workspaces.json"))
        let store: [String: Any] = ["windows": [
            ["isPopup": true, "tabs": []],
            ["tabs": [
                ["entries": [["url": "https://github.example/", "title": "GitHub"]], "index": 1, "pinned": true,
                 "zenWorkspace": "{w}", "zenEssential": NSNull()],
                ["entries": [["url": "https://chat.example/", "title": "Chat"]], "index": 1, "pinned": true, "zenEssential": "true"],
            ]],
        ]]
        try Self.mozlz4(json: store).write(to: profile.appendingPathComponent("sessionstore.jsonlz4"))
        let sidebar = try XCTUnwrap(Zen.sidebar(inProfile: profile))
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Code"])
        XCTAssertEqual(sidebar.spaces[0].symbol, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(Arc.count(sidebar.spaces[0].pinned), 1)
        XCTAssertEqual(sidebar.favorites.map(\.title), ["Chat"], "\"true\", as older Zen wrote it, is an Essential")
    }

    // MARK: - colours

    func testZenColoursFindTheNearestSpaceColour() {
        XCTAssertEqual(Zen.nearest((0.26, 0.52, 0.96)), 1)
        XCTAssertEqual(Zen.nearest((0.5, 0.5, 0.5)), 0, "a grey is no colour")
        XCTAssertEqual(Zen.nearest((0.95, 0.85, 0.2)), 3, "yellow is nearest orange")
        XCTAssertEqual(Zen.nearest((0.6, 0.3, 0.9)), 5)
        XCTAssertNil(Zen.rgb([300, 1, 2]))
        XCTAssertNil(Zen.rgb("#12"))
        XCTAssertEqual(Zen.rgb("rgb(255, 0, 0)").map(Zen.hex), "#FF0000")
    }
}
