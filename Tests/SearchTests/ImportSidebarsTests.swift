import Foundation
import XCTest
import SQLite3
import CommonCrypto
@testable import Search

/// Ardia's, Yab's and Dia's spaces, pins and folders, read from files made
/// here in each browser's shape (see ImportSidebars.swift). Only synthetic
/// files: no real browser's data, no keychain.
@available(macOS 14, *)
final class ImportSidebarsTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: - Ardia

    func testArdiaBringsEachProfileAsASpaceWithItsTilesRowsAndNestedFolders() throws {
        let session: [String: Any] = [
            "profileOrder": ["default", "p-work"],
            "profiles": [
                "default": ["name": "Home", "color": "green", "icon": "symbol:house"],
                "p-work": ["name": "Work", "color": "blue", "icon": "💼", "dataId": "p-work"],
                "p-side": ["name": "Side", "dataId": "default"],
            ],
            "windows": [["id": "w1", "tabIds": ["t1", "t2", "t3", "t4", "t5", "t6", "t7"]]],
            "tabs": [
                ["id": "t1", "profileId": "default", "pin": ["as": "tile"], "pinnedUrl": "https://mail.example.com/", "url": "https://mail.example.com/x", "title": "Mail"],
                ["id": "t2", "profileId": "default", "pin": ["as": "row"], "pinnedUrl": "https://docs.example.com/", "title": "Docs", "customTitle": "My docs"],
                ["id": "t3", "profileId": "default", "url": "https://deep.example.com/", "title": "Deep"],
                ["id": "t4", "profileId": "default", "url": "https://today.example.com/", "title": "Not pinned"],
                ["id": "t5", "profileId": "p-work", "pin": ["as": "row"], "url": "javascript:alert(1)", "title": "Dropped"],
                ["id": "t6", "profileId": "p-work", "pin": ["as": "row"], "url": "https://user:pw@jira.example.com/", "title": "Jira"],
                ["id": "t7", "profileId": "default", "pin": ["as": "row"], "url": "https://top.example.com/", "title": "In top"],
            ],
            "groups": [
                ["id": "g1", "name": "Reading", "pinned": true, "tabIds": ["t3", "t7"]],
                ["id": "g2", "name": "Deeper", "pinned": true, "parentId": "g1", "tabIds": ["t3"]],
            ],
            "parkedPins": ["p-side": ["tabs": [["id": "s1", "pin": ["as": "row"], "url": "https://side.example.com/", "title": "Side pin", "groupId": "pg"]],
                                      "groups": [["id": "pg", "name": "Parked folder", "pinned": true]]]],
        ]
        let sidebar = try XCTUnwrap(Ardia.parse(session, profile: nil))
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Home", "Work", "Side"])
        let home = sidebar.spaces[0]
        XCTAssertEqual(home.profile, "Default")
        XCTAssertEqual(home.symbol, "house")
        XCTAssertEqual(home.colour, 2)
        XCTAssertEqual(home.favorites, [.init(title: "Mail", url: url("https://mail.example.com/"))])
        XCTAssertEqual(home.pinned, [
            .item(.init(title: "My docs", url: url("https://docs.example.com/"))),
            .folder(.init(title: "Reading", items: [
                .folder(.init(title: "Deeper", items: [.item(.init(title: "Deep", url: url("https://deep.example.com/")))])),
                .item(.init(title: "In top", url: url("https://top.example.com/"))),
            ])),
        ])
        let work = sidebar.spaces[1]
        XCTAssertEqual(work.profile, "Profile p-work")
        XCTAssertEqual(work.symbol, "briefcase")
        XCTAssertEqual(work.pinned, [.item(.init(title: "Jira", url: url("https://jira.example.com/")))])
        XCTAssertEqual(sidebar.profileNames?["Profile p-work"], "Work")
        // A profile with no window keeps its pins parked; it signs in with the first.
        XCTAssertEqual(sidebar.spaces[2].profile, "Default")
        XCTAssertEqual(sidebar.spaces[2].pinned, [.folder(.init(title: "Parked folder", items: [.item(.init(title: "Side pin", url: url("https://side.example.com/")))]))])
        // One profile: only its spaces.
        XCTAssertEqual(Ardia.parse(session, profile: "Profile p-work")?.spaces.map(\.name), ["Work"])
        XCTAssertNil(Ardia.parse(["tabs": []], profile: nil))
    }

    // MARK: - Yab

    func testYabBringsItsSpacesWithTilesKeptTabsAndFolderPaths() throws {
        let files: [String: [[String: Any]]] = [
            "session.json": [
                ["pin": "tile", "home": "https://mail.example.com/", "url": "https://mail.example.com/inbox", "homeTitle": "Mail"],
                ["kept": true, "home": "https://a.example.com/", "homeTitle": "A", "folder": "f2", "folderName": "Inner",
                 "folderPath": [["id": "f1", "name": "Outer"]]],
                ["kept": true, "url": "https://b.example.com/", "title": "B", "name": "Bee"],
                ["url": "https://today.example.com/", "title": "Today"],
            ],
            "session-AAAA.json": [["kept": true, "url": "https://w.example.com/", "title": "W", "folder": "f9", "folderName": "Tools"]],
            "session-\(Yab.sharedID).json": [["pin": "tile", "url": "https://shared.example.com/", "title": "Shared"]],
        ]
        let spaces: [[String: Any]] = [
            ["id": Yab.firstID, "name": "Personal", "icon": "🏠"],
            ["id": "aaaa", "name": "Work", "icon": "terminal", "ownSignIns": true, "paint": ["swatch": "coral"]],
        ]
        func parse(everySpace: Bool, profile: String? = nil) -> ArcSidebar? {
            Yab.parse(spaces, profile: profile, tabs: { files[$0] ?? [] }, everySpace: everySpace,
                      sharedFolder: "space-SHARED", ownFolder: { $0 == "AAAA" ? "space-AAAA" : nil })
        }
        let own = try XCTUnwrap(parse(everySpace: false))
        XCTAssertEqual(own.spaces.map(\.name), ["Personal", "Work"])
        let personal = own.spaces[0]
        XCTAssertEqual(personal.profile, "Default")
        XCTAssertEqual(personal.symbol, "house")
        XCTAssertEqual(personal.favorites, [.init(title: "Mail", url: url("https://mail.example.com/"))])
        XCTAssertEqual(personal.pinned, [
            .folder(.init(title: "Outer", items: [.folder(.init(title: "Inner", items: [.item(.init(title: "A", url: url("https://a.example.com/")))]))])),
            .item(.init(title: "Bee", url: url("https://b.example.com/"))),
        ])
        let work = own.spaces[1]
        XCTAssertEqual(work.profile, "space-AAAA")
        XCTAssertEqual(work.symbol, "terminal")
        XCTAssertEqual(work.colour, 4)
        XCTAssertEqual(own.profileNames?["space-AAAA"], "Work")

        // Pins in every space: the shared tiles head the spaces signing in
        // with the first; a space of its own keeps its own.
        let shared = try XCTUnwrap(parse(everySpace: true))
        XCTAssertEqual(shared.spaces[0].favorites?.map(\.title), ["Shared"])
        XCTAssertEqual(shared.spaces[1].favorites, [])
        // The shared Chromium folder chosen: the spaces using it.
        XCTAssertEqual(parse(everySpace: false, profile: "space-SHARED")?.spaces.map(\.name), ["Personal"])
        XCTAssertEqual(parse(everySpace: false, profile: "space-AAAA")?.spaces.map(\.name), ["Work"])
    }

    // MARK: - Dia

    func testDiasKeyIsDerivedAsDiaDerivesIt() {
        // Worked out separately (Python's hashlib/hmac) for a made-up secret.
        let root = Chromium.stretchedKey("search-test-secret")
        XCTAssertEqual(Data(root).map { String(format: "%02x", $0) }.joined(), "d61adb8cd8f7eed84c98a8af0b0d6849")
        XCTAssertEqual(DiaTabs.key(root: root, profile: "Default").map { String(format: "%02x", $0) }.joined(),
                       "dece82845ecdfca52e785ce3ea956c43b7decc959e11ac9ad53e53d0c6c022f2")
    }

    func testDiasSidebarDecryptsAndReadsWithItsSpacesFavouritesPinsAndFolders() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("search-dia-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scratchRoot = scratch.resolvingSymlinksInPath()
        let plainFile = scratchRoot.appendingPathComponent("plain.db")
        try Self.makeDiaDatabase(at: plainFile)
        let key = DiaTabs.key(root: Chromium.stretchedKey("search-test-secret"), profile: "Default")
        let encrypted = scratchRoot.appendingPathComponent("tabs.db")
        try Self.encrypt(Data(contentsOf: plainFile), key: key).write(to: encrypted)

        XCTAssertNil(DiaTabs.decrypt(encrypted, inside: scratchRoot, key: Data(repeating: 7, count: 32)), "a wrong key opens nothing")
        let plain = try XCTUnwrap(DiaTabs.decrypt(encrypted, inside: scratchRoot, key: key))
        let spaces = try XCTUnwrap(DiaTabs.read(plain, profile: "Default"))
        XCTAssertEqual(spaces.map(\.name), ["Home", "Work"])
        let home = spaces[0]
        XCTAssertEqual(home.profile, "Default")
        XCTAssertEqual(home.colour, 3)
        XCTAssertEqual(home.favorites, [.init(title: "Mail", url: url("https://mail.example.com/"))])
        XCTAssertEqual(home.pinned, [
            .item(.init(title: "My docs", url: url("https://docs.example.com/"))),
            .folder(.init(title: "Reading", items: [
                .item(.init(title: "Left", url: url("https://left.example.com/"))),
                .item(.init(title: "Right", url: url("https://right.example.com/"))),
                .folder(.init(title: "Deep", items: [.item(.init(title: "Deep read", url: url("https://deep.example.com/")))])),
            ])),
        ])
        XCTAssertEqual(spaces[1].pinned, [.item(.init(title: "CI", url: url("https://ci.example.com/")))])
    }

    /// A Dia-shaped sidebar database, 80 bytes kept at the end of each page
    /// as SQLCipher keeps them.
    static func makeDiaDatabase(at file: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var reserve: Int32 = 80
        _ = sqlite3_file_control(db, "main", SQLITE_FCNTL_RESERVE_BYTES, &reserve)
        let sql = """
        PRAGMA page_size = 4096;
        CREATE TABLE spaces (id TEXT PRIMARY KEY, title TEXT, creation_date TEXT, theme TEXT);
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, kind TEXT, entity_id TEXT, parent_id INTEGER, "order" INTEGER, deleted_at TEXT, space_id TEXT);
        CREATE TABLE tab_groups (id TEXT PRIMARY KEY, title TEXT);
        CREATE TABLE content_panes (id TEXT PRIMARY KEY, custom_title TEXT);
        CREATE TABLE web_contents (id INTEGER PRIMARY KEY, content_pane_id TEXT, url TEXT, title TEXT);
        INSERT INTO spaces VALUES ('home', 'Home', '2026-10-01 08:00:00.000', 'yellow'), ('work', 'Work', '2026-10-02 08:00:00.000', 'neutral');
        INSERT INTO nodes VALUES (1, 'pinned_container', 'pc1', NULL, 0, NULL, 'home'), (2, 'pinned_container', 'pc2', NULL, 1, NULL, 'work'),
          (3, 'favorites', 'fav1', NULL, 2, NULL, 'home'),
          (4, 'tab', 't1', 3, 0, NULL, 'home'), (5, 'content_pane', 'p1', 4, 0, NULL, 'home'),
          (6, 'tab', 't2', 1, 0, NULL, 'home'), (7, 'content_pane', 'p2', 6, 0, NULL, 'home'),
          (8, 'group', 'g1', 1, 1, NULL, 'home'),
          (9, 'tab', 't3', 8, 0, NULL, 'home'), (10, 'content_pane', 'p3', 9, 0, NULL, 'home'), (11, 'content_pane', 'p4', 9, 1, NULL, 'home'),
          (12, 'group', 'g2', 8, 1, NULL, 'home'), (13, 'tab', 't4', 12, 0, NULL, 'home'), (14, 'content_pane', 'p5', 13, 0, NULL, 'home'),
          (15, 'tab', 't5', 1, 2, '2026-10-20 10:00:00', 'home'), (16, 'content_pane', 'p6', 15, 0, NULL, 'home'),
          (17, 'tab', 't6', 2, 0, NULL, 'work'), (18, 'content_pane', 'p7', 17, 0, NULL, 'work'),
          (19, 'window', 'w1', NULL, 3, NULL, 'home'), (20, 'tab', 't7', 19, 0, NULL, 'home'), (21, 'content_pane', 'p8', 20, 0, NULL, 'home');
        INSERT INTO tab_groups VALUES ('g1', 'Reading'), ('g2', 'Deep');
        INSERT INTO content_panes VALUES ('p1', NULL), ('p2', 'My docs'), ('p3', NULL), ('p4', NULL), ('p5', NULL), ('p6', NULL), ('p7', NULL), ('p8', NULL);
        INSERT INTO web_contents (content_pane_id, url, title) VALUES ('p1', 'https://mail.example.com/', 'Mail'), ('p2', 'https://docs.example.com/', 'Docs'),
          ('p3', 'https://left.example.com/', 'Left'), ('p4', 'https://right.example.com/', 'Right'), ('p5', 'https://deep.example.com/', 'Deep read'),
          ('p6', 'https://gone.example.com/', 'Deleted'), ('p7', 'https://ci.example.com/', 'CI'), ('p8', 'https://open.example.com/', 'Open');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// SQLCipher 4's pages, as Dia writes them: AES-256-CBC over each page
    /// but its last 80 bytes (the first page's first 16 too, a salt in place
    /// of SQLite's header), the IV after it.
    static func encrypt(_ plain: Data, key: Data) throws -> Data {
        let page = 4096, reserve = 80
        XCTAssertEqual(plain.count % page, 0)
        XCTAssertEqual(plain[20], 80, "SQLite kept the 80 bytes")
        var out = Data()
        for index in 0..<(plain.count / page) {
            let first = index == 0
            let start = index * page + (first ? 16 : 0)
            let body = plain.subdata(in: start..<(index + 1) * page - reserve)
            let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            var cipher = Data(count: body.count)
            var moved = 0
            let status = cipher.withUnsafeMutableBytes { o in body.withUnsafeBytes { i in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, v.baseAddress,
                        i.baseAddress, body.count, o.baseAddress, body.count, &moved)
            } } } }
            XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
            if first { out += Data(repeating: 0x5A, count: 16) }
            out += cipher + iv + Data(repeating: 0, count: reserve - 16)
        }
        return out
    }
}
