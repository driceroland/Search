import XCTest
@testable import Search

/// The Lighthouse panel's later audits (DeveloperLighthouseRulesMore.swift):
/// axe's remaining page checks, the byte-efficiency audits over coverage and
/// the files' text, the connection and redirect audits, CSP, paste,
/// permission requests, source maps and robots.txt.
final class DeveloperLighthouseMoreTests: XCTestCase {
    private typealias Rules = DeveloperLighthouseRules
    private typealias Page = DeveloperLighthousePage

    private func node(_ index: Int) -> DeveloperLighthouseNode {
        DeveloperLighthouseNode(index: index, snippet: "<el \(index)>", selector: "el", label: "el")
    }

    private func page(_ build: (inout Page) -> Void = { _ in }) -> Page {
        var page = Page()
        page.url = "https://example.com/article"
        page.title = "Example"
        page.lang = "en"
        page.viewportWidth = 400
        page.viewportHeight = 800
        build(&page)
        return page
    }

    private func input(_ page: Page, mode: DeveloperLighthouseMode = .navigation,
                       requests: [DeveloperLighthouseRequest] = [],
                       metrics: DeveloperLighthouseMetrics? = nil) -> DeveloperLighthouseInput {
        DeveloperLighthouseInput(mode: mode, formFactor: .mobile, categories: DeveloperLighthouseCategoryID.allCases,
                                 requestedURL: page.url, page: page, requests: requests, metrics: metrics, issues: [])
    }

    // MARK: Catalogue

    func testNewAuditsAreCataloguedWithLighthousesWeights() {
        func weight(_ id: String, _ category: DeveloperLighthouseCategoryID) -> Double? {
            DeveloperLighthouseCatalog.refs(category).first { $0.id == id }?.weight
        }
        XCTAssertEqual(weight("aria-hidden-body", .accessibility), 10)
        XCTAssertEqual(weight("meta-refresh", .accessibility), 10)
        XCTAssertEqual(weight("aria-allowed-attr", .accessibility), 10)
        XCTAssertEqual(weight("bypass", .accessibility), 7)
        XCTAssertEqual(weight("target-size", .accessibility), 7)
        XCTAssertEqual(weight("landmark-one-main", .accessibility), 3)
        XCTAssertEqual(weight("paste-preventing-inputs", .bestPractices), 3)
        XCTAssertEqual(weight("csp-xss", .bestPractices), 0)
        XCTAssertEqual(weight("valid-source-maps", .bestPractices), 0)
        XCTAssertEqual(weight("robots-txt", .seo), 1)
        for id in ["unused-javascript", "unused-css-rules", "unminified-css", "unminified-javascript", "offscreen-images",
                   "redirects", "uses-rel-preconnect", "font-display", "lcp-lazy-loaded"] {
            XCTAssertEqual(weight(id, .performance), 0, id)
        }
        // Every catalogued audit has an implementation.
        let all = input(page())
        for entry in DeveloperLighthouseCatalog.entries {
            XCTAssertNotEqual(Rules.audit(entry.id, all).explanation, "Not implemented in Search.", entry.id)
        }
    }

    // MARK: Accessibility

    func testBypassLandmarkAndHiddenBody() {
        let link = Page.Link(node: node(1), name: "Home", text: "Home", rawHref: "/", href: "https://example.com/")
        let skip = Page.Link(node: node(2), name: "Skip", text: "Skip", rawHref: "#content", href: "https://example.com/article#content")
        XCTAssertEqual(Rules.bypass(page()).mode, .notApplicable)
        XCTAssertEqual(Rules.bypass(page { $0.links = [link] }).score, 0)
        XCTAssertEqual(Rules.bypass(page { $0.links = [link, skip] }).score, 1)
        XCTAssertEqual(Rules.bypass(page { $0.links = [link]; $0.mainLandmarks = 1 }).score, 1)
        XCTAssertEqual(Rules.bypass(page { $0.links = [link]; $0.headings = [.init(node: node(3), level: 1)] }).score, 1)
        XCTAssertEqual(Rules.landmarkOneMain(page()).score, 0)
        XCTAssertEqual(Rules.landmarkOneMain(page { $0.mainLandmarks = 1 }).title, "Document has a main landmark.")
        XCTAssertEqual(Rules.ariaHiddenBody(page()).score, 1)
        let hidden = Rules.ariaHiddenBody(page { $0.bodyAriaHidden = true; $0.bodyNode = node(9) })
        XCTAssertEqual(hidden.score, 0)
        XCTAssertEqual(hidden.details?.items.first?["node"], .node(node(9)))
    }

