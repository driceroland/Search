import XCTest
@testable import Search

/// The count a pin's badge shows, read off the front of its page's title
/// (UnreadBadge.swift): only a bracketed number at the very front, so a year
/// further along, or a word in brackets, is never taken for one.
@available(macOS 14, *)
final class UnreadTests: XCTestCase {
    func testCountsAtTheFront() {
        XCTAssertEqual(Unread.count(in: "(3) WhatsApp"), "3")
        XCTAssertEqual(Unread.count(in: "(12) Messenger"), "12")
        XCTAssertEqual(Unread.count(in: "(12+) Telegram"), "12+")
        XCTAssertEqual(Unread.count(in: "( 4 ) Discord"), "4")
        XCTAssertEqual(Unread.count(in: "  (7) X"), "7")
    }

    func testCappedAtNinetyNine() {
        XCTAssertEqual(Unread.count(in: "(150) Facebook"), "99+")
    }

    func testNothingElseIsACount() {
        for title in ["WhatsApp", "(0) WhatsApp", "Dune (2021) - IMDb", "(beta) Notes", "()", "(3",
                      "(123456) x", "(١٢) Arabic digits", "Inbox (3) - Gmail", ""] {
            XCTAssertNil(Unread.count(in: title), title)
        }
    }
}
