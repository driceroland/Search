import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A new tab's site tiles (HomeTiles.swift): what may be a tile's address,
/// how its name is kept, how they're kept in the Home folder, moved and
/// capped, and what a private tab may do with them.
@available(macOS 14, *)
@MainActor
final class HomeTilesTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func refused(_ typed: String, file: StaticString = #filePath, line: UInt = #line) -> TileAddress.Problem? {
        if case let .failure(problem) = TileAddress.read(typed) { return problem }
        return nil
    }

    private func read(_ typed: String) -> URL? {
        if case let .success(url) = TileAddress.read(typed) { return url }
        return nil
    }

    // MARK: addresses

    func testEveryOtherSchemeIsRefused() {
        let schemes = [
            "javascript:alert(1)", "JavaScript:alert(document.cookie)", "javascript://%0aalert(1)",
            "data:text/html,<script>alert(1)</script>", "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd", "file://localhost/Users", "blob:https://example.com/0f6c-11",
            "about:blank", "about:config", "chrome-extension://abcdefghijklmnop/popup.html",
            "webkit-extension://abc/page.html", "\(InternalPage.scheme)://settings", "search://history",
            "mailto:someone@example.com", "ftp://example.com/file", "vbscript:msgbox", "view-source:https://example.com",
        ]
        for typed in schemes {
            let problem = refused(typed)
            XCTAssertNotNil(problem, "\(typed) must be refused")
            XCTAssertTrue(problem == .scheme || problem == .notAddress, "\(typed): \(String(describing: problem))")
        }
        XCTAssertEqual(refused("javascript:alert(1)"), .scheme, "said as a scheme refused, not a typo")
        XCTAssertEqual(refused("data:text/html,x"), .scheme)
        XCTAssertEqual(refused("file:///etc/passwd"), .scheme)
    }

    func testWebAddressesAreReadAsTheFieldReadsThem() {
        XCTAssertEqual(read("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(read("  https://Example.com/a?b=1#c  ")?.absoluteString, "https://Example.com/a?b=1#c")
        XCTAssertEqual(read("http://example.com")?.scheme, "http", "plain http kept when typed")
        XCTAssertEqual(read("localhost:3000")?.absoluteString, "http://localhost:3000", "a local server, http, not a scheme")
        XCTAssertEqual(read("192.168.1.10/admin")?.scheme, "http")
        XCTAssertEqual(refused(""), .empty)
        XCTAssertEqual(refused("   "), .empty)
        XCTAssertEqual(refused("hello world"), .notAddress)
        XCTAssertEqual(refused("todo"), .notAddress)
        XCTAssertEqual(refused("someone@example.com"), .notAddress, "an email address")
    }

    func testANameAndPasswordBeforeTheHostIsRefused() {
        XCTAssertEqual(refused("https://bank.example@evil.example/"), .credentials)
        XCTAssertEqual(refused("https://user:pass@example.com"), .credentials)
        XCTAssertEqual(TileAddress.check(URL(string: "https://a:b@example.com")!), .failure(.credentials))
    }

    func testLengthIsCapped() {
        let long = "https://example.com/" + String(repeating: "a", count: TileAddress.most)
        XCTAssertEqual(refused(long), .tooLong)
        let fits = "https://example.com/" + String(repeating: "a", count: TileAddress.most - 40)
        XCTAssertNotNil(read(fits))
        XCTAssertFalse(TileAddress.allowed(URL(string: long)!))
    }

    func testInternationalNamesAreKeptAsPunycodeAndShownSafely() {
        // Cyrillic letters that pass for "apple": kept and shown as punycode.
        let spoof = read("аррӏе.com")
        XCTAssertEqual(spoof?.host(percentEncoded: false), "xn--80ak6aa92e.com")
        XCTAssertEqual(spoof.map(TileAddress.shown), "xn--80ak6aa92e.com", "a look-alike is shown as what it is")
        // Latin with accents can't pass for another site: shown as itself.
        let accents = read("bücher.de")
        XCTAssertEqual(accents?.host(percentEncoded: false), "xn--bcher-kva.de")
        XCTAssertEqual(accents.map(TileAddress.shown), "bücher.de")
        XCTAssertEqual(TileAddress.shown(URL(string: "https://www.example.com/x")!), "example.com")
        XCTAssertEqual(TileAddress.shown(URL(string: "http://localhost:3000/")!), "localhost:3000")
        XCTAssertEqual(TileAddress.shown(URL(string: "https://example.com:443/")!), "example.com")
    }

    // MARK: names

    func testNamesArePlainShortOneLineText() {
        XCTAssertEqual(TileName.clean("  Mail  "), "Mail")
        XCTAssertEqual(TileName.clean("<img src=x onerror=alert(1)>"), "<img src=x onerror=alert(1)>",
                       "kept as text: nothing renders it as markup")
        XCTAssertEqual(TileName.clean("Two\nlines\r\n\tand\u{0}more"), "Two lines and more")
        XCTAssertEqual(TileName.clean("\u{202E}moc.elgoog"), "moc.elgoog", "no turning text around")
        XCTAssertEqual(TileName.clean("a\u{2066}b\u{200F}c"), "abc")
        XCTAssertEqual(TileName.clean(String(repeating: "x", count: 500)).count, TileName.most)
        XCTAssertEqual(TileName.clean(String(repeating: "👩‍👩‍👧", count: 100)).count, TileName.most, "cut by characters, not bytes")
    }

    // MARK: kept

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testTilesAreKeptInTheHomeFolderAndComeBack() {
        _ = NSApplication.shared
        let file = "home-tiles-test.json"
        let list = Bookmarks(file: file)
        list.adopt([.site("Elsewhere", url("https://elsewhere.example/"))])
        XCTAssertTrue(list.tiles.isEmpty)

        guard case .success = list.addTile(name: "  News\n", url: url("https://news.example/")) else { return XCTFail() }
        XCTAssertNotNil(list.homeFolder, "the folder is made")
        XCTAssertEqual(list.tiles.map(\.title), ["News"])
        guard case .success = list.addTile(name: "", url: url("https://www.mail.example/")) else { return XCTFail() }
        XCTAssertEqual(list.tiles.last?.title, "mail.example", "no name, the site's")
        Disk.drain()

        let again = Bookmarks(file: file)
        XCTAssertEqual(again.tiles.map(\.url), ["https://news.example/", "https://www.mail.example/"], "written and read back")
        XCTAssertEqual(again.roots.first?.title, "Elsewhere", "nothing else moved")
        again.retire()
    }

    func testBadFilesAndBadEntriesDoNoHarm() throws {
        _ = NSApplication.shared
        let file = "home-tiles-bad.json"
        try Data("{not json".utf8).write(to: Store.file(file))
        let broken = Bookmarks(file: file)
        XCTAssertTrue(broken.tiles.isEmpty, "a file that doesn't read is no tiles")
        broken.retire()

        let list = Bookmarks(file: "home-tiles-mixed.json")
        defer { list.retire() }
        // As a synced or imported list could have it.
        list.adopt([.folder("home", [
            Bookmark(title: "Script", url: "javascript:alert(1)", children: nil),
            Bookmark(title: "File", url: "file:///etc/passwd", children: nil),
            Bookmark(title: "Data", url: "data:text/html,x", children: nil),
            Bookmark(title: "Trick", url: "https://a@evil.example/", children: nil),
            Bookmark(title: "Broken", url: "not a url at all", children: nil),
            .folder("Sub", [.site("Deep", url("https://deep.example/"))]),
            .site("Good", url("https://good.example/")),
        ])])
        XCTAssertEqual(list.tiles.map(\.title), ["Good"], "only web addresses, top of the folder only")
    }

    func testAddingIsCappedAndKeepsNoTwins() {
        _ = NSApplication.shared
        let list = Bookmarks(file: "home-tiles-cap.json")
        defer { list.retire() }
        for n in 0..<HomeTiles.most {
            guard case .success = list.addTile(name: "S\(n)", url: url("https://s\(n).example/")) else { return XCTFail("\(n)") }
        }
        XCTAssertEqual(list.addTile(name: "One more", url: url("https://more.example/")).failure, .full)
        XCTAssertEqual(list.tiles.count, 12)
        list.removeTile(list.tiles[0].id)
        XCTAssertEqual(list.addTile(name: "Twin", url: url("https://s1.example/")).failure, .already)
        XCTAssertEqual(list.addTile(name: "Bad", url: url("file:///tmp/x")).failure, .scheme)
        // A Home folder with more than twelve: the first twelve are tiles.
        list.adopt([.folder("Home", (0..<20).map { .site("S\($0)", url("https://s\($0).example/")) })])
        XCTAssertEqual(list.tiles.count, 12)
        XCTAssertEqual(list.addTile(name: "x", url: url("https://x.example/")).failure, .full)
    }

    func testEditingChecksTheAddressAndTheName() {
        _ = NSApplication.shared
        let list = Bookmarks(file: "home-tiles-edit.json")
        defer { list.retire() }
        list.addTile(name: "A", url: url("https://a.example/"))
        list.addTile(name: "B", url: url("https://b.example/"))
        let a = list.tiles[0].id
        XCTAssertNil(list.editTile(a, name: "  Alpha\u{202E} ", url: url("https://alpha.example/")))
        XCTAssertEqual(list.tiles[0].title, "Alpha")
        XCTAssertEqual(list.tiles[0].url, "https://alpha.example/")
        XCTAssertEqual(list.editTile(a, name: "x", url: url("https://b.example/")), .already)
        XCTAssertEqual(list.editTile(a, name: "x", url: url("javascript:alert(1)")), .scheme)
        XCTAssertEqual(list.tiles[0].url, "https://alpha.example/", "a refused edit changes nothing")
    }

    func testMovingKeepsWhatElseTheFolderHolds() {
        _ = NSApplication.shared
        let list = Bookmarks(file: "home-tiles-move.json")
        defer { list.retire() }
        list.adopt([.folder("Home", [
            .site("A", url("https://a.example/")),
            .folder("Sub", []),
            .site("B", url("https://b.example/")),
            Bookmark(title: "Script", url: "javascript:void(0)", children: nil),
            .site("C", url("https://c.example/")),
            .site("D", url("https://d.example/")),
        ])])
        func names() -> [String] { list.tiles.map(\.title) }
        func folder() -> [String] { list.homeFolder?.children?.map(\.title) ?? [] }

        list.moveTile(list.tiles[0].id, to: 3)
        XCTAssertEqual(names(), ["B", "C", "D", "A"])
        list.moveTile(list.tiles[3].id, to: 0)
        XCTAssertEqual(names(), ["A", "B", "C", "D"])
        list.moveTile(list.tiles[1].id, to: 2)
        XCTAssertEqual(names(), ["A", "C", "B", "D"])
        list.moveTile(list.tiles[3].id, to: 99)
        XCTAssertEqual(names(), ["A", "C", "B", "D"], "past the end is the end")
        list.moveTile(list.tiles[0].id, to: -4)
        XCTAssertEqual(names(), ["A", "C", "B", "D"])
        XCTAssertTrue(folder().contains("Sub") && folder().contains("Script"), "the rest of the folder stays")
        list.removeTile(list.tiles[1].id)
        XCTAssertEqual(names(), ["A", "B", "D"])
        list.removeTile(list.homeFolder!.children!.first { $0.title == "Sub" }!.id)
        XCTAssertEqual(names(), ["A", "B", "D"], "removeTile takes only tiles")
    }

    // MARK: the window

    func testOffUntilTurnedOnAndAPrivateTabChangesNothing() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.bookmarks.roots
        let was = browser.prefs.homeTiles
        defer { browser.prefs.homeTiles = was; browser.bookmarks.adopt(saved); browser.closeAll() }
        browser.bookmarks.adopt([])

        browser.prefs.homeTiles = false
        XCTAssertFalse(HomeTiles.showing(browser))
        XCTAssertEqual(browser.addTile(name: "A", typed: "a.example"), .notAddress, "off, nothing kept")
        XCTAssertNil(browser.bookmarks.homeFolder, "off, no folder made")

        browser.prefs.homeTiles = true
        XCTAssertTrue(HomeTiles.showing(browser))
        XCTAssertEqual(HomeTiles.count(browser), 1, "the + alone")
        XCTAssertNil(browser.addTile(name: "A", typed: "a.example"))
        XCTAssertEqual(browser.addTile(name: "J", typed: "javascript:alert(1)"), .scheme)
        XCTAssertEqual(HomeTiles.count(browser), 2)
        XCTAssertEqual(HomeTiles.height(browser), HomeTiles.chipHeight, "one line of chips")

        browser.newShyTab()
        XCTAssertEqual(browser.active?.shy, true)
        XCTAssertTrue(HomeTiles.showing(browser), "shown in a private tab")
        XCTAssertFalse(browser.tilesEditable)
        XCTAssertEqual(HomeTiles.count(browser), 1, "without the +")
        XCTAssertEqual(browser.addTile(name: "B", typed: "b.example"), .notAddress, "nothing added from a private tab")
        XCTAssertEqual(browser.bookmarks.tiles.count, 1)
        XCTAssertFalse(browser.offersTile(browser.active!))
    }

    func testHeightFollowsRowsAndWidth() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.bookmarks.roots
        let was = browser.prefs.homeTiles
        defer { browser.prefs.homeTiles = was; browser.bookmarks.adopt(saved); browser.closeAll() }
        browser.prefs.homeTiles = true
        browser.bookmarks.adopt([.folder("Home", (0..<12).map { .site("S\($0)", url("https://s\($0).example/")) })])
        let h = HomeTiles.chipHeight, g = HomeTiles.gap
        let widths = HomeTiles.widths(browser)
        XCTAssertEqual(widths.count, 12, "twelve chips, no +")
        let lines = HomeTiles.lines(widths, in: Metrics.fieldWidth)
        XCTAssertTrue((2...3).contains(lines), "twelve short names: two or three lines in the field's width, got \(lines)")
        XCTAssertEqual(HomeTiles.height(browser), CGFloat(lines) * h + CGFloat(lines - 1) * g)
        let narrow = HomeTiles.lines(widths, in: 200)
        XCTAssertGreaterThan(narrow, lines, "more lines when narrow")
        XCTAssertEqual(HomeTiles.height(browser, width: 200), CGFloat(narrow) * h + CGFloat(narrow - 1) * g)
        XCTAssertEqual(HomeGrid.height(browser), HomeTiles.height(browser), "what lies under it makes room for the chips")
        // The wrap rule itself.
        XCTAssertEqual(HomeTiles.lines([], in: 100), 0)
        XCTAssertEqual(HomeTiles.lines([40, 40], in: 86), 1, "40 + 6 + 40 fits")
        XCTAssertEqual(HomeTiles.lines([40, 40], in: 85), 2)
        XCTAssertEqual(HomeTiles.lines([500], in: 100), 1, "one too wide still takes one line")
        // A long name is cut at the chip's label width.
        XCTAssertEqual(HomeTiles.labelFit(String(repeating: "W", count: 60)), HomeTiles.labelWidth)
        XCTAssertLessThan(HomeTiles.chipWidth("Mail"), HomeTiles.chipWidth(String(repeating: "W", count: 60)))
        XCTAssertEqual(HomeTiles.chipWidth(String(repeating: "W", count: 60)),
                       ceil(HomeTiles.padding * 2 + HomeTiles.iconSize + HomeTiles.iconGap + HomeTiles.labelWidth))
    }

    // MARK: pictures

    /// The tiles under the field, offscreen, never in a window: 0, 1, 6
    /// and 12 sites, light and dark, and the editor. Written where
    /// TILES_SHOTS says, when it does.
    func testPictures() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.bookmarks.roots
        let was = browser.prefs.homeTiles
        defer { browser.prefs.homeTiles = was; browser.bookmarks.adopt(saved); browser.closeAll() }
        browser.prefs.homeTiles = true
        let names = ["Mail", "Calendar", "News", "GitHub", "Figma", "Music", "Docs", "Maps", "Photos", "Weather", "Notes", "The Very Long Name of a Newspaper Site"]
        // Two icons known, as browsing would have left them; the rest letters.
        for (host, colour) in [("mail.example", NSColor.systemBlue), ("github.example", NSColor.black)] {
            let data = icon(colour)
            await_ { await Favicons.shared.adopt(data, for: host) }
        }
        let out = ProcessInfo.processInfo.environment["TILES_SHOTS"].map { URL(fileURLWithPath: $0) }
        for count in [0, 1, 6, 12] {
            browser.bookmarks.adopt(count == 0 ? [] : [.folder("Home", names.prefix(count).map {
                .site($0, url("https://\($0.lowercased().filter(\.isLetter)).example/"))
            })])
            for dark in [false, true] {
                let png = picture(HomePage(browser: browser), dark: dark)
                XCTAssertGreaterThan(png.count, 1000)
                try out.map { try png.write(to: $0.appendingPathComponent("tiles-\(count)-\(dark ? "dark" : "light").png")) }
            }
        }
        browser.bookmarks.adopt([.folder("Home", names.prefix(3).map { .site($0, url("https://\($0.lowercased().filter(\.isLetter)).example/")) })])
        for dark in [false, true] {
            let png = picture(HomePage(browser: browser, editing: .new), dark: dark)
            try out.map { try png.write(to: $0.appendingPathComponent("tiles-editor-\(dark ? "dark" : "light").png")) }
        }
        browser.newShyTab()
        let shy = picture(HomePage(browser: browser), dark: false)
        try out.map { try shy.write(to: $0.appendingPathComponent("tiles-private.png")) }
        // Narrow window: three to a row.
        browser.bookmarks.adopt([.folder("Home", names.map { .site($0, url("https://\($0.lowercased().filter(\.isLetter)).example/")) })])
        let narrow = picture(HomePage(browser: browser, field: false), dark: false, size: NSSize(width: 340, height: 620))
        try out.map { try narrow.write(to: $0.appendingPathComponent("tiles-narrow.png")) }
    }

    private struct HomePage: View {
        let browser: Browser
        var editing: HomeTiles.Editing?
        /// The field too; not in the narrow one, where its NSTextField's
        /// own width widens an offscreen host past the window's.
        var field = true
        var body: some View {
            ZStack {
                Palette.ground
                HomeTiles(browser: browser, editorForTest: editing)
                if field { Omnibox(browser: browser, over: false) }
            }
        }
    }

    private func await_(_ work: @escaping @MainActor () async -> Void) {
        let done = expectation(description: "adopted")
        Task { await work(); done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func icon(_ colour: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 14, yRadius: 14).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: 28, height: 28)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func picture<V: View>(_ view: V, dark: Bool, size: NSSize = NSSize(width: 820, height: 620)) -> Data {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Twice: the editor fills itself in on appear.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])!
    }
}

@available(macOS 14, *)
private extension Result {
    var failure: Failure? {
        if case let .failure(f) = self { return f }
        return nil
    }
}
