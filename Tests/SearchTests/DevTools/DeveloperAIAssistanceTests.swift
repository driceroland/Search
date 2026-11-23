import XCTest
@testable import Search

/// AI assistance's context and prompt: what the on-device model is told
/// about an element, a request or a Console message, and the trimming that
/// keeps it inside the model's context window. No model needed.
final class DeveloperAIAssistanceTests: XCTestCase {
    typealias AIText = DeveloperAIContextText
    typealias Detail = DeveloperToolsSession.Detail
    typealias StyleRule = DeveloperToolsSession.StyleRule

    // MARK: Trimming

    func testTrimLeavesShortTextAlone() {
        XCTAssertEqual(AIText.trim("hello", to: 10), "hello")
        XCTAssertEqual(AIText.trim("0123456789", to: 10), "0123456789")
    }

    func testTrimCutsToTheLimitAndSaysSo() {
        let long = String(repeating: "a", count: 1_000)
        let trimmed = AIText.trim(long, to: 100)
        XCTAssertLessThanOrEqual(trimmed.count, 100)
        XCTAssertTrue(trimmed.hasPrefix("aaaa"))
        XCTAssertTrue(trimmed.hasSuffix("(trimmed 900 characters)"))
    }

    func testOneLineCollapsesWhitespaceAndEllipsizes() {
        XCTAssertEqual(AIText.oneLine("  a\n\tb   c ", limit: 20), "a b c")
        XCTAssertEqual(AIText.oneLine("abcdefghij", limit: 5), "abcd…")
    }

    func testLinesKeepsWholeLinesAndCountsTheRest() {
        let text = AIText.lines(["aaaa", "bbbb", "cccc"], within: 9)
        XCTAssertEqual(text, "aaaa\nbbbb\n… (1 more not shown)")
        XCTAssertEqual(AIText.lines(["a", "b"], within: 100), "a\nb")
    }

    // MARK: Element

    func testElementLabelNamesTagIDAndClasses() {
        XCTAssertEqual(AIText.elementLabel(name: "DIV", attributes: ["class", "card  wide", "id", "main", "data-x", "1"]),
                       "div#main.card.wide")
        XCTAssertEqual(AIText.elementLabel(name: "SPAN", attributes: []), "span")
        XCTAssertEqual(AIText.elementLabel(name: "p", attributes: ["class", "a b c d e"]), "p.a.b.c")
    }

    func testOuterHTMLIsCompactedAndTrimmed() {
        let html = "<div>\n      <p>hi</p>\n    </div>\n"
        XCTAssertEqual(AIText.outerHTML(html), "<div>\n<p>hi</p>\n</div>")
        let huge = "<div>" + String(repeating: "<span>x</span>", count: 500) + "</div>"
        let trimmed = AIText.outerHTML(huge)
        XCTAssertLessThanOrEqual(trimmed.count, AIText.outerHTMLBudget)
        XCTAssertTrue(trimmed.hasPrefix("<div><span>"), "the opening tag comes first")
    }

    func testComputedKeepsLayoutPropertiesInOrder() {
        let styles = [Detail(name: "color", value: "red"), Detail(name: "-webkit-locale", value: "auto"),
                      Detail(name: "display", value: "none"), Detail(name: "width", value: "10px")]
        XCTAssertEqual(AIText.computed(styles), "display: none;\nwidth: 10px;\ncolor: red;")
    }

    func testRulesLeaveOutDeclarationsThatDontApply() {
        var overridden = Detail(name: "color", value: "blue")
        overridden.overridden = true
        var disabled = Detail(name: "margin", value: "0")
        disabled.enabled = false
        var important = Detail(name: "display", value: "flex")
        important.important = true
        let rules = [
            StyleRule(id: 0, selector: "", origin: "", properties: [Detail(name: "color", value: "red")]),
            StyleRule(id: 1, selector: ".card", origin: "site.css:4", properties: [overridden, disabled, important],
                      groupings: ["@media (min-width: 600px)"]),
            StyleRule(id: 2, selector: ".empty", origin: "site.css:9", properties: [overridden]),
        ]
        let text = AIText.rules(rules)
        XCTAssertTrue(text.contains("element.style {\n  color: red;\n}"))
        XCTAssertTrue(text.contains("@media (min-width: 600px) .card { /* site.css:4 */\n  display: flex !important;\n}"))
        XCTAssertFalse(text.contains("blue"))
        XCTAssertFalse(text.contains("margin"))
        XCTAssertFalse(text.contains(".empty"), "a rule with nothing that applies is left out")
    }

