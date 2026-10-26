import XCTest
@testable import Search

/// Profiles (Profiles.swift): what each keeps apart in its files — its
/// spaces, its pins every space shows, its history — and what an older
/// Search finds there. WebKit stores are left to Tests/profiles.py, which
/// runs a hidden probe: made here they would land in xctest's own container.
@MainActor
final class ProfilesTests: XCTestCase {
    private static var world: String?

    override class func setUp() {
        super.setUp()
        let name = "profiles-tests-\(UUID().uuidString.lowercased().prefix(8))"
        world = name
        setenv("SEARCH_PROBE", name, 1)
    }

    override class func tearDown() {
        Disk.drain()
        if let world, Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(world)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    private func def(_ letter: String) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/", title: letter)
    }

    func testSharedPinsKeepEachProfileApartAndPersonalWhereItWas() throws {
        let other = UUID()
        let mine = [def("A")], theirs = [def("B")]
        let data = try XCTUnwrap(Pins.encode(bySpace: [:], shared: mine, others: [other: theirs]))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Personal's under "shared", as 1.0.4 to 1.0.6 wrote and read them.
        XCTAssertNotNil(raw["shared"])
        XCTAssertNotNil(raw["shared:\(other.uuidString)"])
        let lists = Pins.sharedLists(data)
        XCTAssertEqual(lists[Profile.personalID], mine)
        XCTAssertEqual(lists[other], theirs)
        // An older reader takes the other profile's key for no space.
        XCTAssertEqual(Pins.decode(data)?.shared, mine)
        XCTAssertEqual(Pins.decode(data)?.bySpace.isEmpty, true)
    }

