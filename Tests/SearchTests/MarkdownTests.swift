import Foundation
import XCTest
@testable import Search

final class MarkdownTests: XCTestCase {
    private let base = URL(string: "https://docs.example.test/guide/start.md")

    private func html(_ text: String) -> String {
        Markdown.page(text, base: base).html
    }

    // MARK: - the title

    func testFirstHeadingBecomesTheTitleAndLeavesTheBody() {
        let page = Markdown.page("# Getting *started*\n\nHello.", base: base)
        XCTAssertEqual(page.title, "Getting started")
        XCTAssertEqual(page.html, "<p>Hello.</p>")
    }

    func testHeadingBelowASectionIsNotTheTitle() {
        let page = Markdown.page("## Setup\n\n# Later\n", base: base)
        XCTAssertNil(page.title)
        XCTAssertTrue(page.html.contains("<h1 id=\"later\">Later</h1>"))
    }

    func testFrontMatterGivesTheTitleAndIsNotShown() {
        let page = Markdown.page("---\ntitle: \"Intro to Things\"\nurl: https://x.test\n---\n\nBody text.", base: base)
        XCTAssertEqual(page.title, "Intro to Things")
        XCTAssertEqual(page.html, "<p>Body text.</p>")
    }

    func testNoteToAgentsAboutLlmsTxtIsDropped() {
        let page = Markdown.page("""
        > ## Documentation Index
        > Fetch the complete documentation index at: https://docs.example.test/llms.txt

        # Quickstart

        > A real quote.
        """, base: base)
        XCTAssertEqual(page.title, "Quickstart")
        XCTAssertFalse(page.html.contains("llms.txt"))
        XCTAssertEqual(page.html, "<blockquote><p>A real quote.</p></blockquote>")
    }

    // MARK: - nothing gets through as markup of its own

    func testRawScriptIsDropped() {
        let out = html("<script>alert(1)</script>\n\nText <script>x()</script> here")
        XCTAssertFalse(out.lowercased().contains("<script"))
    }

    func testDangerousAddressesAreNotLinked() {
        let out = html("[click](javascript:alert(1)) ![x](data:text/html,hi) <a href=\"javascript:bad()\">a</a>")
        XCTAssertFalse(out.contains("javascript:"))
        XCTAssertFalse(out.contains("data:"))
        XCTAssertTrue(out.contains("click"))
    }

    func testAttributesAreTrimmedToTheSafeOnes() {
        let out = html("<img src=\"/a.png\" onerror=\"steal()\" alt=\"A\">")
        XCTAssertEqual(out, "<img alt=\"A\" src=\"https://docs.example.test/a.png\" loading=\"lazy\">")
    }

    func testTextIsEscaped() {
        XCTAssertEqual(html("1 < 2 & \"so\" 3 > 2"), "<p>1 &lt; 2 &amp; &quot;so&quot; 3 &gt; 2</p>")
    }

    func testEntitiesPassThrough() {
        XCTAssertEqual(html("AT&amp;T &copy; &#8212;"), "<p>AT&amp;T &copy; &#8212;</p>")
    }

    // MARK: - addresses

    func testRelativeAddressesResolveAgainstTheTwin() {
        let out = html("[next](next.md) [root](/pricing) [here](#setup) ![pic](img/a.png)")
        XCTAssertTrue(out.contains("href=\"https://docs.example.test/guide/next.md\""))
        XCTAssertTrue(out.contains("href=\"https://docs.example.test/pricing\""))
        XCTAssertTrue(out.contains("href=\"#setup\""))
        XCTAssertTrue(out.contains("src=\"https://docs.example.test/guide/img/a.png\""))
    }

    func testEmptyPictureIsLeftOut() {
        XCTAssertEqual(html("Before ![]() after"), "<p>Before  after</p>")
    }

    func testReferenceLinks() {
        let out = html("See [the docs][d] and [Docs].\n\n[d]: https://x.test/a \"Title\"\n[docs]: https://x.test/b")
        XCTAssertTrue(out.contains("<a href=\"https://x.test/a\" title=\"Title\">the docs</a>"))
        XCTAssertTrue(out.contains("<a href=\"https://x.test/b\">Docs</a>"))
    }

    func testBareAddressesAreLinkedWithoutTheirFullStop() {
        let out = html("Go to https://example.test/a_b. Or www.example.test!")
        XCTAssertTrue(out.contains("<a href=\"https://example.test/a_b\">https://example.test/a_b</a>."))
        XCTAssertTrue(out.contains("<a href=\"https://www.example.test\">www.example.test</a>!"))
    }

    // MARK: - inline

    func testEmphasis() {
        XCTAssertEqual(html("*a* **b** _c_ __d__ ~~e~~"),
                       "<p><em>a</em> <strong>b</strong> <em>c</em> <strong>d</strong> <del>e</del></p>")
    }

    func testUnderscoresInsideWordsAndStarsInsideCodeStayPut() {
        XCTAssertEqual(html("snake_case_name and `a*b*c` and 2 * 3 * 4"),
                       "<p>snake_case_name and <code>a*b*c</code> and 2 * 3 * 4</p>")
    }

