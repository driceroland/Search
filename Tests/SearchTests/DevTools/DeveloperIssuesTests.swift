import XCTest
@testable import Search

/// The Issues tool's pure logic: console messages classified into CSP,
/// mixed content, CORS and deprecation issues; Set-Cookie analysis; the
/// form rules on a page snapshot; low-contrast issues from the CSS
/// overview; and the dedup, grouping and counting the pane shows.
final class DeveloperIssuesTests: XCTestCase {
    private typealias Rules = DeveloperIssueRules

    private func message(_ text: String, level: String = "error", url: String? = nil, line: Int? = nil) -> DeveloperIssueMessage {
        DeveloperIssueMessage(level: level, text: text, source: "security", url: url, line: line)
    }

    // MARK: Content Security Policy

    func testBlockedResourceIsAURLViolationWithDirectiveRequestAndSource() throws {
        let issues = Rules.classify([message(
            "Refused to load https://evil.example/x.js because it does not appear in the script-src directive of the Content Security Policy.",
            url: "https://site.example/page", line: 3)])
        let issue = try XCTUnwrap(issues.first)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issue.code, .cspURL)
        XCTAssertEqual(issue.kind, .pageError)
        XCTAssertEqual(issue.code.category, .contentSecurityPolicy)
        let directive = try XCTUnwrap(issue.resources.first { $0.kind == .directive })
        XCTAssertEqual(directive.label, "script-src")
        XCTAssertEqual(directive.detail, "blocked: https://evil.example/x.js")
        XCTAssertEqual(issue.resources.first { $0.kind == .request }?.url, "https://evil.example/x.js")
        let source = try XCTUnwrap(issue.resources.first { $0.kind == .source })
        XCTAssertEqual(source.label, "page:3")
        XCTAssertEqual(source.url, "https://site.example/page")
        XCTAssertEqual(source.line, 3)
    }

    func testQuotedURLsInlineAndEvalViolations() {
        let quoted = Rules.csp(message("Refused to connect to 'wss://live.example/socket' because it does not appear in the connect-src directive of the Content Security Policy."))
        XCTAssertEqual(quoted?.code, .cspURL)
        XCTAssertEqual(quoted?.resources.first { $0.kind == .request }?.url, "wss://live.example/socket")
        XCTAssertEqual(quoted?.resources.first?.label, "connect-src")

        let inline = Rules.csp(message("Refused to execute a script because its hash, its nonce, or 'unsafe-inline' does not appear in the script-src directive of the Content Security Policy."))
        XCTAssertEqual(inline?.code, .cspInline)
        XCTAssertEqual(inline?.code.title, "Content Security Policy blocks inline execution of scripts and stylesheets")
        XCTAssertNil(inline?.resources.first { $0.kind == .request })

        let style = Rules.csp(message("Refused to apply a stylesheet because its hash, its nonce, or 'unsafe-inline' does not appear in the style-src directive of the Content Security Policy."))
        XCTAssertEqual(style?.code, .cspInline)
        XCTAssertEqual(style?.resources.first?.label, "style-src")

        let eval = Rules.csp(message("Refused to evaluate a string as JavaScript because 'unsafe-eval' does not appear in the script-src directive of the Content Security Policy."))
        XCTAssertEqual(eval?.code, .cspEval)
    }

    func testReportOnlyViolationsAreImprovements() {
        let issue = Rules.csp(message("[Report Only] Refused to load the image 'http://cdn.example/a.png' because it does not appear in the img-src directive of the Content Security Policy.",
                                      level: "warning"))
        XCTAssertEqual(issue?.code, .cspURL)
        XCTAssertEqual(issue?.kind, .improvement)
        XCTAssertEqual(issue?.resources.first?.detail, "report-only: http://cdn.example/a.png")
        XCTAssertEqual(issue?.resources.first { $0.kind == .request }?.url, "http://cdn.example/a.png")
    }

    func testOtherMessagesAreNotCSP() {
        XCTAssertNil(Rules.csp(message("Refused to display 'https://a.example/' in a frame because it set 'X-Frame-Options' to 'deny'.")))
        XCTAssertNil(Rules.csp(message("TypeError: undefined is not an object")))
    }

    // MARK: Mixed content

    func testWebKitMixedContentMessages() {
        let blocked = Rules.mixedContent(message("[blocked] The page at https://a.example/ was not allowed to display insecure content from http://b.example/i.png."))
        XCTAssertEqual(blocked?.code, .mixedContent)
        XCTAssertEqual(blocked?.resources.first?.url, "http://b.example/i.png")
        XCTAssertEqual(blocked?.resources.first?.detail, "Blocked")

        let upgraded = Rules.mixedContent(message("The page at https://a.example/ requested insecure content from http://b.example/i.png. This content was automatically upgraded and should be served over HTTPS.",
                                                  level: "warning"))
        XCTAssertEqual(upgraded?.resources.first?.url, "http://b.example/i.png")
        XCTAssertEqual(upgraded?.resources.first?.detail, "Automatically upgraded")

        let warned = Rules.mixedContent(message("The page at https://a.example/ was allowed to display insecure content from http://b.example/v.mp4.",
                                                level: "warning"))
        XCTAssertEqual(warned?.resources.first?.detail, "Warned")
        XCTAssertEqual(warned?.resources.first?.url, "http://b.example/v.mp4")

        let chrome = Rules.mixedContent(message("Mixed Content: The page at 'https://a.example/' was loaded over HTTPS, but requested an insecure script 'http://b.example/s.js'. This request has been blocked; the content must be served over HTTPS."))
        XCTAssertEqual(chrome?.resources.first?.url, "http://b.example/s.js")
        XCTAssertEqual(chrome?.resources.first?.detail, "Blocked")
    }

    /// MixedContentChecker's wording in current WebKit (WebCore's format
    /// strings: "[blocked] ", "The page at ", " requested insecure content
    /// from ", ". This content was ", "blocked and must" / "automatically
    /// upgraded and should", " be served over HTTPS.").
    func testCurrentWebKitMixedContentWording() {
        let blocked = Rules.mixedContent(message("[blocked] The page at https://a.example/ requested insecure content from http://b.example/s.js. This content was blocked and must be served over HTTPS."))
        XCTAssertEqual(blocked?.resources.first?.url, "http://b.example/s.js")
        XCTAssertEqual(blocked?.resources.first?.detail, "Blocked")
        let upgraded = Rules.mixedContent(message("The page at https://a.example/ requested insecure content from http://b.example/i.png. This content was automatically upgraded and should be served over HTTPS.",
                                                  level: "warning"))
        XCTAssertEqual(upgraded?.resources.first?.url, "http://b.example/i.png")
        XCTAssertEqual(upgraded?.resources.first?.detail, "Automatically upgraded")
        XCTAssertTrue(Rules.isCandidate(message("[blocked] The page at https://a.example/ requested insecure content from http://b.example/s.js. This content was blocked and must be served over HTTPS.")))
    }

    /// ContentSecurityPolicy's wording when only default-src names the
    /// sources: "… appears in neither the script-src directive nor the
    /// default-src directive of the Content Security Policy."
    func testCSPMessageNamingDefaultSrc() {
        let inline = Rules.csp(message("Refused to execute a script because its hash, its nonce, or 'unsafe-inline' appears in neither the script-src directive nor the default-src directive of the Content Security Policy."))
        XCTAssertEqual(inline?.code, .cspInline)
        XCTAssertEqual(inline?.resources.first?.label, "script-src")
        let eval = Rules.csp(message("Refused to evaluate a string as JavaScript because 'unsafe-eval' or 'trusted-types-eval' is not an allowed source of script in the following Content Security Policy directive: \"script-src 'self'\"."))
        XCTAssertEqual(eval?.code, .cspEval)
        XCTAssertEqual(eval?.resources.first?.label, "script-src")
        let blocked = Rules.csp(message("Refused to load http://evil.example/x.js because it appears in neither the script-src directive nor the default-src directive of the Content Security Policy."))
        XCTAssertEqual(blocked?.code, .cspURL)
        XCTAssertEqual(blocked?.resources.first { $0.kind == .request }?.url, "http://evil.example/x.js")
    }

    func testMixedContentFromRequestsOnlyOnHTTPSPagesAndNotLoopback() {
        let requests: [(id: String, url: String, failed: Bool)] = [
            ("1", "http://b.example/i.png", false), ("2", "http://localhost:8000/x.js", false),
            ("3", "https://c.example/x.js", false), ("4", "http://d.example/s.js", true),
        ]
        let issues = Rules.mixedContent(requests: requests, pageURL: "https://a.example/")
        XCTAssertEqual(issues.map { $0.resources.first?.requestID }, ["1", "4"])
        XCTAssertEqual(issues.map { $0.resources.first?.detail }, ["Warned", "Blocked"])
        XCTAssertEqual(Rules.mixedContent(requests: requests, pageURL: "http://a.example/").count, 0)
        // The Console's message about the same address is the same issue.
        let console = Rules.mixedContent(message("[blocked] The page at https://a.example/ was not allowed to display insecure content from http://b.example/i.png."))
        XCTAssertEqual(console?.key, issues.first?.key)
    }

    // MARK: CORS

    func testCORSReasonAndURLMessagesMakeOneIssue() throws {
        let issues = Rules.classify([
            message("Origin https://a.example is not allowed by Access-Control-Allow-Origin. Status code: 200"),
            message("Fetch API cannot load https://api.example/data due to access control checks.", url: "https://a.example/app.js", line: 12),
        ])
        XCTAssertEqual(issues.count, 1)
        let issue = try XCTUnwrap(issues.first)
        XCTAssertEqual(issue.code, .corsAllowOrigin)
        XCTAssertEqual(issue.code.category, .cors)
        let request = try XCTUnwrap(issue.resources.first { $0.kind == .request })
        XCTAssertEqual(request.url, "https://api.example/data")
        XCTAssertEqual(request.detail, "Origin https://a.example is not allowed by Access-Control-Allow-Origin. Status code: 200")
        XCTAssertEqual(issue.resources.first { $0.kind == .source }?.label, "app.js:12")
    }

    func testCORSReasonsClassify() {
        XCTAssertEqual(Rules.corsReason("Preflight response is not successful. Status code: 403")?.code, .corsPreflight)
        XCTAssertEqual(Rules.corsReason("Request header field X-Token is not allowed by Access-Control-Allow-Headers.")?.code, .corsHeaderNotAllowed)
        XCTAssertEqual(Rules.corsReason("Method PUT is not allowed by Access-Control-Allow-Methods.")?.code, .corsMethodNotAllowed)
        XCTAssertEqual(Rules.corsReason("Credentials flag is true, but Access-Control-Allow-Credentials is not \"true\".")?.code, .corsCredentials)
        XCTAssertEqual(Rules.corsReason("Cross origin requests are only supported for HTTP.")?.code, .corsScheme)
        XCTAssertEqual(Rules.corsReason("Access-Control-Allow-Origin cannot contain more than one origin.")?.code, .corsAllowOrigin)
        XCTAssertNil(Rules.corsReason("Failed to load resource: the server responded with a status of 404"))
        XCTAssertEqual(Rules.corsURL("XMLHttpRequest cannot load https://api.example/x?y=1 due to access control checks."), "https://api.example/x?y=1")
        XCTAssertEqual(Rules.corsURL("Cannot load image https://img.example/a.png due to access control checks."), "https://img.example/a.png")
    }

    func testAURLMessageAloneAndAReasonAloneAreEachAnIssue() {
        let alone = Rules.classify([message("Fetch API cannot load https://api.example/a due to access control checks.")])
        XCTAssertEqual(alone.map(\.code), [.corsAllowOrigin])
        XCTAssertEqual(alone.first?.resources.first?.url, "https://api.example/a")

        let reasonThenOther = Rules.classify([
            message("Preflight response is not successful. Status code: 500"),
            message("'webkitURL' is deprecated. Please use 'URL' instead.", level: "warning"),
        ])
        XCTAssertEqual(reasonThenOther.map(\.code), [.corsPreflight, .deprecation])
        XCTAssertEqual(reasonThenOther.first?.resources.first?.label, "Preflight response is not successful. Status code: 500")
    }

    // MARK: Deprecations

    func testDeprecationWarningsAreBreakingChangesListedApartByMessage() {
        let issues = Rules.classify([
            message("'window.webkitStorageInfo' is deprecated. Please use 'navigator.webkitTemporaryStorage' instead.", level: "warning",
                    url: "https://a.example/old.js", line: 4),
            message("Synchronous XMLHttpRequest on the main thread is deprecated.", level: "warning"),
        ])
        XCTAssertEqual(issues.map(\.code), [.deprecation, .deprecation])
        XCTAssertEqual(issues.first?.kind, .breakingChange)
        XCTAssertEqual(issues.first?.resources.first?.label, "old.js:4")
        let groups = Rules.aggregate(issues, includeThirdParty: false)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.last?.subtitle, "Synchronous XMLHttpRequest on the main thread is deprecated.")
        XCTAssertNil(Rules.deprecation(message("Something deprecated happened", level: "log")))
    }

    func testOrdinaryMessagesAreNoIssues() {
        XCTAssertTrue(Rules.classify([message("hello", level: "log"), message("TypeError: x is not a function")]).isEmpty)
    }

    func testCandidates() {
        XCTAssertTrue(Rules.isCandidate(message("Refused to load https://a/x because it does not appear in the script-src directive of the Content Security Policy.")))
        XCTAssertTrue(Rules.isCandidate(message("'x' is deprecated.", level: "warning")))
        XCTAssertFalse(Rules.isCandidate(DeveloperIssueMessage(level: "log", text: "the Content Security Policy is fine")))
        XCTAssertFalse(Rules.isCandidate(message("TypeError: x is not a function")))
    }

    // MARK: Cookies

    func testSameSiteNoneWithoutSecure() {
        let issues = Rules.cookies(setCookie: "a=1; Path=/; SameSite=None", responseURL: "https://shop.example/api",
                                   pageURL: "https://shop.example/", requestID: "r1")
        XCTAssertEqual(issues.map(\.code), [.cookieSameSiteNoneInsecure])
        XCTAssertEqual(issues.first?.thirdParty, false)
        let cookie = issues.first?.resources.first { $0.kind == .cookie }
        XCTAssertEqual(cookie?.label, "a")
        XCTAssertEqual(cookie?.detail, "shop.example/")
        XCTAssertEqual(cookie?.requestID, "r1")
        XCTAssertTrue(Rules.cookies(setCookie: "b=1; SameSite=None; Secure", responseURL: "https://shop.example/api",
                                    pageURL: "https://shop.example/", requestID: nil).isEmpty)
    }

    func testOversizedCookiesAndAttributes() {
        let big = Rules.cookies(setCookie: "c=" + String(repeating: "x", count: 4_100), responseURL: "https://a.example/",
                                pageURL: "https://a.example/", requestID: nil)
        XCTAssertEqual(big.map(\.code), [.cookieTooLarge])
        XCTAssertEqual(big.first?.kind, .pageError)
        let attribute = Rules.cookies(setCookie: "d=1; Path=/" + String(repeating: "p", count: 1_100), responseURL: "https://a.example/",
                                      pageURL: "https://a.example/", requestID: nil)
        XCTAssertEqual(attribute.map(\.code), [.cookieAttributeTooLarge])
    }

    func testDomainMustMatchTheHost() {
        let invalid = Rules.cookies(setCookie: "d=1; Domain=other.example", responseURL: "https://shop.example/",
                                    pageURL: "https://shop.example/", requestID: nil)
        XCTAssertEqual(invalid.map(\.code), [.cookieInvalidDomain])
        XCTAssertTrue(Rules.cookies(setCookie: "e=1; Domain=.example.com", responseURL: "https://www.example.com/",
                                    pageURL: "https://www.example.com/", requestID: nil).isEmpty)
        XCTAssertTrue(Rules.domainMatches(host: "www.example.com", domain: "example.com"))
        XCTAssertTrue(Rules.domainMatches(host: "example.com", domain: ".EXAMPLE.com"))
        XCTAssertFalse(Rules.domainMatches(host: "example.com", domain: "www.example.com"))
        XCTAssertFalse(Rules.domainMatches(host: "badexample.com", domain: "example.com"))
        XCTAssertFalse(Rules.domainMatches(host: "example.com", domain: "com"))
        XCTAssertTrue(Rules.domainMatches(host: "127.0.0.1", domain: "127.0.0.1"))
        XCTAssertFalse(Rules.domainMatches(host: "10.0.0.1", domain: "0.0.1"))
    }

    func testThirdPartyCookiesAreBlockedAndMarked() {
        let issues = Rules.cookies(setCookie: "t=1; SameSite=None; Secure", responseURL: "https://tracker.example/pixel",
                                   pageURL: "https://news.example/", requestID: "r9")
        XCTAssertEqual(issues.map(\.code), [.cookieThirdPartyBlocked])
        XCTAssertEqual(issues.first?.thirdParty, true)
        // Same site, other subdomain: first party.
        XCTAssertTrue(Rules.cookies(setCookie: "s=1", responseURL: "https://api.news.example/x", pageURL: "https://www.news.example/",
                                    requestID: nil).isEmpty)
    }

    func testEachSetCookieLineIsJudged() {
        let issues = Rules.cookies(setCookie: "a=1; SameSite=None\nb=2\nc=3; SameSite=None", responseURL: "https://a.example/",
                                   pageURL: "https://a.example/", requestID: "r")
        XCTAssertEqual(issues.map { $0.resources.first?.label }, ["a", "c"])
    }

    func testSites() {
        XCTAssertEqual(Rules.site(of: "a.b.example.com"), "example.com")
        XCTAssertEqual(Rules.site(of: "x.github.io"), "x.github.io")
        XCTAssertEqual(Rules.site(of: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Rules.site(of: "localhost"), "localhost")
        XCTAssertEqual(Rules.site(of: "192.168.1.2"), "192.168.1.2")
    }

    // MARK: Forms

    private var snapshot: DeveloperFormSnapshot {
        typealias Field = DeveloperFormSnapshot.Field
        typealias Label = DeveloperFormSnapshot.Label
        return DeveloperFormSnapshot(
            fields: [
                Field(index: 0, tag: "input", type: "text", id: "email", labels: 1, form: 0, label: "input#email"),
                Field(index: 1, tag: "input", type: "password", name: "pw", form: 0, label: "input[type=password]"),
                Field(index: 2, tag: "input", type: "text", autocomplete: "off", labels: 1, form: 0, label: "input"),
                Field(index: 3, tag: "input", type: "text", id: "dup", name: "a", autocomplete: "off", labels: 1, form: 0, label: "input#dup"),
                Field(index: 4, tag: "input", type: "text", id: "dup", name: "b", autocomplete: "off", labels: 1, form: 0, label: "input#dup"),
                Field(index: 5, tag: "input", type: "text", id: "dup", name: "c", autocomplete: "off", labels: 1, form: 1, label: "input#dup"),
                Field(index: 6, tag: "input", type: "submit", form: 0, label: "input[type=submit]"),
                Field(index: 7, tag: "input", type: "text", id: "x", name: "y", autocomplete: "", labels: 1, form: 0, label: "input#x"),
                Field(index: 8, tag: "select", id: "s", name: "s", ariaLabelledBy: "missing", form: 0, label: "select#s"),
            ],
            labels: [
                Label(index: 9, forID: "nothere"),
                Label(index: 10, forID: "pw"),
                Label(index: 11, forID: nil, hasField: false),
                Label(index: 12, forID: nil, hasField: true),
                Label(index: 13, forID: "email"),
            ],
            ids: ["email", "dup", "x", "s"],
            quirks: true)
    }

    func testFormRules() {
        let issues = Rules.forms(snapshot, scan: "scan1")
        func indexes(_ code: DeveloperIssueCode) -> [[Int]] {
            issues.filter { $0.code == code }.map { $0.resources.compactMap { $0.element?.index } }
        }
        XCTAssertEqual(indexes(.formDuplicateId), [[3, 4]])
        XCTAssertEqual(indexes(.formEmptyIdAndName), [[2]])
        XCTAssertEqual(indexes(.formInputWithNoLabel), [[1], [8]])
        XCTAssertEqual(indexes(.formAutocompleteMissing), [[0], [1]])
        XCTAssertEqual(indexes(.formAutocompleteEmpty), [[7]])
        XCTAssertEqual(indexes(.formAriaLabelledByNonExistingId), [[8]])
        XCTAssertEqual(indexes(.formLabelForNonExistingId), [[9]])
        XCTAssertEqual(indexes(.formLabelForName), [[10]])
        XCTAssertEqual(indexes(.formLabelHasNoField), [[11]])
        XCTAssertEqual(issues.filter { $0.code == .quirksMode }.count, 1)
        XCTAssertFalse(issues.contains { $0.resources.contains { $0.element?.index == 6 } }, "a submit button needs no label")
        XCTAssertEqual(issues.first { $0.code == .formAutocompleteMissing }?.resources.first?.detail, "id=email")
        XCTAssertEqual(issues.first { $0.code == .formDuplicateId }?.kind, .pageError)
        XCTAssertEqual(issues.first { $0.code == .formEmptyIdAndName }?.kind, .improvement)
        XCTAssertTrue(issues.allSatisfy { $0.code.category == .generic || $0.code == .quirksMode })
        XCTAssertEqual(issues.first { $0.code == .formDuplicateId }?.resources.first?.element?.scan, "scan1")
    }

    func testSnapshotReadsThePageScan() {
        let raw: [String: Any] = [
            "fields": [["i": 0, "tag": "INPUT", "type": "Email", "id": "e", "name": "", "autocomplete": NSNull(), "labels": 0,
                        "ariaLabel": "", "ariaLabelledBy": "", "title": "", "form": 2, "label": "input#e"]],
            "labels": [["i": 1, "for": NSNull(), "hasField": true, "label": "label"]],
            "ids": ["e"], "quirks": false,
        ]
        let snapshot = DeveloperFormSnapshot(raw: raw)
        XCTAssertEqual(snapshot.fields.first?.tag, "input")
        XCTAssertEqual(snapshot.fields.first?.type, "email")
        XCTAssertNil(snapshot.fields.first?.autocomplete)
        XCTAssertEqual(snapshot.fields.first?.form, 2)
        XCTAssertNil(snapshot.labels.first?.forID)
        XCTAssertEqual(snapshot.labels.first?.hasField, true)
        XCTAssertEqual(snapshot.ids, ["e"])
        XCTAssertEqual(Rules.forms(snapshot, scan: "s").map(\.code), [.formInputWithNoLabel, .formAutocompleteMissing])
    }

    // MARK: Contrast

    func testContrastProblemsAreOneIssuePerElement() {
        let problem = DeveloperCSSOverview.ContrastIssue(text: DeveloperCSSColor(red: 170, green: 170, blue: 170), background: .white,
                                                         ratio: 2.5, threshold: 4.5, elements: [3, 5])
        let issues = Rules.contrast([problem], label: { "p\($0)" }, scan: "c1")
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.first?.code, .lowTextContrast)
        XCTAssertEqual(issues.first?.kind, .improvement)
        XCTAssertEqual(issues.first?.resources.first?.label, "p3")
        XCTAssertEqual(issues.first?.resources.first?.element, DeveloperIssueElement(scan: "c1", index: 3))
        XCTAssertTrue(issues.first?.resources.first?.detail?.hasPrefix("Contrast ratio 2.50, minimum AA ratio 4.5") ?? false)
    }

    // MARK: Grouping

    func testRepeatsAreDroppedAndIssuesOfATypeGathered() {
        let a = "Refused to load https://a.example/1.js because it does not appear in the script-src directive of the Content Security Policy."
        let b = "Refused to load https://a.example/2.js because it does not appear in the script-src directive of the Content Security Policy."
        let issues = Rules.classify([message(a), message(a), message(b)])
        XCTAssertEqual(issues.count, 3)
        let groups = Rules.aggregate(issues, includeThirdParty: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.resources(.request).map(\.url), ["https://a.example/1.js", "https://a.example/2.js"])
        XCTAssertEqual(groups.first?.resources(.directive).count, 2)
        XCTAssertEqual(groups.first?.title, DeveloperIssueCode.cspURL.title)
    }

    func testThirdPartyCookieIssuesAreHiddenUnlessIncluded() {
        let third = Rules.cookies(setCookie: "t=1", responseURL: "https://tracker.example/p", pageURL: "https://news.example/", requestID: "r")
        let first = Rules.cookies(setCookie: "a=1; SameSite=None", responseURL: "https://news.example/", pageURL: "https://news.example/", requestID: "s")
        let all = third + first
        XCTAssertEqual(Rules.aggregate(all, includeThirdParty: false).map(\.code), [.cookieSameSiteNoneInsecure])
        XCTAssertEqual(Rules.hiddenCount(all, includeThirdParty: false), 1)
        XCTAssertEqual(Rules.aggregate(all, includeThirdParty: true).map(\.code), [.cookieThirdPartyBlocked, .cookieSameSiteNoneInsecure])
        XCTAssertEqual(Rules.hiddenCount(all, includeThirdParty: true), 0)
    }

    private var mixedGroups: [DeveloperIssueGroup] {
        let issues = [
            DeveloperIssue(code: .cspInline, key: "1", resources: []),
            DeveloperIssue(code: .deprecation, key: "2", subtitle: "x is deprecated", resources: []),
            DeveloperIssue(code: .quirksMode, key: "3", resources: []),
            DeveloperIssue(code: .cookieInvalidDomain, key: "4", resources: []),
            DeveloperIssue(code: .cookieInvalidDomain, key: "5", resources: []),
        ]
        return Rules.aggregate(issues, includeThirdParty: false)
    }

    func testCountsByKind() {
        let counts = Rules.counts(mixedGroups)
        XCTAssertEqual(counts[.pageError], 3)
        XCTAssertEqual(counts[.breakingChange], 1)
        XCTAssertEqual(counts[.improvement], 1)
    }

    func testSectionsByKindCategoryBothOrNeither() {
        let groups = mixedGroups
        let byKind = Rules.sections(groups, byKind: true, byCategory: false)
        XCTAssertEqual(byKind.map(\.title), ["Page Errors", "Breaking Changes", "Improvements"])
        XCTAssertEqual(byKind.first?.count, 3)
        XCTAssertEqual(byKind.first?.groups.map(\.code), [.cspInline, .cookieInvalidDomain])

        let byCategory = Rules.sections(groups, byKind: false, byCategory: true)
        XCTAssertEqual(byCategory.map(\.title), ["Cookie", "Content Security Policy", "Quirks Mode", "Other"])

        let both = Rules.sections(groups, byKind: true, byCategory: true)
        XCTAssertEqual(both.first?.children.map(\.title), ["Cookie", "Content Security Policy"])
        XCTAssertEqual(both.first?.count, 3)

        let neither = Rules.sections(groups, byKind: false, byCategory: false)
        XCTAssertEqual(neither.count, 1)
        XCTAssertEqual(neither.first?.groups.map(\.kind), [.pageError, .pageError, .breakingChange, .improvement])
        XCTAssertTrue(Rules.sections([], byKind: false, byCategory: false).isEmpty)
    }

    func testRequestResourcesLinkToTheLatestRequestWithTheirAddress() {
        let issue = DeveloperIssue(code: .corsAllowOrigin, key: "k",
                                   resources: [DeveloperAffectedResource(kind: .request, label: "x", url: "https://x.example/a")])
        let linked = Rules.link([issue], requests: [(id: "1", url: "https://x.example/a"), (id: "2", url: "https://x.example/a"),
                                                    (id: "3", url: "https://x.example/b")])
        XCTAssertEqual(linked.first?.resources.first?.requestID, "2")
    }

    func testEveryCodeHasTextAndALink() {
        for code in DeveloperIssueCode.allCases {
            XCTAssertFalse(code.title.isEmpty, code.rawValue)
            XCTAssertFalse(code.explanation.isEmpty, code.rawValue)
            XCTAssertFalse(code.links.isEmpty, code.rawValue)
            for link in code.links { XCTAssertTrue(link.url.hasPrefix("https://"), link.url) }
        }
    }
}
