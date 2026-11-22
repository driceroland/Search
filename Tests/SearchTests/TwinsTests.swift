import AppKit
import XCTest
@testable import Search

/// Same tabs in every window (Twins.swift): a row set against the twins,
/// a row read from its file, the session file with and without twin ids,
/// and two windows of one profile following each other. Nothing is loaded:
/// every tab is made asleep at its page.
@MainActor
final class TwinsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: - plan

    func testATwinNewToTheWindowIsMadeInItsPlace() {
        let plan = Twins.plan([a, c], twins: [a, b, c], known: [a, b, c])
        XCTAssertEqual(plan.order, [.kept(0), .made(1), .kept(1)])
        XCTAssertEqual(plan.gone, [])
    }

    func testATwinClosedElsewhereGoes() {
        let plan = Twins.plan([a, b, c], twins: [a, c], known: [a, b, c])
        XCTAssertEqual(plan.order, [.kept(0), .kept(2)])
        XCTAssertEqual(plan.gone, [1])
    }

    func testTheTwinsOrderWins() {
        let plan = Twins.plan([a, b, c], twins: [c, a, b], known: [a, b, c])
        XCTAssertEqual(plan.order, [.kept(2), .kept(0), .kept(1)])
    }

    func testTheWindowsOwnTabsStayAfterTheTabTheyFollowed() {
        // nil: an empty or private tab; d: a tab no window has said yet.
        let plan = Twins.plan([nil, a, d, b, nil], twins: [b, a], known: [a, b])
        XCTAssertEqual(plan.order, [.kept(0), .kept(3), .kept(4), .kept(1), .kept(2)])
        XCTAssertEqual(plan.gone, [])
    }

    func testATabNeverSaidIsNotTakenForClosed() {
        // Turned on with each window's tabs of its own: they come together.
        let plan = Twins.plan([c, d], twins: [a, b], known: [a, b])
        XCTAssertEqual(plan.order, [.kept(0), .kept(1), .made(0), .made(1)])
        XCTAssertEqual(plan.gone, [])
    }

    func testOneTabForEachTwin() {
        let plan = Twins.plan([a, a], twins: [a], known: [a])
        XCTAssertEqual(plan.order, [.kept(0)])
        XCTAssertEqual(plan.gone, [1])
    }

    // MARK: - groups

    func testGroupsAreTheTwinsFoldedAsThisWindowHadThem() {
        let g = UUID(), h = UUID(), own = UUID()
        let theirs = [TabGroup(id: g, name: "Work", collapsed: false), TabGroup(id: h, name: "New", collapsed: false)]
        let ours = [TabGroup(id: g, name: "Old name", collapsed: true), TabGroup(id: own, name: "Mine", collapsed: false),
                    TabGroup(id: UUID(), name: "Empty", collapsed: false)]
        let merged = Twins.merge(theirs, into: ours, holding: [own])
        XCTAssertEqual(merged.map(\.name), ["Work", "New", "Mine"])
        XCTAssertEqual(merged.map(\.collapsed), [true, false, false])
    }

    func testAGroupNotGivenStaysAsItWas() {
        let g = UUID(), h = UUID()
        let defs = [TwinDef(id: a, url: "https://a.example/", title: "a", name: nil, group: g),
                    TwinDef(id: b, url: "https://b.example/", title: "b", name: nil, group: h)]
        let before = [TabGroup(id: g, name: "Kept", collapsed: true), TabGroup(id: UUID(), name: "Gone", collapsed: false)]
        let given = [TabGroup(id: h, name: "Given", collapsed: true)]
        let shared = Twins.sharedGroups(defs, given: given, before: before)
        XCTAssertEqual(shared.map(\.name), ["Given", "Kept"])
        XCTAssertEqual(shared.map(\.collapsed), [false, false])
    }

    // MARK: - a row read from its file

    private func entry(_ path: String, twin: UUID? = nil, pin: String? = nil, group: UUID? = nil) -> Session.Entry {
        Session.Entry(url: "https://\(path).example/", title: path, pin: pin, name: nil, home: nil,
                      groupID: group, twinID: twin)
    }

    private func def(_ id: UUID, _ path: String, name: String? = nil, group: UUID? = nil) -> TwinDef {
        TwinDef(id: id, url: "https://\(path).example/", title: path.uppercased(), name: name, group: group)
    }

    func testARowFromItsFileTakesTheTwins() {
        let shape = Session.Shape(tabs: [entry("pin", pin: "P"), entry("a", twin: a), entry("b", twin: b), entry("own")],
                                  active: 2)
        let out = Twins.apply(shape, twins: [def(a, "moved", name: "Named"), def(c, "c")], groups: [], known: [a, b, c])
        XCTAssertEqual(out.tabs.map(\.url), ["https://pin.example/", "https://moved.example/",
                                             "https://own.example/", "https://c.example/"])
        XCTAssertEqual(out.tabs[1].name, "Named")
        XCTAssertEqual(out.tabs[1].title, "MOVED")
        XCTAssertEqual(out.tabs[3].twinID, c)
        XCTAssertEqual(out.tabs[0].pin, "P")
        // b was in front and is gone: the tab after it is.
        XCTAssertEqual(out.active, 2)
        XCTAssertNil(out.groups)
    }

    func testAPairKeepsOnlyWhatStays() {
        var shape = Session.Shape(tabs: [entry("a", twin: a), entry("b", twin: b), entry("c", twin: c)], active: 0)
        shape.splits = [Session.Split(tabs: [1, 2], sizes: [0.5, 0.5]), Session.Split(tabs: [0, 1], sizes: [0.5, 0.5])]
        let out = Twins.apply(shape, twins: [def(b, "b"), def(c, "c")], groups: [], known: [a, b, c])
        XCTAssertEqual(out.splits.map(\.tabs), [[0, 1]])
        XCTAssertEqual(out.active, 0)
    }

    func testARowTakesTheTwinsGroups() {
        let g = UUID()
        let shape = Session.Shape(tabs: [entry("a", twin: a)], active: 0)
        let out = Twins.apply(shape, twins: [def(a, "a", group: g)], groups: [TabGroup(id: g, name: "Work", collapsed: false)],
                              known: [a])
        XCTAssertEqual(out.tabs[0].groupID, g)
        XCTAssertEqual(out.groups?.map(\.name), ["Work"])
    }

    // MARK: - the session file

    func testOffTheFileIsWhatItWas() throws {
        let plain = try JSONEncoder().encode(entry("a"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("twinID"))
        let twinned = try JSONEncoder().encode(entry("a", twin: a))
        XCTAssertEqual(try JSONDecoder().decode(Session.Entry.self, from: twinned).twinID, a)
        XCTAssertNil(try JSONDecoder().decode(Session.Entry.self, from: plain).twinID)
    }

    func testOffByDefaultAndFindable() {
        let saved = Store.settings.object(forKey: "tabs.mirror")
        defer { Store.settings.set(saved, forKey: "tabs.mirror") }
        Store.settings.removeObject(forKey: "tabs.mirror")
        XCTAssertFalse(Preferences().mirrorsTabs)
        for words in ["same tabs", "every window", "mirror", "tabs in all windows"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "tabs.mirror" }, words)
        }
        XCTAssertEqual(SettingsIndex.item("tabs.mirror")?.page, .tabs)
    }

    // MARK: - two windows

    private func open(_ browser: Browser, _ path: String) -> Tab {
        browser.newTab()
        let tab = browser.tabs.last!
        tab.restore(url: URL(string: "https://\(path).example/")!, title: path)
        return tab
    }

    private func paths(_ browser: Browser) -> [String] {
        browser.tabs.compactMap { $0.address?.host }.map { String($0.split(separator: ".")[0]) }
    }

    func testTwoWindowsListTheSameTabs() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let saved = (prefs.mirrorsTabs, prefs.usesTabGroups, prefs.splitView)
        prefs.mirrorsTabs = false
        prefs.usesTabGroups = false
        prefs.splitView = false
        let one = Browser(record: WindowRecord())
        let two = Browser(record: WindowRecord())
        defer {
            one.closeAll()
            two.closeAll()
            prefs.mirrorsTabs = saved.0
            prefs.usesTabGroups = saved.1
            prefs.splitView = saved.2
        }
        _ = open(one, "a")
        _ = open(two, "b")
        XCTAssertFalse(paths(one).contains("b"), "off: each window's own")

        // On: they come together, nothing lost.
        prefs.mirrorsTabs = true
        one.joinTwins()
        two.joinTwins()
        one.publishTwins()
        XCTAssertEqual(Set(paths(one)), ["a", "b"])
        XCTAssertEqual(Set(paths(two)), ["a", "b"])

        // Opened in one, it is in the other, asleep.
        _ = open(one, "c")
        one.publishTwins()
        let c = two.tabs.first { $0.address?.host == "c.example" }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.asleep, true)

        // Named in the other, so in the first.
        c?.name = "Kept"
        two.publishTwins()
        XCTAssertEqual(one.tabs.first { $0.address?.host == "c.example" }?.name, "Kept")

        // Closed in one, gone from both.
        if let b = one.tabs.first(where: { $0.address?.host == "b.example" }) { one.close(b) }
        one.publishTwins()
        XCTAssertFalse(paths(two).contains("b"))

        // A window gone leaves the other's tabs.
        two.closeAll()
        one.publishTwins()
        XCTAssertEqual(Set(paths(one)), ["a", "c"])
    }
}
