import XCTest
@testable import Search

/// The Changes drawer tool's diff, as Chrome's draws it: lines added and
/// taken out with both line numbers, unchanged runs folded beside three
/// lines of context, the counts in the footer and Copy's text.
@MainActor
final class DeveloperChangesTests: XCTestCase {
    private typealias Diff = DeveloperChangesDiff

    private func marks(_ lines: [Diff.Line]) -> String {
        lines.map { ($0.kind == .insert ? "+" : $0.kind == .delete ? "-" : " ") + $0.text }.joined(separator: "|")
    }

    // MARK: Lines

    func testLinesIgnoreATrailingNewlineAndCarriageReturns() {
        XCTAssertEqual(Diff.lines(""), [])
        XCTAssertEqual(Diff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(Diff.lines("a\r\nb"), ["a", "b"])
        XCTAssertEqual(Diff.lines("a\n\n"), ["a", ""])
    }

    // MARK: Diff

    func testIdenticalTextsHaveNoChanges() {
        let lines = Diff.diff("a\nb\nc", "a\nb\nc")
        XCTAssertTrue(lines.allSatisfy { $0.kind == .equal })
        XCTAssertEqual(Diff.counts(lines).insertions, 0)
        XCTAssertEqual(Diff.counts(lines).deletions, 0)
    }

    func testAChangedLineIsADeletionThenAnInsertionWithBothNumbers() {
        let lines = Diff.diff("a {\n  color: red;\n}", "a {\n  color: blue;\n}")
        XCTAssertEqual(marks(lines), " a {|-  color: red;|+  color: blue;| }")
        XCTAssertEqual(lines[1].original, 2)
        XCTAssertNil(lines[1].current)
        XCTAssertNil(lines[2].original)
        XCTAssertEqual(lines[2].current, 2)
        XCTAssertEqual(lines[3].original, 3)
        XCTAssertEqual(lines[3].current, 3)
    }

    func testFromAndToEmpty() {
        XCTAssertEqual(marks(Diff.diff("", "a\nb")), "+a|+b")
        XCTAssertEqual(marks(Diff.diff("a\nb", "")), "-a|-b")
    }

    func testTheDiffIsMinimal() {
        // The classic Myers example: ABCABBA to CBABAC takes five edits.
        let a = "A B C A B B A".split(separator: " ").map(String.init)
        let b = "C B A B A C".split(separator: " ").map(String.init)
        let lines = Diff.diff(lines: a, b)
        let counts = Diff.counts(lines)
        XCTAssertEqual(counts.insertions + counts.deletions, 5)
        XCTAssertEqual(lines.filter { $0.kind != .insert }.map(\.text), a, "the original reads back from the diff")
        XCTAssertEqual(lines.filter { $0.kind != .delete }.map(\.text), b, "the current text reads back from the diff")
    }

    func testInsertionsAndDeletionsInTheMiddleOfAFile() {
        let original = (1...10).map { "line \($0)" }
        var current = original
        current.remove(at: 3)
        current.insert("new", at: 6)
        let lines = Diff.diff(lines: original, current)
        XCTAssertEqual(Diff.counts(lines).insertions, 1)
        XCTAssertEqual(Diff.counts(lines).deletions, 1)
        XCTAssertEqual(lines.first { $0.kind == .delete }?.text, "line 4")
        XCTAssertEqual(lines.first { $0.kind == .insert }?.current, 7)
    }

    func testAFewThousandLinesDiffQuickly() {
        let original = (0..<5_000).map { "line \($0)" }
        var current = original
        for index in stride(from: 100, to: 5_000, by: 250) { current[index] = "changed \(index)" }
        let started = Date()
        let lines = Diff.diff(lines: original, current)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(Diff.counts(lines).insertions, 20)
        XCTAssertEqual(Diff.counts(lines).deletions, 20)
    }

    func testPastTheEditLimitTheMiddleIsReplacedWhole() {
        let original = ["same"] + (0..<50).map { "a\($0)" } + ["end"]
        let current = ["same"] + (0..<50).map { "b\($0)" } + ["end"]
        let lines = Diff.diff(lines: original, current, editLimit: 10)
        XCTAssertEqual(lines.first?.kind, .equal)
        XCTAssertEqual(lines.last?.kind, .equal)
        XCTAssertEqual(Diff.counts(lines).deletions, 50)
        XCTAssertEqual(Diff.counts(lines).insertions, 50)
        XCTAssertEqual(lines.filter { $0.kind != .insert }.map(\.text), original)
        XCTAssertEqual(lines.filter { $0.kind != .delete }.map(\.text), current)
    }

    // MARK: Rows

    func testUnchangedRunsFoldBesideThreeLinesOfContext() {
        let original = (1...20).map { "line \($0)" }
        var current = original
        current[9] = "changed"
        let lines = Diff.diff(lines: original, current)
        let rows = Diff.rows(lines)
        // 6 folded, 3 context, -, +, 3 context, 7 folded.
        XCTAssertEqual(rows.count, 1 + 3 + 2 + 3 + 1)
        XCTAssertEqual(rows.first, .collapsed(at: 0, count: 6))
        XCTAssertEqual(rows.last, .collapsed(at: 14, count: 7))
        guard case .line(_, let first) = rows[1] else { return XCTFail("context after the fold") }
        XCTAssertEqual(first.text, "line 7")
    }

    func testAnExpandedFoldShowsItsLines() {
        let original = (1...20).map { "line \($0)" }
        var current = original
        current[9] = "changed"
        let rows = Diff.rows(Diff.diff(lines: original, current), expanded: [0])
        XCTAssertEqual(rows.first?.id, 0)
        if case .collapsed = rows.first { XCTFail("the first run is open") }
        XCTAssertEqual(rows.count, 9 + 2 + 3 + 1)
    }

    func testAFoldNeverHidesASingleLine() {
        // Seven unchanged lines between two changes: 3 + 1 + 3 stays open.
        let original = ["x"] + (1...7).map { "line \($0)" } + ["y"]
        let current = ["X"] + (1...7).map { "line \($0)" } + ["Y"]
        let rows = Diff.rows(Diff.diff(lines: original, current))
        XCTAssertFalse(rows.contains { if case .collapsed = $0 { return true } else { return false } })
        let eight = ["x"] + (1...8).map { "line \($0)" } + ["y"]
        let eightCurrent = ["X"] + (1...8).map { "line \($0)" } + ["Y"]
        let folded = Diff.rows(Diff.diff(lines: eight, eightCurrent))
        XCTAssertTrue(folded.contains(.collapsed(at: 5, count: 2)))
    }

    // MARK: Counts

    func testTheFooterCountsInsertionsAndDeletions() {
        let lines = Diff.diff("a\nb\nc", "a\nB\nc\nd")
        XCTAssertEqual(Diff.counts(lines).insertions, 2)
        XCTAssertEqual(Diff.counts(lines).deletions, 1)
        XCTAssertEqual(Diff.summary(lines), "2 insertions (+), 1 deletion (−)")
    }

    // MARK: Copy

    func testCopyForAStyleSheetGivesTheChangedRules() {
        let original = "body {\n  margin: 0;\n}\n\na {\n  color: red;\n  display: block;\n}\n"
        let current = "body {\n  margin: 0;\n}\n\na {\n  color: blue;\n  display: block;\n}\n"
        let lines = Diff.diff(original, current)
        XCTAssertEqual(Diff.cssChanges(lines, original: original, current: current),
                       "a {\n  /* color: red; */\n  color: blue;\n}")
    }

    func testCopyLeavesOutDeclarationsALineKeptWhenRewritten() {
        // setStyleText puts a rule's declarations on one line.
        let original = "a {\n  color: red;\n  display: block;\n}"
        let current = "a {color: red; display: inline;}"
        let lines = Diff.diff(original, current)
        XCTAssertEqual(Diff.cssChanges(lines, original: original, current: current),
                       "a {\n  /* display: block; */\n  display: inline;\n}")
    }

    func testCopyForARuleAdded() {
        let lines = Diff.diff("", ".box {}")
        XCTAssertEqual(Diff.cssChanges(lines, original: "", current: ".box {}"), ".box {\n}")
        let filled = Diff.diff("", ".box {color: red;}")
        XCTAssertEqual(Diff.cssChanges(filled, original: "", current: ".box {color: red;}"), ".box {\n  color: red;\n}")
    }

    func testCopyForInlineStylesUsesElementStyle() {
        let lines = Diff.diff("color: red", "color: red; margin: 0;")
        XCTAssertEqual(Diff.cssChanges(lines, original: "color: red", current: "color: red; margin: 0;", inline: true),
                       "element.style {\n  margin: 0;\n}")
    }

    func testASwitchedOffDeclarationStaysACommentInCopy() {
        let original = "a {\n  color: red;\n}"
        let current = "a {\n  /* color: red; */\n}"
        let lines = Diff.diff(original, current)
        XCTAssertEqual(Diff.cssChanges(lines, original: original, current: current), "a {\n  /* color: red; */\n}")
    }

    func testRulesInsideAtRulesKeepTheirSelector() {
        let css = "@media (max-width: 600px) {\n  .nav {\n    display: none;\n  }\n}"
        XCTAssertEqual(Diff.selectors(css), ["@media (max-width: 600px)", ".nav", ".nav", ".nav", "@media (max-width: 600px)"])
    }

    func testDeclarationsSplitOutsideStringsAndBrackets() {
        XCTAssertEqual(Diff.declarations(inLine: "  background: url(\"a;b.png\"); color: red;"),
                       ["background: url(\"a;b.png\")", "color: red"])
        XCTAssertEqual(Diff.declarations(inLine: "a:hover,"), [])
        XCTAssertEqual(Diff.declarations(inLine: "}"), [])
    }

    func testCopyForAScriptIsAUnifiedDiff() {
        let original = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let current = original.replacingOccurrences(of: "line 6", with: "six")
        let text = Diff.unified(Diff.diff(original, current))
        XCTAssertEqual(text, """
            @@ -3,7 +3,7 @@
             line 3
             line 4
             line 5
            -line 6
            +six
             line 7
             line 8
             line 9
            """)
    }

    // MARK: Names

    func testFileNames() {
        XCTAssertEqual(DeveloperChanges.fileName("https://example.com/css/site.css"), "site.css")
        XCTAssertEqual(DeveloperChanges.fileName("https://example.com/"), "(index)")
    }
}
