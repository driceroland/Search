import XCTest
@testable import Search

/// The Lighthouse panel's pure logic: Lighthouse's log-normal scoring and
/// control points, the weighted category scores and their re-normalising,
/// TBT, the audits over a page snapshot, the report's grouping and the
/// LHR JSON export.
final class DeveloperLighthouseTests: XCTestCase {
    private typealias Scoring = DeveloperLighthouseScoring
    private typealias Rules = DeveloperLighthouseRules
    private typealias Page = DeveloperLighthousePage

    private func node(_ index: Int) -> DeveloperLighthouseNode {
        DeveloperLighthouseNode(index: index, snippet: "<el \(index)>", selector: "el", label: "el")
    }

    private func input(_ page: Page, mode: DeveloperLighthouseMode = .navigation,
                       requests: [DeveloperLighthouseRequest] = [], metrics: DeveloperLighthouseMetrics? = nil,
                       categories: [DeveloperLighthouseCategoryID] = DeveloperLighthouseCategoryID.allCases) -> DeveloperLighthouseInput {
        DeveloperLighthouseInput(mode: mode, formFactor: .mobile, categories: categories, requestedURL: page.url, page: page,
                                 requests: requests, metrics: metrics, issues: [])
    }

    private func page(_ build: (inout Page) -> Void = { _ in }) -> Page {
        var page = Page()
        page.url = "https://example.com/article"
        page.title = "Example"
        page.lang = "en"
        page.doctype = .init(name: "html", publicID: "", systemID: "")
        page.charsetMeta = true
        page.viewport = "width=device-width, initial-scale=1"
        page.metaDescription = "An example."
        build(&page)
        return page
    }

    // MARK: Scoring

    func testErfMatchesKnownValues() {
        XCTAssertEqual(Scoring.erf(0), 0, accuracy: 1e-7)
        XCTAssertEqual(Scoring.erf(1), 0.8427007929, accuracy: 1e-6)
        XCTAssertEqual(Scoring.erf(-1), -0.8427007929, accuracy: 1e-6)
        XCTAssertEqual(Scoring.erf(3), 0.9999779095, accuracy: 1e-6)
    }

    func testLogNormalIsHalfAtTheMedianAndNinetyAtP10() {
        let curve = Scoring.Curve(p10: 2_500, median: 4_000)
        XCTAssertEqual(Scoring.logNormal(4_000, curve), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Scoring.logNormal(2_500, curve), 0.9, accuracy: 1e-4)
        XCTAssertEqual(Scoring.logNormal(0, curve), 1)
        XCTAssertLessThan(Scoring.logNormal(10_000, curve), 0.1)
        XCTAssertGreaterThan(Scoring.logNormal(1_000, curve), Scoring.logNormal(2_000, curve))
    }

    func testScoreFloorsToTwoPlacesAndBoostsAboveNinety() {
        let curve = Scoring.Curve(p10: 2_500, median: 4_000)
        XCTAssertEqual(Scoring.score(4_000, curve), 0.5)
        let raw = Scoring.logNormal(1_500, curve)
        XCTAssertGreaterThan(raw, 0.9)
        let boosted = raw + 0.05 * (raw - 0.9)
        XCTAssertEqual(Scoring.score(1_500, curve), (boosted * 100).rounded(.down) / 100)
        XCTAssertEqual(Scoring.score(0, curve), 1)
    }

    func testControlPointsAreLighthouses() {
        func points(_ metric: DeveloperLighthouseMetric, _ factor: DeveloperLighthouseFormFactor) -> [Double] {
            let curve = Scoring.curve(metric, factor)
            return [curve.p10, curve.median]
        }
        XCTAssertEqual(points(.largestContentfulPaint, .desktop), [1_200, 2_400])
        XCTAssertEqual(points(.largestContentfulPaint, .mobile), [2_500, 4_000])
        XCTAssertEqual(points(.firstContentfulPaint, .mobile), [1_800, 3_000])
        XCTAssertEqual(points(.firstContentfulPaint, .desktop), [934, 1_600])
        XCTAssertEqual(points(.totalBlockingTime, .mobile), [200, 600])
        XCTAssertEqual(points(.totalBlockingTime, .desktop), [150, 350])
        XCTAssertEqual(points(.cumulativeLayoutShift, .mobile), [0.1, 0.25])
        XCTAssertEqual(points(.cumulativeLayoutShift, .desktop), [0.1, 0.25])
        XCTAssertEqual(points(.speedIndex, .mobile), [3_387, 5_800])
        XCTAssertEqual(points(.speedIndex, .desktop), [1_311, 2_300])
        XCTAssertEqual(DeveloperLighthouseMetric.allCases.map(\.weight).reduce(0, +), 100)
        XCTAssertEqual(DeveloperLighthouseMetric.totalBlockingTime.weight, 30)
        XCTAssertEqual(DeveloperLighthouseMetric.largestContentfulPaint.weight, 25)
    }

    func testWeightedMeanRenormalisesOverWhatWasMeasured() {
        let mean = Scoring.weightedMean([(1, 10), (nil, 10), (nil, 25), (0.5, 30), (1, 25)])
        XCTAssertEqual(mean ?? -1, (10 + 15 + 25) / 65, accuracy: 1e-9)
        XCTAssertNil(Scoring.weightedMean([(nil, 10), (1, 0)]))
    }

