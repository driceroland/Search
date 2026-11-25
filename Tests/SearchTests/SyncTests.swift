import Foundation
import XCTest
@testable import Search

/// Sync through a shared folder (Sync.swift, SyncMerge.swift): Macs that
/// each write only their own file agree, item by item, whatever order they
/// run in — edits on both, deletions, clocks that disagree, a Mac joining
/// late, files that are damaged or belong to another profile.
@MainActor
final class SyncTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-sync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// One Mac: what it has, what it last agreed, its own clock. A pass
    /// reads the others' files from the folder and writes its own there,
    /// through the same encode and decode the app uses.
    final class Mac {
        let device: String
        var items: [String: String]
        var base: [String: SyncEntry]?
        /// Seconds this Mac's clock is off by.
        var skew: Double = 0
        let scope: String
        let folder: URL

        init(_ device: String, _ items: [String: String] = [:], scope: String = "app", folder: URL) {
            self.device = device
            self.items = items
            self.scope = scope
            self.folder = folder.appendingPathComponent(scope, isDirectory: true)
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        }

        var file: URL { folder.appendingPathComponent(device + ".json") }

        @discardableResult
        func pass(at now: Double, understood: (String, String) -> Bool = { _, _ in true }) -> [String: SyncEntry] {
            var theirs: [[String: SyncEntry]] = []
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent != file.lastPathComponent {
                guard let data = try? Data(contentsOf: url), let read = SyncMerge.decode(data, scope: scope),
                      read.device != device else { continue }
                theirs.append(read.items)
            }
            let merged = SyncMerge.pass(current: items, base: base, theirs: theirs, device: device,
                                        now: now + skew, understood: understood)
            items = SyncMerge.live(merged)
            base = merged
            let out = SyncFile(format: SyncMerge.format, device: device, name: device, scope: scope, written: now, items: merged)
            try? SyncMerge.encode(out)?.write(to: file, options: .atomic)
            return merged
        }
    }

    private func mac(_ device: String, _ items: [String: String] = [:], scope: String = "app") -> Mac {
        Mac(device, items, scope: scope, folder: folder)
    }

    /// Every Mac passes until nothing changes: what they all end with.
    private func settle(_ macs: [Mac], from start: Double) {
        var now = start
        for _ in 0..<4 {
            for mac in macs {
                now += 1
                mac.pass(at: now)
            }
        }
    }

    // MARK: - the merge

    func testEditsOnTwoMacsBothArrive() {
        let a = mac("A", ["x": "1"]), b = mac("B")
        settle([a, b], from: 1000)
        a.items["a-only"] = "a"
        b.items["b-only"] = "b"
        settle([a, b], from: 2000)
        XCTAssertEqual(a.items, ["x": "1", "a-only": "a", "b-only": "b"])
        XCTAssertEqual(b.items, a.items)
    }

    func testTheLaterEditOfOneItemWins() {
        let a = mac("A", ["name": "\"Work\""]), b = mac("B")
        settle([a, b], from: 1000)
        a.items["name"] = "\"Office\""
        b.items["name"] = "\"Studio\""
        // A passes first, B a second later: B's edit is the later one.
        a.pass(at: 2000)
        b.pass(at: 2001)
        settle([a, b], from: 2002)
        XCTAssertEqual(a.items["name"], "\"Studio\"")
        XCTAssertEqual(b.items["name"], "\"Studio\"")
    }

    func testADeletionTravelsAndStaysDeleted() {
        let a = mac("A", ["keep": "1", "drop": "2"]), b = mac("B")
        settle([a, b], from: 1000)
        XCTAssertEqual(b.items["drop"], "2")
        a.items["drop"] = nil
        settle([a, b], from: 2000)
        XCTAssertNil(b.items["drop"])
        XCTAssertNil(a.items["drop"])
        XCTAssertEqual(b.items["keep"], "1")
        // Still a tombstone in every file, so a third Mac doesn't bring it back.
        XCTAssertNil(a.base?["drop"]?.v)
        XCTAssertNotNil(a.base?["drop"])
    }

    func testAnEditAfterADeletionBringsItBackAndADeletionAfterAnEditWins() {
        let a = mac("A", ["x": "1"]), b = mac("B")
        settle([a, b], from: 1000)
        // A deletes, then B edits later, before seeing the deletion.
        a.items["x"] = nil
        a.pass(at: 2000)
        b.items["x"] = "2"
        b.pass(at: 2005)
        settle([a, b], from: 2010)
        XCTAssertEqual(a.items["x"], "2")
        XCTAssertEqual(b.items["x"], "2")
        // B edits, then A deletes later: gone.
        b.items["x"] = "3"
        b.pass(at: 3000)
        a.items["x"] = nil
        a.pass(at: 3005)
        settle([a, b], from: 3010)
        XCTAssertNil(a.items["x"])
        XCTAssertNil(b.items["x"])
    }

    func testAMacWhoseClockIsBehindStillWinsWithAnEditMadeAfterItSawTheValue() {
        let a = mac("A", ["x": "1"]), b = mac("B")
        b.skew = 3600 // an hour ahead
        settle([a, b], from: 1000)
        b.items["x"] = "from B"
        b.pass(at: 2000) // stamped about 5600
        a.pass(at: 2001) // A sees it
        XCTAssertEqual(a.items["x"], "from B")
        a.items["x"] = "from A" // A's clock says 2002, behind B's stamp
        settle([a, b], from: 2002)
        XCTAssertEqual(a.items["x"], "from A")
        XCTAssertEqual(b.items["x"], "from A")
    }

    func testAMacJoiningTakesWhatIsAgreedAndAddsWhatOnlyItHas() {
        let a = mac("A", ["set:look": "\"dark\"", "space:shared": "\"A's name\""])
        a.pass(at: 1000) // alone in the folder: its values are the folder's
        // A late Mac with every setting at its default and one thing of its own.
        let b = mac("B", ["set:look": "\"light\"", "space:shared": "\"B's name\"", "space:b": "\"mine\""])
        settle([b, a], from: 5000)
        XCTAssertEqual(b.items["set:look"], "\"dark\"")
        XCTAssertEqual(b.items["space:shared"], "\"A's name\"")
        XCTAssertEqual(a.items["space:b"], "\"mine\"")
        XCTAssertEqual(a.items, b.items)
    }

    func testTheFirstMacInAnEmptyFolderStampsItsValues() {
        let a = mac("A", ["x": "1"])
        let merged = a.pass(at: 1000)
        XCTAssertEqual(merged["x"]?.t, 1000)
    }

    func testTheMergeIsTheSameInAnyOrder() {
        let maps: [[String: SyncEntry]] = [
            ["k": SyncEntry(v: "1", t: 5, d: "A"), "j": SyncEntry(v: nil, t: 3, d: "A")],
            ["k": SyncEntry(v: "2", t: 5, d: "B"), "j": SyncEntry(v: "x", t: 3, d: "A")],
            ["k": SyncEntry(v: "0", t: 4, d: "C"), "i": SyncEntry(v: "y", t: 1, d: "C")],
        ]
        let one = SyncMerge.merge(maps)
        XCTAssertEqual(SyncMerge.merge(maps.reversed()), one)
        XCTAssertEqual(SyncMerge.merge([maps[1], maps[2], maps[0]]), one)
        XCTAssertEqual(one["k"]?.v, "2") // same time: the device id decides
        XCTAssertNil(one["j"]?.v) // same time and device: the deletion
    }

    func testANewPassWithNothingChangedChangesNothing() {
        let a = mac("A", ["x": "1"]), b = mac("B", ["y": "2"])
        settle([a, b], from: 1000)
        let before = a.base
        let written = try? Data(contentsOf: a.file)
        let after = a.pass(at: 9000)
        XCTAssertEqual(after, before)
        let again = (try? Data(contentsOf: a.file)).flatMap { SyncMerge.decode($0, scope: "app") }
        XCTAssertEqual(again?.items, written.flatMap { SyncMerge.decode($0, scope: "app") }?.items)
    }

    func testOldDeletionsAreForgotten() {
        let year = SyncMerge.tombstoneLife
        let map = ["gone": SyncEntry(v: nil, t: 10, d: "A"), "recent": SyncEntry(v: nil, t: year, d: "A"),
                   "here": SyncEntry(v: "1", t: 10, d: "A")]
        let kept = SyncMerge.prune(map, now: year + 100)
        XCTAssertNil(kept["gone"])
        XCTAssertNotNil(kept["recent"])
        XCTAssertNotNil(kept["here"])
    }

    // MARK: - files that can't be trusted

    func testDamagedAndForeignFilesAreIgnoredAndDeleteNothing() throws {
        let a = mac("A", ["x": "1", "y": "2"])
        a.pass(at: 1000)
        let dir = folder.appendingPathComponent("app")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data().write(to: dir.appendingPathComponent("empty.json"))
        // A newer format, and a file of another profile's folder copied in.
        let newer = SyncFile(format: 99, device: "N", name: nil, scope: "app", written: 1, items: ["x": SyncEntry(v: nil, t: 1e12, d: "N")])
        try SyncMerge.encode(newer)!.write(to: dir.appendingPathComponent("N.json"))
        let elsewhere = SyncFile(format: 1, device: "P", name: nil, scope: "profile-other", written: 1, items: ["y": SyncEntry(v: nil, t: 1e12, d: "P")])
        try SyncMerge.encode(elsewhere)!.write(to: dir.appendingPathComponent("P.json"))
        // A readable file with one bad stamp: that entry alone is left out.
        let odd = SyncFile(format: 1, device: "O", name: nil, scope: "app", written: 1,
                           items: ["x": SyncEntry(v: nil, t: -5, d: "O"), "z": SyncEntry(v: "3", t: 2000, d: "O")])
        try SyncMerge.encode(odd)!.write(to: dir.appendingPathComponent("O.json"))
        a.pass(at: 3000)
        XCTAssertEqual(a.items, ["x": "1", "y": "2", "z": "3"])
        XCTAssertNil(SyncMerge.decode(Data("[]".utf8), scope: "app"))
    }

    func testAnItemThisBuildCantReadIsCarriedAndNeverDeleted() {
        let reads: (String, String) -> Bool = { key, _ in !key.hasPrefix("future:") }
        let a = mac("A", ["x": "1"]), b = mac("B")
        a.items["future:thing"] = "{}"
        a.pass(at: 1000, understood: reads)
        // B can't apply it, so B's own snapshot never has it.
        b.pass(at: 1001, understood: reads)
        b.items["future:thing"] = nil
        b.pass(at: 1002, understood: reads)
        XCTAssertEqual(b.base?["future:thing"]?.v, "{}")
        a.pass(at: 1003, understood: reads)
        XCTAssertEqual(a.items["future:thing"], "{}")
        XCTAssertFalse(SyncItems.understood("future:thing", "{}"))
        XCTAssertFalse(SyncItems.understood("space:\(UUID().uuidString)", "{broken"))
        XCTAssertTrue(SyncItems.understood("set:look", "\"dark\""))
    }

    func testEveryBookmarkVanishingAtOnceIsNotDeletedEverywhere() {
        let tree = (0..<6).map { Bookmark.site("Site \($0)", URL(string: "https://s\($0).example/")!) }
        let a = mac("A", SyncItems.bookmarks(tree), scope: Sync.scope(Profile.personalID))
        let b = mac("B", scope: Sync.scope(Profile.personalID))
        settle([a, b], from: 1000)
        // A's bookmarks file didn't read: the list is empty.
        a.items = [:]
        settle([a, b], from: 2000)
        XCTAssertEqual(SyncItems.applyBookmarks(b.items).count, 6)
        XCTAssertEqual(SyncItems.applyBookmarks(a.items).count, 6)
        // One removed on purpose still goes.
        a.items = SyncItems.bookmarks(Array(tree.dropFirst()))
        settle([a, b], from: 3000)
        XCTAssertEqual(SyncItems.applyBookmarks(b.items).map(\.id), tree.dropFirst().map(\.id))
    }

    func testEachProfileIsItsOwnFolder() {
        let work = UUID(), home = UUID()
        let aWork = mac("A", ["x": "work"], scope: Sync.scope(work))
        let aHome = mac("A", ["x": "home"], scope: Sync.scope(home))
        let bWork = mac("B", scope: Sync.scope(work))
        let bHome = mac("B", scope: Sync.scope(home))
        settle([aWork, aHome, bWork, bHome], from: 1000)
        XCTAssertEqual(bWork.items, ["x": "work"])
        XCTAssertEqual(bHome.items, ["x": "home"])
        XCTAssertNotEqual(Sync.scope(work), Sync.scope(home))
    }

    // MARK: - spaces

    private func space(_ name: String, id: UUID = UUID(), colour: Int = 0, icon: String? = nil, shares: Bool? = true) -> Space {
        Space(id: id, name: name, colour: colour, icon: icon, sharesSignIns: shares, downloads: nil, profile: nil)
    }

    func testSpacesGoAndComeBackTheSame() {
        let list = [Space.first(), space("Work", colour: 2, icon: "briefcase"), space("Play", shares: false)]
        let items = SyncItems.spaces(list)
        let back = SyncItems.applySpaces(items, to: [], profile: Profile.personalID, home: Space.firstID)
        XCTAssertEqual(back.map(\.id), list.map(\.id))
        XCTAssertEqual(SyncItems.spaces(back), items)
        XCTAssertEqual(back[2].sharesSignIns, false)
    }

    /// The order of a list is one item: the later list wins, and a space
    /// it doesn't name — made meanwhile on the other Mac — is kept, last.
    func testAReorderOnOneMacAndANewSpaceOnTheOtherBothStay() {
        let work = space("Work"), play = space("Play")
        let start = [Space.first(), work, play]
        let a = mac("A", SyncItems.spaces(start), scope: Sync.scope(Profile.personalID))
        let b = mac("B", scope: Sync.scope(Profile.personalID))
        settle([a, b], from: 1000)
        var bList = SyncItems.applySpaces(b.items, to: [], profile: Profile.personalID, home: Space.firstID)
        let new = space("New")
        bList.append(new)
        b.items = SyncItems.spaces(bList)
        b.pass(at: 2000)
        // A reorders a moment later, without having seen the new space.
        a.items = SyncItems.spaces([play, Space.first(), work])
        a.pass(at: 2001)
        settle([a, b], from: 2002)
        let final = SyncItems.applySpaces(a.items, to: [], profile: Profile.personalID, home: Space.firstID)
        XCTAssertEqual(final.map(\.name), ["Play", "Personal", "Work", "New"])
        XCTAssertEqual(SyncItems.applySpaces(b.items, to: bList, profile: Profile.personalID, home: Space.firstID).map(\.id), final.map(\.id))
    }

    func testASpaceDeletedElsewhereGoesButTheHomeNeverDoes() {
        let work = space("Work")
        let local = [Space.first(), work]
        var items = SyncItems.spaces(local)
        items[SyncItems.spaceKey(work.id)] = nil
        items[SyncItems.spaceKey(Space.firstID)] = nil
        let after = SyncItems.applySpaces(items, to: local, profile: Profile.personalID, home: Space.firstID)
        XCTAssertEqual(after.map(\.id), [Space.firstID])
    }

    func testWhatIsOnlyThisMacsStaysAndSignInsNeverChangeOnASpaceThatExists() {
        var mine = space("Work", shares: false)
        mine.downloads = "/Users/me/Work"
        var theirs = mine
        theirs.name = "Studio"
        theirs.sharesSignIns = true
        theirs.downloads = "/Users/them/Elsewhere"
        let after = SyncItems.applySpaces(SyncItems.spaces([Space.first(), theirs]), to: [Space.first(), mine],
                                          profile: Profile.personalID, home: Space.firstID)
        XCTAssertEqual(after[1].name, "Studio")
        XCTAssertEqual(after[1].downloads, "/Users/me/Work")
        XCTAssertEqual(after[1].sharesSignIns, false)
        // And this Mac doesn't then argue: its items say what was agreed.
        let agreed = SyncItems.spaces([Space.first(), theirs])
        XCTAssertEqual(SyncItems.spaces(after, base: agreed), agreed)
    }

    func testASpaceOfAnotherProfileIsMadeInThatProfile() {
        let profile = UUID()
        let home = space("Clients")
        let made = SyncItems.applySpaces(SyncItems.spaces([home]), to: [], profile: profile, home: home.id)
        XCTAssertEqual(made.first?.profile, profile)
    }

    // MARK: - pins

    private func pin(_ letter: String, _ home: String, title: String = "Title", listed: Bool? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: home, title: title, name: nil, listed: listed)
    }

    func testPinsGoAndComeBackTheSame() {
        let s = UUID()
        let own = [pin("M", "https://mail.example/"), pin("C", "https://cal.example/", listed: true)]
        let shared = [pin("N", "https://notes.example/")]
        let items = SyncItems.pins(bySpace: [s: own], shared: shared, base: [:])
        let back = SyncItems.applyPins(items, spaces: [s], local: [:], localShared: [])
        XCTAssertEqual(back.bySpace[s], own)
        XCTAssertEqual(back.shared, shared)
    }

    func testAPinsPageTitleNeverCountsAsAnEdit() {
        let s = UUID()
        var mail = pin("M", "https://mail.example/", title: "Inbox (3)")
        let agreed = SyncItems.pins(bySpace: [s: [mail]], shared: [], base: [:])
        mail.title = "Inbox (4)"
        XCTAssertEqual(SyncItems.pins(bySpace: [s: [mail]], shared: [], base: agreed), agreed)
    }

    func testAPinSharedOnOneMacAndEditedOnAnotherIsShownOnce() {
        let s = UUID()
        var mail = pin("M", "https://mail.example/")
        var items = SyncItems.pins(bySpace: [s: [mail]], shared: [mail], base: [:])
        mail.letter = "E"
        items.merge(SyncItems.pins(bySpace: [s: [mail]], shared: [], base: [:])) { _, new in new }
        let back = SyncItems.applyPins(items, spaces: [s], local: [:], localShared: [])
        XCTAssertEqual(back.shared.map(\.id), [mail.id])
        XCTAssertNil(back.bySpace[s])
    }

    func testPinsOfSpacesNotAskedForAreLeftAlone() {
        let mine = UUID(), another = UUID()
        let items = SyncItems.pins(bySpace: [mine: [pin("A", "https://a.example/")], another: [pin("B", "https://b.example/")]],
                                   shared: [], base: [:])
        let back = SyncItems.applyPins(items, spaces: [mine], local: [:], localShared: [])
        XCTAssertEqual(Array(back.bySpace.keys), [mine])
    }

    // MARK: - pin folders

    /// One Mac's pinned rows in one space, synced as the app does: its
    /// items made from what it has, a pass, and what the pass says applied.
    /// `old`: a Search from before pin folders synced (1.0.16), which
    /// neither reads nor writes them and drops each pin's folder.
    final class Rows {
        let mac: Mac
        let space: UUID
        let old: Bool
        var pins: [PinDef] = []
        var folders: [PinFolder] = []

        init(_ mac: Mac, space: UUID, old: Bool = false) {
            self.mac = mac
            self.space = space
            self.old = old
        }

        static func before(_ key: String, _ text: String) -> Bool {
            !key.hasPrefix("pinfolder") && !key.hasPrefix("infolder:") && SyncItems.understood(key, text)
        }

        func pass(at now: Double) {
            let defs = old ? pins.map { pin -> PinDef in var pin = pin; pin.folder = nil; return pin } : pins
            var items = SyncItems.pins(bySpace: defs.isEmpty ? [:] : [space: defs], shared: [], base: mac.items)
            if !old { items.merge(SyncItems.pinFolders(folders.isEmpty ? [:] : [space: folders])) { a, _ in a } }
            mac.items = items
            mac.pass(at: now, understood: old ? Rows.before : SyncItems.understood)
            let live = mac.items
            if !old { folders = PinTree.sanitized(SyncItems.applyPinFolders(live, space: space, local: folders)) }
            pins = SyncItems.applyPins(live, spaces: [space], local: [space: pins], localShared: []).bySpace[space] ?? []
            if old { pins = pins.map { var pin = $0; pin.folder = nil; return pin } }
        }
    }

    private func rows(_ macs: [Rows], from start: Double) {
        var now = start
        for _ in 0..<4 {
            for mac in macs {
                now += 1
                mac.pass(at: now)
            }
        }
    }

    private func twoMacs(old: Bool = false) -> (Rows, Rows, Rows?) {
        let s = UUID(), scope = Sync.scope(Profile.personalID)
        let a = Rows(mac("A", scope: scope), space: s), b = Rows(mac("B", scope: scope), space: s)
        return (a, b, old ? Rows(mac("O", scope: scope), space: s, old: true) : nil)
    }

    func testPinFoldersGoAndComeBackTheSame() {
        let s = UUID()
        let feed = URL(string: "https://blog.example/feed")!
        let work = PinFolder(id: UUID(), name: "Work")
        let inner = PinFolder(id: UUID(), name: "Inner", parent: work.id)
        let live = PinFolder(id: UUID(), name: "Blog", feed: feed)
        var mail = pin("M", "https://mail.example/", listed: true)
        mail.folder = inner.id
        var items = SyncItems.pins(bySpace: [s: [mail]], shared: [], base: [:])
        items.merge(SyncItems.pinFolders([s: [work, inner, live]])) { a, _ in a }
        XCTAssertEqual(SyncItems.applyPinFolders(items, space: s, local: []), [work, inner, live])
        XCTAssertEqual(SyncItems.applyPins(items, spaces: [s], local: [:], localShared: []).bySpace[s], [mail])
        // Folded here, and a live folder's posts here, stay as they are.
        var folded = work
        folded.collapsed = true
        var fetched = live
        fetched.items = [FeedItem(id: UUID(), title: "Post", link: URL(string: "https://blog.example/1")!)]
        XCTAssertEqual(SyncItems.applyPinFolders(items, space: s, local: [folded, fetched]), [folded, inner, fetched])
        // Neither is in what goes.
        XCTAssertEqual(SyncItems.pinFolders([s: [folded, inner, fetched]]), SyncItems.pinFolders([s: [work, inner, live]]))
        // Every item is one this build reads, so can be deleted.
        for (key, text) in items { XCTAssertTrue(SyncItems.understood(key, text), key) }
    }

    func testAFolderMadeRenamedNestedAndDeletedOnOneMacFollowsOnTheOther() {
        let (a, b, _) = twoMacs()
        var mail = pin("M", "https://mail.example/", listed: true)
        let docs = pin("D", "https://docs.example/", listed: true)
        a.pins = [mail, docs]
        rows([a, b], from: 1000)
        XCTAssertEqual(b.pins.map(\.id), [mail.id, docs.id])

        // Made, with a pin in it.
        let work = PinFolder(id: UUID(), name: "Work")
        a.folders = [work]
        mail.folder = work.id
        a.pins = [mail, docs]
        rows([a, b], from: 2000)
        XCTAssertEqual(b.folders.map(\.name), ["Work"])
        XCTAssertEqual(b.pins.first { $0.id == mail.id }?.folder, work.id)
        XCTAssertNil(b.pins.first { $0.id == docs.id }?.folder)

        // Renamed on A, folded on B: the name goes, the fold stays B's.
        b.folders[0].collapsed = true
        a.folders[0].name = "Office"
        rows([a, b], from: 3000)
        XCTAssertEqual(b.folders.map(\.name), ["Office"])
        XCTAssertEqual(b.folders.first?.collapsed, true)
        XCTAssertEqual(a.folders.first?.collapsed, false)

        // Nested.
        let outer = PinFolder(id: UUID(), name: "Outer")
        a.folders = [outer] + a.folders.map { var f = $0; f.parent = outer.id; return f }
        rows([a, b], from: 4000)
        XCTAssertEqual(b.folders.first { $0.id == work.id }?.parent, outer.id)

        // Out of the folder, then into it again.
        a.pins = a.pins.map { var p = $0; p.folder = nil; return p }
        rows([a, b], from: 5000)
        XCTAssertNil(b.pins.first { $0.id == mail.id }?.folder)
        a.pins = a.pins.map { var p = $0; if p.id == docs.id { p.folder = work.id }; return p }
        rows([a, b], from: 6000)
        XCTAssertEqual(b.pins.first { $0.id == docs.id }?.folder, work.id)

        // Deleted: what it held goes up into the folder that held it.
        let gone = PinTree.removing(work.id, folders: a.folders, pins: a.pins)
        a.folders = gone.folders
        a.pins = gone.pins
        rows([a, b], from: 7000)
        XCTAssertEqual(b.folders.map(\.id), [outer.id])
        XCTAssertEqual(b.pins.first { $0.id == docs.id }?.folder, outer.id)
        XCTAssertEqual(b.pins.map(\.id), [mail.id, docs.id])
    }

    func testAnOlderMacsPinNeverTakesAPinOutOfItsFolder() {
        let (a, b, o) = twoMacs(old: true)
        let old = o!
        let work = PinFolder(id: UUID(), name: "Work")
        var mail = pin("M", "https://mail.example/", listed: true)
        mail.folder = work.id
        a.folders = [work]
        a.pins = [mail]
        rows([a, b, old], from: 1000)
        XCTAssertEqual(b.pins.first?.folder, work.id)
        // The older Mac edits the pin: its item has no folder in it.
        old.pins[0].letter = "E"
        rows([old, a, b], from: 2000)
        XCTAssertEqual(b.pins.first?.letter, "E")
        XCTAssertEqual(b.pins.first?.folder, work.id)
        XCTAssertEqual(a.pins.first?.folder, work.id)
        XCTAssertEqual(b.folders.map(\.id), [work.id])
        // It carried the folder items along without deleting one.
        XCTAssertEqual(old.mac.base?[SyncItems.inFolderKey(mail.id)]?.v, SyncMerge.text(work.id.uuidString))
        XCTAssertNotNil(old.mac.base?[SyncItems.pinFolderKey(b.space, work.id)]?.v)
        // And a pin's item as 1.0.16 wrote it still reads.
        XCTAssertNotNil(SyncMerge.value(SyncedPin.self, #"{"home":"https://mail.example/","letter":"M"}"#))
    }

    func testAPinThatComesBeforeItsFolderKeepsItAndFilesItselfWhenItComes() {
        let s = UUID()
        let work = PinFolder(id: UUID(), name: "Work")
        var mail = pin("M", "https://mail.example/", listed: true)
        mail.folder = work.id
        let pinsOnly = SyncItems.pins(bySpace: [s: [mail]], shared: [], base: [:])
        let here = SyncItems.applyPins(pinsOnly, spaces: [s], local: [:], localShared: []).bySpace[s] ?? []
        XCTAssertEqual(here.first?.folder, work.id)
        let none = SyncItems.applyPinFolders(pinsOnly, space: s, local: [])
        XCTAssertEqual(PinTree.lines(pins: here.map { ($0.id, $0.folder) }, folders: none), [.pin(mail.id, depth: 0)])
        // The pin, made from these, keeps saying so: no edit goes back.
        XCTAssertEqual(SyncItems.pins(bySpace: [s: here], shared: [], base: pinsOnly), pinsOnly)
        var all = pinsOnly
        all.merge(SyncItems.pinFolders([s: [work]])) { a, _ in a }
        let folders = SyncItems.applyPinFolders(all, space: s, local: none)
        XCTAssertEqual(PinTree.lines(pins: here.map { ($0.id, $0.folder) }, folders: folders),
                       [.folder(work, depth: 0), .pin(mail.id, depth: 1)])
    }

    func testAFolderItemThisBuildCantReadLeavesThePinWhereItIs() {
        let s = UUID(), work = UUID()
        var mail = pin("M", "https://mail.example/")
        mail.folder = work
        var items = SyncItems.pins(bySpace: [s: [mail]], shared: [], base: [:])
        items[SyncItems.inFolderKey(mail.id)] = #"{"future":true}"#
        XCTAssertEqual(SyncItems.applyPins(items, spaces: [s], local: [s: [mail]], localShared: []).bySpace[s]?.first?.folder, work)
        XCTAssertFalse(SyncItems.understood(SyncItems.inFolderKey(mail.id), #"{"future":true}"#))
    }

    func testEveryPinVanishingAtOnceKeepsTheirFolders() {
        let (a, b, _) = twoMacs()
        let work = PinFolder(id: UUID(), name: "Work")
        a.folders = [work]
        a.pins = (0..<6).map { i in var p = pin("\(i)", "https://s\(i).example/", listed: true); p.folder = work.id; return p }
        rows([a, b], from: 1000)
        // A's pins file didn't read.
        a.pins = []
        rows([a, b], from: 2000)
        XCTAssertEqual(b.pins.count, 6)
        XCTAssertTrue(b.pins.allSatisfy { $0.folder == work.id })
        XCTAssertTrue(a.pins.allSatisfy { $0.folder == work.id })
    }

    // MARK: - bookmarks

    func testBookmarksGoAndComeBackTheSame() {
        let tree = [
            Bookmark.site("Example", URL(string: "https://example.com/")!),
            Bookmark.folder("Work", [Bookmark.site("Docs", URL(string: "https://docs.example/")!),
                                     Bookmark.folder("Deep", [Bookmark.site("Deeper", URL(string: "https://deep.example/")!)])]),
            Bookmark.folder("Empty", []),
        ]
        let back = SyncItems.applyBookmarks(SyncItems.bookmarks(tree))
        XCTAssertEqual(back, tree)
        XCTAssertEqual(SyncItems.bookmarks(back), SyncItems.bookmarks(tree))
    }

    func testABookmarkAddedToAFolderDeletedElsewhereIsKept() {
        let docs = Bookmark.site("Docs", URL(string: "https://docs.example/")!)
        let folderNode = Bookmark.folder("Work", [docs])
        let a = mac("A", SyncItems.bookmarks([folderNode]), scope: Sync.scope(Profile.personalID))
        let b = mac("B", scope: Sync.scope(Profile.personalID))
        settle([a, b], from: 1000)
        // A deletes the folder; B, not knowing, files a new bookmark in it.
        a.items = SyncItems.bookmarks([])
        a.pass(at: 2000)
        let added = Bookmark.site("New", URL(string: "https://new.example/")!)
        var bTree = SyncItems.applyBookmarks(b.items)
        bTree[0].children?.append(added)
        b.items = SyncItems.bookmarks(bTree)
        b.pass(at: 2001)
        settle([a, b], from: 2002)
        let final = SyncItems.applyBookmarks(a.items)
        XCTAssertEqual(final.map(\.id), [added.id])
        XCTAssertEqual(SyncItems.applyBookmarks(b.items).map(\.id), [added.id])
    }

    func testTwoFoldersMovedIntoEachOtherLoseNothing() {
        let one = Bookmark.folder("One", []), two = Bookmark.folder("Two", [])
        var items = SyncItems.bookmarks([one, two])
        items[SyncItems.childrenKey(SyncItems.rootFolder)] = nil
        items[SyncItems.childrenKey(one.id.uuidString)] = SyncMerge.text([two.id.uuidString])
        items[SyncItems.childrenKey(two.id.uuidString)] = SyncMerge.text([one.id.uuidString])
        let tree = SyncItems.applyBookmarks(items)
        XCTAssertEqual(Bookmarks.folders(tree).count, 2)
    }

    // MARK: - settings

    func testSettingsGoAndComeBack() {
        let prefs = Preferences()
        let was = prefs.look
        defer { prefs.look = was }
        prefs.look = .dark
        let items = SyncSettings.items(prefs)
        XCTAssertEqual(items["set:look"], "\"dark\"")
        XCTAssertEqual(Set(items.keys), Set(SyncSettings.known.map { "set:" + $0 }))
        prefs.look = .light
        SyncSettings.apply(items, to: prefs)
        XCTAssertEqual(prefs.look, .dark)
        // A value this build doesn't know is passed over.
        SyncSettings.apply(["set:look": "\"sepia\""], to: prefs)
        XCTAssertEqual(prefs.look, .dark)
    }

    /// Tabs show site icons by default since letters were (Glyph.standard).
    /// A Mac that never chose doesn't stamp its new default over a value the
    /// Macs agreed — it may be another Mac's choice — and once chosen here,
    /// its own value goes.
    func testAChangedDefaultNeverOverwritesWhatWasAgreed() {
        let store = Store.settings
        let kept = store.object(forKey: "glyph")
        defer { if let kept { store.set(kept, forKey: "glyph") } else { store.removeObject(forKey: "glyph") } }
        store.removeObject(forKey: "glyph")
        let prefs = Preferences()
        XCTAssertEqual(prefs.glyph, .icons)
        XCTAssertNil(store.object(forKey: "glyph"), "a default is never written")
        XCTAssertEqual(SyncSettings.items(prefs)["set:glyph"], "\"icons\"", "nothing agreed: the default goes")
        XCTAssertEqual(SyncSettings.items(prefs, agreed: ["set:glyph": "\"letters\""])["set:glyph"], "\"letters\"")
        // The pass applies what was agreed: chosen elsewhere, it is taken here.
        SyncSettings.apply(["set:glyph": "\"letters\""], to: prefs)
        XCTAssertEqual(prefs.glyph, .letters)
        prefs.glyph = .icons
        XCTAssertEqual(SyncSettings.items(prefs, agreed: ["set:glyph": "\"letters\""])["set:glyph"], "\"icons\"",
                       "chosen here, this Mac's own value goes")
    }
}