    func testAriaRolesAndAllowedAttributes() {
        let typo = Page.Aria(node: node(1), tag: "div", role: "buton", attributes: [])
        let abstract = Page.Aria(node: node(2), tag: "div", role: "widget", attributes: [])
        let fallback = Page.Aria(node: node(3), tag: "div", role: "switch checkbox", attributes: ["aria-checked"])
        let fine = Page.Aria(node: node(4), tag: "div", role: "button", attributes: ["aria-pressed"])
        let roles = Rules.ariaRolesAudit(page { $0.aria = [typo, abstract, fallback, fine] })
        XCTAssertEqual(roles.details?.items.map { $0["node"] }, [.node(node(1)), .node(node(2))])
        XCTAssertEqual(Rules.ariaRolesAudit(page()).mode, .notApplicable)

        let checkedLink = Page.Aria(node: node(5), tag: "a", role: nil, attributes: ["aria-checked"], implicitRole: "link")
        let expandedDiv = Page.Aria(node: node(6), tag: "div", role: nil, attributes: ["aria-expanded", "aria-label"],
                                    implicitRole: "generic")
        let expandedButton = Page.Aria(node: node(7), tag: "button", role: nil, attributes: ["aria-expanded"], implicitRole: "button")
        let unknown = Page.Aria(node: node(8), tag: "custom-el", role: nil, attributes: ["aria-checked"])
        let sorted = Page.Aria(node: node(10), tag: "th", role: nil, attributes: ["aria-sort"], implicitRole: "columnheader")
        let allowed = Rules.ariaAllowedAttributes(page { $0.aria = [checkedLink, expandedDiv, expandedButton, unknown, sorted, fine] })
        XCTAssertEqual(allowed.details?.items.map { $0["node"] }, [.node(node(5)), .node(node(6))])
        // Global attributes alone aren't checked.
        let global = Page.Aria(node: node(11), tag: "div", role: nil, attributes: ["aria-label"], implicitRole: "generic")
        XCTAssertEqual(Rules.ariaAllowedAttributes(page { $0.aria = [global] }).mode, .notApplicable)
    }

    func testTargetSize() {
        let big = Page.Target(node: node(1), x: 0, y: 0, width: 44, height: 44)
        let lonely = Page.Target(node: node(2), x: 200, y: 200, width: 16, height: 16)
        let crowdedA = Page.Target(node: node(3), x: 0, y: 100, width: 16, height: 16)
        let crowdedB = Page.Target(node: node(4), x: 18, y: 100, width: 16, height: 16)
        let nearBig = Page.Target(node: node(5), x: 46, y: 10, width: 10, height: 10)
        let failures = Rules.targetSizeFailures([big, lonely, crowdedA, crowdedB, nearBig]).map { $0.target.node }
        XCTAssertEqual(failures, [node(3), node(4), node(5)])
        XCTAssertEqual(Rules.targetSize(page { $0.targets = [big, lonely] }).score, 1)
        XCTAssertEqual(Rules.targetSize(page()).mode, .notApplicable)
        // A small target inside a big one isn't crowded by it.
        let inside = Page.Target(node: node(6), x: 10, y: 10, width: 12, height: 12)
        XCTAssertTrue(Rules.targetSizeFailures([big, inside]).isEmpty)
    }