    func testRatingBands() {
        XCTAssertEqual(Scoring.rating(0.49), .fail)
        XCTAssertEqual(Scoring.rating(0.5), .average)
        XCTAssertEqual(Scoring.rating(0.89), .average)
        XCTAssertEqual(Scoring.rating(0.9), .pass)
        XCTAssertEqual(Scoring.rating(1), .pass)
    }

    func testWastedMsScore() {
        XCTAssertEqual(Scoring.scoreForWastedMs(0), 1)
        XCTAssertEqual(Scoring.scoreForWastedMs(100), 0.9)
        XCTAssertEqual(Scoring.scoreForWastedMs(500), 0.65)
        XCTAssertEqual(Scoring.scoreForWastedMs(1_000), 0)
        XCTAssertEqual(Scoring.milliseconds(forBytes: 204_800, .mobile), 204_800 * 8 / 1_638.4, accuracy: 1e-9)
    }

    func testTotalBlockingTimeClipsToFCP() {
        let tasks: [(start: Double, duration: Double)] = [(0, 100), (200, 120), (400, 40), (900, 60)]
        // The first task's 50 ms after FCP don't block; the second blocks 70, the last 10.
        XCTAssertEqual(DeveloperLighthouseMetrics.totalBlockingTime(tasks, after: 50), 80)
        XCTAssertEqual(DeveloperLighthouseMetrics.totalBlockingTime(tasks, after: 50, until: 300), 50)
    }

    // MARK: Metrics and the Performance score

    func testPerformanceScoreFromMetricsWithUnmeasuredOnesLeftOut() {
        let metrics = DeveloperLighthouseMetrics(fcp: 900, lcp: nil, lcpSupported: false, cls: nil, clsSupported: false,
                                                 tasks: [], taskSource: .eventLoopGaps)
        let report = Rules.report(input(page(), metrics: metrics, categories: [.performance]))
        let audits = report.audits
        XCTAssertEqual(audits["first-contentful-paint"]?.score, 1)
        XCTAssertEqual(audits["first-contentful-paint"]?.displayValue, "0.9 s")
        XCTAssertEqual(audits["largest-contentful-paint"]?.mode, .notApplicable)
        XCTAssertEqual(audits["cumulative-layout-shift"]?.mode, .notApplicable)
        XCTAssertEqual(audits["speed-index"]?.mode, .notApplicable)
        XCTAssertEqual(audits["total-blocking-time"]?.numericValue, 0)
        XCTAssertFalse(audits["total-blocking-time"]?.warnings.isEmpty ?? true)
        // FCP (10) and TBT (30) both score 1: the score is 1 over their weights alone.
        XCTAssertEqual(report.category(.performance)?.score, 1)
    }

    func testSnapshotHasNoMetricsAndNoPerformanceScore() {
        let report = Rules.report(input(page { $0.dom.elements = 100 }, mode: .snapshot, categories: [.performance]))
        XCTAssertEqual(report.audits["first-contentful-paint"]?.mode, .notApplicable)
        XCTAssertNil(report.category(.performance)?.score)
        let fraction = report.fraction(report.category(.performance)!)
        XCTAssertGreaterThan(fraction.total, 0)
        XCTAssertEqual(report.audits["render-blocking-resources"]?.mode, .notApplicable)
    }

    func testTimespanAuditsTBTCLSAndINPOverTheSpanOnly() throws {
        // Tasks from when the timespan started (1000), not from FCP; INP the
        // worst interaction.
        let raw: [String: Any] = [
            "now": 5_000, "started": 1_000, "fcp": 200, "cls": 0.05, "clsSupported": true,
            "tasks": [[500, 300], [1_200, 250], [3_000, 40]].map { $0.map { NSNumber(value: $0) } }, "taskSource": "gaps",
            "inpSupported": true, "inp": 320, "interactions": 3, "inpEvent": "click", "inpTarget": "<button id=\"go\">",
            "observed": true,
        ]
        let metrics = DeveloperLighthouseMetrics(raw)
        XCTAssertEqual(metrics.timespanBlockingTime, 200)
        let report = Rules.report(input(page(), mode: .timespan, metrics: metrics))
        // Accessibility and SEO aren't run over a timespan.
        XCTAssertEqual(report.categories.map(\.id), [.performance, .bestPractices])
        XCTAssertNil(report.audits["first-contentful-paint"])
        XCTAssertNil(report.audits["speed-index"])
        XCTAssertNil(report.audits["dom-size"])
        XCTAssertNil(report.audits["render-blocking-resources"])
        let tbt = try XCTUnwrap(report.audits["total-blocking-time"])
        XCTAssertEqual(tbt.numericValue, 200)
        XCTAssertEqual(tbt.displayValue, "200 ms")
        XCTAssertEqual(report.audits["cumulative-layout-shift"]?.numericValue, 0.05)
        let inp = try XCTUnwrap(report.audits["interaction-to-next-paint"])
        XCTAssertEqual(inp.mode, .numeric)
        XCTAssertEqual(inp.numericValue, 320)
        XCTAssertEqual(inp.displayValue, "320 ms")
        XCTAssertEqual(inp.score, Scoring.score(.interactionToNextPaint, value: 320, .mobile))
        XCTAssertEqual(inp.details?.items.first?["eventType"], .text("click"))
        XCTAssertNotNil(report.audits["errors-in-console"])
        // No score, passed of total instead, as in Snapshot mode.
        let performance = try XCTUnwrap(report.category(.performance))
        XCTAssertNil(performance.score)
        XCTAssertEqual(report.fraction(performance).total, performance.refs.compactMap { report.audits[$0.id] }.filter(\.scored).count)
        let json = DeveloperLighthouseLHR.object(report)
        XCTAssertEqual(json["gatherMode"] as? String, "timespan")

        // Without event timing, or without interactions, INP is not applicable.
        var unsupported = metrics
        unsupported.inpSupported = false
        XCTAssertEqual(Rules.metricAudit(.interactionToNextPaint, input(page(), mode: .timespan, metrics: unsupported)).mode,
                       .notApplicable)
        var idle = metrics
        idle.interactions = 0
        idle.inp = nil
        let none = Rules.metricAudit(.interactionToNextPaint, input(page(), mode: .timespan, metrics: idle))
        XCTAssertEqual(none.mode, .notApplicable)
        XCTAssertEqual(none.explanation, "No user interactions were recorded during the timespan.")
        // Navigation reports don't list INP.
        XCTAssertNil(Rules.report(input(page(), metrics: metrics, categories: [.performance])).audits["interaction-to-next-paint"])
    }