    func testSpacesFromBeforeProfilesAreAllPersonal() throws {
        let work = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: false)
        Spaces.write([Space(id: Space.firstID, name: "Personal", colour: 0), work])
        XCTAssertEqual(Spaces.read(profile: Profile.personalID).map(\.id), [Space.firstID, work.id])
        // A space with sign-ins of its own keeps them, inside Personal.
        XCTAssertEqual(Spaces.known[work.id]?.sharesSignIns, false)
        XCTAssertEqual(Spaces.profile(of: work.id), Profile.personalID)
        // Nothing written about profiles until there is a second one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.file("profiles.json").path))
        XCTAssertEqual(Profiles.read().map(\.id), [Profile.personalID])
    }

    func testTheHomeSpaceCanBeMovedAndTheOrderSurvives() throws {
        Store.settings.removeObject(forKey: "spaces.orderKept")
        let work = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: false)
        // A file from before the order was kept had the home first.
        Spaces.write([Space.first(), work])
        XCTAssertEqual(Spaces.read(profile: Profile.personalID).map(\.id), [Space.firstID, work.id])

        // The user's first reorder is written in that order and marks the
        // setting; a later read must not put the special first space back.
        Store.settings.set(true, forKey: "spaces.orderKept")
        Spaces.write([work, Space.first()])
        XCTAssertEqual(Spaces.read(profile: Profile.personalID).map(\.id), [work.id, Space.firstID])
    }

    func testAFileWithoutTheFirstSpaceStillLeavesItsHomeReachable() throws {
        Store.settings.removeObject(forKey: "spaces.orderKept")
        let work = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: false)
        Spaces.write([work])
        let spaces = Spaces.read(profile: Profile.personalID)
        XCTAssertEqual(spaces.map(\.id), [Space.firstID, work.id])
        XCTAssertTrue(spaces.contains { $0.id == Space.firstID })
    }

    func testDuplicateHomeEntriesKeepOneHomeInItsChosenPlace() {
        let home = Space(id: Space.firstID, name: "Personal renamed", colour: 1)
        let duplicate = Space(id: Space.firstID, name: "Stray", colour: 2)
        let work = Space(id: UUID(), name: "Work", colour: 0)
        for marked in [false, true] {
            Store.settings.set(marked, forKey: "spaces.orderKept")
            for saved in [[home, work, duplicate], [work, home, duplicate]] {
                Spaces.write(saved)
                let loaded = Spaces.read(profile: Profile.personalID)
                let expected = saved[0].isFirst ? [Space.firstID, work.id] : [work.id, Space.firstID]
                XCTAssertEqual(loaded.map(\.id), expected)
                XCTAssertEqual(loaded.filter(\.isFirst).count, 1)
                XCTAssertEqual(loaded.first(where: \.isFirst)?.name, home.name)
            }
        }
    }

    func testAnExistingOrderedFileIsNotRewrittenByTheNewReader() throws {
        Store.settings.removeObject(forKey: "spaces.orderKept")
        let work = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: false)
        let another = Profiles.shared.add(named: "Elsewhere")
        defer { Profiles.shared.delete(another.id) }
        let elsewhere = try XCTUnwrap(Spaces.read(profile: another.id).first)
        // The old reader always put the home first. A second profile's home
        // moved within its own block shows that the old writer had persisted
        // a user's order, which this reader must keep.
        let anotherSecond = Space(id: UUID(), name: "Elsewhere Two", colour: 0,
                                  sharesSignIns: true, profile: another.id)
        Spaces.write([Space.first(), work, anotherSecond, elsewhere])
        XCTAssertEqual(Spaces.read(profile: Profile.personalID).map(\.id), [Space.firstID, work.id])
        XCTAssertEqual(Spaces.read(profile: another.id).map(\.id), [anotherSecond.id, elsewhere.id])
    }

    func testAProfilesHomeSpaceIsHomeWhereverItSits() throws {
        let made = Profiles.shared.add(named: "Ordered")
        defer { Profiles.shared.delete(made.id) }
        let second = Space(id: UUID(), name: "Second", colour: 0,
                           sharesSignIns: true, profile: made.id)
        Spaces.write(Spaces.read() + [second])
        Store.settings.removeObject(forKey: "spaces.orderKept")
        let home = try XCTUnwrap(Spaces.read(profile: made.id).first { $0.id == made.home })
        var all = Spaces.read().filter { $0.profileID != made.id }
        all += [second, home]
        Spaces.write(all)
        XCTAssertEqual(Spaces.read(profile: made.id).map(\.id), [second.id, made.home])
    }

    func testASpacesOffWindowOpensOnTheMovedHome() throws {
        Store.settings.removeObject(forKey: "spaces.orderKept")
        let work = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: false)
        Spaces.write([work, Space.first()])
        let prefs = Shared.prefs
        let previous = prefs.usesSpaces
        defer { prefs.usesSpaces = previous }
        prefs.usesSpaces = false
        let browser = Browser(record: nil)
        defer { browser.closeAll() }
        XCTAssertEqual(browser.spaces.map(\.id), [work.id, Space.firstID])
        XCTAssertEqual(browser.spaceID, Space.firstID,
                       "with spaces off, the window must use the profile home, not the leftmost space")
    }

    func testANewProfileHasItsOwnSpacesHistoryAndBookmarks() throws {
        let made = Profiles.shared.add(named: "Raycast")
        defer { Profiles.shared.delete(made.id) }
        XCTAssertTrue(Profiles.shared.several)
        let theirs = Spaces.read(profile: made.id)
        XCTAssertEqual(theirs.map(\.id), [made.home])
        XCTAssertEqual(theirs.first?.sharesSignIns, true)
        XCTAssertFalse(Spaces.read(profile: Profile.personalID).contains { $0.id == made.home })
        XCTAssertEqual(Spaces.profile(of: made.home), made.id)

        let url = try XCTUnwrap(URL(string: "https://only-raycast.example/"))
        Profiles.history(made.id).record(url, title: "Raycast only")
        XCTAssertTrue(Profiles.history(made.id).everything().contains { $0.url == url })
        XCTAssertFalse(Profiles.history(Profile.personalID).everything().contains { $0.url == url })
        XCTAssertFalse(Profiles.history(Profile.personalID).suggestions(for: "only-ray").contains { $0.url == url })
        XCTAssertFalse(Profiles.bookmarks(made.id) === Profiles.bookmarks(Profile.personalID))
    }

    func testDeletingAProfileTakesItsSpacesAndFiles() throws {
        let made = Profiles.shared.add(named: "Gone")
        let url = try XCTUnwrap(URL(string: "https://gone.example/"))
        Profiles.history(made.id).record(url, title: "Gone")
        Profiles.history(made.id).settle()
        Profiles.shared.delete(made.id)
        Disk.drain()
        // The save waits a moment (History.save); it must not bring the file back.
        let pause = expectation(description: "save window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pause.fulfill() }
        wait(for: [pause], timeout: 4)
        Disk.drain()
        XCTAssertFalse(Profiles.shared.list.contains { $0.id == made.id })
        XCTAssertTrue(Spaces.read(profile: made.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.file("history-\(made.id.uuidString).json").path))
        XCTAssertFalse(Profiles.history(made.id).everything().contains { $0.url == url }, "a deleted profile's history is not read back")
    }
}
