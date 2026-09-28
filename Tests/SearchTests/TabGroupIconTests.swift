import AppKit
import Darwin
import XCTest
@testable import Search

final class TabGroupIconTests: XCTestCase {
    private static var probeWorld: String?

    override class func setUp() {
        let world = "group-icons-\(UUID().uuidString.lowercased())"
        probeWorld = world
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if let probeWorld, Store.world == probeWorld {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(probeWorld)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(probeWorld)")
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    func testEmojiHelperAcceptsSingleNativeEmojiSequences() {
        let accepted = [
            "😀",
            "👨‍👩‍👧‍👦",
            "👍🏽",
            "👩🏽‍💻",
            "🇩🇪",
            "1️⃣",
            "1⃣",
            "❤️‍🔥",
            "🏳️‍🌈",
            "🏳️‍⚧️",
        ]

        for emoji in accepted {
            XCTAssertEqual(TabGroupIcon.emoji(from: emoji), .emoji(emoji), "Expected one emoji for \(emoji)")
        }
    }

    func testEmojiHelperRejectsTextDigitsAndIncompleteSequences() {
        let rejected = [
            "",
            "hello",
            "1",
            "123",
            "1️",
            "😀😀",
            "😀‍",
            "🏽",
            "©🏽",
            "🇩",
            "🏳️‍",
        ]

        for text in rejected {
            XCTAssertNil(TabGroupIcon.emoji(from: text), "Expected no emoji for \(text)")
        }
    }

    func testOnlySpacesSymbolsAndValidEmojiPassIconValidation() {
        XCTAssertEqual(TabGroupIcon.symbol("house").validated, .symbol("house"))
        XCTAssertNil(TabGroupIcon.symbol("not-a-space-symbol").validated)
        XCTAssertNil(TabGroupIcon.emoji("plain text").validated)
    }

    func testSessionShapeRoundTripsSymbolAndEmojiIcons() throws {
        let groups = [
            TabGroup(id: UUID(), name: "Work", collapsed: false, icon: .symbol("briefcase")),
            TabGroup(id: UUID(), name: "Family", collapsed: true, icon: .emoji("👨‍👩‍👧‍👦")),
        ]
        let shape = Session.Shape(tabs: [], active: 0, groups: groups)

        let restored = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(shape))

        XCTAssertEqual(restored.groups, groups)
    }

    func testLegacyAndMalformedIconsDoNotDiscardGroups() throws {
        let groups = [
            TabGroup(id: UUID(), name: "Legacy", collapsed: false),
            TabGroup(id: UUID(), name: "Wrong type", collapsed: false, icon: .symbol("house")),
            TabGroup(id: UUID(), name: "Unsupported symbol", collapsed: false, icon: .symbol("house")),
            TabGroup(id: UUID(), name: "Invalid emoji", collapsed: false, icon: .emoji("😀")),
        ]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Session.Shape(tabs: [], active: 0, groups: groups)
        )) as? [String: Any])
        var encodedGroups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        encodedGroups[0].removeValue(forKey: "icon")
        encodedGroups[1]["icon"] = 17
        encodedGroups[2]["icon"] = try encodedIcon(.symbol("unknown-symbol"))
        encodedGroups[3]["icon"] = try encodedIcon(.emoji("😀😀"))
        object["groups"] = encodedGroups

        let decoded = try JSONDecoder().decode(Session.Shape.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.groups?.map(\.id), groups.map(\.id))
        XCTAssertEqual(decoded.groups?.map(\.icon), [nil, nil, nil, nil])
    }

    @MainActor
    func testBrowserSetterPersistsAndRemovesIconsThroughReadRow() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let group = TabGroup(id: UUID(), name: "Research", collapsed: false)
        let row = Session.Shape(
            tabs: [Session.Entry(url: "https://group-icon.example/", title: "Research", groupID: group.id)],
            active: 0,
            groups: [group]
        )
        var record = WindowRecord()
        record.rows[Space.firstID.uuidString] = row
        let browser = Browser(record: record)
        defer { browser.closeAll() }

        browser.setTabGroupIcon(group.id, to: .emoji("🏳️‍🌈"))
        XCTAssertEqual(browser.readRow(Space.firstID).groups?.first?.icon, .emoji("🏳️‍🌈"))

        browser.setTabGroupIcon(group.id, to: .emoji("two emojis"))
        XCTAssertEqual(browser.readRow(Space.firstID).groups?.first?.icon, .emoji("🏳️‍🌈"))

        browser.setTabGroupIcon(group.id, to: nil)
        XCTAssertNil(browser.readRow(Space.firstID).groups?.first?.icon)
    }

    private func encodedIcon(_ icon: TabGroupIcon) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(icon))
    }
}