    // MARK: Accessibility

    func testImageAlt() {
        let missing = Page.Image(node: node(1), src: "a.png", naturalWidth: 10, naturalHeight: 10, displayedWidth: 10,
                                 displayedHeight: 10, alt: nil, role: nil)
        var decorative = missing
        decorative.alt = ""
        decorative.node = node(2)
        var labelled = missing
        labelled.name = "Logo"
        labelled.node = node(3)
        var presentational = missing
        presentational.role = "presentation"
        let audit = Rules.imageAlt(page { $0.images = [missing, decorative, labelled, presentational] })
        XCTAssertEqual(audit.score, 0)
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertEqual(audit.details?.items.first?["node"], .node(node(1)))
        XCTAssertEqual(audit.title, "Image elements do not have `[alt]` attributes")
        XCTAssertEqual(Rules.imageAlt(page()).mode, .notApplicable)
        XCTAssertEqual(Rules.imageAlt(page { $0.images = [decorative] }).score, 1)
    }

    func testNamesOfControls() {
        let fields = [Page.Named(node: node(1), name: ""), Page.Named(node: node(2), name: "Email")]
        XCTAssertEqual(Rules.nameAudit("label", fields).score, 0)
        XCTAssertEqual(Rules.nameAudit("button-name", [Page.Named(node: node(3), name: "Go")]).score, 1)
        XCTAssertEqual(Rules.nameAudit("frame-title", []).mode, .notApplicable)
    }

    func testDocumentAndLanguage() {
        XCTAssertEqual(Rules.documentTitle(page { $0.title = nil }).score, 0)
        XCTAssertEqual(Rules.documentTitle(page { $0.title = "  " }).score, 0)
        XCTAssertEqual(Rules.documentTitle(page()).score, 1)
        XCTAssertEqual(Rules.htmlHasLang(page { $0.lang = nil }).score, 0)
        XCTAssertEqual(Rules.htmlLangValid(page { $0.lang = "en-US" }).score, 1)
        XCTAssertEqual(Rules.htmlLangValid(page { $0.lang = "zh-Hant-TW" }).score, 1)
        XCTAssertEqual(Rules.htmlLangValid(page { $0.lang = "english" }).score, 0)
        XCTAssertEqual(Rules.htmlLangValid(page { $0.lang = "e" }).score, 0)
        XCTAssertEqual(Rules.htmlLangValid(page { $0.lang = nil }).mode, .notApplicable)
    }

    func testMetaViewportZooming() {
        XCTAssertEqual(Rules.metaViewport(page()).score, 1)
        XCTAssertEqual(Rules.metaViewport(page { $0.viewport = "width=device-width, user-scalable=no" }).score, 0)
        XCTAssertEqual(Rules.metaViewport(page { $0.viewport = "width=device-width, maximum-scale=2" }).score, 0)
        XCTAssertEqual(Rules.metaViewport(page { $0.viewport = "width=device-width, maximum-scale=5" }).score, 1)
        XCTAssertEqual(Rules.metaViewport(page { $0.viewport = nil }).mode, .notApplicable)
    }

    func testHeadingOrderTabindexAndLists() {
        let headings = [Page.Heading(node: node(1), level: 1), Page.Heading(node: node(2), level: 2),
                        Page.Heading(node: node(3), level: 4), Page.Heading(node: node(4), level: 2)]
        let order = Rules.headingOrder(page { $0.headings = headings })
        XCTAssertEqual(order.score, 0)
        XCTAssertEqual(order.details?.items.count, 1)
        XCTAssertEqual(Rules.tabIndex(page { $0.tabIndexes = [.init(node: node(1), value: 0), .init(node: node(2), value: 3)] })
            .details?.items.count, 1)
        let good = Page.ListElement(node: node(1), children: [("li", nil), ("script", nil), ("template", nil)])
        let bad = Page.ListElement(node: node(2), children: [("li", nil), ("div", nil)])
        XCTAssertEqual(Rules.lists(page { $0.lists = [good] }).score, 1)
        XCTAssertEqual(Rules.lists(page { $0.lists = [good, bad] }).details?.items.count, 1)
        let stray = Page.ListItem(node: node(3), parentTag: "div", parentRole: nil)
        let inList = Page.ListItem(node: node(4), parentTag: "div", parentRole: "list")
        XCTAssertEqual(Rules.listItems(page { $0.listItems = [stray, inList] }).details?.items.count, 1)
    }