    func testTablesLanguagesRefreshAndSelects() {
        let good = Page.HeadersCell(node: node(1), headers: ["h1", "h2"], found: ["h1", "h2"])
        let missing = Page.HeadersCell(node: node(2), headers: ["h1", "elsewhere"], found: ["h1"])
        let selfRef = Page.HeadersCell(node: node(3), headers: ["me"], found: ["me"], id: "me")
        XCTAssertEqual(Rules.tdHeadersAttribute(page { $0.headersCells = [good, missing, selfRef] }).details?.items.count, 2)
        XCTAssertEqual(Rules.tdHeadersAttribute(page()).mode, .notApplicable)

        let langs = [Page.Lang(node: node(1), lang: "fr-CA"), Page.Lang(node: node(2), lang: "français"),
                     Page.Lang(node: node(3), lang: "")]
        let valid = Rules.validLang(page { $0.langs = langs })
        XCTAssertEqual(valid.details?.items.map { $0["node"] }, [.node(node(2))])

        XCTAssertEqual(Rules.refreshDelay("5; url=https://example.com/"), 5)
        XCTAssertEqual(Rules.refreshDelay("0"), 0)
        XCTAssertNil(Rules.refreshDelay("url=/x"))
        let timed = Page.MetaRefresh(node: node(1), content: "30")
        let instant = Page.MetaRefresh(node: node(2), content: "0; url=/next")
        let dayLong = Page.MetaRefresh(node: node(3), content: "90000")
        XCTAssertEqual(Rules.metaRefresh(page { $0.metaRefreshes = [timed, instant, dayLong] }).details?.items.count, 1)
        XCTAssertEqual(Rules.metaRefresh(page { $0.metaRefreshes = [instant] }).score, 1)
        XCTAssertEqual(Rules.metaRefresh(page()).mode, .notApplicable)

        XCTAssertEqual(Rules.selectName(page { $0.selects = [.init(node: node(1), name: "")] }).score, 0)
        XCTAssertEqual(Rules.selectName(page { $0.selects = [.init(node: node(1), name: "Country")] }).score, 1)
    }

    // MARK: Byte efficiency

    func testTokenLengthStripsCommentsAndWhitespace() {
        XCTAssertEqual(Rules.tokenLength("a { color : red ; } /* note */", javaScript: false), "a{color:red;}".count)
        XCTAssertEqual(Rules.tokenLength("/*! keep */a{}", javaScript: false), "/*! keep */a{}".count)
        XCTAssertEqual(Rules.tokenLength("content: ' a  b ';", javaScript: false), "content:' a  b ';".count)
        XCTAssertEqual(Rules.tokenLength("var x = 1; // one\nvar y = \"a b\";", javaScript: true), "varx=1;vary=\"a b\";".count)
        // A regular expression keeps its spaces; a division isn't one.
        XCTAssertEqual(Rules.tokenLength("x = / a /g; y = a / b", javaScript: true), "x=/ a /g;y=a/b".count)
        // Unbalanced: the whole length.
        XCTAssertEqual(Rules.tokenLength("var s = 'open", javaScript: true), "var s = 'open".count)
    }

    func testUnminifiedFiles() {
        let pretty = String(repeating: "body {\n    color : red ;\n    margin : 0 ;\n}\n\n", count: 200)
        let tight = String(repeating: "a{b:c}", count: 2_000)
        let run = { (contents: [DeveloperLighthouseContent], requests: [DeveloperLighthouseRequest]) -> DeveloperLighthouseAudit in
            var run = self.input(self.page(), requests: requests)
            run.contents = contents
            return Rules.unminified("unminified-css", kind: .stylesheet, minPercent: 5, run)
        }
        let audit = run([.init(url: "https://example.com/a.css", kind: .stylesheet, text: pretty),
                         .init(url: "https://example.com/b.css", kind: .stylesheet, text: tight)], [])
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertEqual(audit.details?.items.first?["url"], .url("https://example.com/a.css"))
        XCTAssertEqual(audit.title, "Minify CSS")
        // Savings scale with what went over the wire.
        let gzipped = DeveloperLighthouseRequest(url: "https://example.com/a.css", type: "Stylesheet", mimeType: "text/css",
                                                 transferSize: 1_000)
        XCTAssertEqual(run([.init(url: "https://example.com/a.css", kind: .stylesheet, text: pretty)], [gzipped]).score, 1)
        var none = input(page())
        none.contents = nil
        XCTAssertEqual(Rules.unminified("unminified-javascript", kind: .script, minPercent: 10, none).mode, .notApplicable)
    }

