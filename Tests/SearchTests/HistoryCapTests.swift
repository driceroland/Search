import Foundation
import XCTest
@testable import Search

/// The file has always kept 2,000 places; memory kept every one of the
/// session, with its text and its prefix weights, and the address field
/// scanned all of it on every key.
@MainActor
final class HistoryCapTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "history-cap-\(getpid())", 1)
        super.setUp()
    }

    /// What a History holds, read from its private stores: nothing public
    /// says how much is kept, and the point is that nothing is kept for a
    /// place that has gone.
    private struct Held {
        let visits: Set<String>
        let text: Set<String>
        let prefixes: Set<String>
        let hosts: Set<String>
    }

    private func held(_ history: History) -> Held {
        func keys(_ name: String) -> Set<String> {
            guard let store = Mirror(reflecting: history).children.first(where: { $0.label == name })?.value else { return [] }
            return Set(Mirror(reflecting: store).children.compactMap { child in
                Mirror(reflecting: child.value).children.first?.value as? String
            })
        }
        let hosts = Mirror(reflecting: history).children.first { $0.label == "visitedHosts" }?.value as? Set<String> ?? []
        return Held(visits: keys("visits"), text: keys("pageText"), prefixes: keys("weights"), hosts: hosts)
    }

    /// A History on a file of its own, emptied and removed with the test.
    private func fresh() -> History {
        History(file: "history-cap-\(UUID().uuidString).json")
    }

    private func site(_ i: Int) -> URL { URL(string: "https://site\(i).example/")! }

    func testMemoryHoldsNoMoreThanTheCapAndSlackAndNothingForWhatWentOut() {
        let history = fresh()
        defer { history.retire() }
        // Ten places visited again and again: they outrank every one-off
        // that comes after, however many, so they must still be here.
        let favourites = (0..<10).map(site)
        for _ in 0..<5 { for url in favourites { history.record(url, title: "Favourite") } }
        let ones = History.cap + History.slack + 600
        for i in 10..<(10 + ones) { history.record(site(i), title: "Once \(i)") }

        let now = held(history)
        XCTAssertLessThanOrEqual(now.visits.count, History.cap + History.slack, "memory runs past the cap by the slack at most")
        XCTAssertGreaterThanOrEqual(now.visits.count, History.cap, "and is not cut below what the file keeps")
        XCTAssertEqual(now.text, now.visits, "text only for the places still held")
        XCTAssertEqual(now.hosts.count, now.visits.count, "and the hosts of those places only")

        // Every place here is its own host, so each holds one prefix: those
        // of the places that went must have gone with them.
        let hostsHeld = Set(history.everything().compactMap { $0.url.host() })
        XCTAssertEqual(now.hosts, hostsHeld)
        XCTAssertEqual(now.prefixes, hostsHeld, "a prefix for each place held, none for a place gone")

        for url in favourites {
            XCTAssertTrue(now.visits.contains(History.identity(for: url)), "\(url) is what the file would keep, so it stays")
        }
        XCTAssertEqual(history.suggestions(for: "site3.example").first?.url, site(3))
    }

    func testAPlaceForgottenLeavesNoPrefixBehind() {
        let history = fresh()
        defer { history.retire() }
        // Deep pages, on one site and on its own: each also credits its
        // front door, and each prefix is a sum of weights that rounding
        // would leave a crumb in if it were only ever added to and taken from.
        let pages = (0..<6).map { URL(string: "https://one.example/team/\($0 % 3)/page\($0)")! }
            + [URL(string: "https://two.example/a/b")!]
        for url in pages {
            history.record(url, title: "Deep")
            history.record(url, title: "Deep")
        }
        XCTAssertFalse(held(history).prefixes.isEmpty)

        for key in held(history).visits { history.forget(key) }

        let left = held(history)
        XCTAssertTrue(left.visits.isEmpty)
        XCTAssertTrue(left.text.isEmpty)
        XCTAssertTrue(left.prefixes.isEmpty, "weights for \(left.prefixes) outlived every page under them")
        XCTAssertTrue(left.hosts.isEmpty)
    }

    func testWhatIsKeptStillRanksTheWayItDid() {
        let history = fresh()
        defer { history.retire() }
        // A site nobody has left, and one visited twice: past the cap, with
        // pruning going on around them, the first still comes first.
        for _ in 0..<20 { history.record(URL(string: "https://busy.example/")!, title: "Busy") }
        for _ in 0..<2 { history.record(URL(string: "https://busyish.example/")!, title: "Busyish") }
        for i in 100..<(100 + History.cap + History.slack + 300) { history.record(site(i), title: "Once \(i)") }

        XCTAssertEqual(history.suggestions(for: "busy").map(\.title).prefix(2), ["Busy", "Busyish"])
    }
}
