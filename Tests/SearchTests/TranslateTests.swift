import XCTest
@testable import Search

/// Translate Page's sentence marks and language checks (Translate.swift):
/// pure functions, no page and no translator.
final class TranslateTests: XCTestCase {
    func testJoinedMarksEachPartButTheFirst() {
        XCTAssertEqual(PageTranslator.joined(["Visit", "the museum", "today."], gaps: [false, true, true]),
                       "Visit [1]the museum [2]today.")
        XCTAssertEqual(PageTranslator.joined(["un", "deux"], gaps: [false, false]), "un[1]deux")
        XCTAssertEqual(PageTranslator.joined(["seul"], gaps: [false]), "seul")
    }

    func testJoinedRefusesTextThatLooksLikeAMark() {
        XCTAssertNil(PageTranslator.joined(["See note", "[3]", "below"], gaps: [false, true, true]))
        XCTAssertNil(PageTranslator.joined(["Paris[12] is", "big"], gaps: [false, true]))
        XCTAssertNotNil(PageTranslator.joined(["Paris [a] is", "big"], gaps: [false, true]))
    }

    func testSplitBackIntoPieces() {
        XCTAssertEqual(PageTranslator.split("Visitez [1]le musée [2]aujourd'hui.", count: 3), ["Visitez", "le musée", "aujourd'hui."])
        XCTAssertEqual(PageTranslator.split("a[1][2]c", count: 3), ["a", "", "c"])
        XCTAssertEqual(PageTranslator.split("seul", count: 1), ["seul"])
    }

    func testSplitRefusesLostMovedOrExtraMarks() {
        XCTAssertNil(PageTranslator.split("Visitez le musée [2]aujourd'hui.", count: 3), "a mark lost")
        XCTAssertNil(PageTranslator.split("Visitez [2]le musée [1]aujourd'hui.", count: 3), "out of order")
        XCTAssertNil(PageTranslator.split("Visitez [1]le [1]musée [2]aujourd'hui.", count: 3), "one twice")
        XCTAssertNil(PageTranslator.split("[1]a[2]b[3]c", count: 3), "one more")
    }

    func testRoundTripThroughAStandIn() {
        let parts = ["Le", "Louvre", "est à", "Paris", "."]
        let gaps = [false, true, true, true, false]
        guard let line = PageTranslator.joined(parts, gaps: gaps) else { return XCTFail("no line") }
        XCTAssertEqual(PageTranslator.split("[fr→en] " + line, count: parts.count), ["[fr→en] Le", "Louvre", "est à", "Paris", "."])
    }

    func testBlocksKeepTheirOwnLanguageOnlyWhenClear() {
        let english = "The quick brown fox jumps over the lazy dog while the band plays on the square."
        let german = "Der schnelle braune Fuchs springt über den faulen Hund, während die Kapelle auf dem Platz spielt."
        let short = "OK merci"
        XCTAssertEqual(PageTranslator.languages(of: [english, german, short], page: "fr"), ["en", "de", "fr"])
    }

    func testPageLanguageFallsBackToTheLangAttribute() {
        XCTAssertEqual(PageTranslator.detect("", hint: "fr-FR").map(PageTranslator.code), "fr")
        XCTAssertEqual(PageTranslator.detect("Bonjour à tous, voici la page d'accueil du musée du Louvre à Paris.", hint: "en").map(PageTranslator.code), "fr")
        XCTAssertNil(PageTranslator.detect("", hint: nil))
    }

    func testCodesAndNames() {
        XCTAssertEqual(PageTranslator.code(Locale.Language(identifier: "fr-FR")), "fr")
        XCTAssertEqual(PageTranslator.code(Locale.Language(identifier: "zh-Hant")), "zh-Hant")
        XCTAssertEqual(PageTranslator.name("fr"), "French")
        XCTAssertTrue(PageTranslator.same(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")))
        XCTAssertFalse(PageTranslator.same(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
    }
}

/// A translation run against a real page, with the stand-in translator.
@MainActor
final class TranslateRunTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "translate-run-\(getpid())", 1)
        setenv("SEARCH_TRANSLATE_FAKE", "1", 1)
        super.setUp()
    }

    private static let french = """
        <html><body><p>Bonjour à tous, voici la page d'accueil du musée du Louvre à Paris.</p>
        <p>Le musée est ouvert tous les jours sauf le mardi, de neuf heures à dix-huit heures.</p>
        <script>window.fixtureReady = true</script></body></html>
        """

    private func frenchTab() async throws -> Tab {
        _ = NSApplication.shared
        let tab = Tab(bench: true)
        tab.web.loadHTMLString(Self.french, baseURL: URL(string: "https://translate-run.invalid/"))
        for _ in 0..<200 {
            if (try? await tab.web.evaluateJavaScript("window.fixtureReady")) as? Bool == true { return tab }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out loading the French page")
        throw CancellationError()
    }

    func testARunLeftByANewPageMarksNothing() async throws {
        let shown = try await frenchTab()
        XCTAssertNotNil(PageTranslator.start(shown, to: Locale.Language(identifier: "en")))
        for _ in 0..<200 where shown.translation?.phase != .done {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(shown.translation, TranslationMark(from: "fr", to: "en", phase: .done))
        shown.translationGone(sleeping: false)

        // The page goes while the first collect is still out in the page.
        let left = try await frenchTab()
        XCTAssertNotNil(PageTranslator.start(left, to: Locale.Language(identifier: "en")))
        left.translationGone(sleeping: false)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(left.translator)
        XCTAssertNil(left.translation)
    }
}