    func testUnusedJavaScriptAndCSS() {
        var run = input(page(), requests: [
            DeveloperLighthouseRequest(url: "https://example.com/app.js", type: "Script", mimeType: "text/javascript",
                                       transferSize: 100_000, resourceSize: 300_000),
        ])
        run.scriptCoverage = [
            .init(url: "https://example.com/app.js", kind: .javaScript, total: 300_000, unused: 150_000),
            .init(url: "https://example.com/small.js", kind: .javaScript, total: 10_000, unused: 9_000),
        ]
        let js = Rules.unusedJavaScript(run)
        XCTAssertEqual(js.details?.items.count, 1)
        XCTAssertEqual(js.details?.items.first?["wastedBytes"], .bytes(50_000))
        XCTAssertEqual(js.details?.overallSavingsBytes, 50_000)
        XCTAssertLessThan(js.score ?? 1, 1)
        XCTAssertEqual(Rules.unusedJavaScript(input(page(), mode: .snapshot)).mode, .notApplicable)
        run.scriptCoverage = nil
        XCTAssertEqual(Rules.unusedJavaScript(run).mode, .notApplicable)

        var css = input(page())
        css.styleCoverage = [.init(url: "https://example.com/site.css", kind: .css, total: 40_000, unused: 30_000)]
        XCTAssertEqual(Rules.unusedCSS(css).details?.items.first?["wastedBytes"], .bytes(30_000))
        css.styleCoverage = [.init(url: "https://example.com/site.css", kind: .css, total: 40_000, unused: 2_000)]
        XCTAssertEqual(Rules.unusedCSS(css).score, 1)
    }

    func testOffscreenImages() {
        func image(_ index: Int, _ src: String, top: Double, lazy: Bool = false) -> Page.Image {
            var image = Page.Image(node: node(index), src: src, naturalWidth: 400, naturalHeight: 400, displayedWidth: 400,
                                   displayedHeight: 400, alt: "", role: nil)
            image.documentRect = [top, 0, top + 400, 400]
            image.lazy = lazy
            return image
        }
        let requests = ["above", "below", "lazy"].map {
            DeveloperLighthouseRequest(url: "https://example.com/\($0).jpg", type: "Image", mimeType: "image/jpeg", transferSize: 50_000)
        }
        let images = [image(1, "https://example.com/above.jpg", top: 0), image(2, "https://example.com/below.jpg", top: 6_000),
                      image(3, "https://example.com/lazy.jpg", top: 6_000, lazy: true)]
        let audit = Rules.offscreenImages(input(page { $0.images = images }, requests: requests))
        XCTAssertEqual(audit.details?.items.map { $0["url"] }, [.url("https://example.com/below.jpg")])
        XCTAssertEqual(audit.details?.items.first?["wastedBytes"], .bytes(50_000))
        // Within three viewports below: not offscreen enough.
        XCTAssertEqual(Rules.visiblePixels([1_000, 0, 1_400, 400], width: 400, height: 800), 400 * 400)
        XCTAssertEqual(Rules.offscreenImages(input(page { $0.images = images }, mode: .snapshot)).mode, .notApplicable)
    }

    // MARK: Network

    func testPreconnectAndRedirects() {
        var document = DeveloperLighthouseRequest(url: "https://example.com/article", type: "Document", mimeType: "text/html")
        document.startedAt = 10
        document.endedAt = 10.2
        var cdn = DeveloperLighthouseRequest(url: "https://cdn.other.com/lib.js", type: "Script", mimeType: "text/javascript")
        cdn.startedAt = 10.25
        cdn.connectMs = 180
        var reused = DeveloperLighthouseRequest(url: "https://img.other.com/a.png", type: "Image", mimeType: "image/png")
        reused.startedAt = 10.3
        var late = DeveloperLighthouseRequest(url: "https://late.other.com/b.js", type: "Script", mimeType: "text/javascript")
        late.startedAt = 14
        late.connectMs = 200
        let metrics = DeveloperLighthouseMetrics(fcp: 900, lcp: 2_000, lcpSupported: true)
        let audit = Rules.preconnect(input(page(), requests: [document, cdn, reused, late], metrics: metrics))
        XCTAssertEqual(audit.details?.items.map { $0["url"] }, [.url("https://cdn.other.com")])
        XCTAssertEqual(Rules.number(audit.details?.items.first?["wastedMs"]) ?? 0, 130, accuracy: 1e-6)
        let hinted = Rules.preconnect(input(page { $0.preconnects = ["https://cdn.other.com/"] },
                                            requests: [document, cdn], metrics: metrics))
        XCTAssertEqual(hinted.score, 1)

        XCTAssertEqual(Rules.redirects(input(page(), requests: [document])).score, 1)
        var moved = document
        moved.originalURL = "http://example.com/article"
        var timed = metrics
        timed.redirectMs = 900
        let redirected = Rules.redirects(input(page(), requests: [moved], metrics: timed))
        XCTAssertEqual(redirected.details?.items.count, 2)
        XCTAssertEqual(redirected.details?.items.first?["url"], .url("http://example.com/article"))
        XCTAssertEqual(redirected.score, Scoring.scoreForWastedMs(900))
    }

