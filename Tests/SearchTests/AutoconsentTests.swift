import XCTest
@testable import Search

/// DuckDuckGo's rules, cut down for one frame the way autoconsent's own
/// filterCompactRules does, and when a new copy is fetched (Autoconsent.swift).
/// The rules are a few of the real ones (Tests/AutoconsentFixtures), so
/// nothing here fetches anything.
final class AutoconsentTests: XCTestCase {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AutoconsentFixtures/rules.json")

    private var data = Data()
    private var book: Rulebook!

    override func setUpWithError() throws {
        data = try Data(contentsOf: Self.file)
        book = try XCTUnwrap(Rulebook(data))
    }

    private func names(_ cut: [String: Any]) -> [String] { (cut["r"] as? [[Any]] ?? []).compactMap { $0[1] as? String } }
    private func strings(_ cut: [String: Any]) -> Int { (cut["s"] as? [Any])?.count ?? -1 }

    func testASiteWithNoRulesOfItsOwnGetsOnlyThoseForAnySite() {
        let cut = book.rules(for: "https://nothing-of-its-own.example/", mainFrame: true)
        XCTAssertEqual(names(cut), ["Complianz banner", "didomi", "cookiealert", "piano.io"])
        XCTAssertEqual(strings(cut), 2494, "the strings up to genericStringEnd")
        XCTAssertEqual(cut["v"] as? Int, 1)
    }

    func testASiteWithARuleOfItsOwnGetsItToo() {
        let cut = book.rules(for: "https://www.abcacupuncture1.com/", mainFrame: true)
        XCTAssertEqual(names(cut), ["Complianz banner", "didomi", "cookiealert", "piano.io", "abcacupuncture1"])
        XCTAssertEqual(strings(cut), 4662, "every string, as filterCompactRules")
    }

    func testAFrameGetsOnlyRulesThatRunInFrames() {
        let cut = book.rules(for: "https://cmp.example/consent", mainFrame: false)
        XCTAssertEqual(names(cut), ["cookiealert", "piano.io"])
        XCTAssertEqual(strings(cut), 2562, "the strings up to frameStringEnd")
    }

    func testAFrameOfOneSiteGetsThatSitesFrameRule() {
        XCTAssertTrue(names(book.rules(for: "https://www.dropbox.com/", mainFrame: false))
            .contains("auto_AU_help.dropbox.com_4ad_+1"))
    }

    func testARuleForFramesStaysOffTheTopPage() {
        XCTAssertFalse(names(book.rules(for: "https://www.dropbox.com/", mainFrame: true))
            .contains("auto_AU_help.dropbox.com_4ad_+1"))
    }

    func testARuleForASitesOwnPageStaysOutOfItsFrames() {
        XCTAssertFalse(names(book.rules(for: "https://www.abcacupuncture1.com/", mainFrame: false)).contains("abcacupuncture1"))
    }

    func testHeuristicsStayOff() {
        XCTAssertEqual(Autoconsent.config["enableHeuristicDetection"] as? Bool, false)
        XCTAssertEqual(Autoconsent.config["heuristicMode"] as? String, "off")
        XCTAssertEqual(Autoconsent.config["autoAction"] as? String, "optOut")
    }

    func testWhatIsntRulesTheScriptReadsIsntABook() throws {
        XCTAssertNil(Rulebook(Data("{}".utf8)))
        XCTAssertNil(Rulebook(Data("<html>Not found</html>".utf8)))
        XCTAssertNil(Rulebook(Data(#"{"v":1,"s":[],"r":[[1]],"index":{"genericRuleRange":[0,9]}}"#.utf8)))
        // A newer format than the shipped script's: refused, the last copy kept.
        var newer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        newer["v"] = Rulebook.format + 1
        XCTAssertNil(Rulebook(try JSONSerialization.data(withJSONObject: newer)))
    }

    func testANewCopyIsDueWhenThereIsNoneOrItIsAWeekOld() {
        let now = Date()
        XCTAssertTrue(ConsentRules.due(fetched: nil, tried: nil, now: now))
        XCTAssertFalse(ConsentRules.due(fetched: now.addingTimeInterval(-6 * 86_400), tried: nil, now: now))
        XCTAssertTrue(ConsentRules.due(fetched: now.addingTimeInterval(-7 * 86_400), tried: nil, now: now))
    }

    func testNotAskedAgainWithinTheHourAfterAFetchThatFailed() {
        let now = Date()
        XCTAssertFalse(ConsentRules.due(fetched: nil, tried: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(ConsentRules.due(fetched: nil, tried: now.addingTimeInterval(-3_600), now: now))
    }

    func testRulesComeForTheScriptsOwnMajorVersion() {
        XCTAssertEqual(ConsentRules.address(for: "18.0.0")?.absoluteString,
                       "https://cdn.jsdelivr.net/npm/@duckduckgo/autoconsent@18/rules/compact-rules.json")
        XCTAssertNil(ConsentRules.address(for: nil))
        XCTAssertNil(ConsentRules.address(for: "next"))
    }
}
