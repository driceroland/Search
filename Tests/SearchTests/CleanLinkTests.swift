import AppKit
import XCTest
@testable import Search

/// Copy Clean Link's rules on made-up addresses, and the bytes it copies,
/// on a pasteboard of its own rather than the Mac's clipboard (#594).
final class CleanLinkTests: XCTestCase {
    private func clean(_ text: String) -> String { CleanLink.clean(URL(string: text)!).absoluteString }

    func testTrackingGoesTheRestStaysInOrder() {
        XCTAssertEqual(clean("https://example.com/article?id=42&utm_source=newsletter#details"),
                       "https://example.com/article?id=42#details")
        XCTAssertEqual(clean("https://example.com/?b=2&utm_medium=x&a=1&fbclid=abc&gclid=1&z=%20y"),
                       "https://example.com/?b=2&a=1&z=%20y")
        XCTAssertEqual(clean("https://example.com/p?UTM_Campaign=Fall&mc_eid=9&igshid=q&msclkid=m"),
                       "https://example.com/p")
        XCTAssertEqual(clean("https://example.com/p?utm_source=a"), "https://example.com/p")
    }

    func testNothingToTakeOutLeavesItAlone() {
        for text in ["https://example.com/", "https://example.com/?q=a+b&x=%2F#top",
                     "https://example.com/?si=keep", "file:///Users/me/a.html?utm_source=x",
                     "mailto:a@example.com?subject=utm_source"] {
            XCTAssertEqual(clean(text), text)
        }
    }

    func testShareIdOnlyWhereItTracks() {
        XCTAssertEqual(clean("https://youtu.be/abc?si=XyZ&t=30"), "https://youtu.be/abc?t=30")
        XCTAssertEqual(clean("https://www.youtube.com/watch?v=abc&si=XyZ"), "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(clean("https://open.spotify.com/track/1?si=abc"), "https://open.spotify.com/track/1")
        XCTAssertEqual(clean("https://notyoutube.com/watch?si=1"), "https://notyoutube.com/watch?si=1")
    }

    func testSignedAddressesAreCopiedAsTheyAre() {
        let signed = "https://bucket.s3.amazonaws.com/f.pdf?utm_source=x&X-Amz-Signature=abc"
        XCTAssertEqual(clean(signed), signed)
        let goog = "https://storage.googleapis.com/b/o?X-Goog-Signature=1&utm_medium=y"
        XCTAssertEqual(clean(goog), goog)
    }

    @MainActor
    func testCopiedBytesAndWebKitsCopyRewritten() {
        let board = NSPasteboard(name: NSPasteboard.Name("search.cleanlink.test.\(getpid())"))
        defer { board.releaseGlobally() }
        CleanLink.copy(URL(string: "https://example.com/a?x=1&utm_term=t")!, to: board)
        XCTAssertEqual(board.string(forType: .string), "https://example.com/a?x=1")

        // As WebKit's Copy Link leaves it, written after the menu's action.
        let before = board.changeCount
        board.clearContents()
        board.setString("https://example.com/b?gclid=1&k=v", forType: .URL)
        board.setString("https://example.com/b?gclid=1&k=v", forType: .string)
        CleanLink.rewrite(board, since: before)
        XCTAssertEqual(board.string(forType: .string), "https://example.com/b?k=v")
    }
}
