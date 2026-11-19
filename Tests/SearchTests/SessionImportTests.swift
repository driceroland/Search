import Foundation
import XCTest
import AppKit
@testable import Search

/// Open tabs and tab groups read from a Chromium session file. The vectors
/// below are written by hand in the test, field by field the way Chromium
/// writes them, so a wrong offset fails here rather than in someone's
/// browser. Only synthetic files: no real browser's session is read here.
/// First written by @timwuhaotian (#841).
final class SessionImportTests: XCTestCase {
    // MARK: - writing the vectors

    private func w16(_ v: UInt16, into data: inout Data) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    private func wi32(_ v: Int32, into data: inout Data) {
        for shift in [0, 8, 16, 24] as [Int32] {
            data.append(UInt8(truncatingIfNeeded: v >> shift))
        }
    }

    private func wu32(_ v: UInt32, into data: inout Data) {
        wi32(Int32(bitPattern: v), into: &data)
    }

    private func wu64(_ v: UInt64, into data: inout Data) {
        for shift in [0, 8, 16, 24, 32, 40, 48, 56] as [UInt64] {
            data.append(UInt8(truncatingIfNeeded: v >> shift))
        }
    }

    /// A pickle string: a byte count, the bytes, padding to four.
    private func wstr(_ s: String, into data: inout Data) {
        let bytes = Array(s.utf8)
        wi32(Int32(bytes.count), into: &data)
        data.append(contentsOf: bytes)
        data.append(contentsOf: [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4))
    }

    /// A pickle string16: a unit count, UTF-16LE, padding to four.
    private func wstr16(_ s: String, into data: inout Data) {
        var units: [UInt16] = []
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x10000 {
                units.append(UInt16(v))
            } else {
                let rest = v - 0x10000
                units.append(0xD800 + UInt16(rest >> 10))
                units.append(0xDC00 + UInt16(rest & 0x3FF))
            }
        }
        wi32(Int32(units.count), into: &data)
        for unit in units {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        data.append(contentsOf: [UInt8](repeating: 0, count: (4 - (units.count * 2) % 4) % 4))
    }

    private func frame(id: UInt8, body: Data) -> Data {
        var out = Data()
        w16(UInt16(body.count + 1), into: &out)
        out.append(id)
        out.append(body)
        return out
    }

    private func raw(_ ints: Int32...) -> Data {
        var out = Data()
        for v in ints { wi32(v, into: &out) }
        return out
    }

    /// An UpdateTabNavigation for one entry: tab, entry index, URL, title.
    private func navigation(tab: Int32, index: Int32, url: String, title: String) -> Data {
        var body = Data()
        wu32(0, into: &body) // the pickle's size, unread
        wi32(tab, into: &body)
        wi32(index, into: &body)
        wstr(url, into: &body)
        wstr16(title, into: &body)
        return frame(id: 6, body: body)
    }

    /// A SetTabGroup: tab, alignment padding, token, still grouped or not.
    private func grouping(tab: Int32, high: UInt64, low: UInt64, grouped: Bool = true) -> Data {
        var body = Data()
        wi32(tab, into: &body)
        wu32(0, into: &body)
        wu64(high, into: &body)
        wu64(low, into: &body)
        body.append(grouped ? 1 : 0)
        return frame(id: 25, body: body)
    }

    /// A SetTabGroupMetadata2: token, title, colour, folded, saved.
    private func metadata(high: UInt64, low: UInt64, title: String, collapsed: Bool = false) -> Data {
        var body = Data()
        wu32(0, into: &body)
        wu64(high, into: &body)
        wu64(low, into: &body)
        wstr16(title, into: &body)
        wu32(1, into: &body)
        wi32(collapsed ? 1 : 0, into: &body)
        wi32(0, into: &body)
        return frame(id: 27, body: body)
    }