    func testAriaRules() {
        let typo = Page.Aria(node: node(1), tag: "div", role: nil, attributes: ["aria-lable"])
        let fine = Page.Aria(node: node(2), tag: "div", role: nil, attributes: ["aria-label", "aria-hidden"])
        XCTAssertEqual(Rules.ariaValidAttributes(page { $0.aria = [typo, fine] }).details?.items.count, 1)
        let checkbox = Page.Aria(node: node(3), tag: "div", role: "checkbox", attributes: [])
        let checked = Page.Aria(node: node(4), tag: "div", role: "checkbox", attributes: ["aria-checked"])
        let native = Page.Aria(node: node(5), tag: "input", role: "checkbox", attributes: [], native: true)
        let required = Rules.ariaRequiredAttributes(page { $0.aria = [checkbox, checked, native] })
        XCTAssertEqual(required.details?.items.count, 1)
        XCTAssertEqual(required.details?.items.first?["node"], .node(node(3)))
        let referenced = Page.DuplicateID(id: "label", referenced: true, nodes: [node(6), node(7)])
        let unreferenced = Page.DuplicateID(id: "x", referenced: false, nodes: [node(8), node(9)])
        XCTAssertEqual(Rules.duplicateIDs(page { $0.duplicateIDs = [unreferenced]; $0.aria = [fine] }).score, 1)
        XCTAssertEqual(Rules.duplicateIDs(page()).mode, .notApplicable)
        XCTAssertEqual(Rules.duplicateIDs(page { $0.duplicateIDs = [referenced, unreferenced] }).details?.items.count, 2)
    }

    func testColorContrast() {
        let grey = Page.Text(node: node(1), color: "rgb(119, 119, 119)", backgrounds: [], fontSize: "16px", fontWeight: "400")
        let largeGrey = Page.Text(node: node(2), color: "rgb(119, 119, 119)", backgrounds: ["rgb(255, 255, 255)"],
                                  fontSize: "24px", fontWeight: "400")
        let black = Page.Text(node: node(3), color: "rgb(0, 0, 0)", backgrounds: ["rgba(0, 0, 0, 0)", "rgb(255, 255, 255)"],
                              fontSize: "16px", fontWeight: "400")
        let overImage = Page.Text(node: node(4), color: "rgb(250, 250, 250)", backgrounds: nil, fontSize: "16px", fontWeight: "400")
        let audit = Rules.colorContrast(page { $0.texts = [grey, largeGrey, black, overImage] })
        XCTAssertEqual(audit.score, 0)
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertEqual(audit.details?.items.first?["node"], .node(node(1)))
        XCTAssertEqual(Rules.effectiveBackground(["rgba(0, 0, 0, 0.5)", "rgb(255, 255, 255)"]).hex, "#808080")
        XCTAssertEqual(Rules.colorContrast(page { $0.texts = [overImage] }).mode, .notApplicable)
    }

    // MARK: Best practices

    func testHTTPS() {
        let secure = DeveloperLighthouseRequest(url: "https://example.com/a.js", type: "Script", mimeType: "text/javascript")
        let mixed = DeveloperLighthouseRequest(url: "http://cdn.example.com/b.png", type: "Image", mimeType: "image/png")
        let local = DeveloperLighthouseRequest(url: "http://localhost:3000/c.js", type: "Script", mimeType: "text/javascript")
        XCTAssertEqual(Rules.https(input(page(), requests: [secure, local])).score, 1)
        XCTAssertEqual(Rules.https(input(page(), requests: [secure, mixed])).details?.items.count, 1)
        XCTAssertEqual(Rules.https(input(page { $0.url = "http://example.com/" })).score, 0)
        XCTAssertEqual(Rules.https(input(page { $0.url = "http://127.0.0.1:8080/" })).score, 1)
    }

    func testDoctypeAndCharset() {
        XCTAssertEqual(Rules.doctype(page()).score, 1)
        XCTAssertEqual(Rules.doctype(page { $0.doctype = nil }).score, 0)
        XCTAssertEqual(Rules.doctype(page { $0.doctype = .init(name: "html", publicID: "-//W3C//DTD HTML 4.01//EN", systemID: "") }).score, 0)
        XCTAssertEqual(Rules.doctype(page { $0.compatMode = "BackCompat" }).score, 0)
        XCTAssertEqual(Rules.charset(input(page { $0.charsetMeta = false })).score, 0)
        let document = DeveloperLighthouseRequest(url: "https://example.com/article", type: "Document", mimeType: "text/html",
                                                  status: 200, headers: ["content-type": "text/html; charset=utf-8"])
        XCTAssertEqual(Rules.charset(input(page { $0.charsetMeta = false }, requests: [document])).score, 1)
    }

