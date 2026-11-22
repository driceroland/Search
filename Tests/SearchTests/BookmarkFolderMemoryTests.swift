import AppKit
import XCTest
@testable import Search

/// ⇧⌘B (Add This Page) files a new bookmark in the folder picked last on
/// its card, per profile, instead of the top level every time.
@MainActor
final class BookmarkFolderMemoryTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testNextBookmarkGoesToTheFolderPickedLast() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let bookmarks = browser.bookmarks
        let saved = bookmarks.lastFolder
        var made: [Bookmark.ID] = []
        defer {
            for id in made { bookmarks.remove(id) }
            bookmarks.lastFolder = saved
            browser.closeAll()
        }
        bookmarks.lastFolder = nil
        browser.folded = false
        let reading = bookmarks.insert(.folder("Reading", []), into: nil)
        made.append(reading.id)

        func bookmark(_ path: String) -> Bookmark.ID? {
            browser.active?.restore(url: URL(string: "https://example.com/\(path)")!, title: path)
            browser.bookmarkCurrent()
            guard let id = browser.bookmarkCard else { return nil }
            made.append(id)
            return id
        }

        // Nothing picked yet: the top level.
        let first = try! XCTUnwrap(bookmark("first"))
        XCTAssertNil(bookmarks.parent(of: first))
        // Filed in Reading on its card...
        bookmarks.file(first, into: reading.id)
        XCTAssertEqual(bookmarks.parent(of: first), reading.id)
        XCTAssertEqual(bookmarks.lastFolder, reading.id)
        // ...the next one starts there.
        let second = try! XCTUnwrap(bookmark("second"))
        XCTAssertEqual(bookmarks.parent(of: second), reading.id)
        // One kept before stays where it is.
        bookmarks.file(first, into: nil)
        bookmarks.lastFolder = reading.id
        browser.active?.restore(url: URL(string: "https://example.com/first")!, title: "first")
        browser.bookmarkCurrent()
        XCTAssertEqual(browser.bookmarkCard, first)
        XCTAssertNil(bookmarks.parent(of: first))
        // Top Level picked: back to the top.
        bookmarks.file(second, into: nil)
        XCTAssertNil(bookmarks.lastFolder)
        let third = try! XCTUnwrap(bookmark("third"))
        XCTAssertNil(bookmarks.parent(of: third))
        // The folder gone: the top level again, not nowhere.
        bookmarks.lastFolder = reading.id
        bookmarks.remove(reading.id)
        XCTAssertNil(bookmarks.lastFolder)
        let fourth = try! XCTUnwrap(bookmark("fourth"))
        XCTAssertNil(bookmarks.parent(of: fourth))
    }

    /// Each profile's bookmarks remember their own folder.
    func testEachProfileRemembersItsOwn() {
        let tag = UUID().uuidString
        let a = Bookmarks(file: "bookmarks-a-\(tag).json")
        let b = Bookmarks(file: "bookmarks-b-\(tag).json")
        defer {
            a.lastFolder = nil
            b.lastFolder = nil
            a.retire()
            b.retire()
        }
        let work = a.insert(.folder("Work", []), into: nil)
        let home = b.insert(.folder("Home", []), into: nil)
        a.lastFolder = work.id
        XCTAssertEqual(a.lastFolder, work.id)
        XCTAssertNil(b.lastFolder)
        b.lastFolder = home.id
        // Read back from its file, once the write of it on the Disk queue
        // has landed: behind a slow write of another file, it hadn't yet.
        Disk.drain()
        XCTAssertEqual(Bookmarks(file: "bookmarks-a-\(tag).json").lastFolder, work.id, "kept across launches")
        XCTAssertEqual(b.lastFolder, home.id)
        // A folder of another profile's is no folder here.
        b.lastFolder = work.id
        XCTAssertNil(b.lastFolder)
    }
}
