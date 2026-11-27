import Foundation
import XCTest
@testable import Search

/// A Firefox's or Zen's open tabs and tab groups, read from session stores
/// written here by hand (see ImportGeckoTabs.swift). Only synthetic files in
/// a scratch folder: no real browser's profile is read.
@available(macOS 14, *)
final class GeckoTabsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-gecko-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratch = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    static func firefoxStore() -> [String: Any] {
        func tab(_ url: String, _ title: String, pinned: Bool = false, group: String? = nil, index: Int = 1) -> [String: Any] {
            var out: [String: Any] = ["entries": [["url": "https://earlier.example/", "title": "Earlier"], ["url": url, "title": title]],
                                      "index": index, "pinned": pinned]
            if let group { out["groupId"] = group }
            return out
        }
        return ["windows": [
            ["tabs": [tab("https://pinned.example/", "Pinned", pinned: true, index: 2),
                      tab("https://one.example/", "One", group: "1712-1", index: 2),
                      tab("https://two.example/", "", group: "1712-1", index: 2),
                      tab("https://three.example/", "Three", group: "1712-2", index: 2),
                      tab("about:preferences", "Settings", index: 2),
                      tab("https://back.example/", "Back", index: 1)],
             "groups": [["id": "1712-1", "name": "Trip", "color": "blue", "collapsed": true],
                        ["id": "1712-2", "name": "", "color": "red", "collapsed": false]]],
            ["isPopup": true, "tabs": [tab("https://popup.example/", "Popup", index: 2)]],
            ["tabs": [tab("https://second.example/", "Second", index: 2)]],
        ], "_closedWindows": [["tabs": [tab("https://closed.example/", "Closed", index: 2)]]]]
    }

    func testFirefoxOpenTabsAndGroups() throws {
        let snapshot = MozillaSession.read(Self.firefoxStore(), leavingPins: false)
        XCTAssertEqual(snapshot.windows.count, 2, "the popup and the closed window stay behind")
        XCTAssertEqual(snapshot.windows[0].map(\.url.absoluteString),
                       ["https://pinned.example/", "https://one.example/", "https://two.example/", "https://three.example/",
                        "https://earlier.example/"])
        XCTAssertEqual(snapshot.windows[0].map(\.pinned), [true, false, false, false, false])
        XCTAssertEqual(snapshot.windows[0][2].title, "two.example", "a page with no title is called by its site")
        let trip = try XCTUnwrap(snapshot.windows[0][1].group)
        XCTAssertEqual(snapshot.windows[0][2].group, trip)
        XCTAssertEqual(snapshot.groups[trip], .init(title: "Trip", collapsed: true))
        let unnamed = try XCTUnwrap(snapshot.windows[0][3].group)
        XCTAssertEqual(snapshot.groups[unnamed]?.title, "Group 1")
        XCTAssertEqual(snapshot.tabs, 6)
    }

    func testZenOpenTabsLeaveItsPinsBehind() throws {
        let snapshot = MozillaSession.read(["windows": [ZenImportTests.sidebarFixture()]], leavingPins: true)
        XCTAssertEqual(snapshot.windows.joined().map(\.url.absoluteString), ["https://open.example/"])
        let group = try XCTUnwrap(snapshot.windows[0][0].group)
        XCTAssertEqual(snapshot.groups[group]?.title, "Reading")
    }

    func testMozillaSessionPicksTheNewestStore() throws {
        let profile = scratch.appendingPathComponent("fx", isDirectory: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
        let old = profile.appendingPathComponent("sessionstore.jsonlz4")
        let new = profile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4")
        try ZenImportTests.mozlz4(json: ["windows": [["tabs": [["entries": [["url": "https://old.example/"]], "index": 1]]]]]).write(to: old)
        try ZenImportTests.mozlz4(json: ["windows": [["tabs": [["entries": [["url": "https://new.example/"]], "index": 1]]]]]).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let top = try XCTUnwrap(MozillaSession.store(in: profile))
        XCTAssertEqual(MozillaSession.read(top, leavingPins: false).windows.first?.first?.url.absoluteString, "https://new.example/")
    }

    /// A Mac browser open with its last window closed keeps that window only
    /// among the closed ones: its tabs come from there (idea 1116).
    func testLastClosedWindowWhenNoneIsOpen() {
        var store = Self.firefoxStore()
        store["windows"] = []
        let snapshot = MozillaSession.read(store, leavingPins: false)
        XCTAssertEqual(snapshot.windows.joined().map(\.url.absoluteString), ["https://closed.example/"])
    }

    /// Zen's open tabs carry their space, and its spaces' names come with
    /// them, read from zen-sessions.jsonlz4 before any session store.
    func testZenTabsKeepTheirSpaceFromZensOwnFile() throws {
        let profile = scratch.appendingPathComponent("zen", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try ZenImportTests.mozlz4(json: ZenImportTests.sidebarFixture()).write(to: profile.appendingPathComponent("zen-sessions.jsonlz4"))
        let snapshot = Zen.sessionTabs(inProfile: profile)
        let open = try XCTUnwrap(snapshot.windows.first?.first)
        XCTAssertEqual(open.url.absoluteString, "https://open.example/")
        XCTAssertEqual(open.space.flatMap { snapshot.spaceNames[$0] }, "Work")
    }
}