    func testEscapedPunctuation() {
        XCTAssertEqual(html(#"\*not em\* and \[not a link\]"#), "<p>*not em* and [not a link]</p>")
    }

    func testHardBreaks() {
        XCTAssertEqual(html("one  \ntwo\\\nthree\nfour"), "<p>one<br>two<br>\nthree\nfour</p>")
    }

    // MARK: - blocks

    func testFencedCodeKeepsItsTextAndLanguage() {
        let out = html("```bash theme={null}\necho \"<hi>\" *x*\n```")
        XCTAssertEqual(out, "<pre><code class=\"language-bash\">echo &quot;&lt;hi&gt;&quot; *x*</code></pre>")
    }

    func testFourSpacesIsNotCode() {
        XCTAssertEqual(html("    Indented, as MDX does."), "<p>Indented, as MDX does.</p>")
    }

    func testTightAndLooseLists() {
        XCTAssertEqual(html("- a\n- b"), "<ul><li>a</li><li>b</li></ul>")
        XCTAssertEqual(html("- a\n\n- b"), "<ul><li><p>a</p></li><li><p>b</p></li></ul>")
    }

    func testNestedAndOrderedLists() {
        let out = html("3. three\n4. four\n   - inner\n   - more\n5. five")
        XCTAssertEqual(out, "<ol start=\"3\"><li>three</li><li>four\n<ul><li>inner</li><li>more</li></ul></li><li>five</li></ol>")
    }

    func testCodeInsideAListItem() {
        let out = html("1. Run:\n\n   ```bash\n   mint dev \\\n     --port 3000\n   ```\n2. Done")
        XCTAssertTrue(out.contains("<pre><code class=\"language-bash\">mint dev \\\n  --port 3000</code></pre>"))
        XCTAssertTrue(out.hasPrefix("<ol><li><p>Run:</p>"))
    }

    func testTaskList() {
        let out = html("- [ ] todo\n- [x] done")
        XCTAssertEqual(out, "<ul><li><input type=\"checkbox\" disabled> todo</li><li><input type=\"checkbox\" checked disabled> done</li></ul>")
    }

    func testSentenceEndingInANumberIsNotAList() {
        XCTAssertEqual(html("It began\n1984. Then it ended."), "<p>It began\n1984. Then it ended.</p>")
    }

    func testTable() {
        let out = html("| Name | Cost |\n| :--- | ---: |\n| `a|b` | **1** |")
        XCTAssertEqual(out, "<div class=\"office-wide\"><table><thead><tr><th style=\"text-align:left\">Name</th><th style=\"text-align:right\">Cost</th></tr></thead><tbody><tr><td style=\"text-align:left\"><code>a|b</code></td><td style=\"text-align:right\"><strong>1</strong></td></tr></tbody></table></div>")
    }

    func testSetextHeadingsAndRules() {
        let page = Markdown.page("Title\n=====\n\nSub\n---\n\n***", base: base)
        XCTAssertEqual(page.title, "Title")
        XCTAssertEqual(page.html, "<h2 id=\"sub\">Sub</h2>\n<hr>")
    }

    func testRepeatedHeadingsGetTheirOwnIds() {
        XCTAssertEqual(html("## Setup\n## Setup"), "<h2 id=\"setup\">Setup</h2>\n<h2 id=\"setup-1\">Setup</h2>")
    }

    func testCommentsAreDropped() {
        XCTAssertEqual(html("<!-- a\nb -->\nText <!-- c --> end"), "<p>Text  end</p>")
    }

    // MARK: - what docs sites write

    func testComponentsGiveTheirTitlesAndStepAside() {
        let out = html("""
        <Steps>
          <Step title="Make your first call">
            Install the SDK and send a message.

            [Go to the quickstart](/get-started)
          </Step>
        </Steps>
        """)
        XCTAssertEqual(out, """
        <p class="office-part"><strong>Make your first call</strong></p>
        <p>Install the SDK and send a message.</p>
        <p><a href="https://docs.example.test/get-started">Go to the quickstart</a></p>
        """.replacingOccurrences(of: "\n\n", with: "\n"))
    }

    func testCardTitleLinksWhereTheCardGoes() {
        let out = html("<Card\n  title=\"Pricing\"\n  href=\"/pricing\"\n  icon=\"coins\"\n>\n  How it's billed.\n</Card>")
        XCTAssertTrue(out.hasPrefix("<p class=\"office-part\"><a href=\"https://docs.example.test/pricing\"><strong>Pricing</strong></a></p>"))
        XCTAssertTrue(out.contains("<p>How it&#39;s billed.</p>"))
    }

    func testCalloutsBecomeQuotes() {
        let out = html("<Note>\n  Looking to chat? Visit [the app](https://app.test).\n</Note>")
        XCTAssertEqual(out, "<blockquote>\n<p>Looking to chat? Visit <a href=\"https://app.test\">the app</a>.</p>\n</blockquote>")
    }

    func testInlineHtmlThatIsKnownIsKept() {
        XCTAssertEqual(html("[<u>Markdown</u>](https://x.test) <kbd>⌘R</kbd> <span>plain</span>"),
                       "<p><a href=\"https://x.test\"><u>Markdown</u></a> <kbd>⌘R</kbd> plain</p>")
    }

    func testDetailsSurvive() {
        let out = html("<details>\n<summary>More</summary>\n\nHidden text.\n\n</details>")
        XCTAssertEqual(out, "<details>\n<summary>More</summary>\n<p>Hidden text.</p>\n</details>")
    }

    // MARK: - size

    func testALargeDocumentRendersQuickly() {
        let section = """
        ## Section

        Some **bold** text with a [link](https://example.test/page) and `code`, and more words to read.

        - one
        - two with *emphasis*

        ```swift
        let x = 1
        ```

        """
        let text = String(repeating: section, count: 2_000)
        let start = Date()
        let page = Markdown.page(text, base: base)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(page.html.contains("id=\"section-1999\""))
    }
}
