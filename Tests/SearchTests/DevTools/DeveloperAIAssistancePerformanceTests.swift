import XCTest
@testable import Search

/// AI assistance about a Performance entry, a Performance insight and a file
/// open in Sources: the context the on-device model is told. No model needed.
final class DeveloperAIAssistancePerformanceTests: XCTestCase {
    typealias AIText = DeveloperAIContextText
    typealias Timing = DeveloperToolsSession.Timing

    private var profile: DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([
            Timing(type: "EventDispatch", start: 0, end: 0.080, data: ["type": "click"]),
            Timing(type: "FunctionCall", start: 0.001, end: 0.070, depth: 1,
                   data: ["scriptName": "https://example.com/app.js"], stack: ["onClick — app.js:12"]),
            Timing(type: "Layout", start: 0.010, end: 0.030, depth: 2),
            Timing(type: "RecalculateStyles", start: 0.040, end: 0.045, depth: 2),
        ])
    }

    func testATraceEventCarriesItsCallTree() throws {
        let profile = profile
        let call = try XCTUnwrap(profile.events.first { $0.type == "FunctionCall" })
        let text = AIText.traceEvent(call, in: profile)
        XCTAssertTrue(text.contains("Name: Function call"))
        XCTAssertTrue(text.contains("scriptName: https://example.com/app.js"))
        XCTAssertTrue(text.contains("onClick — app.js:12"), "its stack")
        XCTAssertTrue(text.contains("It ran inside (innermost first):\nEvent: click"))
        let children = try XCTUnwrap(text.range(of: "Its children, longest first:"))
        let after = text[children.upperBound...]
        let layout = try XCTUnwrap(after.range(of: "Layout"))
        let style = try XCTUnwrap(after.range(of: "Recalculate style"))
        XCTAssertLessThan(layout.lowerBound, style.lowerBound, "the longer child first")
        XCTAssertLessThanOrEqual(text.count, AIText.contextBudget)
    }

    func testALongTaskSaysSo() throws {
        let profile = profile
        let task = try XCTUnwrap(profile.events.first { $0.type == "EventDispatch" })
        XCTAssertTrue(AIText.traceEvent(task, in: profile).contains("This is a long task"))
    }

    func testAnInsightCarriesItsFindings() {
        let insight = DeveloperPerformanceInsight(
            kind: .characterSet, title: "Declare a character set", verdict: .fail,
            explanation: "Declare the encoding.", headline: "No character set declared",
            rows: [.init(id: 0, label: "Content-Type header", value: "No charset", detail: "text/html", failing: true)])
        let text = AIText.insight(insight)
        XCTAssertTrue(text.hasPrefix("The Performance insight “Declare a character set” (failed): No character set declared"))
        XCTAssertTrue(text.contains("What it checks:\nDeclare the encoding."))
        XCTAssertTrue(text.contains("[problem] Content-Type header: No charset (text/html)"))
    }

    func testAShortFileGoesWholeWithLineNumbers() {
        XCTAssertEqual(AIText.excerpt("let a = 1\nlet b = 2", around: 2), "1: let a = 1\n2: let b = 2")
    }

    func testALongFileIsCutAroundTheCaret() {
        let text = (1...2_000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = AIText.excerpt(text, around: 1_000, limit: 300)
        XCTAssertTrue(excerpt.contains("1000: line 1000"))
        XCTAssertTrue(excerpt.hasPrefix("… (lines 1–"))
        XCTAssertTrue(excerpt.hasSuffix("–2000 not shown)"))
        XCTAssertFalse(excerpt.contains("\n1: line 1\n"))
    }

    func testAMinifiedLineIsCut() {
        let excerpt = AIText.excerpt(String(repeating: "x", count: 10_000), around: 1, limit: 200)
        XCTAssertLessThanOrEqual(excerpt.count, 201)
        XCTAssertTrue(excerpt.hasPrefix("1: xxx"))
    }

    func testAFileCarriesItsNameSelectionAndText() {
        let text = AIText.file(url: "https://example.com/js/app.js", language: AIText.languageName(.js),
                               text: "function go() {}\ngo()", line: 2, selection: "go()")
        XCTAssertTrue(text.contains("File name: app.js"))
        XCTAssertTrue(text.contains("Language: JavaScript"))
        XCTAssertTrue(text.contains("The caret is on line 2."))
        XCTAssertTrue(text.contains("The selected text:\n```\ngo()\n```"))
        XCTAssertTrue(text.contains("1: function go() {}\n2: go()"))
    }

    func testSubjectsAreTheSameByWhatTheyAreAbout() {
        let a = DeveloperAISubject.traceEvent(id: "r:1", label: "Layout", context: "x")
        XCTAssertTrue(a.same(as: .traceEvent(id: "r:1", label: "Layout", context: "y")))
        XCTAssertFalse(a.same(as: .traceEvent(id: "r:2", label: "Layout", context: "x")))
        let file = DeveloperAISubject.file(url: "a.js", label: "a.js", context: "v1")
        XCTAssertFalse(file.same(as: .file(url: "a.js", label: "a.js", context: "v2")), "edited since: told again")
        XCTAssertEqual(file.examplePrompts.first, "What does this file do?")
    }
}
