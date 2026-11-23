import XCTest
@testable import Search

/// Code folding's blocks and what folding them hides
/// (DeveloperSourcesFolding.swift).
final class DeveloperSourcesFoldingTests: XCTestCase {
    private func startLines(_ text: String, _ language: SourceLanguage = .js) -> [Int] {
        SourceFolding.folds(text, language: language).map(\.startLine)
    }

    func testFunctionBodyFoldsFromItsBraceToTheClosingOne() {
        let text = "function a() {\n  return 1;\n}\nb();"
        let folds = SourceFolding.folds(text, language: .js)
        XCTAssertEqual(folds.count, 1)
        let fold = folds[0]
        XCTAssertEqual(fold.startLine, 0)
        XCTAssertEqual(fold.endLine, 2)
        let string = text as NSString
        XCTAssertEqual(fold.start, string.range(of: "{").location + 1)
        XCTAssertEqual(fold.end, string.range(of: "}").location)
        XCTAssertEqual(fold.lineEnd, fold.end + 1, "to the end of the closing line, before its line break")
    }

    func testBracesInStringsCommentsAndRegexDoNotCount() {
        let text = """
        const s = '{';
        // {
        /* { */
        let r = /[{(]/;
        foo({
          a: "}"
        });
        """
        XCTAssertEqual(startLines(text), [4])
        // Both ( and { open on line 4: the first one is the line's fold.
        let fold = SourceFolding.folds(text, language: .js)[0]
        XCTAssertEqual(fold.start, (text as NSString).range(of: "foo(").location + 4)
        XCTAssertEqual(fold.endLine, 6)
    }

    func testSingleLineBlocksDoNotFold() {
        XCTAssertEqual(startLines("if (a) { b() }\nc = [1, 2]"), [])
    }

    func testNestedBlocksEachFold() {
        let text = "a = {\n  b: [\n    1,\n  ],\n  c: (\n    2\n  ),\n};"
        XCTAssertEqual(startLines(text), [0, 1, 4])
        let folds = SourceFolding.folds(text, language: .js)
        XCTAssertEqual(folds.map(\.endLine), [7, 3, 6])
    }

    func testJSXTextDoesNotConfuseIt() {
        let text = """
        const x = (
          <div>
            a ( b [ c
            {items.map(i => (
              <li/>
            ))}
          </div>
        );
        """
        let folds = SourceFolding.folds(text, language: .javascript(typescript: false, jsx: true))
        XCTAssertEqual(folds.map(\.startLine), [0, 3])
        XCTAssertEqual(folds.map(\.endLine), [7, 5])
    }

    func testTemplateSubstitutionFolds() {
        let text = "s = `x ${\n  a\n} y`;"
        XCTAssertEqual(SourceFolding.folds(text, language: .js).map(\.endLine), [2])
    }

    func testJSONFolds() {
        XCTAssertEqual(startLines("{\n  \"a\": [\n    \"{\"\n  ]\n}", .json), [0, 1])
    }

    func testCSSBlocks() {
        let text = "a { color: red; }\n@media x {\n  b {\n    c: \"}\";\n  }\n}\n/* {\n */"
        XCTAssertEqual(startLines(text, .css), [1, 2])
    }

    func testHTMLElementsAndTheirScripts() {
        let text = """
        <html>
        <body>
        <div>
        <br>
        <img src="a>b">
        <!-- <section>
        -->
        </div>
        <script>
        if (a) {
          b("</div>")
        }
        </script>
        </body>
        </html>
        """
        let folds = SourceFolding.folds(text, language: .html)
        XCTAssertEqual(folds.map(\.startLine), [0, 1, 2, 8, 9])
        XCTAssertEqual(folds.map(\.endLine), [14, 13, 7, 12, 11])
        // An element folds from the end of its opening tag to its closing one.
        let div = folds[2]
        let string = text as NSString
        XCTAssertEqual(div.start, string.range(of: "<div>").location + 5)
        XCTAssertEqual(div.end, string.range(of: "</div>\n<script>").location)
    }