    private func session(_ frames: Data...) -> Data {
        var out = Data("SNSS".utf8)
        wi32(3, into: &out)
        for f in frames { out.append(f) }
        return out
    }

    // MARK: - reading

    func testWindowsTabsAndGroups() {
        let data = session(
            frame(id: 9, body: raw(7, 0)), // window 7, normal
            frame(id: 0, body: raw(7, 101)),
            frame(id: 2, body: raw(101, 1)),
            navigation(tab: 101, index: 0, url: "https://b.example/", title: "B"),
            frame(id: 7, body: raw(101, 0)),
            frame(id: 0, body: raw(7, 100)),
            frame(id: 2, body: raw(100, 0)),
            navigation(tab: 100, index: 0, url: "https://a.example/", title: "A"),
            grouping(tab: 100, high: 1, low: 2),
            grouping(tab: 101, high: 1, low: 2),
            metadata(high: 1, low: 2, title: "Work", collapsed: true),
            frame(id: 0, body: raw(7, 102)),
            frame(id: 2, body: raw(102, 2)),
            navigation(tab: 102, index: 0, url: "https://c.example/", title: "C"),
            frame(id: 12, body: raw(102) + Data([1])), // pinned
            // A popup window's tabs are its own business.
            frame(id: 9, body: raw(8, 1)),
            frame(id: 0, body: raw(8, 200)),
            navigation(tab: 200, index: 0, url: "https://popup.example/", title: "P"),
            // A closed tab leaves nothing behind.
            frame(id: 0, body: raw(7, 103)),
            navigation(tab: 103, index: 0, url: "https://gone.example/", title: "Gone"),
            frame(id: 16, body: raw(103)),
            // Not a page to keep.
            frame(id: 0, body: raw(7, 104)),
            frame(id: 2, body: raw(104, 3)),
            navigation(tab: 104, index: 0, url: "chrome://newtab/", title: "New Tab")
        )
        let read = SessionImport.read(data)
        XCTAssertEqual(read.windows.count, 1)
        let tabs = read.windows[0]
        XCTAssertEqual(tabs.map(\.url.absoluteString),
                       ["https://a.example/", "https://b.example/", "https://c.example/"])
        XCTAssertEqual(tabs[0].title, "A")
        XCTAssertFalse(tabs[0].pinned)
        XCTAssertTrue(tabs[2].pinned)
        // Pins are never in a group, even a grouped one.
        XCTAssertEqual(read.groups.count, 1)
        let token = SessionImport.Token(high: 1, low: 2)
        XCTAssertEqual(read.groups[token]?.title, "Work")
        XCTAssertEqual(read.groups[token]?.collapsed, true)
        XCTAssertEqual(tabs[0].group, token)
        XCTAssertEqual(tabs[1].group, token)
        XCTAssertNil(tabs[2].group)
        XCTAssertEqual(read.tabs, 3)
    }

    func testSelectedEntryUngroupingAndShortMetadata() {
        let data = session(
            frame(id: 0, body: raw(7, 105)),
            frame(id: 2, body: raw(105, 0)),
            navigation(tab: 105, index: 0, url: "https://old.example/", title: "Old"),
            navigation(tab: 105, index: 1, url: "https://new.example/", title: "New"),
            frame(id: 7, body: raw(105, 0)), // went back: the old entry shows
            frame(id: 0, body: raw(7, 106)),
            grouping(tab: 106, high: 5, low: 6),
            navigation(tab: 106, index: 0, url: "https://g.example/", title: "G"),
            grouping(tab: 106, high: 5, low: 6, grouped: false),
            // Metadata from before folding was stored: name and colour only.
            {
                var body = Data()
                self.wu32(0, into: &body)
                self.wu64(9, into: &body)
                self.wu64(9, into: &body)
                self.wstr16("Short", into: &body)
                self.wu32(2, into: &body)
                return self.frame(id: 27, body: body)
            }(),
            frame(id: 0, body: raw(7, 107)),
            grouping(tab: 107, high: 9, low: 9),
            navigation(tab: 107, index: 0, url: "https://h.example/", title: "H")
        )
        let read = SessionImport.read(data)
        let tabs = read.windows.flatMap { $0 }
        XCTAssertEqual(tabs.first { $0.url.absoluteString == "https://old.example/" }?.title, "Old")
        XCTAssertNil(tabs.first { $0.url.absoluteString == "https://new.example/" })
        XCTAssertNil(tabs.first { $0.url.absoluteString == "https://g.example/" }?.group)
        let short = read.groups[SessionImport.Token(high: 9, low: 9)]
        XCTAssertEqual(short?.title, "Short")
        XCTAssertEqual(short?.collapsed, false)
        // Ungrouped away, the group has no tabs and is gone with it.
        XCTAssertNil(read.groups[SessionImport.Token(high: 5, low: 6)])
    }