    func testConsoleErrorsAndIssues() {
        var run = input(page())
        XCTAssertEqual(Rules.consoleErrors(run).score, 1)
        run.consoleErrors = [.init(text: "Uncaught TypeError: x is undefined", url: "https://example.com/app.js")]
        XCTAssertEqual(Rules.consoleErrors(run).score, 0)
        run.issues = nil
        XCTAssertEqual(Rules.deprecations(run).mode, .notApplicable)
        run.issues = [.init(title: "Deprecated feature used", category: "Other", subtitle: "Synchronous XHR", count: 2, deprecation: true),
                      .init(title: "Mixed content", category: "Mixed Content", subtitle: nil, count: 1, deprecation: false),
                      .init(title: "Low contrast", category: "Low Text Contrast", subtitle: nil, count: 4, deprecation: false)]
        XCTAssertEqual(Rules.deprecations(run).displayValue, "2 warnings found")
        XCTAssertEqual(Rules.inspectorIssues(run).details?.items.count, 1)
    }

    func testImageAspectRatioAndResolution() {
        let stretched = Page.Image(node: node(1), src: "a.jpg", naturalWidth: 400, naturalHeight: 200, displayedWidth: 200,
                                   displayedHeight: 200, alt: "", role: nil)
        var covered = stretched
        covered.objectFit = "cover"
        XCTAssertEqual(Rules.aspectRatio(page { $0.images = [stretched] }).score, 0)
        XCTAssertEqual(Rules.aspectRatio(page { $0.images = [covered] }).mode, .notApplicable)
        let blurry = Page.Image(node: node(2), src: "b.jpg", naturalWidth: 100, naturalHeight: 100, displayedWidth: 300,
                                displayedHeight: 300, alt: "", role: nil)
        XCTAssertEqual(Rules.sizeResponsive(page { $0.images = [blurry]; $0.devicePixelRatio = 2 }).score, 0)
        XCTAssertEqual(Rules.expectedSize(300, dpr: 2), 300)
        XCTAssertEqual(Rules.expectedSize(40, dpr: 1.75), 45)
        XCTAssertEqual(Rules.quantizedDPR(1.75), 1.5)
    }

    // MARK: SEO

    func testSEOBasics() {
        XCTAssertEqual(Rules.viewport(page { $0.viewport = nil }).score, 0)
        XCTAssertEqual(Rules.viewport(page { $0.viewport = "user-scalable=yes" }).score, 0)
        XCTAssertEqual(Rules.viewport(page()).score, 1)
        XCTAssertEqual(Rules.metaDescription(page { $0.metaDescription = nil }).score, 0)
        XCTAssertEqual(Rules.metaDescription(page { $0.metaDescription = " " }).score, 0)
        let notFound = DeveloperLighthouseRequest(url: "https://example.com/article", type: "Document", mimeType: "text/html", status: 404)
        XCTAssertEqual(Rules.httpStatus(input(page(), requests: [notFound])).score, 0)
        XCTAssertEqual(Rules.httpStatus(input(page())).mode, .notApplicable)
    }

    func testLinkTextAndCrawlableAnchors() {
        let generic = Page.Link(node: node(1), name: "click here", text: "Click here", rawHref: "/pricing",
                                href: "https://example.com/pricing")
        let good = Page.Link(node: node(2), name: "Pricing", text: "Pricing", rawHref: "/pricing", href: "https://example.com/pricing")
        let samePage = Page.Link(node: node(3), name: "more", text: "more", rawHref: "#more", href: "https://example.com/article#more")
        XCTAssertEqual(Rules.linkText(page { $0.links = [generic, good, samePage] }).details?.items.count, 1)
        let script = Page.Link(node: node(4), name: "Open", text: "Open", rawHref: "javascript:void(0)", href: "javascript:void(0)")
        let mail = Page.Link(node: node(5), name: "Mail", text: "Mail", rawHref: "mailto:a@example.com", href: "mailto:a@example.com")
        let placeholder = Page.Link(node: node(6), name: "", text: "", rawHref: nil)
        var clickable = placeholder
        clickable.onclick = true
        clickable.node = node(7)
        var withRole = script
        withRole.role = "button"
        let audit = Rules.crawlableAnchors(page { $0.links = [good, script, mail, placeholder, clickable, withRole] })
        XCTAssertEqual(audit.details?.items.map { $0["node"] }, [.node(node(4)), .node(node(7))])
    }

    func testIsCrawlable() {
        XCTAssertEqual(Rules.crawlable(input(page())).score, 1)
        XCTAssertEqual(Rules.crawlable(input(page { $0.robots = ["noindex, follow"] })).score, 0)
        XCTAssertEqual(Rules.crawlable(input(page { $0.robots = ["index, follow"] })).score, 1)
        let header = DeveloperLighthouseRequest(url: "https://example.com/article", type: "Document", mimeType: "text/html",
                                                status: 200, headers: ["x-robots-tag": "none"])
        XCTAssertEqual(Rules.crawlable(input(page(), requests: [header])).score, 0)
        let otherBot = DeveloperLighthouseRequest(url: "https://example.com/article", type: "Document", mimeType: "text/html",
                                                  status: 200, headers: ["x-robots-tag": "otherbot: noindex"])
        XCTAssertEqual(Rules.crawlable(input(page(), requests: [otherBot])).score, 1)
    }