    private typealias Scoring = DeveloperLighthouseScoring

    func testFontDisplayAndLazyLCP() {
        let font = DeveloperLighthouseRequest(url: "https://example.com/f.woff2", type: "Font", mimeType: "font/woff2",
                                              durationMs: 4_500)
        let swapped = DeveloperLighthouseRequest(url: "https://example.com/g.woff2", type: "Font", mimeType: "font/woff2",
                                                 durationMs: 400)
        let faces = [Page.FontFace(family: "F", display: "", urls: ["https://example.com/f.woff2"]),
                     Page.FontFace(family: "G", display: "swap", urls: ["https://example.com/g.woff2"])]
        let audit = Rules.fontDisplay(input(page { $0.fontFaces = faces }, requests: [font, swapped]))
        XCTAssertEqual(audit.score, 0)
        XCTAssertEqual(audit.details?.items.first?["wastedMs"], .ms(3_000))
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertTrue(Rules.fontDisplayPasses("block"))
        XCTAssertFalse(Rules.fontDisplayPasses("auto"))

        var metrics = DeveloperLighthouseMetrics(fcp: 500, lcp: 1_000, lcpSupported: true)
        metrics.lcpElement = "<img src=\"hero.jpg\" loading=\"lazy\">"
        XCTAssertEqual(Rules.lcpLazyLoaded(input(page(), metrics: metrics)).mode, .notApplicable)
        metrics.lcpImage = true
        metrics.lcpLazy = true
        XCTAssertEqual(Rules.lcpLazyLoaded(input(page(), metrics: metrics)).score, 0)
        metrics.lcpLazy = false
        XCTAssertEqual(Rules.lcpLazyLoaded(input(page(), metrics: metrics)).score, 1)
    }

    // MARK: Best practices

    func testPasteAndPermissionsOnStart() {
        XCTAssertEqual(Rules.pastePreventing(page()).score, 1)
        XCTAssertEqual(Rules.pastePreventing(page { $0.pasteBlocked = [node(1)] }).details?.items.count, 1)

        let early = Page.PermissionCall(api: .geolocation, url: "https://example.com/app.js", line: 3, column: 9)
        let clicked = Page.PermissionCall(api: .notification, url: "https://example.com/app.js", line: 8, column: 1, gesture: true)
        let watched = page { $0.permissionCalls = [early, clicked] }
        let geolocation = Rules.permissionOnStart("geolocation-on-start", api: .geolocation, input(watched))
        XCTAssertEqual(geolocation.score, 0)
        XCTAssertEqual(geolocation.details?.items.first?["source"], .code("https://example.com/app.js:3:9"))
        XCTAssertEqual(Rules.permissionOnStart("notification-on-start", api: .notification, input(watched)).score, 1)
        XCTAssertEqual(Rules.permissionOnStart("geolocation-on-start", api: .geolocation, input(page())).mode, .notApplicable)
    }