    func testTornTailUnknownCommandsAndVersions() {
        let good = session(
            frame(id: 0, body: raw(7, 101)),
            navigation(tab: 101, index: 0, url: "https://a.example/", title: "A"),
            frame(id: 99, body: raw(1, 2, 3)) // a newer Chrome's command
        )
        var torn = good
        torn.append(contentsOf: [0x20, 0x00, 6]) // a frame Chrome never finished
        let read = SessionImport.read(torn)
        XCTAssertEqual(read.tabs, 1)

        var magic = Data("X NSS".utf8)
        wi32(3, into: &magic)
        XCTAssertTrue(SessionImport.read(magic).windows.isEmpty)

        var encrypted = Data("SNSS".utf8)
        wi32(5, into: &encrypted)
        XCTAssertTrue(SessionImport.read(encrypted).windows.isEmpty)

        XCTAssertTrue(SessionImport.read(Data()).windows.isEmpty)
    }

    // MARK: - hostile files

    func testHugePruneCountIsQuickAndShiftsLaterEntries() {
        let data = session(
            frame(id: 0, body: raw(7, 101)),
            navigation(tab: 101, index: 0, url: "https://zero.example/", title: "0"),
            navigation(tab: 101, index: 1, url: "https://one.example/", title: "1"),
            navigation(tab: 101, index: 2, url: "https://two.example/", title: "2"),
            navigation(tab: 101, index: 3, url: "https://three.example/", title: "3"),
            frame(id: 7, body: raw(101, 3)),
            // Entries 1 and 2 go; 3 becomes 1, and stays the one showing.
            frame(id: 24, body: raw(101, 1, 2)),
            frame(id: 0, body: raw(7, 102)),
            navigation(tab: 102, index: 0, url: "https://kept.example/", title: "K"),
            navigation(tab: 102, index: 5, url: "https://late.example/", title: "L"),
            frame(id: 7, body: raw(102, 0)),
            // A count the file made up: only the entries there are looked at.
            frame(id: 24, body: raw(102, 1, Int32.max)),
            frame(id: 24, body: raw(102, Int32.max, Int32.max)),
            frame(id: 24, body: raw(102, -5, 3))
        )
        let started = Date()
        let read = SessionImport.read(data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(read.windows.joined().map(\.url.absoluteString),
                       ["https://three.example/", "https://kept.example/"])
    }

    func testPruneOverTheShowingEntryShowsTheOneBefore() {
        let data = session(
            frame(id: 0, body: raw(7, 101)),
            navigation(tab: 101, index: 0, url: "https://a.example/", title: "A"),
            navigation(tab: 101, index: 1, url: "https://b.example/", title: "B"),
            navigation(tab: 101, index: 2, url: "https://c.example/", title: "C"),
            frame(id: 7, body: raw(101, 1)),
            frame(id: 24, body: raw(101, 1, 2))
        )
        XCTAssertEqual(SessionImport.read(data).windows.joined().map(\.url.absoluteString), ["https://a.example/"])
    }

    func testTornAndMadeUpFramesReadNothingWorseThanNothing() {
        // A navigation whose strings claim more than the frame holds, a
        // group with no token, metadata too short, a frame running past the end.
        var data = session(
            frame(id: 0, body: raw(7, 101)),
            navigation(tab: 101, index: 0, url: "https://a.example/", title: "A")
        )
        var lying = Data()
        wu32(0, into: &lying)
        wi32(102, into: &lying)
        wi32(0, into: &lying)
        wi32(Int32.max, into: &lying) // the address's length
        data.append(frame(id: 6, body: lying))
        var lyingTitle = Data()
        wu32(0, into: &lyingTitle)
        wi32(103, into: &lyingTitle)
        wi32(0, into: &lyingTitle)
        wstr("https://t.example/", into: &lyingTitle)
        wi32(Int32.max, into: &lyingTitle) // the title's length
        data.append(frame(id: 6, body: lyingTitle))
        data.append(frame(id: 25, body: raw(101)))
        data.append(frame(id: 27, body: Data([1, 2, 3])))
        data.append(contentsOf: [0xFF, 0xFF, 0x06, 0x01])
        let read = SessionImport.read(data)
        XCTAssertEqual(read.windows.joined().map(\.url.absoluteString), ["https://a.example/"])
        XCTAssertNil(read.windows.joined().first?.group)

        var zero = session()
        zero.append(contentsOf: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(SessionImport.read(zero).windows.isEmpty)

        // Noise after a good header, the same noise every run: never a trap.
        var generator = SplitMix(seed: 841)
        for _ in 0 ..< 200 {
            var noise = session()
            noise.append(contentsOf: (0 ..< Int(generator.next() % 4096)).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            _ = SessionImport.read(noise)
        }
    }

    func testAtMostTheLimitComeOver() {
        var frames = Data()
        for tab in Int32(1) ... 400 {
            frames.append(frame(id: 0, body: raw(7, tab)))
            frames.append(frame(id: 2, body: raw(tab, tab)))
            frames.append(navigation(tab: tab, index: 0, url: "https://\(tab).example/", title: "\(tab)"))
            if tab > 290 { frames.append(grouping(tab: tab, high: UInt64(tab), low: 1)) }
        }
        let read = SessionImport.read(session(frames))
        XCTAssertEqual(read.tabs, 400)
        let capped = read.capped()
        XCTAssertEqual(capped.tabs, SessionImport.limit)
        XCTAssertEqual(capped.found, 400)
        XCTAssertEqual(capped.windows[0].last?.url.absoluteString, "https://300.example/")
        XCTAssertEqual(capped.groups.count, 10, "only the groups the kept tabs are in")
    }

    // MARK: - bringing them in

    @MainActor
    func testTakeSessionBringsTabsAsleepGroupsAndPinsOnce() throws {
        let world = "session-import-tests-\(UUID().uuidString.lowercased())"
        setenv("SEARCH_PROBE", world, 1)
        defer {
            Disk.drain()
            if Store.world == world { try? FileManager.default.removeItem(at: Store.folder) }
            UserDefaults(suiteName: "com.officecommun.search.test.\(world)")?
                .removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
            unsetenv("SEARCH_PROBE")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let pinsBefore = Pins.defs(browser.spaceID)
        defer { Pins.set(browser.spaceID, pinsBefore, from: browser) }

        let read = SessionImport.read(session(
            frame(id: 0, body: raw(7, 100)),
            frame(id: 2, body: raw(100, 0)),
            navigation(tab: 100, index: 0, url: "https://pinned-841.example/", title: "Pinned"),
            frame(id: 12, body: raw(100) + Data([1])),
            frame(id: 0, body: raw(7, 101)),
            frame(id: 2, body: raw(101, 1)),
            navigation(tab: 101, index: 0, url: "https://grouped-841.example/", title: "Grouped"),
            grouping(tab: 101, high: 3, low: 4),
            metadata(high: 3, low: 4, title: "Reading 841", collapsed: true),
            frame(id: 0, body: raw(7, 102)),
            frame(id: 2, body: raw(102, 2)),
            navigation(tab: 102, index: 0, url: "https://loose-841.example/", title: "Loose")
        ))
        let got = browser.takeSession(read)
        XCTAssertEqual(got.pins, 1)
        XCTAssertEqual(got.tabs, 2)
        XCTAssertEqual(got.groups, 1)
        let mine: Set<String> = ["https://grouped-841.example/", "https://loose-841.example/"]
        let added = browser.tabs.filter { $0.pending.map { mine.contains($0.absoluteString) } ?? false }
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.allSatisfy(\.asleep), "brought in asleep, not loading")
        let group = try XCTUnwrap(browser.tabGroups.first { $0.name == "Reading 841" })
        XCTAssertTrue(group.collapsed)
        XCTAssertEqual(added.first { $0.pending?.host() == "grouped-841.example" }?.groupID, group.id)
        XCTAssertTrue(Pins.defs(browser.spaceID).contains { $0.home == "https://pinned-841.example/" })

        let again = browser.takeSession(read)
        XCTAssertEqual(again.pins + again.tabs + again.groups, 0, "nothing twice")
        XCTAssertEqual(browser.tabs.filter { $0.pending.map { mine.contains($0.absoluteString) } ?? false }.count, 2)
    }

    // MARK: - finding the file

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("Default/Sessions")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // A profile counts when it holds a browser file; every real one does.
        try Data("{}".utf8).write(to: root.appendingPathComponent("Default/Bookmarks"))
        return root
    }

    private func sessionFile(_ name: String, in profile: URL, _ data: Data, date: Date? = nil) throws {
        let file = profile.appendingPathComponent(name)
        try data.write(to: file)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
    }

    func testNewestSessionWins() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default")
        let one = session(frame(id: 0, body: raw(7, 101)),
                          navigation(tab: 101, index: 0, url: "https://old.example/", title: "Old"))
        let two = session(frame(id: 0, body: raw(7, 102)),
                          navigation(tab: 102, index: 0, url: "https://new.example/", title: "New"))
        try sessionFile("Sessions/Session_100", in: profile, two,
                        date: Date(timeIntervalSince1970: 1_700_000_000))
        try sessionFile("Sessions/Session_200", in: profile, one,
                        date: Date(timeIntervalSince1970: 1_700_000_100))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "",
                                     rootOverride: root)
        let read = Chromium.sessions(in: source, profile: "Default")
        // The newer file wins, whatever the names say.
        XCTAssertEqual(read.tabs, 1)
        XCTAssertEqual(read.windows[0][0].url.absoluteString, "https://old.example/")
    }

    func testLegacySessionBesideTheProfile() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default")
        try sessionFile("Current Session", in: profile,
                        session(frame(id: 0, body: raw(7, 101)),
                                navigation(tab: 101, index: 0, url: "https://a.example/", title: "A")))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "",
                                     rootOverride: root)
        XCTAssertEqual(Chromium.sessions(in: source, profile: "Default").tabs, 1)
    }

    func testLinkedSessionReadsNothing() throws {
        // A session link cannot leave the browser's folder, the way no
        // other import read can.
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("browser")
        let outside = parent.appendingPathComponent("browser-other")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Sessions"),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Default/Bookmarks"))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("Session_x")
        try session(frame(id: 0, body: raw(7, 101)),
                    navigation(tab: 101, index: 0, url: "https://a.example/", title: "A"))
            .write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Default/Sessions/Session_x"), withDestinationURL: target)
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "",
                                     rootOverride: root)
        XCTAssertTrue(Chromium.sessions(in: source, profile: "Default").windows.isEmpty)
    }
}

/// A small seeded generator, so the noise test reads the same bytes each run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
