import XCTest
@testable import Search

/// Settings › Preferences › Sources: indentation for the Tab key, and
/// what Search in all files goes through.
final class DeveloperSourcesPreferencesTests: XCTestCase {
    func testDetectsTwoAndFourSpaces() {
        XCTAssertEqual(SourceIndentation.detect("a {\n  b {\n    c\n  }\n}"), "  ")
        XCTAssertEqual(SourceIndentation.detect("a {\n    b {\n        c\n    }\n}"), "    ")
    }

    func testDetectsTabs() {
        XCTAssertEqual(SourceIndentation.detect("a {\n\tb {\n\t\tc\n\t}\n}"), "\t")
    }

    func testCommentStarsAndBlankLinesDoNotCount() {
        let text = "/**\n * doc\n */\nfunction a() {\n  \n  b()\n}\n"
        XCTAssertEqual(SourceIndentation.detect(text), "  ")
    }

    func testNothingToDetect() {
        XCTAssertNil(SourceIndentation.detect("a()\nb()\n"))
        XCTAssertNil(SourceIndentation.detect(""))
    }

    func testUnitFallsBackToTheDefault() {
        XCTAssertEqual(SourceIndentation.unit(for: "a()\nb()", detect: true, fallback: "\t"), "\t")
        XCTAssertEqual(SourceIndentation.unit(for: "a {\n  b\n}", detect: true, fallback: "    "), "  ")
        XCTAssertEqual(SourceIndentation.unit(for: "a {\n  b\n}", detect: false, fallback: "    "), "    ")
    }

    func testIndentUnitReadsTheSettings() {
        let defaults = UserDefaults(suiteName: "DeveloperSourcesPreferencesTests")!
        defaults.removePersistentDomain(forName: "DeveloperSourcesPreferencesTests")
        // Chrome's defaults: detect, else 4 spaces.
        XCTAssertEqual(DeveloperSourcesPreferences.indentUnit(for: "x", in: defaults), "    ")
        XCTAssertEqual(DeveloperSourcesPreferences.indentUnit(for: "a {\n  b\n}", in: defaults), "  ")
        defaults.set(false, forKey: DeveloperSourcesPreferences.detectIndentationKey)
        defaults.set("\t", forKey: DeveloperSourcesPreferences.defaultIndentationKey)
        XCTAssertEqual(DeveloperSourcesPreferences.indentUnit(for: "a {\n  b\n}", in: defaults), "\t")
        defaults.set("junk", forKey: DeveloperSourcesPreferences.defaultIndentationKey)
        XCTAssertEqual(DeveloperSourcesPreferences.indentUnit(for: "x", in: defaults), "    ")
        defaults.removePersistentDomain(forName: "DeveloperSourcesPreferencesTests")
    }

    func testTabInsertsSpacesToTheNextStop() {
        XCTAssertEqual(SourceIndentation.insertion(unit: "    ", column: 0), "    ")
        XCTAssertEqual(SourceIndentation.insertion(unit: "    ", column: 3), " ")
        XCTAssertEqual(SourceIndentation.insertion(unit: "    ", column: 4), "    ")
        XCTAssertEqual(SourceIndentation.insertion(unit: "  ", column: 5), " ")
        XCTAssertEqual(SourceIndentation.insertion(unit: "\t", column: 3), "\t")
    }

    func testSearchLeavesOutContentAndAnonymousScriptsUnlessAsked() {
        let page = [
            SourceResource(frame: "f", url: "https://example.com/app.js", type: "Script"),
            SourceResource(frame: "f", url: "", type: "Script"),
        ]
        let content = [SourceResource(frame: "7", url: "safari-web-extension://x/content.js", type: "ContentScript")]
        let off = SourceSearch.files(resources: page, contentScripts: content, authored: [], includeContentScripts: false)
        XCTAssertEqual(off.map(\.url), ["https://example.com/app.js"])
        let on = SourceSearch.files(resources: page, contentScripts: content, authored: [], includeContentScripts: true)
        XCTAssertEqual(on.map(\.url), ["https://example.com/app.js", "", "safari-web-extension://x/content.js"])
    }
}