    func testElementContextHasEverySectionWithinBudget() {
        let manyRules = (1...200).map { index in
            StyleRule(id: index, selector: ".rule-\(index)", origin: "site.css", properties: [Detail(name: "color", value: "red")])
        }
        let text = AIText.element(label: "div#main", outerHTML: "<div id=\"main\">" + String(repeating: "x", count: 5_000) + "</div>",
                                computed: [Detail(name: "display", value: "block")], rules: manyRules)
        XCTAssertLessThanOrEqual(text.count, AIText.contextBudget)
        XCTAssertTrue(text.hasPrefix("The selected element: div#main"))
        XCTAssertTrue(text.contains("Its outer HTML:\n```html\n<div id=\"main\">"))
        XCTAssertTrue(text.contains("Its computed style:\n```css\ndisplay: block;"))
        XCTAssertTrue(text.contains(".rule-1 {"))
        XCTAssertTrue(text.contains("more not shown"))
    }

    func testElementContextWithoutStylesSkipsTheirSections() {
        let text = AIText.element(label: "p", outerHTML: "<p>hi</p>", computed: [], rules: [])
        XCTAssertFalse(text.contains("computed style"))
        XCTAssertFalse(text.contains("CSS rules"))
    }

    // MARK: Network

    private func request(status: Int? = 404) -> DeveloperToolsSession.Request {
        var request = DeveloperToolsSession.Request(id: "1", url: "https://example.test/api/items?page=2", method: "POST",
                                                    type: "Fetch", loader: nil, started: 1.0)
        request.sent = 1.01
        request.received = 1.21
        request.ended = 1.25
        request.status = status
        request.statusText = "Not Found"
        request.mimeType = "application/json"
        return request
    }

    private let details = DeveloperRequestDetails([
        "url": "https://example.test/api/items?page=2",
        "method": "POST",
        "requestHeaders": [["Cookie", "session=secret"], ["Accept", "application/json"], ["Authorization", "Bearer token"]],
        "response": [
            "status": 404, "statusText": "Not Found", "mimeType": "application/json",
            "headers": [["Set-Cookie", "id=secret"], ["Content-Type", "application/json"]],
        ] as [String: Any],
        "metrics": ["remoteAddress": "192.0.2.1:443", "protocol": "h2"],
    ])

    func testHeadersRedactCredentials() {
        let text = AIText.headers(details.requestHeaders)
        XCTAssertEqual(text, "Cookie: <redacted>\nAccept: application/json\nAuthorization: <redacted>")
        XCTAssertFalse(AIText.headers(details.responseHeaders).contains("secret"))
    }

    func testTimingSplitsWaitingFromDownload() {
        XCTAssertEqual(AIText.timing(request()),
                       "Queueing and connection: 10 ms\nWaiting for server response: 200 ms\nContent download: 40 ms\nTotal: 250 ms")
        let pending = DeveloperToolsSession.Request(id: "2", url: "https://example.test/", method: "GET", type: "Document",
                                                    loader: nil, started: 1)
        XCTAssertEqual(AIText.timing(pending), "")
    }