    func testHreflangAndCanonical() {
        XCTAssertEqual(Rules.hreflang(page()).score, 1)
        XCTAssertEqual(Rules.hreflang(page { $0.hreflangs = [("de", "https://example.com/de", "https://example.com/de"),
                                                               ("x-default", "https://example.com/", "https://example.com/")] }).score, 1)
        XCTAssertEqual(Rules.hreflang(page { $0.hreflangs = [("german", "https://example.com/de", "https://example.com/de")] }).score, 0)
        XCTAssertEqual(Rules.hreflang(page { $0.hreflangs = [("de", "/de", "https://example.com/de")] }).score, 0)
        XCTAssertEqual(Rules.canonical(page()).mode, .notApplicable)
        XCTAssertEqual(Rules.canonical(page { $0.canonicals = [("https://example.com/article", "https://example.com/article")] }).score, 1)
        XCTAssertEqual(Rules.canonical(page { $0.canonicals = [("/article", "https://example.com/article")] }).score, 0)
        XCTAssertEqual(Rules.canonical(page { $0.canonicals = [("https://example.com/", "https://example.com/")] }).score, 0)
        XCTAssertEqual(Rules.canonical(page { $0.canonicals = [("https://example.com/a", "https://example.com/a"),
                                                                ("https://example.com/b", "https://example.com/b")] }).score, 0)
    }

    // MARK: Performance audits

    func testTextCompression() {
        let plain = DeveloperLighthouseRequest(url: "https://example.com/app.js", type: "Script", mimeType: "text/javascript",
                                               status: 200, transferSize: 50_000, resourceSize: 50_000, headers: ["content-type": "text/javascript"])
        let gzipped = DeveloperLighthouseRequest(url: "https://example.com/b.js", type: "Script", mimeType: "text/javascript",
                                                 status: 200, transferSize: 10_000, resourceSize: 40_000, headers: ["content-encoding": "br"])
        let small = DeveloperLighthouseRequest(url: "https://example.com/c.css", type: "Stylesheet", mimeType: "text/css",
                                               status: 200, transferSize: 900, resourceSize: 900, headers: ["x": "y"])
        let image = DeveloperLighthouseRequest(url: "https://example.com/d.png", type: "Image", mimeType: "image/png",
                                               status: 200, transferSize: 90_000, resourceSize: 90_000, headers: ["x": "y"])
        let audit = Rules.textCompression(input(page(), requests: [plain, gzipped, small, image]))
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertEqual(audit.details?.kind, .opportunity)
        XCTAssertEqual(audit.details?.overallSavingsBytes ?? 0, 50_000 * 0.65, accuracy: 1e-6)
        XCTAssertLessThan(audit.score ?? 1, 1)
    }

    func testCacheLifetimeAndHitProbability() {
        XCTAssertEqual(Rules.cacheLifetime(["cache-control": "public, max-age=3600"]), 3_600)
        XCTAssertEqual(Rules.cacheLifetime(["cache-control": "no-cache"]), 0)
        XCTAssertNil(Rules.cacheLifetime([:]))
        XCTAssertEqual(Rules.cacheLifetime(["pragma": "no-cache"]), 0)
        XCTAssertEqual(Rules.cacheHitProbability(0), 0)
        XCTAssertEqual(Rules.cacheHitProbability(3_600), 0.2, accuracy: 1e-9)
        XCTAssertEqual(Rules.cacheHitProbability(365 * 24 * 3_600), 1, accuracy: 1e-9)
        XCTAssertTrue(Rules.skipsCaching(["cache-control": "private, max-age=60"]))
        let short = DeveloperLighthouseRequest(url: "https://example.com/app.js", type: "Script", mimeType: "text/javascript",
                                               status: 200, transferSize: 100_000, headers: ["cache-control": "max-age=600"])
        let long = DeveloperLighthouseRequest(url: "https://example.com/logo.png", type: "Image", mimeType: "image/png",
                                              status: 200, transferSize: 100_000, headers: ["cache-control": "max-age=31536000"])
        let audit = Rules.cachePolicy(input(page(), requests: [short, long]))
        XCTAssertEqual(audit.details?.items.count, 1)
        XCTAssertEqual(audit.displayValue, "1 resource found")
    }

    func testByteWeightDOMSizeAndUnsizedImages() {
        let big = DeveloperLighthouseRequest(url: "https://example.com/v.mp4", type: "Media", mimeType: "video/mp4",
                                             transferSize: 8_000 * 1_024)
        let weight = Rules.totalByteWeight(input(page(), requests: [big]))
        XCTAssertLessThan(weight.score ?? 1, 0.5)
        XCTAssertEqual(weight.title, "Avoid enormous network payloads")
        let dom = Rules.domSize(page { $0.dom = .init(elements: 3_000, depth: 40, widestChildren: 200) })
        XCTAssertLessThan(dom.score ?? 1, 0.5)
        XCTAssertEqual(dom.details?.items.count, 3)
        XCTAssertEqual(Rules.domSize(page { $0.dom.elements = 300 }).score, 1)
        let unsized = Page.Image(node: node(1), src: "a.png", naturalWidth: 10, naturalHeight: 10, displayedWidth: 10,
                                 displayedHeight: 10, alt: "", role: nil)
        var sized = unsized
        sized.widthAttribute = true
        sized.heightAttribute = true
        var fixed = unsized
        fixed.position = "fixed"
        XCTAssertEqual(Rules.unsizedImages(page { $0.images = [unsized, sized, fixed] }).details?.items.count, 1)
    }

