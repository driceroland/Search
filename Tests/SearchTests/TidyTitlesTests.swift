import WebKit
import XCTest
@testable import Search

@MainActor
final class TidyTitlesTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var before = false
    private var tabs: [Tab] = []
    private var asked: [String] = []

    override func setUp() {
        super.setUp()
        TidyTitles.faking = true
        before = Shared.prefs.tidiesTitles
        Shared.prefs.tidiesTitles = true
        TidyTitles.forget()
        asked = []
        TidyTitles.fake = { [weak self] title in
            self?.asked.append(title)
            return TidyTitles.madeUp(title)
        }
    }

    override func tearDown() {
        tabs.forEach { $0.close() }
        tabs = []
        Shared.prefs.tidiesTitles = before
        TidyTitles.forget()
        TidyTitles.fake = { TidyTitles.madeUp($0) }
        TidyTitles.faking = false
        super.tearDown()
    }

    private let long = "How to bake sourdough bread at home: a beginner's guide | The Kitchen Blog"
    private let kitchen = URL(string: "https://kitchen.example/sourdough")!

    func testTheAnswerIsCleanedToOneShortLine() {
        XCTAssertEqual(TidyTitles.clean("Short title: \"Sourdough bread guide.\"\nand more", from: long), "Sourdough bread guide")
        XCTAssertEqual(TidyTitles.clean("  “Inbox” ", from: long), "Inbox")
        XCTAssertEqual(TidyTitles.clean("YouTube", from: "YouTube"), "")
        XCTAssertEqual(TidyTitles.clean("", from: long), "")
        XCTAssertEqual(TidyTitles.clean("Twenty-six letters, near", from: "Twenty-six letters, nearly"), "")
        XCTAssertEqual(TidyTitles.clean("Twenty-six", from: "Twenty-six letters, nearly"), "Twenty-six")
        let cut = TidyTitles.clean(String(repeating: "word ", count: 30), from: String(repeating: "x", count: 400))
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, TidyTitles.longest + 1)
    }

    func testTheModelIsToldWhereAPageIsOnTheWebOnly() {
        XCTAssertEqual(TidyTitles.place(of: URL(string: "https://kitchen.example/sourdough?q=secret#step-3")), "kitchen.example/sourdough")
        XCTAssertEqual(TidyTitles.place(of: URL(fileURLWithPath: "/Users/someone/Documents/notes.html")), "")
        XCTAssertEqual(TidyTitles.place(of: nil), "")
    }

    func testShownForItsOwnTitleOnlyAndNeverOverAName() {
        let tab = tidying()
        tab.restore(url: kitchen, title: long)
        XCTAssertEqual(tab.label, long, "the page's own title until the tidy one comes")
        until("tidied") { tab.label == "Tidy How to bake" }

        let next = "Rye bread with seeds, a recipe for the weekend | The Kitchen Blog"
        tab.restore(url: URL(string: "https://kitchen.example/rye")!, title: next)
        XCTAssertEqual(tab.label, next)
        until("tidied again") { tab.label == "Tidy Rye bread with" }

        tab.restore(url: kitchen, title: long)
        XCTAssertEqual(tab.label, "Tidy How to bake")

        tab.name = "Bread"
        XCTAssertEqual(tab.label, "Bread")
        tab.name = nil
        XCTAssertEqual(tab.label, "Tidy How to bake")

        tab.restore(url: URL(string: "https://example.com")!, title: "Example Domain")
        spin(0.2)
        XCTAssertEqual(tab.label, "Example Domain")

        tab.restore(url: kitchen, title: long)
        XCTAssertEqual(tab.label, "Tidy How to bake")
        Shared.prefs.tidiesTitles = false
        XCTAssertEqual(tab.label, long)
    }

    func testACountInFrontIsTheSameTitle() {
        XCTAssertEqual(TidyTitles.plain("(3) Inbox - Example Mail"), "Inbox - Example Mail")
        XCTAssertEqual(TidyTitles.plain("[12] • Inbox"), "Inbox")
        XCTAssertEqual(TidyTitles.plain("(99+) Inbox"), "Inbox")
        XCTAssertEqual(TidyTitles.plain("(Draft) Inbox"), "(Draft) Inbox")
        XCTAssertEqual(TidyTitles.plain("(3)"), "(3)")

        let tab = tidying()
        tab.restore(url: kitchen, title: "(3) " + long)
        until("tidied") { tab.label != "(3) " + long }
        let worn = tab.label

        tab.restore(url: kitchen, title: "(4) " + long)
        XCTAssertEqual(tab.label, worn)
        tab.restore(url: kitchen, title: long)
        XCTAssertEqual(tab.label, worn)
        spin(0.2)
        XCTAssertEqual(asked.count, 1)
    }

    func testAPrivateTabsTitleIsNotKept() {
        let shy = tidying(shy: true)
        shy.restore(url: kitchen, title: long)
        until("tidied in the private tab") { shy.label == "Tidy How to bake" }

        let open = tidying()
        open.restore(url: kitchen, title: long)
        XCTAssertEqual(open.label, long)
        until("tidied in its own turn") { open.label == "Tidy How to bake" }
        XCTAssertEqual(asked.count, 2)
    }

    func testANameOrTurningOffWhileTheModelAnswers() {
        var answering: CheckedContinuation<Void, Never>?
        TidyTitles.fake = { title in
            await withCheckedContinuation { answering = $0 }
            return TidyTitles.madeUp(title)
        }

        let tab = tidying()
        tab.restore(url: kitchen, title: long)
        until("asked") { answering != nil }
        tab.name = "Bread"
        answering?.resume()
        answering = nil
        spin(0.1)
        XCTAssertNil(tab.tidy)
        XCTAssertEqual(tab.label, "Bread")
        tab.name = nil
        XCTAssertEqual(tab.label, "Tidy How to bake")

        let rye = "Rye bread with seeds, a recipe for the weekend | The Kitchen Blog"
        let other = tidying()
        other.restore(url: URL(string: "https://kitchen.example/rye")!, title: rye)
        until("asked again") { answering != nil }
        Shared.prefs.tidiesTitles = false
        answering?.resume()
        answering = nil
        spin(0.1)
        Shared.prefs.tidiesTitles = true
        XCTAssertNil(other.tidy)
        XCTAssertEqual(other.label, rye)
    }

    func testTabsThatDontShowTheirTitleAreNotAsked() {
        let named = tidying()
        named.restore(url: kitchen, title: long, name: "Bread")
        let popup = tidying()
        popup.popup = true
        popup.restore(url: kitchen, title: long)
        spin(0.3)
        XCTAssertEqual(named.label, "Bread")
        XCTAssertEqual(popup.label, "kitchen.example")
        XCTAssertEqual(asked, [])
    }

    func testOneTabIsAskedAboutOnceWhileItWaits() {
        var answering: CheckedContinuation<Void, Never>?
        TidyTitles.fake = { [weak self] title in
            self?.asked.append(title)
            await withCheckedContinuation { answering = $0 }
            return TidyTitles.madeUp(title)
        }
        let first = tidying()
        first.restore(url: kitchen, title: long)
        until("asked") { answering != nil }
        let second = tidying(shy: true)
        let rye = "Rye bread with seeds, a recipe for the weekend | The Kitchen Blog"
        second.restore(url: URL(string: "https://kitchen.example/rye")!, title: "(1) " + rye)
        spin(0.1)
        second.restore(url: URL(string: "https://kitchen.example/rye")!, title: "(2) " + rye)
        spin(0.1)
        while let next = answering {
            answering = nil
            next.resume()
            spin(0.1)
        }
        XCTAssertEqual(asked.count, 2)
    }

    private func tidying(shy: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: shy, configuration: configuration)
        tabs.append(tab)
        return tab
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func until(_ what: String, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), what)
    }
}