    func testLineEndStopsBeforeCRLF() {
        let text = "a {\r\n b\r\n};\r\nc"
        let fold = SourceFolding.folds(text, language: .js)[0]
        XCTAssertEqual(fold.endLine, 2)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: fold.end, length: fold.lineEnd - fold.end)), "};")
    }

    // MARK: Folded state

    func testHiddenLinesAndTheNumbersShown() {
        let text = "a {\n b\n c\n}\nd {\n e\n}\nf"
        let folds = Set(SourceFolding.folds(text, language: .js))
        XCTAssertEqual(folds.count, 2)
        let hidden = SourceFolding.hiddenLines(folds)
        XCTAssertEqual(Array(hidden), [1, 2, 3, 5, 6])
        XCTAssertEqual(SourceFolding.shownLines(count: 8, hidden: hidden), [1, 5, 8])
        let first = folds.filter { $0.startLine == 0 }
        XCTAssertEqual(SourceFolding.shownLines(count: 8, hidden: SourceFolding.hiddenLines(first)), [1, 5, 6, 7, 8])
    }

    func testRevealingOpensOnlyTheFoldsHidingTheOffset() {
        let text = "a {\n b {\n  c\n }\n}\nd"
        let folds = SourceFolding.folds(text, language: .js)
        let outer = folds[0], inner = folds[1]
        let all: Set<SourceFold> = [outer, inner]
        let c = (text as NSString).range(of: "c").location
        XCTAssertEqual(SourceFolding.revealing(c, in: all), all)
        // Just after `{` and at the end of the closing line stay on screen.
        XCTAssertEqual(SourceFolding.revealing(outer.start, in: all), [])
        XCTAssertEqual(SourceFolding.revealing(outer.lineEnd, in: all), [])
        let b = (text as NSString).range(of: "b").location
        XCTAssertEqual(SourceFolding.revealing(b, in: all), [outer])
        XCTAssertEqual(SourceFolding.revealing((text as NSString).range(of: "d").location, in: all), [])
    }

    func testFoldedLineDrawsTheClosingText() {
        let text = "x = {\n  a\n};\nb"
        let fold = SourceFolding.folds(text, language: .js)[0]
        let lines = SourceFolding.foldedLines([fold])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].hidden, NSRange(location: fold.start, length: fold.lineEnd - fold.start))
        guard lines[0].pieces.count == 2, case let .text(start, end) = lines[0].pieces[1] else {
            return XCTFail("a placeholder, then the closing text")
        }
        XCTAssertEqual(lines[0].pieces[0], .placeholder(fold))
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: end - start)), "};")
    }

    func testElseChainFoldsOntoOneLine() {
        let text = "if (a) {\n  x\n} else {\n  y\n}\nz"
        let folds = SourceFolding.folds(text, language: .js)
        XCTAssertEqual(folds.map(\.startLine), [0, 2])
        let lines = SourceFolding.foldedLines(Set(folds))
        XCTAssertEqual(lines.count, 1)
        let string = text as NSString
        let pieces = lines[0].pieces.map { piece -> String in
            switch piece {
            case .placeholder: return "…"
            case let .text(start, end): return string.substring(with: NSRange(location: start, length: end - start))
            }
        }
        XCTAssertEqual(pieces.joined(), "…} else {…}")
        XCTAssertEqual(NSMaxRange(lines[0].hidden), folds[1].lineEnd)
        XCTAssertEqual(Array(SourceFolding.hiddenLines(Set(folds))), [1, 2, 3, 4])
    }

    func testFoldInsideAFoldedOneIsPartOfIt() {
        let text = "a {\n b {\n  c\n }\n}"
        let folds = Set(SourceFolding.folds(text, language: .js))
        let lines = SourceFolding.foldedLines(folds)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].pieces.count, 2)
    }
}