    func testResponsiveImagesAndRenderBlocking() {
        let image = Page.Image(node: node(1), src: "https://example.com/hero.jpg", naturalWidth: 2_000, naturalHeight: 1_000,
                               displayedWidth: 400, displayedHeight: 200, alt: "", role: nil)
        let request = DeveloperLighthouseRequest(url: "https://example.com/hero.jpg", type: "Image", mimeType: "image/jpeg",
                                                 status: 200, transferSize: 400_000)
        let sized = Rules.responsiveImages(input(page { $0.images = [image]; $0.devicePixelRatio = 1 }, requests: [request]))
        XCTAssertEqual(sized.details?.items.count, 1)
        XCTAssertEqual(sized.details?.overallSavingsBytes ?? 0, 400_000 * (1 - 80_000.0 / 2_000_000), accuracy: 1e-6)
        let modern = Rules.modernFormats(input(page(), requests: [request]))
        XCTAssertEqual(modern.details?.overallSavingsBytes ?? 0, 120_000, accuracy: 1e-6)

        let sync = Page.HeadResource(node: node(2), kind: .script, url: "https://example.com/a.js")
        let deferred = Page.HeadResource(node: node(3), kind: .script, url: "https://example.com/b.js", deferred: true)
        let css = Page.HeadResource(node: node(4), kind: .stylesheet, url: "https://example.com/a.css")
        let print = Page.HeadResource(node: node(5), kind: .stylesheet, url: "https://example.com/print.css", mediaMatches: false)
        let late = Page.HeadResource(node: node(6), kind: .stylesheet, url: "https://example.com/late.css")
        let timings = [
            Page.Timing(url: "https://example.com/a.js", initiatorType: "script", startTime: 100, responseEnd: 400,
                        transferSize: 2_000, encodedBodySize: 2_000, decodedBodySize: 2_000),
            Page.Timing(url: "https://example.com/a.css", initiatorType: "link", startTime: 120, responseEnd: 500,
                        transferSize: 3_000, encodedBodySize: 3_000, decodedBodySize: 3_000),
            Page.Timing(url: "https://example.com/late.css", initiatorType: "link", startTime: 900, responseEnd: 1_400,
                        transferSize: 3_000, encodedBodySize: 3_000, decodedBodySize: 3_000),
        ]
        let blocking = Rules.renderBlocking(input(page { $0.headResources = [sync, deferred, css, print, late]; $0.timings = timings },
                                                  metrics: DeveloperLighthouseMetrics(fcp: 800)))
        XCTAssertEqual(blocking.details?.items.count, 2)
        XCTAssertEqual(blocking.details?.overallSavingsMs, 400)
        XCTAssertEqual(blocking.score, 0.65)
    }

    // MARK: Page parsing

    func testPageReadsThePageScriptsAnswer() {
        let image: [String: Any] = [
            "n": [0, "<img src=\"a.png\">", "img", "img"] as [Any], "src": "https://example.com/a.png", "nw": 100, "nh": 50,
            "dw": 50, "dh": 25, "alt": NSNull(), "wa": true, "ha": false, "visible": true,
        ]
        let link: [String: Any] = [
            "n": [1, "<a href=\"#\">", "a", "Top"] as [Any], "tag": "a", "name": "Top", "text": "Top", "raw": "#",
            "href": "https://example.com/#", "visible": true,
        ]
        let list: [String: Any] = [
            "n": [2, "<ul>", "ul", "ul"] as [Any], "children": [["li", NSNull()] as [Any], ["div", "listitem"] as [Any]],
        ]
        let dom: [String: Any] = ["elements": 120, "depth": 9, "children": 14, "depthNode": [3, "<span>", "span", "x"] as [Any]]
        let resource: [String: Any] = [
            "name": "https://example.com/a.js", "type": "script", "start": 10, "end": 90, "transfer": 1_000,
            "encoded": 900, "decoded": 2_000, "blocking": "blocking",
        ]
        let raw: [String: Any] = [
            "url": "https://example.com/", "title": NSNull(), "lang": "en", "compatMode": "CSS1Compat",
            "doctype": ["name": "html", "publicId": "", "systemId": ""], "charsetMeta": true, "viewport": "width=device-width",
            "description": "Hi", "robots": ["noindex"], "canonicals": [["/a", "https://example.com/a"]],
            "hreflangs": [["de", "/de", "https://example.com/de"]], "dpr": 2, "width": 412, "height": 823,
            "images": [image], "links": [link], "lists": [list], "dom": dom, "resources": [resource],
        ]
        let page = Page(raw)
        XCTAssertNil(page.title)
        XCTAssertEqual(page.doctype?.name, "html")
        XCTAssertEqual(page.canonicals.first?.resolved, "https://example.com/a")
        XCTAssertEqual(page.hreflangs.first?.lang, "de")
        XCTAssertEqual(page.images.first?.alt, nil)
        XCTAssertEqual(page.images.first?.node.index, 0)
        XCTAssertEqual(page.images.first?.widthAttribute, true)
        XCTAssertEqual(page.links.first?.rawHref, "#")
        XCTAssertEqual(page.lists.first?.children.map { $0.tag }, ["li", "div"])
        XCTAssertEqual(page.lists.first?.children.map { $0.role }, [nil, "listitem"])
        XCTAssertEqual(page.dom.depthNode?.index, 3)
        XCTAssertEqual(page.timings.first?.renderBlockingStatus, "blocking")
        XCTAssertEqual(page.devicePixelRatio, 2)

        let metrics = DeveloperLighthouseMetrics(["fcp": 500, "lcp": 900, "lcpSupported": true, "cls": NSNull(),
                                                  "clsSupported": false, "tasks": [[NSNumber(value: 600), NSNumber(value: 120)]], "taskSource": "gaps",
                                                  "now": 3_000, "ttfb": 80])
        XCTAssertEqual(metrics.lcp, 900)
        XCTAssertNil(metrics.cls)
        XCTAssertEqual(metrics.totalBlockingTime, 70)
        XCTAssertEqual(metrics.ttfb, 80)
    }

