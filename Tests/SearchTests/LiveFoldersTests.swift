import XCTest
@testable import Search

/// Live folders (LiveFolders.swift): RSS and Atom read, a page's feed found,
/// the folder kept in pin-folders.json and readable by what came before,
/// and nothing carried into one. Feeds are strings here; no network.
final class LiveFoldersTests: XCTestCase {
    private let base = URL(string: "https://blog.example/feeds/main.xml")!

    private func read(_ xml: String) throws -> Feed.Read {
        try XCTUnwrap(Feed.parse(Data(xml.utf8), url: base))
    }

    // MARK: - reading

    func testRSSReadsTitlesLinksAndTheFeedsName() throws {
        let read = try read("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>A Blog</title><link>https://blog.example/</link>
          <item><title>First post</title><link>https://blog.example/1</link></item>
          <item><title>Second post</title><link>https://blog.example/2</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(read.title, "A Blog")
        XCTAssertEqual(read.feed, base)
        XCTAssertEqual(read.items.map(\.title), ["First post", "Second post"])
        XCTAssertEqual(read.items.map(\.link.absoluteString), ["https://blog.example/1", "https://blog.example/2"])
    }

    func testCDATAAndEntitiesReadAsText() throws {
        let read = try read("""
        <rss version="2.0"><channel><title>Tom &amp; Jerry&#8217;s</title>
          <item><title><![CDATA[Cats <b>&</b> dogs]]></title><link>https://x.example/a</link></item>
          <item><title>Fish &amp;amp; chips &#x2014; again</title><link>https://x.example/b</link></item>
          <item><title>  spread
              over lines  </title><link>https://x.example/c</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(read.title, "Tom & Jerry’s")
        XCTAssertEqual(read.items.map(\.title), ["Cats <b>&</b> dogs", "Fish & chips — again", "spread over lines"])
    }

    func testAPostWithNoTitleIsCalledWhereItGoesAndOneWithNoLinkIsLeftOut() throws {
        let read = try read("""
        <rss version="2.0"><channel><title>T</title>
          <item><link>https://x.example/notes/7</link></item>
          <item><title>Nowhere</title></item>
          <item><title>By guid</title><guid>https://x.example/g</guid></item>
          <item><title>Not a link</title><guid isPermaLink="false">tag:x,1</guid></item>
        </channel></rss>
        """)
        XCTAssertEqual(read.items.map(\.title), ["x.example/notes/7", "By guid"])
    }

    func testRelativeLinksAreReadAgainstTheFeedAndOnlyWebOnesKept() throws {
        let read = try read("""
        <rss version="2.0"><channel><title>T</title>
          <item><title>Root</title><link>/posts/1</link></item>
          <item><title>Beside</title><link>two.html</link></item>
          <item><title>Script</title><link>javascript:alert(1)</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(read.items.map(\.link.absoluteString), ["https://blog.example/posts/1", "https://blog.example/feeds/two.html"])
    }

    func testAtomReadsTheAlternateLinkAndHTMLTitles() throws {
        let read = try read("""
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">Releases from owner/repo</title>
          <link rel="self" href="https://github.com/owner/repo/releases.atom"/>
          <entry>
            <title type="html">v1.2 &lt;em&gt;stable&lt;/em&gt;</title>
            <link rel="self" href="https://api.example/entries/1"/>
            <link rel="alternate" type="text/html" href="/owner/repo/releases/tag/v1.2"/>
            <source><title>Not this one</title></source>
          </entry>
          <entry><title>No rel</title><link href="https://x.example/norel"/></entry>
          <entry><title>Only self</title><link rel="self" href="https://x.example/self"/></entry>
        </feed>
        """)
        XCTAssertEqual(read.title, "Releases from owner/repo")
        XCTAssertEqual(read.items.map(\.title), ["v1.2 stable", "No rel"])
        XCTAssertEqual(read.items.first?.link.absoluteString, "https://blog.example/owner/repo/releases/tag/v1.2")
    }

    func testRSS1IsAFeedToo() throws {
        let read = try read("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
          <channel><title>Old School</title></channel>
          <item><title>One</title><link>https://x.example/1</link></item>
        </rdf:RDF>
        """)
        XCTAssertEqual(read.title, "Old School")
        XCTAssertEqual(read.items.map(\.title), ["One"])
    }

    func testAFeedWithNoNameIsCalledByItsSite() throws {
        let read = try read(#"<rss version="2.0"><channel><item><title>A</title><link>https://x.example/a</link></item></channel></rss>"#)
        XCTAssertEqual(read.title, "blog.example")
    }

    func testAtMostTwelveAndNoRepeats() throws {
        let items = (1...30).map { "<item><title>P\($0)</title><link>https://x.example/\($0 == 2 ? 1 : $0)</link></item>" }.joined()
        let read = try read("<rss version=\"2.0\"><channel><title>T</title>\(items)</channel></rss>")
        XCTAssertEqual(read.items.count, LiveFolders.most)
        XCTAssertEqual(read.items.prefix(2).map(\.title), ["P1", "P3"])
    }

    func testAPageOrBrokenXMLIsNoFeedButKeepsWhatWasRead() throws {
        XCTAssertNil(Feed.parse(Data("<!doctype html><html><head><title>x</title></head></html>".utf8), url: base))
        XCTAssertNil(Feed.parse(Data("not xml at all".utf8), url: base))
        let broken = try read("<rss version=\"2.0\"><channel><title>T</title><item><title>Kept</title><link>https://x.example/k</link></item><item><title>Bad &nbsp; entity")
        XCTAssertEqual(broken.items.map(\.title), ["Kept"])
    }

    // MARK: - finding a page's feed

    func testAPagesFeedIsFoundFromItsAlternateLink() {
        let page = URL(string: "https://site.example/blog/")!
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/s.css">
        <link rel="alternate" type="application/json" href="/feed.json">
        <LINK REL='alternate' TYPE='application/atom+xml' TITLE='Atom' HREF='atom.xml?a=1&amp;b=2'>
        <link rel="alternate" type="application/rss+xml" href="/rss.xml">
        </head></html>
        """
        XCTAssertEqual(Feed.discover(Data(html.utf8), page: page)?.absoluteString, "https://site.example/blog/atom.xml?a=1&b=2")
        XCTAssertNil(Feed.discover(Data("<html><link rel=alternate type=application/rss+xml href=\"javascript:x\"></html>".utf8), page: page))
        XCTAssertNil(Feed.discover(Data("<html><head></head></html>".utf8), page: page))
    }

    func testWhatIsTypedIsAWebAddressOrNothing() {
        XCTAssertEqual(Feed.address("example.com/feed")?.absoluteString, "https://example.com/feed")
        XCTAssertEqual(Feed.address("  http://example.com/rss  ")?.absoluteString, "http://example.com/rss")
        XCTAssertNil(Feed.address("file:///etc/passwd"))
        XCTAssertNil(Feed.address("javascript:alert(1)"))
        XCTAssertNil(Feed.address("two words"))
        XCTAssertNil(Feed.address(""))
    }

    func testARefetchKeepsEachPostsIDByLink() {
        let old = [FeedItem(id: UUID(), title: "A", link: URL(string: "https://x.example/a")!)]
        let fresh = [FeedItem(id: UUID(), title: "B", link: URL(string: "https://x.example/b")!),
                     FeedItem(id: UUID(), title: "A", link: URL(string: "https://x.example/a")!)]
        let kept = Feed.keepingIDs(fresh, from: old)
        XCTAssertEqual(kept[1], old[0])
        XCTAssertEqual(kept[0], fresh[0])
    }

    // MARK: - the file

    private func liveFolder(_ name: String = "Feed", in parent: UUID? = nil) -> PinFolder {
        PinFolder(id: UUID(), name: name, parent: parent, feed: URL(string: "https://x.example/feed")!,
                  items: [FeedItem(id: UUID(), title: "Post", link: URL(string: "https://x.example/p")!)])
    }

    func testALiveFolderRoundTripsAndAPlainOneIsWrittenAsBefore() throws {
        let live = liveFolder(), plain = PinFolder(id: UUID(), name: "Work")
        let data = try XCTUnwrap(PinFolders.encode([live, plain]))
        XCTAssertEqual(PinFolders.decode(data), [live, plain])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("feed"))
        XCTAssertFalse(keys.contains("items"))
    }

    func testAnOlderFileReadsAsPlainFolders() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Work","collapsed":true}"#
        let read = try JSONDecoder().decode(PinFolder.self, from: Data(json.utf8))
        XCTAssertEqual(read, PinFolder(id: id, name: "Work", collapsed: true))
        XCTAssertFalse(read.isLive)
    }

    func testPostsThatDontReadLeaveTheFolderLiveAndEmpty() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"F","feed":"https://x.example/f","items":[{"title":3}]}"#
        let read = try JSONDecoder().decode(PinFolder.self, from: Data(json.utf8))
        XCTAssertTrue(read.isLive)
        XCTAssertNil(read.items)
    }

    // MARK: - what goes where

    func testItsPostsAreDrawnUnderItAndFoldAway() {
        var live = liveFolder()
        let lines = PinTree.lines(pins: [], folders: [live])
        XCTAssertEqual(lines.count, 2)
        guard case .item(let item, let folder, 1) = lines[1] else { return XCTFail("\(lines)") }
        XCTAssertEqual(item.title, "Post")
        XCTAssertEqual(folder, live.id)
        live.collapsed = true
        XCTAssertEqual(PinTree.lines(pins: [], folders: [live]).count, 1)
    }

    func testNoPinAndNoFolderGoesInOne() {
        let live = liveFolder()
        let work = PinFolder(id: UUID(), name: "Work")
        let folders = [live, work]
        XCTAssertFalse(PinTree.canMake(in: live.id, in: folders))
        XCTAssertFalse(PinTree.canMove(work.id, into: live.id, in: folders))
        XCTAssertTrue(PinTree.canMove(live.id, into: work.id, in: folders))
        // A folder or a pin that says it is in one is at the top.
        let inside = PinFolder(id: UUID(), name: "In", parent: live.id)
        XCTAssertNil(PinTree.sanitized([live, inside])[1].parent)
        let pin = UUID()
        XCTAssertEqual(PinTree.lines(pins: [(pin, live.id)], folders: [live]).last, .pin(pin, depth: 0))
        // Never offered as a place to move to.
        XCTAssertEqual(PinFolderMenu.entries(folders).map(\.folder.id), [work.id])
    }

    func testAPinLetGoOverOneOrItsPostsMovesNothing() {
        let live = liveFolder()
        let item = live.items![0]
        let carried = UUID()
        let lines: [(line: PinTree.Line, frame: CGRect)] = [
            (.folder(live, depth: 0), CGRect(x: 0, y: 0, width: 200, height: 24)),
            (.item(item, folder: live.id, depth: 1), CGRect(x: 0, y: 26, width: 200, height: 28)),
            (.pin(carried, depth: 0), CGRect(x: 0, y: 56, width: 200, height: 28)),
        ]
        XCTAssertNil(PinTree.place(y: 10, lines: lines, folders: [carried: nil], carrying: carried))
        XCTAssertNil(PinTree.place(y: 40, lines: lines, folders: [carried: nil], carrying: carried))
    }

    func testAnArcImportNeverFillsALiveFolderOfTheSameName() {
        let live = liveFolder("Reading")
        let arc: [ArcSidebar.Node] = [.folder(ArcSidebar.Folder(title: "Reading", items: [
            .item(ArcSidebar.Item(title: "Page", url: URL(string: "https://p.example/")!)),
        ]))]
        let (folders, pages) = PinTree.fromArc(arc, into: [live])
        XCTAssertEqual(folders.count, 2)
        XCTAssertNotEqual(pages.first?.folder, live.id)
        // And an import's sweep of empty folders leaves it.
        XCTAssertEqual(PinTree.withoutEmpty([live], keeping: [], pins: []).map(\.id), [live.id])
    }
}
