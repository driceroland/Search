import Foundation
import XCTest
import SQLite3
@testable import Search

/// Orion's bookmarks and history, read from files written here in the shape
/// Orion keeps them (see ImportWebKit.swift), in the test world's own Import
/// folder: never a real browser's.
final class WebKitImportTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "webkit-import-\(ProcessInfo.processInfo.processIdentifier)", 1)
        super.setUp()
    }

    private var orion: URL { Chromium.base.appendingPathComponent("Orion", isDirectory: true) }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: orion)
    }

    static let favourites: [String: Any] = [
        "f-bar": ["id": "f-bar", "type": "folder", "title": "Favorites", "index": 0, "parentId": "root"],
        "f-work": ["id": "f-work", "type": "folder", "title": "Work", "index": 1, "parentId": "f-bar"],
        "b-docs": ["id": "b-docs", "type": "bookmark", "title": "Docs", "url": "https://docs.example/", "index": 0, "parentId": "f-work"],
        "b-kagi": ["id": "b-kagi", "type": "bookmark", "title": "Kagi", "url": "https://kagi.example/", "index": 0, "parentId": "f-bar"],
        "b-loose": ["id": "b-loose", "type": "bookmark", "title": "", "url": "https://loose.example/", "index": 1, "parentId": "root"],
        "b-bad": ["id": "b-bad", "type": "bookmark", "title": "Bad", "url": "javascript:void(0)", "index": 2, "parentId": "root"],
        "f-empty": ["id": "f-empty", "type": "folder", "title": "Empty", "index": 3, "parentId": "root"],
        "f-loop": ["id": "f-loop", "type": "folder", "title": "Loop", "index": 4, "parentId": "f-loop"],
    ]

    func testOrionFavouritesRebuildTheirFolders() throws {
        let items = try XCTUnwrap(WebKitBrowser.orionItems(Self.favourites))
        let tree = WebKitBrowser.orionTree(items)
        XCTAssertEqual(tree.count, 2, "Favorites and the loose page; the script, the empty folder and the loop stay behind")
        XCTAssertEqual(tree[0].title, "Favorites")
        XCTAssertEqual(tree[1].url, "https://loose.example/")
        XCTAssertFalse(tree[1].title.isEmpty, "a page with no name is called by its address")
        let inBar = tree[0].children ?? []
        XCTAssertEqual(inBar.map(\.title), ["Kagi", "Work"])
        XCTAssertEqual(inBar[1].children?.map(\.url), ["https://docs.example/"])
    }

    func testOrionProfileIsFoundAndRead() throws {
        let defaults = orion.appendingPathComponent("Defaults", isDirectory: true)
        let other = orion.appendingPathComponent("A1B2-PROFILE", isDirectory: true)
        try FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orion.appendingPathComponent("bk_2026"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: Self.favourites, format: .binary, options: 0)
            .write(to: defaults.appendingPathComponent("favourites.plist"))
        try PropertyListSerialization.data(fromPropertyList: [["defaults": ["name": "Personal"],
                                                               "profiles": [["identifier": "A1B2-PROFILE", "name": "Work"]]]],
                                           format: .xml, options: 0)
            .write(to: orion.appendingPathComponent("profiles"))

        var db: OpaquePointer?
        let history = other.appendingPathComponent("history")
        XCTAssertEqual(sqlite3_open(history.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE history_items (ID INTEGER PRIMARY KEY, URL TEXT, TITLE TEXT, VISIT_COUNT INTEGER, LAST_VISIT_TIME);
        INSERT INTO history_items VALUES (1, 'https://old.example/', 'Old', 3, 700000000);
        INSERT INTO history_items VALUES (2, 'https://new.example/', 'New', 1, '2026-11-01 10:00:00');
        INSERT INTO history_items VALUES (3, 'file:///etc/hosts', 'File', 9, 800000000);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let source = try XCTUnwrap(ImportSource.installed().first { $0.name == "Orion" })
        XCTAssertEqual(source.profiles.map(\.id), ["Defaults", "A1B2-PROFILE"])
        XCTAssertEqual(source.profiles.map(\.name), ["Personal", "Work"])
        XCTAssertFalse(source.importsPasswords)
        XCTAssertTrue(source.passwordsInPasswordsApp)
        XCTAssertFalse(source.readsOpenTabs)
        XCTAssertEqual(source.preview(profile: "Defaults").bookmarks, 3)
        let places = source.places(profile: "A1B2-PROFILE")
        XCTAssertEqual(places.map(\.url.absoluteString), ["https://new.example/", "https://old.example/"])
        XCTAssertEqual(places[1].last, Date(timeIntervalSince1970: 700_000_000 + WebKitBrowser.appleEpoch))
        XCTAssertThrowsError(try source.read())
    }

    func testOrionWrittenDates() {
        XCTAssertNotNil(WebKitBrowser.written("2026-11-01T10:00:00Z"))
        XCTAssertNotNil(WebKitBrowser.written("2026-11-01 10:00:00"))
        XCTAssertEqual(WebKitBrowser.written("0.0"), nil)
        XCTAssertNil(WebKitBrowser.written("yesterday"))
    }
}
