import XCTest
@testable import Search

/// Lighthouse's "Save as HTML": the self-contained report page.
final class DeveloperLighthouseHTMLTests: XCTestCase {
    private func report() -> DeveloperLighthouseReport {
        let lcp = DeveloperLighthouseAudit(
            id: "largest-contentful-paint", title: "Largest Contentful Paint", description: "Largest paint.",
            score: 0.42, mode: .numeric, numericValue: 4_200, numericUnit: "millisecond", displayValue: "4.2 s")
        let compression = DeveloperLighthouseAudit(
            id: "uses-text-compression", title: "Enable text compression", description: "Compress text.",
            score: 0.5, mode: .numeric, numericValue: 300, numericUnit: "millisecond", displayValue: nil,
            details: DeveloperLighthouseDetails(.opportunity,
                                                headings: [.init(key: "url", label: "URL", valueType: "url"),
                                                           .init(key: "wastedBytes", label: "Est Savings", valueType: "bytes")],
                                                items: [["url": .url("https://example.com/app.js?a=1&b=2"), "wastedBytes": .bytes(20_480)]],
                                                savingsMs: 300, savingsBytes: 20_480))
        let alt = DeveloperLighthouseAudit(
            id: "image-alt", title: "Image elements have `[alt]` attributes", description: "Alt <script>alert(1)</script>",
            score: 0, mode: .binary,
            details: .nodes([DeveloperLighthouseNode(index: 0, snippet: "<img src=\"x.png\">", selector: "img", label: "Logo & mark")]))
        let lang = DeveloperLighthouseAudit(id: "html-has-lang", title: "`<html>` element has a `[lang]` attribute",
                                            description: "Lang.", score: 1, mode: .binary)
        let frames = DeveloperLighthouseAudit(id: "frame-title", title: "Frames have a title", description: "Frames.",
                                              score: nil, mode: .notApplicable)
        let audits = [lcp, compression, alt, lang, frames]
        let categories = [
            DeveloperLighthouseCategory(id: .performance, refs: [
                DeveloperLighthouseAuditRef(id: lcp.id, weight: 25, group: "metrics"),
                DeveloperLighthouseAuditRef(id: compression.id, weight: 0, group: "load-opportunities"),
            ], score: 0.42),
            DeveloperLighthouseCategory(id: .accessibility, refs: [
                DeveloperLighthouseAuditRef(id: alt.id, weight: 10, group: "a11y-names-labels"),
                DeveloperLighthouseAuditRef(id: lang.id, weight: 7, group: "a11y-language"),
                DeveloperLighthouseAuditRef(id: frames.id, weight: 7, group: "a11y-names-labels"),
            ], score: 0.97),
        ]
        return DeveloperLighthouseReport(requestedURL: "https://example.com/?q=<x>", finalURL: "https://example.com/?q=<x>",
                                         fetchTime: Date(timeIntervalSince1970: 1_700_000_000), mode: .navigation,
                                         formFactor: .mobile, categories: categories,
                                         audits: Dictionary(uniqueKeysWithValues: audits.map { ($0.id, $0) }),
                                         warnings: ["A \"warning\""], userAgent: "Mozilla/5.0 Test", emulation: "Mobile",
                                         totalTime: 1_234)
    }

    func testReportHasScoresAuditsAndEnvironment() {
        let html = DeveloperLighthouseHTML.html(report())
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertFalse(html.contains("<script"))
        // A gauge per category, with its score and rating.
        XCTAssertTrue(html.contains("class=\"gauge fail\""))
        XCTAssertTrue(html.contains(">42</text>"))
        XCTAssertTrue(html.contains("class=\"gauge pass\""))
        XCTAssertTrue(html.contains(">97</text>"))
        XCTAssertTrue(html.contains("Performance"))
        XCTAssertTrue(html.contains("Accessibility"))
        // Metrics, the opportunity with its savings, the failing audit's details.
        XCTAssertTrue(html.contains("4.2 s"))
        XCTAssertTrue(html.contains("Opportunities"))
        XCTAssertTrue(html.contains("Est savings of 300 ms, 20 KiB"))
        XCTAssertTrue(html.contains("<td class=\"number\">20 KiB</td>"))
        XCTAssertTrue(html.contains("Names and labels"))
        XCTAssertTrue(html.contains("<code>[alt]</code>"))
        // Passed and not applicable audits in their own clumps.
        XCTAssertTrue(html.contains("Passed audits <span class=\"count\">(1)</span>"))
        XCTAssertTrue(html.contains("Not applicable <span class=\"count\">(1)</span>"))
        XCTAssertTrue(html.contains("Frames have a title"))
        // Run info.
        XCTAssertTrue(html.contains("Runtime settings"))
        XCTAssertTrue(html.contains("Mozilla/5.0 Test"))
        XCTAssertTrue(html.contains("412×823"))
    }

    func testTextIsEscaped() {
        let html = DeveloperLighthouseHTML.html(report())
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("Alt &lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;img src=&quot;x.png&quot;&gt;"))
        XCTAssertTrue(html.contains("Logo &amp; mark"))
        XCTAssertTrue(html.contains("https://example.com/app.js?a=1&amp;b=2"))
        XCTAssertTrue(html.contains("https://example.com/?q=&lt;x&gt;"))
        XCTAssertFalse(html.contains("?q=<x>"))
        XCTAssertTrue(html.contains("A &quot;warning&quot;"))
        XCTAssertTrue(html.contains("<code>&lt;html&gt;</code>"))
    }

    func testInlineMarkdown() {
        XCTAssertEqual(DeveloperLighthouseHTML.inline("Use `<b>` & [learn more](https://web.dev/x?a=1&b=2)."),
                       "Use <code>&lt;b&gt;</code> &amp; <a href=\"https://web.dev/x?a=1&amp;b=2\">learn more</a>.")
        XCTAssertEqual(DeveloperLighthouseHTML.inline("[bad](javascript:alert(1))"), "bad)")
        XCTAssertEqual(DeveloperLighthouseHTML.escape("'\"<>&"), "&#39;&quot;&lt;&gt;&amp;")
    }
}
