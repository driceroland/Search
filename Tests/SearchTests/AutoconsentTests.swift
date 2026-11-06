import XCTest
@testable import Search

/// DuckDuckGo's rules as shipped (Autoconsent/rules.json), cut down for one
/// frame the way autoconsent's own filterCompactRules does (Autoconsent.swift).
final class AutoconsentTests: XCTestCase {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Autoconsent/rules.json")

    private var shipped: [String: Any] = [:]
    private var book: Rulebook!

    override func setUpWithError() throws {
        let data = try Data(contentsOf: Self.file)
        shipped = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        book = try XCTUnwrap(Rulebook(data))
    }

    private func index(_ key: String) -> [Int] { (shipped["index"] as? [String: Any])?[key] as? [Int] ?? [] }
    private func names(_ cut: [String: Any]) -> [String] { (cut["r"] as? [[Any]] ?? []).compactMap { $0[1] as? String } }
    private func contexts(_ cut: [String: Any]) -> Set<Int> { Set((cut["r"] as? [[Any]] ?? []).compactMap { $0[4] as? Int }) }

    func testASiteWithNoRulesOfItsOwnGetsOnlyTheGenericOnes() {
        let cut = book.rules(for: "https://nothing-of-its-own.example/", mainFrame: true)
        let generic = index("genericRuleRange")
        XCTAssertEqual((cut["r"] as? [Any])?.count, generic[1] - generic[0])
        XCTAssertEqual((cut["s"] as? [Any])?.count, (shipped["index"] as? [String: Any])?["genericStringEnd"] as? Int)
        XCTAssertEqual(cut["v"] as? Int, shipped["v"] as? Int)
    }

    func testAFrameGetsOnlyRulesThatRunInFrames() {
        let cut = book.rules(for: "https://cmp.example/consent", mainFrame: false)
        XCTAssertFalse(names(cut).isEmpty)
        XCTAssertTrue(contexts(cut).isDisjoint(with: [10, 12, 20, 22]), "\(contexts(cut))")
        let range = index("frameRuleRange")
        XCTAssertLessThanOrEqual(names(cut).count, range[1] - range[0])
        XCTAssertEqual((cut["s"] as? [Any])?.count, (shipped["index"] as? [String: Any])?["frameStringEnd"] as? Int)
    }

    /// The first rule for one site's own page, and that site.
    private func topPageRule() throws -> (name: String, host: String) {
        let rules = try XCTUnwrap(shipped["r"] as? [[Any]])
        let range = index("specificRuleRange")
        let simple = "^https?://(www\\.)?"
        let top = try XCTUnwrap(rules[range[0]..<range[1]].first {
            $0[4] as? Int == 22 && (($0[3] as? String) ?? "").hasPrefix(simple)
        })
        let pattern = try XCTUnwrap(top[3] as? String)
        let host = String(pattern.dropFirst(simple.count).prefix { $0 != "/" && $0 != "|" })
            .replacingOccurrences(of: "\\", with: "")
        return (try XCTUnwrap(top[1] as? String), host)
    }

    func testASiteWithRulesOfItsOwnGetsThemToo() throws {
        let (name, host) = try topPageRule()
        let cut = book.rules(for: "https://\(host)/", mainFrame: true)
        XCTAssertTrue(names(cut).contains(name), host)
        XCTAssertEqual((cut["s"] as? [Any])?.count, (shipped["s"] as? [Any])?.count, "every string, as filterCompactRules")
        XCTAssertFalse(names(book.rules(for: "https://nothing-of-its-own.example/", mainFrame: true)).contains(name))
    }

    func testARuleForASitesOwnPageStaysOutOfItsFrames() throws {
        let (name, host) = try topPageRule()
        XCTAssertFalse(names(book.rules(for: "https://\(host)/", mainFrame: false)).contains(name), host)
    }

    func testHeuristicsStayOff() {
        XCTAssertEqual(Autoconsent.config["enableHeuristicDetection"] as? Bool, false)
        XCTAssertEqual(Autoconsent.config["heuristicMode"] as? String, "off")
        XCTAssertEqual(Autoconsent.config["autoAction"] as? String, "optOut")
    }

    func testBrokenRulesAreNotABook() {
        XCTAssertNil(Rulebook(Data("{}".utf8)))
        XCTAssertNil(Rulebook(Data(#"{"v":1,"s":[],"r":[],"index":{"genericRuleRange":[0,9]}}"#.utf8)))
    }
}