    func testCSPFindings() {
        var none = input(page())
        XCTAssertEqual(Rules.cspXSS(none).details?.items.first?["description"], .text("No CSP found in enforcement mode"))
        XCTAssertEqual(Rules.cspXSS(none).mode, .informative)

        let weak = Rules.cspFindings("script-src 'self' 'unsafe-inline' https://cdn.example.com")
        XCTAssertTrue(weak.contains { $0.description.hasPrefix("`'unsafe-inline'`") && $0.severity == .high })
        XCTAssertTrue(weak.contains { $0.description.hasPrefix("Host allowlists") })
        XCTAssertTrue(weak.contains { $0.directive == "object-src" })
        let strict = Rules.cspFindings("script-src 'nonce-abc123' 'strict-dynamic' https: 'unsafe-inline'; object-src 'none'; base-uri 'none'; report-uri /csp")
        XCTAssertTrue(strict.isEmpty, "\(strict)")
        XCTAssertTrue(Rules.cspFindings("script-src 'nonce-abc'; object-src 'none'; scirpt-src x")
            .contains { $0.severity == .syntax && $0.directive == "scirpt-src" })
        XCTAssertTrue(Rules.cspFindings("script-src 'nonce-abc' 'strict-dynamic'; object-src 'none'")
            .contains { $0.directive == "base-uri" })

        // A strict policy alongside a weak one: no bypass is reported.
        none.page.metaCSPs = ["default-src *"]
        let audit = Rules.cspXSS(input(page { $0.metaCSPs = ["script-src 'nonce-abc123' 'strict-dynamic' https: 'unsafe-inline'; object-src 'none'; base-uri 'none'; report-uri /csp", "default-src *"] }))
        let descriptions = audit.details?.items.compactMap { item -> String? in
            if case .text(let text)? = item["description"] { return text }
            return nil
        } ?? []
        XCTAssertFalse(descriptions.contains { $0.hasPrefix("Avoid using plain wildcard") }, "\(descriptions)")
        XCTAssertTrue(descriptions.contains { $0.hasPrefix("The page contains a CSP defined in a `<meta>` tag") })
    }

    func testValidSourceMaps() {
        let big = String(repeating: "x", count: Rules.largeScript + 10)
        var run = input(page())
        run.contents = [.init(url: "https://example.com/app.js", kind: .script, text: big),
                        .init(url: "https://cdn.other.com/vendor.js", kind: .script, text: big),
                        .init(url: "https://example.com/mapped.js", kind: .script, text: "x\n//# sourceMappingURL=mapped.js.map")]
        run.sourceMaps = [.init(scriptURL: "https://example.com/mapped.js", mapURL: "https://example.com/mapped.js.map",
                                error: "Unexpected token")]
        let audit = Rules.validSourceMaps(run)
        XCTAssertEqual(audit.score, 0)
        XCTAssertEqual(audit.title, "Missing source maps for large first-party JavaScript")
        XCTAssertEqual(audit.details?.items.count, 2)
        XCTAssertEqual(audit.details?.items.first?["error"], .text("Large JavaScript file is missing a source map"))
        XCTAssertEqual(audit.details?.items.last?["error"], .text("Unexpected token"))
        run.sourceMaps = nil
        XCTAssertEqual(Rules.validSourceMaps(run).mode, .notApplicable)
    }

    // MARK: SEO

    func testRobotsTxt() {
        let errors = Rules.validateRobots("""
            # comment
            Disallow: /before-group
            User-agent: *
            Allow: /ok$
            Disallow: nope
            Disallow: /a$b
            Sitemap: not a url
            Crawl-delay: 10
            Bogus: 1
            just words
            User-agent:
            """)
        XCTAssertEqual(errors.map(\.line), [2, 5, 6, 7, 9, 10, 11])
        XCTAssertEqual(errors.first?.message, "No user-agent specified")
        XCTAssertEqual(errors.map(\.message)[1], "Pattern should either be empty, start with \"/\" or \"*\"")
        XCTAssertEqual(errors.map(\.message)[4], "Unknown directive")
        XCTAssertEqual(errors.map(\.message)[5], "Syntax not understood")

        var run = input(page())
        XCTAssertEqual(Rules.robotsTxt(run).mode, .notApplicable)
        run.robots = DeveloperLighthouseRobots(status: 404, content: "Not found")
        XCTAssertEqual(Rules.robotsTxt(run).mode, .notApplicable)
        run.robots = DeveloperLighthouseRobots(status: 503, content: nil)
        XCTAssertEqual(Rules.robotsTxt(run).displayValue, "Request for robots.txt returned HTTP status: 503")
        run.robots = DeveloperLighthouseRobots(status: nil, content: nil)
        XCTAssertEqual(Rules.robotsTxt(run).score, 0)
        run.robots = DeveloperLighthouseRobots(status: 200, content: "User-agent: *\nDisallow: /private\nSitemap: https://example.com/sitemap.xml\n")
        XCTAssertEqual(Rules.robotsTxt(run).score, 1)
        run.robots = DeveloperLighthouseRobots(status: 200, content: "User-agent: *\nDisalow: /x\n")
        XCTAssertEqual(Rules.robotsTxt(run).displayValue, "1 error found")
    }

