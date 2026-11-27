import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class TidyTitlesSearchTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        TidyTitles.faking = true
    }

    override func tearDown() {
        TidyTitles.forget()
        TidyTitles.faking = false
        super.tearDown()
    }

    private let raw = "Screen sharing pill: add a ✕ to hide it by harshith-ashok · Pull Request #1592 · driceroland/Search"
    private let pageURL = URL(string: "https://github.example/pull")!

    private func makeBrowser() -> (Browser, Tab) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.newTab()
        return (browser, browser.active!)
    }

    func testSearchFindsWordsCutByTidyTitle() {
        let prefs = Shared.prefs
        let before = prefs.tidiesTitles
        defer { prefs.tidiesTitles = before }
        prefs.tidiesTitles = true

        let (browser, tab) = makeBrowser()
        defer { browser.closeAll() }

        tab.restore(url: pageURL, title: raw)
        until("tidied") { tab.label != raw && !tab.label.isEmpty }
        XCTAssertFalse(tab.label.lowercased().contains("1592"), "sanity: tidy title cut the PR number")
        XCTAssertFalse(tab.label.lowercased().contains("harshith"), "sanity: tidy title cut the author")

        XCTAssertGreaterThan(Browser.relevance(of: tab, to: ["1592"], whole: "1592"), 0)
        XCTAssertGreaterThan(Browser.relevance(of: tab, to: ["harshith"], whole: "harshith"), 0)
        XCTAssertGreaterThan(Browser.relevance(of: tab, to: ["screen", "1592"], whole: "screen 1592"), 0)

        let byNumber = browser.openPages(matching: "1592", front: true)
        XCTAssertEqual(byNumber.first?.tab, tab.id)
        XCTAssertEqual(byNumber.first?.key, tab.label, "still shown under its tidy title")

        let byAuthor = browser.openPages(matching: "harshith", front: true)
        XCTAssertEqual(byAuthor.first?.tab, tab.id)

        tab.name = "My PR"
        XCTAssertEqual(Browser.relevance(of: tab, to: ["harshith"], whole: "harshith"), 0)
        XCTAssertTrue(browser.openPages(matching: "harshith", front: true).isEmpty)
        XCTAssertGreaterThan(Browser.relevance(of: tab, to: ["my", "pr"], whole: "my pr"), 0)
    }

    func testCopiedLinksAndNewTabTilesUseOwnTitleNotTidyTitle() {
        let prefs = Shared.prefs
        let wasTidy = prefs.tidiesTitles
        let wasTiles = prefs.homeTiles
        defer {
            prefs.tidiesTitles = wasTidy
            prefs.homeTiles = wasTiles
        }
        prefs.tidiesTitles = true
        prefs.homeTiles = true

        let (browser, tab) = makeBrowser()
        let savedBookmarks = browser.bookmarks.roots
        defer {
            browser.bookmarks.adopt(savedBookmarks)
            browser.closeAll()
        }
        browser.bookmarks.adopt([])

        tab.restore(url: pageURL, title: raw)
        until("tidied") { tab.label != raw && !tab.label.isEmpty }

        XCTAssertEqual(Browser.ownTitle(of: tab), raw)

        XCTAssertNil(browser.addTile(from: tab))
        XCTAssertEqual(browser.bookmarks.tiles.first?.title, TileName.clean(raw))
        XCTAssertNotEqual(browser.bookmarks.tiles.first?.title, TileName.clean(tab.label))

        browser.select(tab)
        let savedClip = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let savedClip { NSPasteboard.general.setString(savedClip, forType: .string) }
        }
        browser.copyMarkdownLink()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Browser.markdownLink(raw, pageURL))

        tab.name = "My PR"
        XCTAssertEqual(Browser.ownTitle(of: tab), "My PR")
    }

    private func until(_ what: String, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), what)
    }
}
