import XCTest
@testable import Search

/// Containers (Containers.swift): what a tab's and a pin's container is in
/// their files, what an older or odd file reads as, and what is left of a
/// container once it is deleted. A container's own WebKit store is left to
/// Tests/container_tabs.py, which runs a hidden probe: made here it would
/// land in xctest's own WebKit container. Nothing here makes one: every
/// container a tab is given below is one that doesn't exist.
@MainActor
final class ContainersTests: XCTestCase {
    private static var world: String?

    override class func setUp() {
        super.setUp()
        let name = "containers-tests-\(UUID().uuidString.lowercased().prefix(8))"
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

    private func entry(_ fields: [String: Any]) throws -> Session.Entry {
        try JSONDecoder().decode(Session.Entry.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testATabsContainerRoundTripsThroughTheSession() throws {
        let id = UUID()
        let written = Session.Entry(url: "https://outlook.office.com/mail/", title: "Mail", container: id)
        let data = try JSONEncoder().encode(Session.Shape(tabs: [written], active: 0))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tab = try XCTUnwrap((raw["tabs"] as? [[String: Any]])?.first)
        XCTAssertEqual(tab["container"] as? String, id.uuidString)
        let read = try JSONDecoder().decode(Session.Shape.self, from: data)
        XCTAssertEqual(read.tabs.first?.container, id)
        XCTAssertEqual(read.tabs.first?.url, written.url)
    }

    func testATabWithoutAContainerWritesNoKey() throws {
        let data = try JSONEncoder().encode(Session.Entry(url: "https://example.com/", title: "Example"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(raw["container"], "a session without containers is written as it always was")
    }

    func testAnOlderOrOddEntryReadsAsInNoContainer() throws {
        XCTAssertNil(try entry(["url": "https://older.example/", "title": "Older"]).container)
        // Something no Search writes: the tab still comes back, in none.
        let odd = try entry(["url": "https://odd.example/", "title": "Odd", "container": 42, "muted": true])
        XCTAssertNil(odd.container)
        XCTAssertTrue(odd.muted)
    }

    func testAPinsContainerIsPartOfThePin() throws {
        let id = UUID()
        let pin = PinDef(id: UUID(), letter: "O", home: "https://outlook.office.com/", title: "Outlook", container: id)
        let plain = PinDef(id: UUID(), letter: "U", home: "https://outlook.office.com/", title: "Outlook")
        XCTAssertNotEqual(pin, PinDef(id: pin.id, letter: "O", home: pin.home, title: pin.title),
                          "a pin moved to another container is a change the other windows must hear of")
        let space = UUID()
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [pin, plain]], shared: [pin]))
        let read = try XCTUnwrap(Pins.decode(data))
        XCTAssertEqual(read.bySpace[space]?.map(\.container), [id, nil])
        XCTAssertEqual(read.shared.first?.container, id)
    }

    func testAnOddPinContainerLeavesThePinsFileReadable() throws {
        let space = UUID()
        let json: [String: Any] = [space.uuidString: [
            ["id": UUID().uuidString, "letter": "A", "home": "https://a.example/", "title": "A", "container": "not an id"],
            ["id": UUID().uuidString, "letter": "B", "home": "https://b.example/", "title": "B"],
        ]]
        let read = try XCTUnwrap(Pins.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(read.bySpace[space]?.map(\.letter), ["A", "B"])
        XCTAssertEqual(read.bySpace[space]?.compactMap(\.container), [])
    }

    func testAContainerThatDoesNotExistIsNone() {
        let gone = UUID()
        XCTAssertNil(Containers.shared.known(gone))
        XCTAssertNil(Containers.shared.known(nil))
        XCTAssertNil(Containers.store(gone), "no store is made for a container that isn't there")
    }

    func testARowSavedWithADeletedContainerComesBackInItsSpace() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // A window of its own rows, not the session files (see MutedTabRestoreTests).
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let url = "https://deleted-container.example/"
        browser.record.rows[browser.spaceID.uuidString] = Session.Shape(
            tabs: [Session.Entry(url: url, title: "Was in a container", container: UUID())], active: 0)
        let row = browser.loadRow(browser.spaceID)
        let tab = try XCTUnwrap(row.tabs.first { $0.address?.absoluteString == url })
        XCTAssertNil(tab.container)
        XCTAssertTrue(tab.store === Spaces.store(for: browser.spaceID), "in no container, it signs in as its space does")
    }

    func testMakingRenamingAndDeletingAContainer() throws {
        let file = Store.file("containers.json")
        let work = Containers.shared.add(named: "  Work ")
        let study = Containers.shared.add(named: "Study")
        defer {
            Containers.shared.delete(work.id)
            Containers.shared.delete(study.id)
        }
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(Containers.shared.known(work.id), work.id)
        XCTAssertNotEqual(work.colour, study.colour, "each new container wears a colour of its own")
        XCTAssertNotEqual(work.colour, 0, "slate, the colour of nothing in particular, comes last")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Containers.read().map(\.id), [work.id, study.id])

        Containers.shared.rename(work.id, to: "Office")
        Containers.shared.rename(work.id, to: "   ")
        XCTAssertEqual(Containers.shared.container(work.id)?.name, "Office", "an empty name is no rename")
        Containers.shared.setColour(study.id, to: 99)
        XCTAssertTrue(Spaces.colours.indices.contains(Containers.shared.container(study.id)?.colour ?? -1))

        Containers.shared.delete(work.id)
        XCTAssertNil(Containers.shared.known(work.id), "a deleted container is none from now on")
        XCTAssertEqual(Containers.read().map(\.id), [study.id])
        Containers.shared.delete(study.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no containers is no file, as before there were any")
    }
}
