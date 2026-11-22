import XCTest
@testable import Search

/// The model of the panel that asks which space a link opens in
/// (LinkChooser.swift): its rows and their numbers, what it remembers, and
/// the links that wait for it.
@MainActor
final class LinkChooserTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let personal = (id: UUID(), name: "Personal")
    private let work = (id: UUID(), name: "Work")
    private let side = (id: UUID(), name: "Side")

    private func spaces(_ names: [String], profile: UUID) -> [Space] {
        names.map { Space(id: UUID(), name: $0, colour: 0, profile: profile) }
    }

    private func rows(_ names: String...) -> [LinkChooser.Row] {
        names.map { LinkChooser.Row(space: UUID(), name: $0, symbol: "house", tint: nil, profile: "Personal", digit: nil) }
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    func testRowsFollowProfileOrderAndNumberTen() {
        let byProfile = [
            personal.id: spaces(["Home", "Family", "Reading", "Travel", "Health"], profile: personal.id),
            work.id: spaces(["Work", "Mail", "Calendar", "Docs"], profile: work.id),
            side.id: spaces(["Clients", "Studio"], profile: side.id),
        ]
        let rows = LinkChooser.rows(profiles: [personal, work, side]) { byProfile[$0] ?? [] }
        XCTAssertEqual(rows.map(\.name), ["Home", "Family", "Reading", "Travel", "Health",
                                          "Work", "Mail", "Calendar", "Docs", "Clients", "Studio"])
        XCTAssertEqual(rows.map(\.digit), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, nil])
        XCTAssertEqual(rows.map(\.profile), Array(repeating: "Personal", count: 5) + Array(repeating: "Work", count: 4)
                       + Array(repeating: "Side", count: 2))
    }

    func testDigitsByKeyCode() {
        XCTAssertEqual(LinkChooser.digit(keyCode: 18), 1)
        XCTAssertEqual(LinkChooser.digit(keyCode: 25), 9)
        XCTAssertEqual(LinkChooser.digit(keyCode: 29), 0)
        XCTAssertEqual(LinkChooser.digit(keyCode: 83), 1)
        XCTAssertEqual(LinkChooser.digit(keyCode: 82), 0)
        XCTAssertNil(LinkChooser.digit(keyCode: 49))
        XCTAssertNil(LinkChooser.digit(keyCode: 0))
    }

    func testRowForDigit() {
        let names = (0..<11).map { "S\($0)" }
        let list = LinkChooser.rows(profiles: [personal]) { spaces(names, profile: $0) }
        XCTAssertEqual(LinkChooser.row(forDigit: 1, in: list)?.name, "S0")
        XCTAssertEqual(LinkChooser.row(forDigit: 0, in: list)?.name, "S9")
        XCTAssertNil(LinkChooser.row(forDigit: 5, in: Array(list.prefix(2))))
    }

    func testPreselectsMemoryThenFront() {
        let list = rows("Home", "Work", "Mail")
        let memory = [LinkChooser.Choice(site: "github.com", space: list[2].space)]
        XCTAssertEqual(LinkChooser.preselected(site: "github.com", rows: list, memory: memory, front: list[1].space), 2)
        XCTAssertEqual(LinkChooser.preselected(site: "example.org", rows: list, memory: memory, front: list[1].space), 1)
        XCTAssertEqual(LinkChooser.preselected(site: nil, rows: list, memory: memory, front: nil), 0)
        let gone = [LinkChooser.Choice(site: "github.com", space: UUID())]
        XCTAssertEqual(LinkChooser.preselected(site: "github.com", rows: list, memory: gone, front: list[1].space), 1)
    }

    func testRememberedMovesToFrontAndCaps() {
        let first = UUID(), second = UUID()
        var list = LinkChooser.remembered([], site: "a.com", space: first)
        list = LinkChooser.remembered(list, site: "b.com", space: first)
        list = LinkChooser.remembered(list, site: "a.com", space: second)
        XCTAssertEqual(list, [LinkChooser.Choice(site: "a.com", space: second), LinkChooser.Choice(site: "b.com", space: first)])

        var many: [LinkChooser.Choice] = []
        for index in 0...200 { many = LinkChooser.remembered(many, site: "site\(index).com", space: first) }
        XCTAssertEqual(many.count, 200)
        XCTAssertEqual(many.first?.site, "site200.com")
        XCTAssertEqual(many.last?.site, "site1.com")
    }

    func testHiddenCountsUntilJustBeforeTheLink() {
        XCTAssertTrue(Links.cameWhile(true, endedAgo: nil))
        // macOS shows a hidden app about 40 ms before it hands the link over.
        XCTAssertTrue(Links.cameWhile(false, endedAgo: 0.04))
        XCTAssertFalse(Links.cameWhile(false, endedAgo: 5))
        XCTAssertFalse(Links.cameWhile(false, endedAgo: nil))
    }

    func testTitleNamesSenderWhenKnown() {
        XCTAssertEqual(LinkChooser.title(sender: "Slack"), "Open a link from Slack")
        XCTAssertEqual(LinkChooser.title(sender: nil), "Open a link")
    }

    func testPrunedDropsGoneSpaces() {
        let here = UUID(), gone = UUID()
        let list = [LinkChooser.Choice(site: "a.com", space: gone), LinkChooser.Choice(site: "b.com", space: here)]
        XCTAssertEqual(LinkChooser.pruned(list, known: [here]), [list[1]])
    }

    func testQueueKeepsOrderAndSurvivesCancel() {
        var queue = LinkChooser.Queue()
        XCTAssertNil(queue.current)
        queue.add(url("https://a.example/"), sender: "Slack")
        queue.add(url("https://b.example/"), sender: nil, pid: 42)
        queue.add(url("https://c.example/"), sender: "Mail")
        XCTAssertEqual(queue.current?.url, url("https://a.example/"))
        XCTAssertEqual(queue.current?.sender, "Slack")
        XCTAssertEqual(queue.behind, 2)
        queue.finishCurrent()
        XCTAssertEqual(queue.current?.url, url("https://b.example/"))
        XCTAssertEqual(queue.current?.pid, 42)
        queue.finishCurrent()
        XCTAssertEqual(queue.current?.url, url("https://c.example/"))
        XCTAssertEqual(queue.behind, 0)
        queue.finishCurrent()
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.behind, 0)
    }

    func testAskIsOffByDefault() {
        XCTAssertFalse(Preferences().asksSpaceForLinks)
        XCTAssertTrue(Preferences().linkChoices.isEmpty)
    }

    func testLinkChoicesRoundTrip() {
        let prefs = Preferences()
        let choices = [LinkChooser.Choice(site: "example.com", space: UUID()),
                       LinkChooser.Choice(site: "example.org", space: UUID())]
        prefs.linkChoices = choices
        defer { prefs.linkChoices = [] }
        XCTAssertEqual(Preferences().linkChoices, choices)
    }

    func testClearingAProfileDropsItsChoices() {
        let kept = LinkChooser.Choice(site: "example.org", space: UUID())
        let dropped = LinkChooser.Choice(site: "example.com", space: UUID())
        let list = [dropped, kept]
        XCTAssertEqual(LinkChooser.cleared(list, spaces: [dropped.space]), [kept])
        XCTAssertEqual(LinkChooser.cleared(list, spaces: []), list)
    }
}