    // MARK: The report

    func testCategoriesScoreAndSectionsGroup() {
        let missing = Page.Image(node: node(1), src: "a.png", naturalWidth: 10, naturalHeight: 10, displayedWidth: 10,
                                 displayedHeight: 10, alt: nil, role: nil)
        let report = Rules.report(input(page { $0.images = [missing] }, categories: [.accessibility, .seo]))
        let a11y = report.category(.accessibility)!
        // image-alt (10) and landmark-one-main (3) fail; document-title, html-has-lang,
        // html-lang-valid (7 each), meta-viewport and aria-hidden-body (10 each) pass;
        // the rest aren't applicable and drop out.
        XCTAssertEqual(a11y.score ?? -1, 41.0 / 54.0, accuracy: 1e-9)
        let sections = report.sections(a11y)
        XCTAssertEqual(sections.first?.id, "a11y-names-labels")
        XCTAssertEqual(sections.first?.audits.map(\.id), ["image-alt"])
        XCTAssertTrue(sections.contains { $0.id == "passed" && $0.collapsed })
        XCTAssertTrue(sections.contains { $0.id == "notApplicable" })
        XCTAssertTrue(report.sections(a11y, filter: "zzz").isEmpty)
        XCTAssertEqual(report.sections(a11y, filter: "alt").first?.audits.map(\.id), ["image-alt"])
        // The SEO weight of is-crawlable is Lighthouse's 4.043.
        XCTAssertEqual(DeveloperLighthouseCatalog.refs(.seo).first { $0.id == "is-crawlable" }?.weight, 4.043)
        XCTAssertNil(report.audits["first-contentful-paint"])
    }

    func testLHRExport() throws {
        let metrics = DeveloperLighthouseMetrics(fcp: 1_200, lcp: 2_000, lcpSupported: true, cls: 0.02, clsSupported: true,
                                                 tasks: [(1_500, 200)], taskSource: .longTask, ttfb: 100)
        let report = Rules.report(input(page(), metrics: metrics), totalTime: 4_200)
        let data = try XCTUnwrap(DeveloperLighthouseLHR.data(report))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["lighthouseVersion"] as? String, DeveloperLighthouseLHR.version)
        XCTAssertEqual(json["requestedUrl"] as? String, "https://example.com/article")
        XCTAssertEqual(json["finalDisplayedUrl"] as? String, "https://example.com/article")
        XCTAssertNotNil(json["fetchTime"] as? String)
        XCTAssertEqual((json["configSettings"] as? [String: Any])?["formFactor"] as? String, "mobile")
        XCTAssertTrue((json["runWarnings"] as? [String])?.first?.contains("Search") ?? false)
        let categories = try XCTUnwrap(json["categories"] as? [String: Any])
        XCTAssertEqual(Set(categories.keys), ["performance", "accessibility", "best-practices", "seo"])
        let performance = try XCTUnwrap(categories["performance"] as? [String: Any])
        let refs = try XCTUnwrap(performance["auditRefs"] as? [[String: Any]])
        XCTAssertEqual(refs.first { $0["id"] as? String == "total-blocking-time" }?["weight"] as? Double, 30)
        XCTAssertEqual(refs.first { $0["id"] as? String == "largest-contentful-paint" }?["acronym"] as? String, "LCP")
        XCTAssertNotNil(performance["score"] as? Double)
        let audits = try XCTUnwrap(json["audits"] as? [String: Any])
        let lcp = try XCTUnwrap(audits["largest-contentful-paint"] as? [String: Any])
        XCTAssertEqual(lcp["id"] as? String, "largest-contentful-paint")
        XCTAssertEqual(lcp["scoreDisplayMode"] as? String, "numeric")
        XCTAssertEqual(lcp["numericValue"] as? Double, 2_000)
        XCTAssertEqual(lcp["displayValue"] as? String, "2.0 s")
        let speed = try XCTUnwrap(audits["speed-index"] as? [String: Any])
        XCTAssertTrue(speed["score"] is NSNull)
        XCTAssertEqual(speed["scoreDisplayMode"] as? String, "notApplicable")
        for (_, value) in audits {
            let audit = try XCTUnwrap(value as? [String: Any])
            for key in ["id", "title", "description", "score", "scoreDisplayMode"] { XCTAssertNotNil(audit[key], key) }
        }
        XCTAssertNotNil(json["categoryGroups"] as? [String: Any])
    }

    func testNodeValuesExportAsLighthouseNodes() {
        let value = DeveloperLighthouseLHR.value(.node(DeveloperLighthouseNode(index: 4, snippet: "<img>", selector: "img", label: "Logo")))
        let object = value as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "node")
        XCTAssertEqual(object?["snippet"] as? String, "<img>")
        XCTAssertEqual(object?["nodeLabel"] as? String, "Logo")
        XCTAssertEqual(DeveloperLighthouseNode([7, "<a>", "a", "x"] as [Any])?.index, 7)
        XCTAssertNil(DeveloperLighthouseNode("nope"))
    }
}