    // MARK: Reading the page script's answer

    func testPageReadsTheNewFields() {
        func n(_ index: Int, _ tag: String) -> [Any] { [index, "<\(tag)>", tag, ""] }
        let select: [String: Any] = ["n": n(4, "select"), "name": "Size"]
        let target: [String: Any] = ["n": n(5, "a"), "x": 1, "y": 2, "w": 10, "h": 12]
        let cell: [String: Any] = ["n": n(6, "td"), "headers": ["a", "b"], "found": ["a"], "id": "c"]
        let lang: [String: Any] = ["n": n(7, "p"), "lang": "de"]
        let refresh: [String: Any] = ["n": n(8, "meta"), "content": "5"]
        let face: [String: Any] = ["family": "F", "display": "swap", "urls": ["https://example.com/f.woff2"]]
        let call: [String: Any] = ["api": "geolocation", "url": "https://example.com/a.js", "line": 1, "column": 2, "gesture": false]
        let aria: [String: Any] = ["n": n(10, "div"), "tag": "div", "attrs": ["aria-expanded"], "implicit": "generic"]
        let image: [String: Any] = ["n": n(11, "img"), "src": "a.png", "rect": [1, 2, 3, 4].map { NSNumber(value: $0) },
                                    "lazy": true]
        let raw: [String: Any] = [
            "mains": 1, "bodyHidden": true, "body": n(3, "body"), "selects": [select], "targets": [target],
            "headersCells": [cell], "langs": [lang], "metaRefresh": [refresh], "fontFaces": [face],
            "unreadableSheets": 2, "preconnects": ["https://cdn.example.com/"], "metaCSP": ["default-src 'self'"],
            "pasteBlocked": [n(9, "input")], "permissionCalls": [call], "aria": [aria], "images": [image],
        ]
        let page = Page(raw)
        XCTAssertEqual(page.mainLandmarks, 1)
        XCTAssertTrue(page.bodyAriaHidden)
        XCTAssertEqual(page.bodyNode?.index, 3)
        XCTAssertEqual(page.selects.first?.name, "Size")
        XCTAssertEqual(page.targets.first?.height, 12)
        XCTAssertEqual(page.headersCells.first?.found, ["a"])
        XCTAssertEqual(page.langs.first?.lang, "de")
        XCTAssertEqual(page.metaRefreshes.first?.content, "5")
        XCTAssertEqual(page.fontFaces.first?.display, "swap")
        XCTAssertEqual(page.unreadableStyleSheets, 2)
        XCTAssertEqual(page.preconnects, ["https://cdn.example.com/"])
        XCTAssertEqual(page.metaCSPs, ["default-src 'self'"])
        XCTAssertEqual(page.pasteBlocked.first?.index, 9)
        XCTAssertEqual(page.permissionCalls?.first?.api, .geolocation)
        XCTAssertEqual(page.aria.first?.implicitRole, "generic")
        XCTAssertEqual(page.images.first?.documentRect, [1, 2, 3, 4])
        XCTAssertEqual(page.images.first?.lazy, true)
        XCTAssertNil(Page([:]).permissionCalls)

        let metrics = DeveloperLighthouseMetrics(["lcpImage": true, "lcpLazy": true, "redirects": 2, "redirectMs": 120])
        XCTAssertTrue(metrics.lcpImage)
        XCTAssertTrue(metrics.lcpLazy)
        XCTAssertEqual(metrics.redirects, 2)
        XCTAssertEqual(metrics.redirectMs, 120)
        XCTAssertEqual(DeveloperLighthouseModel.connectionTime(["domainLookupStart": 2, "connectStart": 10, "connectEnd": 60]), 58)
        XCTAssertNil(DeveloperLighthouseModel.connectionTime(["domainLookupStart": -1, "connectStart": -1, "connectEnd": -1]))
    }
}