    func testRequestContextHasStatusHeadersAndTiming() {
        let text = AIText.request(request(), details: details)
        XCTAssertTrue(text.hasPrefix("The selected network request:\nRequest URL: https://example.test/api/items?page=2"))
        XCTAssertTrue(text.contains("Request method: POST"))
        XCTAssertTrue(text.contains("Status code: 404 Not Found"))
        XCTAssertTrue(text.contains("Remote address: 192.0.2.1:443"))
        XCTAssertTrue(text.contains("Protocol: h2"))
        XCTAssertTrue(text.contains("Request headers:\nCookie: <redacted>"))
        XCTAssertTrue(text.contains("Response headers:\nSet-Cookie: <redacted>\nContent-Type: application/json"))
        XCTAssertTrue(text.contains("Timing:\nQueueing and connection: 10 ms"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("Bearer"))
    }

    func testRequestContextSaysWhenItFailedOrIsPending() {
        var failed = request(status: nil)
        failed.failure = "The network connection was lost."
        XCTAssertTrue(AIText.request(failed, details: nil).contains("Status: failed (The network connection was lost.)"))
        XCTAssertTrue(AIText.request(request(status: nil), details: nil).contains("Status: pending"))
    }

    func testRequestContextStaysWithinBudget() {
        let headers = (1...400).map { ["X-Header-\($0)", String(repeating: "v", count: 150)] }
        let big = DeveloperRequestDetails(["url": "https://example.test/", "requestHeaders": headers,
                                           "response": ["status": 200, "headers": headers] as [String: Any]])
        let text = AIText.request(request(status: 200), details: big)
        XCTAssertLessThanOrEqual(text.count, AIText.contextBudget)
        XCTAssertTrue(text.contains("more not shown"))
    }

    // MARK: Console

    func testConsoleContextHasTextLocationAndStack() {
        let frames = (0..<15).map { ConsoleCallFrame(functionName: $0 == 0 ? "" : "f\($0)", url: "https://example.test/app.js",
                                                     lineNumber: 10 + $0, columnNumber: 5) }
        let line = DeveloperToolsSession.ConsoleLine(level: "error", text: "TypeError: x is undefined",
                                                     url: "https://example.test/app.js", line: 10,
                                                     details: ConsoleMessageDetails(type: "log", stackTrace: frames))
        let text = AIText.console(line)
        XCTAssertTrue(text.hasPrefix("The Console error:\nTypeError: x is undefined"))
        XCTAssertTrue(text.contains("Logged from: https://example.test/app.js:10"))
        XCTAssertTrue(text.contains("Stack trace:\n(anonymous) @ https://example.test/app.js:10:5\nf1 @ https://example.test/app.js:11:5"))
        XCTAssertTrue(text.contains("f9 @"))
        XCTAssertFalse(text.contains("f10 @"), "only the first \(AIText.stackFrames) frames")
    }

    func testConsoleContextTrimsAHugeMessage() {
        let line = DeveloperToolsSession.ConsoleLine(level: "warning", text: String(repeating: "w", count: 20_000))
        let text = AIText.console(line)
        XCTAssertTrue(text.hasPrefix("The Console warning:"))
        XCTAssertLessThanOrEqual(text.count, AIText.contextBudget)
    }

    // MARK: Prompt

    func testPromptCarriesContextThenQuestion() {
        XCTAssertEqual(AIText.prompt(question: "  Why? \n", context: "ctx"), "# Context\n\nctx\n\n# Question\n\nWhy?")
        XCTAssertEqual(AIText.prompt(question: "Why?", context: nil), "Why?")
        XCTAssertEqual(AIText.prompt(question: "Why?", context: ""), "Why?")
    }

    func testPromptStaysWithinTheWindow() {
        let prompt = AIText.prompt(question: String(repeating: "q", count: 10_000), context: String(repeating: "c", count: 10_000))
        XCTAssertLessThanOrEqual(prompt.count, AIText.contextBudget + AIText.questionBudget + 40)
    }

    func testALongChatStartsAFreshSession() {
        XCTAssertFalse(AIText.needsFreshSession(spent: 0, next: 1_000))
        // A full context and question always fit a fresh session.
        XCTAssertFalse(AIText.needsFreshSession(spent: 0, next: AIText.contextBudget + AIText.questionBudget + 40))
        XCTAssertTrue(AIText.needsFreshSession(spent: 7_000, next: 2_000))
    }

    func testInstructionsSayTheModelOnlyReads() {
        XCTAssertTrue(AIText.instructions.contains("cannot run JavaScript"))
    }

    // MARK: Subject

    func testSubjectsWordTheirPromptsAsChromeDoes() {
        let element = DeveloperAISubject.element(node: 4, label: "div#main")
        let request = DeveloperAISubject.request(id: "7", label: "items")
        let error = DeveloperAISubject.console(.init(level: "error", text: "Uncaught   ReferenceError:\nfoo"))
        let warning = DeveloperAISubject.console(.init(level: "warning", text: "Deprecated"))
        XCTAssertEqual(element.placeholder, "Ask a question about the selected element")
        XCTAssertEqual(request.placeholder, "Ask a question about the selected network request")
        XCTAssertEqual(element.label, "div#main")
        XCTAssertEqual(error.label, "Uncaught ReferenceError: foo")
        XCTAssertEqual(error.examplePrompts.first, "Explain this error")
        XCTAssertEqual(warning.examplePrompts.first, "Explain this warning")
        XCTAssertTrue(request.examplePrompts.contains("Why is this network request taking so long?"))
    }

    func testSameSubjectComparesWhatItIsAbout() {
        XCTAssertTrue(DeveloperAISubject.element(node: 1, label: "a").same(as: .element(node: 1, label: "b")))
        XCTAssertFalse(DeveloperAISubject.element(node: 1, label: "a").same(as: .element(node: 2, label: "a")))
        XCTAssertFalse(DeveloperAISubject.request(id: "1", label: "a").same(as: nil))
        let line = DeveloperToolsSession.ConsoleLine(level: "error", text: "x")
        XCTAssertTrue(DeveloperAISubject.console(line).same(as: .console(line)))
        XCTAssertFalse(DeveloperAISubject.console(line).same(as: .console(.init(level: "error", text: "x"))))
    }

    @MainActor
    func testTurnedOffSaysWhereToTurnItOn() {
        XCTAssertEqual(DeveloperAIAvailability.current(enabled: false), .turnedOff)
        XCTAssertEqual(DeveloperAIAvailability.turnedOff.message,
                       "AI assistance is turned off. You can turn it on in Settings › Preferences.")
        XCTAssertNil(DeveloperAIAvailability.available.message)
    }
}
