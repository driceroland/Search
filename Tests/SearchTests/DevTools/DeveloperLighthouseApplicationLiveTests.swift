import AppKit
import WebKit
import XCTest
@testable import Search

/// The Lighthouse panel and the Application panel's newer sections against
/// real pages and WebKit's real inspector. Lighthouse runs through its own
/// model on a real tab of a Browser, so its observer script lives alongside
/// the tab's own user scripts, which the tab swaps at each navigation
/// (Tab.arm); the report is read as the panel shows it and as its LHR
/// export writes it. The Back/forward cache and Reporting API tests open
/// DevTools as the app does (DeveloperTools.shared), so the Application
/// panel's early script follows the tab's navigations; frames, the storage
/// breakdown and the origin private file system go through the panel's own
/// functions on a bare page. Where WebKit decides something (whether a page
/// is kept for Back, whether COOP and COEP make it cross-origin isolated,
/// which paint metrics it reports), the tests print what it did and check
/// that the panel reports it as it is. Pages come from a loopback server
/// with inline content; nothing leaves the machine.
@MainActor
final class DeveloperLighthouseApplicationLiveTests: XCTestCase {
    private static let label = "[DeveloperLighthouseApplicationLiveTests]"

    /// A 40×40 picture, inline, so it costs no request.
    private static let square = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Crect width='40' height='40' fill='%23369'/%3E%3C/svg%3E"

    /// A stylesheet of about 8 KB, sent without compression.
    private static let bulkyCSS: String = {
        var lines = ["/* blocking.css: render-blocking, uncompressed */", "body { margin: 16px; font: 16px/1.4 sans-serif; }"]
        for index in 0..<240 { lines.append(".rule-\(index) { margin: \(index % 17)px; padding: \(index % 13)px; }") }
        return lines.joined(separator: "\n")
    }()

    // MARK: Lighthouse: Navigation

    /// No <title>, no lang, no meta description, an image without alt, a
    /// nameless button, an unlabelled field, faint text, and a
    /// render-blocking, uncompressed stylesheet.
    private static let flawedPage = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="/blocking.css">
        </head>
        <body>
        <h1>Lighthouse fixture</h1>
        <img id="pic" src="\(square)" width="40" height="40">
        <button id="nameless"></button>
        <input id="unlabelled" type="text">
        <p id="faint" style="color: #bbbbbb; background: #ffffff">Faint text that is hard to read.</p>
        </body>
        </html>
        """

    func testNavigationRunFailsTheFlawedPagesAuditsAndPutsDeviceModeAndTheCacheBack() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Lighthouse start</title><p>start</p>"),
            "/flawed": .init(type: "text/html", body: Self.flawedPage),
            "/blocking.css": .init(type: "text/css", body: Self.bulkyCSS),
        ], path: "/start", title: "Lighthouse start")
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let model = DeveloperLighthouseModel.model(for: session)
        let device = DeveloperDeviceMode.shared
        let saved = (on: device.on, settings: device.settings)
        let savedModel = (mode: model.mode, formFactor: model.formFactor, categories: model.categories)
        let pageURL = live.server.url("/flawed").absoluteString
        let cssURL = live.server.url("/blocking.css").absoluteString
        do {
            try await navigate(live, to: "/flawed", title: nil)
            model.mode = .navigation
            model.formFactor = .desktop
            model.categories = Set(DeveloperLighthouseCategoryID.allCases)
            XCTAssertFalse(session.cacheDisabled, "the cache is on before the run")
            let before = model.reports.count
            model.start()
            XCTAssertTrue(model.running, "the run didn't start: \(model.problem ?? "no problem given")")

            // While it runs: Lighthouse's desktop screen through the device
            // toolbar, and the cache off.
            var emulated = false
            var cacheOff = false
            try await wait("the Navigation run", seconds: 60, state: {
                "phase \(model.phase), problem \(model.problem ?? "none"), reports \(model.reports.count), device \(device.on), cache disabled \(session.cacheDisabled), at \(web.url?.absoluteString ?? "nil")"
            }) {
                if model.running {
                    if device.on, device.settings.responsiveWidth == 1350, device.settings.responsiveHeight == 940,
                       device.settings.responsiveType == .desktop { emulated = true }
                    if session.cacheDisabled { cacheOff = true }
                }
                return !model.running
            }
            XCTAssertNil(model.problem)
            XCTAssertTrue(emulated, "device mode showed Lighthouse's desktop screen during the run")
            XCTAssertTrue(cacheOff, "the cache was disabled during the run")
            XCTAssertEqual(model.reports.count, before + 1)
            let report = try XCTUnwrap(model.reports.last)
            XCTAssertEqual(model.selected?.id, report.id)
            XCTAssertFalse(model.starting)

            // Put back: device mode, the cache, the observer script.
            XCTAssertEqual(device.on, saved.on, "device mode is as it was")
            XCTAssertEqual(device.settings, saved.settings, "the device toolbar's settings are as they were")
            try await wait("the cache to be enabled again", state: { "cache disabled \(session.cacheDisabled)" }) {
                !session.cacheDisabled
            }
            XCTAssertFalse(web.configuration.userContentController.userScripts.contains {
                $0.source == DeveloperLighthouseModel.observeScript
            }, "the observer script was taken out of the tab")

            XCTAssertEqual(report.mode, .navigation)
            XCTAssertEqual(report.formFactor, .desktop)
            XCTAssertEqual(report.finalURL, pageURL)
            XCTAssertTrue(report.emulation.hasPrefix("Desktop: 1350×940"), report.emulation)
            XCTAssertEqual(Set(report.categories.map(\.id)), Set(DeveloperLighthouseCategoryID.allCases))

            // Metrics: FCP measured; LCP and CLS measured or not applicable with a reason.
            let fcp = try XCTUnwrap(report.audit("first-contentful-paint"))
            XCTAssertEqual(fcp.mode, .numeric, "FCP: \(fcp.explanation ?? "no explanation")")
            XCTAssertGreaterThan(fcp.numericValue ?? 0, 0)
            XCTAssertEqual(fcp.numericUnit, "millisecond")
            XCTAssertNotNil(fcp.score)
            print("\(Self.label) FCP measured: \(fcp.numericValue.map { String($0) } ?? "nil") ms, score \(fcp.score.map { String($0) } ?? "nil")")
            for id in ["largest-contentful-paint", "cumulative-layout-shift", "total-blocking-time"] {
                let audit = try XCTUnwrap(report.audit(id))
                switch audit.mode {
                case .numeric:
                    let value = try XCTUnwrap(audit.numericValue, id)
                    XCTAssertGreaterThanOrEqual(value, 0, id)
                    if id == "largest-contentful-paint" { XCTAssertGreaterThan(value, 0, id) }
                    let score = try XCTUnwrap(audit.score, id)
                    XCTAssertTrue((0...1).contains(score), "\(id) score \(score)")
                    print("\(Self.label) \(id): measured \(value)\(audit.warnings.isEmpty ? "" : " (\(audit.warnings.joined(separator: " ")))")")
                case .notApplicable:
                    let reason = try XCTUnwrap(audit.explanation, "\(id) is n/a without a reason")
                    XCTAssertFalse(reason.isEmpty, id)
                    XCTAssertNil(audit.score, id)
                    print("\(Self.label) \(id): not applicable: \(reason)")
                default:
                    XCTFail("\(id) is \(audit.mode)")
                }
            }
            // Speed Index from the filmstrip of snapshots: never below FCP.
            let speedIndex = try XCTUnwrap(report.audit("speed-index"))
            XCTAssertEqual(speedIndex.mode, .numeric, speedIndex.explanation ?? "")
            let firstPaint = try XCTUnwrap(report.audit("first-contentful-paint")?.numericValue)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(speedIndex.numericValue), firstPaint)
            XCTAssertFalse(speedIndex.warnings.isEmpty)
            print("\(Self.label) Speed Index \(speedIndex.numericValue ?? -1) ms, FCP \(firstPaint) ms: \(speedIndex.warnings.joined())")

            // The failing audits, with their elements.
            let failing = Self.failing(report)
            XCTAssertEqual(Self.selectors(report.audit("image-alt")), ["img#pic"], failing)
            XCTAssertEqual(Self.selectors(report.audit("button-name")), ["button#nameless"], failing)
            XCTAssertEqual(Self.selectors(report.audit("label")), ["input#unlabelled"], failing)
            XCTAssertTrue(Self.selectors(report.audit("color-contrast")).contains("p#faint"),
                          "color-contrast: \(Self.selectors(report.audit("color-contrast")))")
            for id in ["image-alt", "button-name", "label", "color-contrast", "html-has-lang", "document-title",
                       "meta-description"] {
                let audit = try XCTUnwrap(report.audit(id), id)
                XCTAssertEqual(audit.mode, .binary, id)
                XCTAssertEqual(audit.score, 0, "\(id) fails: \(failing)")
                XCTAssertEqual(audit.title, DeveloperLighthouseCatalog.byID[id]?.failureTitle, id)
            }
            // The document's status, from Network's record of the reload: 200.
            let status = try XCTUnwrap(report.audit("http-status-code"))
            XCTAssertEqual(status.mode, .binary, status.explanation ?? "")
            XCTAssertEqual(status.score, 1)
            XCTAssertEqual(status.title, "Page has successful HTTP status code")
            let contrast = try XCTUnwrap(report.audit("color-contrast")?.details?.items.first {
                if case .node(let node)? = $0["node"] { return node.selector == "p#faint" }
                return false
            })
            if case .text(let text)? = contrast["contrast"] {
                XCTAssertTrue(text.contains("#bbbbbb on #ffffff"), text)
            } else {
                XCTFail("no contrast column: \(contrast)")
            }

            // The network opportunities name the stylesheet.
            let blocking = try XCTUnwrap(report.audit("render-blocking-resources"))
            XCTAssertEqual(blocking.mode, .numeric)
            XCTAssertEqual(Self.urls(blocking), [cssURL], "render-blocking: \(blocking.displayValue ?? "")")
            XCTAssertEqual(blocking.details?.kind, .opportunity)
            print("\(Self.label) render-blocking-resources: score \(blocking.score.map { String($0) } ?? "nil"), savings \(blocking.numericValue ?? 0) ms")
            let compression = try XCTUnwrap(report.audit("uses-text-compression"))
            XCTAssertTrue(Self.urls(compression).contains(cssURL), "text compression: \(Self.urls(compression))")
            XCTAssertLessThan(compression.score ?? 1, 1)
            XCTAssertGreaterThan(compression.details?.overallSavingsBytes ?? 0, 1_400)
            XCTAssertEqual(compression.title, "Enable text compression")

            // Scores.
            for category in report.categories {
                if let score = category.score {
                    XCTAssertTrue((0...1).contains(score), "\(category.id) score \(score)")
                }
            }
            let performance = try XCTUnwrap(report.category(.performance)?.score, "Performance has a score")
            XCTAssertLessThan(try XCTUnwrap(report.category(.accessibility)?.score), 1)
            XCTAssertLessThan(try XCTUnwrap(report.category(.seo)?.score), 1)
            print("\(Self.label) scores: " + report.categories.map { "\($0.id.rawValue) \($0.score.map { String($0) } ?? "nil")" }
                .joined(separator: ", "))

            // The LHR export.
            let data = try XCTUnwrap(DeveloperLighthouseLHR.data(report))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["gatherMode"] as? String, "navigation")
            XCTAssertEqual(json["finalUrl"] as? String, pageURL)
            XCTAssertEqual((json["configSettings"] as? [String: Any])?["formFactor"] as? String, "desktop")
            let categories = try XCTUnwrap(json["categories"] as? [String: Any])
            let performanceJSON = try XCTUnwrap(categories["performance"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap((performanceJSON["score"] as? NSNumber)?.doubleValue), performance, accuracy: 1e-9)
            XCTAssertFalse((performanceJSON["auditRefs"] as? [Any] ?? []).isEmpty)
            let audits = try XCTUnwrap(json["audits"] as? [String: Any])
            let fcpJSON = try XCTUnwrap(audits["first-contentful-paint"] as? [String: Any])
            XCTAssertEqual((fcpJSON["numericValue"] as? NSNumber)?.doubleValue, fcp.numericValue)
            XCTAssertEqual(fcpJSON["scoreDisplayMode"] as? String, "numeric")
            let altJSON = try XCTUnwrap(audits["image-alt"] as? [String: Any])
            XCTAssertEqual((altJSON["score"] as? NSNumber)?.doubleValue, 0)
            let altItems = (altJSON["details"] as? [String: Any])?["items"] as? [[String: Any]]
            let altNode = altItems?.first?["node"] as? [String: Any]
            XCTAssertEqual(altNode?["type"] as? String, "node")
            XCTAssertEqual(altNode?["selector"] as? String, "img#pic")
            let blockingJSON = (audits["render-blocking-resources"] as? [String: Any])?["details"] as? [String: Any]
            XCTAssertEqual(blockingJSON?["type"] as? String, "opportunity")
            XCTAssertEqual((blockingJSON?["items"] as? [[String: Any]])?.first?["url"] as? String, cssURL)
            let lcpJSON = try XCTUnwrap(audits["largest-contentful-paint"] as? [String: Any])
            if report.audit("largest-contentful-paint")?.mode == .notApplicable {
                XCTAssertTrue(lcpJSON["score"] is NSNull)
                XCTAssertNotNil(lcpJSON["explanation"] as? String)
            }

            // Revealing a failing element selects it in Elements.
            let image = try XCTUnwrap(Self.nodes(report.audit("image-alt")).first)
            XCTAssertTrue(model.live, "the report's elements can still be found")
            model.reveal(image.index)
            try await wait("the image, selected in Elements", seconds: 15, state: {
                let node = session.selectedNode.flatMap { session.nodes[$0] }
                return "selected \(session.selectedNode.map(String.init) ?? "nil") \(node?.display ?? "nil"), panel \(session.panel)"
            }) {
                guard let id = session.selectedNode, let node = session.nodes[id] else { return false }
                return node.name.lowercased() == "img" && node.attributes.contains("pic")
            }

            // A second run in the same session: its elements can be revealed
            // too (the first run's holder is let go before the second's is made).
            model.mode = .snapshot
            model.start()
            try await wait("the second run", seconds: 30, state: {
                "phase \(model.phase), problem \(model.problem ?? "none"), reports \(model.reports.count)"
            }) { !model.running }
            XCTAssertNil(model.problem)
            XCTAssertEqual(model.reports.count, before + 2)
            let second = try XCTUnwrap(model.reports.last)
            XCTAssertEqual(second.mode, .snapshot)
            let button = try XCTUnwrap(Self.nodes(second.audit("button-name")).first)
            XCTAssertEqual(button.selector, "button#nameless")
            XCTAssertTrue(model.live)
            model.reveal(button.index)
            try await wait("the button from the second run, selected in Elements", seconds: 15, state: {
                let node = session.selectedNode.flatMap { session.nodes[$0] }
                return "selected \(session.selectedNode.map(String.init) ?? "nil") \(node?.display ?? "nil")"
            }) {
                guard let id = session.selectedNode, let node = session.nodes[id] else { return false }
                return node.name.lowercased() == "button" && node.attributes.contains("nameless")
            }
        } catch {
            restore(model, savedModel)
            await finish(live)
            throw error
        }
        restore(model, savedModel)
        await finish(live)
    }

    // MARK: Lighthouse: Snapshot

    private static let goodPage = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Good fixture</title>
        <meta name="description" content="A page that passes Lighthouse's accessibility and SEO audits.">
        </head>
        <body style="color: #111111; background: #ffffff">
        <main>
        <h1>Good fixture</h1>
        <img src="\(square)" alt="A blue square" width="40" height="40">
        <label for="name">Your name</label>
        <input id="name" type="text">
        <button type="button">Send</button>
        <p>Readable text on a white page.</p>
        <a href="/start">Back to the start page</a>
        </main>
        </body>
        </html>
        """

    /// CLS where WebKit has no layout-shift entries: the observer's own
    /// Layout Instability run. A 300 px banner pushed in above a 400 px
    /// block after load, in Lighthouse's 1350 × 940 desktop screen: the
    /// block's old and new boxes cover 700 of 940 rows (0.745) and it moved
    /// 300 of 1350 (0.222), a shift of about 0.165.
    func testNavigationRunEstimatesCLSFromAShiftAfterLoad() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Lighthouse start</title><p>start</p>"),
            "/shifty": .init(type: "text/html", body: """
                <!doctype html><html lang=en><title>Shifty</title><body style="margin:0">
                <div id=block style="height:400px;background:#369"></div>
                <script>addEventListener('load', () => setTimeout(() => {
                    const banner = document.createElement('div'); banner.style.height = '300px';
                    document.body.insertBefore(banner, document.getElementById('block'));
                }, 400));</script>
                """),
        ], path: "/start", title: "Lighthouse start")
        defer { live.window.close() }
        let model = DeveloperLighthouseModel.model(for: live.session)
        let savedModel = (mode: model.mode, formFactor: model.formFactor, categories: model.categories)
        defer { model.mode = savedModel.mode; model.formFactor = savedModel.formFactor; model.categories = savedModel.categories }
        do {
            try await navigate(live, to: "/shifty", title: "Shifty")
            model.mode = .navigation
            model.formFactor = .desktop
            model.categories = [.performance]
            model.start()
            try await wait("the Navigation run", seconds: 60, state: { "phase \(model.phase), problem \(model.problem ?? "none")" }) {
                !model.running
            }
            let report = try XCTUnwrap(model.reports.last)
            let cls = try XCTUnwrap(report.audit("cumulative-layout-shift"))
            XCTAssertEqual(cls.mode, .numeric, cls.explanation ?? "")
            let value = try XCTUnwrap(cls.numericValue)
            print("\(Self.label) CLS \(value): \(cls.warnings.joined())")
            XCTAssertGreaterThan(value, 0.1); XCTAssertLessThan(value, 1)
            XCTAssertTrue(cls.warnings.first?.contains("Layout Instability") ?? false, "\(cls.warnings)")
            XCTAssertNotNil(cls.score)
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    func testSnapshotOfAGoodPagePassesAccessibilityAndSEOAndCountsPerformance() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Lighthouse start</title><p>start</p>"),
            "/good": .init(type: "text/html", body: Self.goodPage),
        ], path: "/start", title: "Lighthouse start")
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let model = DeveloperLighthouseModel.model(for: session)
        let device = DeveloperDeviceMode.shared
        let saved = (on: device.on, settings: device.settings)
        let savedModel = (mode: model.mode, formFactor: model.formFactor, categories: model.categories)
        do {
            try await navigate(live, to: "/good", title: "Good fixture")
            // Snapshot mode doesn't reload: what the page holds now stays.
            _ = try await page(web, "window.perchMarker = 'kept'; return true;")
            model.mode = .snapshot
            model.formFactor = .mobile
            model.categories = Set(DeveloperLighthouseCategoryID.allCases)
            let before = model.reports.count
            model.start()
            XCTAssertTrue(model.running, "the run didn't start: \(model.problem ?? "no problem given")")
            var emulated = false
            var cacheOff = false
            try await wait("the Snapshot run", seconds: 30, state: {
                "phase \(model.phase), problem \(model.problem ?? "none"), reports \(model.reports.count)"
            }) {
                if device.on != saved.on || device.settings != saved.settings { emulated = true }
                if session.cacheDisabled { cacheOff = true }
                return !model.running
            }
            XCTAssertNil(model.problem)
            XCTAssertFalse(emulated, "Snapshot mode leaves device mode alone")
            XCTAssertFalse(cacheOff, "Snapshot mode leaves the cache alone")
            let marker = try await page(web, "return window.perchMarker || null;") as? String
            XCTAssertEqual(marker, "kept", "the page wasn't reloaded")
            XCTAssertEqual(model.reports.count, before + 1)
            let report = try XCTUnwrap(model.reports.last)
            XCTAssertEqual(report.mode, .snapshot)
            XCTAssertEqual(report.finalURL, live.server.url("/good").absoluteString)
            let failing = Self.failing(report)

            // Accessibility and SEO: every scored audit passes.
            for id in ["image-alt", "label", "button-name", "html-has-lang", "html-lang-valid", "document-title",
                       "color-contrast", "link-name", "meta-viewport", "heading-order"] {
                let audit = try XCTUnwrap(report.audit(id), id)
                XCTAssertEqual(audit.score, 1, "\(id) passes; failing: \(failing)")
                XCTAssertEqual(audit.title, DeveloperLighthouseCatalog.byID[id]?.title, id)
            }
            for id in ["meta-description", "document-title", "viewport", "is-crawlable", "link-text",
                       "crawlable-anchors", "image-alt"] {
                XCTAssertEqual(report.audit(id)?.score, 1, "\(id) passes; failing: \(failing)")
            }
            // Lighthouse runs http-status-code in Navigation mode only.
            let status = try XCTUnwrap(report.audit("http-status-code"))
            XCTAssertEqual(status.mode, .notApplicable)
            XCTAssertNil(status.score)
            XCTAssertEqual(status.explanation, "Needs a page load: run in Navigation mode.")
            for id in [DeveloperLighthouseCategoryID.accessibility, .seo] {
                let category = try XCTUnwrap(report.category(id))
                let refs = category.refs.compactMap { report.audit($0.id) }.filter(\.scored)
                XCTAssertFalse(refs.isEmpty, "\(id) has scored audits")
                XCTAssertEqual(refs.filter { !$0.passed }.map(\.id), [], "\(id)")
                XCTAssertEqual(category.score, 1, "\(id) scores 100")
            }

            // Performance: no score in Snapshot mode, passed of total instead.
            let performance = try XCTUnwrap(report.category(.performance))
            XCTAssertNil(performance.score)
            let fraction = report.fraction(performance)
            XCTAssertGreaterThan(fraction.total, 0)
            XCTAssertLessThanOrEqual(fraction.passed, fraction.total)
            XCTAssertEqual(report.audit("first-contentful-paint")?.mode, .notApplicable)
            XCTAssertEqual(report.audit("first-contentful-paint")?.explanation, "Snapshot mode doesn't measure load metrics.")
            print("\(Self.label) Snapshot Performance: \(fraction.passed)/\(fraction.total) passed")

            let data = try XCTUnwrap(DeveloperLighthouseLHR.data(report))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["gatherMode"] as? String, "snapshot")
            let performanceJSON = (json["categories"] as? [String: Any])?["performance"] as? [String: Any]
            XCTAssertTrue(performanceJSON?["score"] is NSNull)
            XCTAssertEqual((((json["categories"] as? [String: Any])?["seo"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue, 1)
        } catch {
            restore(model, savedModel)
            await finish(live)
            throw error
        }
        restore(model, savedModel)
        await finish(live)
    }

    // MARK: Lighthouse: Timespan

    /// Start timespan, then the page blocks its main thread for 300 ms and
    /// pushes a banner in above a block; End timespan audits only what
    /// happened in between, without reloading.
    func testTimespanMeasuresBlockingAndShiftsBetweenStartAndEnd() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Lighthouse start</title><p>start</p>"),
            "/span": .init(type: "text/html", body: """
                <!doctype html><html lang=en><title>Span</title><body style="margin:0">
                <div id=block style="height:400px;background:#369"></div>
                """),
        ], path: "/start", title: "Lighthouse start")
        defer { live.window.close() }
        let model = DeveloperLighthouseModel.model(for: live.session)
        let savedModel = (mode: model.mode, formFactor: model.formFactor, categories: model.categories)
        do {
            try await navigate(live, to: "/span", title: "Span")
            _ = try await page(live.page, "window.perchMarker = 'kept'; return true;")
            model.mode = .timespan
            model.formFactor = .desktop
            model.categories = Set(DeveloperLighthouseCategoryID.allCases)
            model.start()
            XCTAssertTrue(model.running, "the timespan didn't start: \(model.problem ?? "no problem given")")
            try await wait("the timespan to start", seconds: 15, state: { "phase \(model.phase)" }) {
                model.phase == .timespan || !model.running
            }
            XCTAssertEqual(model.phase, .timespan, model.problem ?? "")
            try? await Task.sleep(for: .milliseconds(300))
            _ = try await page(live.page, """
                const start = performance.now();
                while (performance.now() - start < 300) {}
                const banner = document.createElement('div'); banner.style.height = '300px';
                document.body.insertBefore(banner, document.getElementById('block'));
                return true;
                """)
            try? await Task.sleep(for: .milliseconds(800))
            model.endTimespan()
            try await wait("the timespan's audit", seconds: 30, state: {
                "phase \(model.phase), problem \(model.problem ?? "none")"
            }) { !model.running }
            XCTAssertNil(model.problem)
            let marker = try await page(live.page, "return window.perchMarker || null;") as? String
            XCTAssertEqual(marker, "kept", "the page wasn't reloaded")
            let report = try XCTUnwrap(model.reports.last)
            XCTAssertEqual(report.mode, .timespan)
            XCTAssertEqual(report.categories.map(\.id), [.performance, .bestPractices])
            XCTAssertNil(report.audit("first-contentful-paint"))
            let tbt = try XCTUnwrap(report.audit("total-blocking-time"))
            XCTAssertEqual(tbt.mode, .numeric, tbt.explanation ?? "")
            // A hidden page's timer gaps are throttling, not blocking, and
            // the test's off-screen window can count as hidden.
            if try await page(live.page, "return document.visibilityState;") as? String == "visible" {
                XCTAssertGreaterThan(tbt.numericValue ?? 0, 150, "the 300 ms task blocks about 250 ms")
            }
            let cls = try XCTUnwrap(report.audit("cumulative-layout-shift"))
            XCTAssertEqual(cls.mode, .numeric, cls.explanation ?? "")
            XCTAssertGreaterThan(cls.numericValue ?? 0, 0.05, "the banner shifted the block")
            let inp = try XCTUnwrap(report.audit("interaction-to-next-paint"))
            // No trusted input was given, so INP is never measured here.
            XCTAssertEqual(inp.mode, .notApplicable)
            print("\(Self.label) Timespan TBT \(tbt.numericValue ?? -1), CLS \(cls.numericValue ?? -1), INP: \(inp.explanation ?? "")")
            XCTAssertNil(report.category(.performance)?.score)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(DeveloperLighthouseLHR.data(report))) as? [String: Any])
            XCTAssertEqual(json["gatherMode"] as? String, "timespan")
        } catch {
            restore(model, savedModel)
            await finish(live)
            throw error
        }
        restore(model, savedModel)
        await finish(live)
    }

    // MARK: Application: Back/forward cache

    func testBackForwardCacheTestOfAPlainPageReportsWhatWebKitDid() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>BFCache start</title><p>start</p>"),
            "/plain": .init(type: "text/html", body: "<!doctype html><title>Plain page</title><p>plain</p>"),
        ], path: "/start", title: "BFCache start", shared: true)
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/plain")
        do {
            DeveloperApplicationProbe.shared.watch(web)
            try await navigate(live, to: "/plain", title: "Plain page")
            try await waitForDocument(address, in: session)
            try await waitForProbe(in: web)
            _ = try await page(web, "window.perchBefore = 'here'; return true;")

            let outcome = try await testBackForwardCache(live, address)
            print("\(Self.label) Back/forward cache, plain page: restored \(outcome.restored); reasons \(outcome.reasons.map(\.title)); caveats \(outcome.caveats)")
            XCTAssertEqual(outcome.url, address.absoluteString)
            XCTAssertEqual(web.url, address, "back on the page")
            XCTAssertEqual(web.title, "Plain page")
            // Honest: restored exactly when the document that left is the one back.
            let same = try await page(web, "return window.perchBefore || null;") as? String == "here"
            XCTAssertEqual(outcome.restored, same, "the outcome matches whether the same document came back")

            let signals = outcome.signals
            XCTAssertTrue(signals.probed)
            XCTAssertTrue(signals.early, "the early script ran ahead of the page")
            XCTAssertTrue(signals.documentRecorded)
            XCTAssertEqual(signals.status, 200)
            XCTAssertEqual(signals.method, "GET")
            XCTAssertNil(signals.cacheControl)
            XCTAssertEqual(signals.unloadListeners, 0)
            XCTAssertFalse(signals.unloadHandler)
            XCTAssertEqual(DeveloperBackForwardCacheAdvisor.reasons(signals), [], "nothing on a plain page blocks the cache")
            if outcome.restored {
                XCTAssertEqual(outcome.reasons, [])
                XCTAssertEqual(outcome.caveats, [])
            } else {
                XCTAssertEqual(outcome.reasons, [])
                XCTAssertEqual(outcome.caveats, DeveloperBackForwardCacheAdvisor.caveats(signals))
                XCTAssertTrue(outcome.caveats.first?.hasPrefix("WebKit does not report why") == true, "\(outcome.caveats)")
            }
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    func testBackForwardCacheTestListsAnUnloadHandlerAndNoStore() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>BFCache start</title><p>start</p>"),
            "/sticky": .init(type: "text/html", body: """
                <!doctype html><title>Sticky page</title><p>sticky</p>
                <script>
                window.onunload = function () {};
                addEventListener("unload", function () {});
                </script>
                """, headers: ["Cache-Control: no-store"]),
        ], path: "/start", title: "BFCache start", shared: true)
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/sticky")
        do {
            DeveloperApplicationProbe.shared.watch(web)
            try await navigate(live, to: "/sticky", title: "Sticky page")
            try await waitForDocument(address, in: session)
            try await waitForProbe(in: web)
            _ = try await page(web, "window.perchBefore = 'here'; return true;")

            let outcome = try await testBackForwardCache(live, address)
            print("\(Self.label) Back/forward cache, unload + no-store: restored \(outcome.restored); reasons \(outcome.reasons.map(\.title))")
            XCTAssertEqual(web.url, address, "back on the page")
            let same = try await page(web, "return window.perchBefore || null;") as? String == "here"
            XCTAssertEqual(outcome.restored, same, "the outcome matches whether the same document came back")

            let signals = outcome.signals
            XCTAssertTrue(signals.early, "the early script ran ahead of the page")
            XCTAssertEqual(signals.unloadListeners, 1, "addEventListener('unload')")
            XCTAssertTrue(signals.unloadHandler, "window.onunload")
            XCTAssertEqual(signals.cacheControl, "no-store")
            let expected = DeveloperBackForwardCacheAdvisor.reasons(signals)
            let titles = expected.map(\.title)
            XCTAssertTrue(titles.contains("The main document has Cache-Control: no-store"), "\(titles)")
            XCTAssertTrue(titles.contains("2 unload handlers"), "\(titles)")
            XCTAssertEqual(expected.first?.kind, .likely, "no-store first, as the likelier")
            if outcome.restored {
                // WebKit kept it anyway: the panel says so and lists nothing.
                XCTAssertEqual(outcome.reasons, [])
            } else {
                XCTAssertEqual(outcome.reasons, expected)
                XCTAssertEqual(outcome.caveats.count, 1, "only WebKit's own silence: \(outcome.caveats)")
            }
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Application: Frames

    func testFrameDetailsShowTheTreeOwnerIsolationAndGroupedResources() async throws {
        let isolation = ["Cross-Origin-Opener-Policy: same-origin", "Cross-Origin-Embedder-Policy: require-corp"]
        let live = try await openPage([
            "/frames": .init(type: "text/html", body: """
                <!doctype html><title>Frames fixture</title>
                <link rel="stylesheet" href="/frame.css">
                <script src="/frame.js"></script>
                <p>frames</p>
                <img src="/frame.svg" width="20" height="20" alt="mark">
                <iframe id="child" name="childframe" src="/child" title="Child"></iframe>
                """, headers: isolation),
            "/child": .init(type: "text/html", body: "<!doctype html><title>Child frame</title><p>child</p>",
                            headers: ["Cross-Origin-Embedder-Policy: require-corp"]),
            "/frame.css": .init(type: "text/css", body: "p { color: #222; }"),
            "/frame.js": .init(type: "text/javascript", body: "window.perchFrameScript = true;"),
            "/frame.svg": .init(type: "image/svg+xml", body: "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><rect width='20' height='20'/></svg>"),
        ])
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/frames")
        do {
            try await navigate(live, to: "/frames", title: "Frames fixture")
            try await waitAsync("the child frame to load", state: { "at \(web.url?.absoluteString ?? "nil")" }) {
                let up = try? await self.page(web, """
                    const frame = document.getElementById("child");
                    const inner = frame && frame.contentDocument;
                    return !!inner && inner.title === "Child frame" && inner.readyState === "complete"
                        && document.images[0].complete;
                    """) as? Bool
                return up == true
            }
            try await waitForDocument(address, in: session)

            // The tree, from WebKit's resource tree.
            var root: DeveloperFrameNode?
            try await waitAsync("the resource tree with the child frame and the resources", state: {
                "root \(root.map { "\($0.url), children \($0.children.map(\.url)), resources \($0.resources.map(\.url))" } ?? "nil")"
            }) {
                guard let raw = try? await session.command("Page.getResourceTree")["frameTree"] as? [String: Any] else {
                    return false
                }
                root = DeveloperFrameNode.parse(raw)
                guard let found = root else { return false }
                return found.children.count == 1 && found.resources.count >= 3
            }
            let top = try XCTUnwrap(root)
            XCTAssertEqual(top.url, address.absoluteString)
            XCTAssertEqual(top.depth, 0)
            XCTAssertEqual(top.title, "top")
            XCTAssertTrue(top.secure, "127.0.0.1 is potentially trustworthy")
            let child = try XCTUnwrap(top.children.first)
            XCTAssertEqual(child.url, live.server.url("/child").absoluteString)
            XCTAssertEqual(child.name, "childframe")
            XCTAssertEqual(child.title, "childframe")
            XCTAssertEqual(child.origin, top.origin, "same-origin")
            XCTAssertEqual(child.depth, 1)
            XCTAssertTrue(child.children.isEmpty)
            XCTAssertEqual(DeveloperFrameDetails.path(to: child.id, in: top), [0])
            XCTAssertEqual(DeveloperFrameDetails.path(to: top.id, in: top), [])

            // Resources, grouped as Chrome's folders, in Chrome's order.
            let groups = DeveloperFrameDetails.orderedGroups(top)
            let known = groups.map(\.title).filter { ["Scripts", "Stylesheets", "Images"].contains($0) }
            XCTAssertEqual(known, ["Scripts", "Stylesheets", "Images"], "\(groups.map(\.title))")
            func group(_ title: String) -> [String] { groups.first { $0.title == title }?.resources.map(\.name) ?? [] }
            XCTAssertEqual(group("Scripts"), ["frame.js"])
            XCTAssertEqual(group("Stylesheets"), ["frame.css"])
            XCTAssertEqual(group("Images"), ["frame.svg"])
            XCTAssertEqual(groups.map(\.title), groups.map(\.title).sorted {
                (DeveloperFrameDetails.folderOrder.firstIndex(of: $0) ?? 99) < (DeveloperFrameDetails.folderOrder.firstIndex(of: $1) ?? 99)
            })

            // Isolation: what the page says of itself, and what the panel shows.
            let pageIsolated = try await page(web, "return !!globalThis.crossOriginIsolated;") as? Bool
            print("\(Self.label) Frames: crossOriginIsolated with COOP same-origin + COEP require-corp: \(pageIsolated.map(String.init) ?? "nil")")
            let topContext = await DeveloperApplicationMore.frameContext(path: [], in: session, address: address)
            XCTAssertEqual(topContext.secure, true)
            XCTAssertEqual(topContext.crossOriginIsolated, pageIsolated, "the panel reports what the page says")
            XCTAssertNil(topContext.owner, "the top frame has no owner")
            let recorded = await DeveloperApplicationMore.documentDetails(address.absoluteString, in: session)
            let details = try XCTUnwrap(recorded, "Network's record of the document")
            let headers = DeveloperResponseHeaders(details.responseHeaders)
            let sections = DeveloperFrameDetails.sections(top, context: topContext, headers: headers)
            let security = try XCTUnwrap(sections.first { $0.title == "Security & Isolation" }).rows
            XCTAssertTrue(security.contains(["Cross-Origin-Opener-Policy", "same-origin"]), "\(security)")
            XCTAssertTrue(security.contains(["Cross-Origin-Embedder-Policy", "require-corp"]), "\(security)")
            XCTAssertTrue(security.contains(["Secure context", "Yes"]), "\(security)")
            XCTAssertTrue(security.contains(["Cross-origin isolated", pageIsolated == true ? "Yes" : "No"]), "\(security)")
            let document = try XCTUnwrap(sections.first { $0.title == "Document" }).rows
            XCTAssertTrue(document.contains(["Child frames", "1"]), "\(document)")
            XCTAssertTrue(document.contains(["Resources", String(top.resources.count)]), "\(document)")
            // The panel's frame view over the same frame says the same.
            let view = try await DeveloperApplication.read(.init(section: .frames, frame: top.id), in: session, address: address)
            XCTAssertTrue(view.rows.map(\.values).contains(["Cross-origin isolated", pageIsolated == true ? "Yes" : "No"]),
                          "\(view.rows.map(\.values))")

            // The child: its owner element, found through window.frames.
            let childContext = await DeveloperApplicationMore.frameContext(path: [0], in: session, address: address)
            let owner = try XCTUnwrap(childContext.owner)
            XCTAssertTrue(owner.hasPrefix("<iframe"), owner)
            XCTAssertTrue(owner.contains("id=\"child\""), owner)
            XCTAssertTrue(owner.contains("name=\"childframe\""), owner)
            XCTAssertEqual(childContext.secure, true)
            let childSections = DeveloperFrameDetails.sections(child, context: childContext, headers: nil)
            XCTAssertTrue(childSections[0].rows.contains(["Owner element", owner]), "\(childSections[0].rows)")

            // Reveal owner element: the IFRAME, selected in Elements.
            DeveloperApplicationMore.revealOwner(path: [0], in: session)
            try await wait("the iframe, selected in Elements", seconds: 15, state: {
                let node = session.selectedNode.flatMap { session.nodes[$0] }
                return "selected \(session.selectedNode.map(String.init) ?? "nil") \(node?.display ?? "nil"), panel \(session.panel)"
            }) {
                guard let id = session.selectedNode, let node = session.nodes[id] else { return false }
                return node.name.uppercased() == "IFRAME" && node.attributes.contains("child")
            }
            XCTAssertEqual(session.panel, .elements)
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Application: Storage breakdown

    func testStorageBreakdownMeasuresAtLeastWhatThePageStored() async throws {
        let live = try await openPage([
            "/storage": .init(type: "text/html", body: "<!doctype html><title>Storage fixture</title><p>storage</p>"),
        ], persistent: true)
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/storage")
        do {
            try await navigate(live, to: "/storage", title: "Storage fixture")
            let stored = try await page(web, Self.opfsWriter + """
                localStorage.setItem("perch-local", "l".repeat(2000));
                sessionStorage.setItem("perch-session", "s".repeat(1500));
                await new Promise((resolve, reject) => {
                    const open = indexedDB.open("perch-sizes", 1);
                    open.onupgradeneeded = () => open.result.createObjectStore("blobs");
                    open.onerror = () => reject(open.error);
                    open.onsuccess = () => {
                        const db = open.result;
                        const transaction = db.transaction("blobs", "readwrite");
                        transaction.objectStore("blobs").put("i".repeat(5000), "record");
                        transaction.oncomplete = () => { db.close(); resolve(); };
                        transaction.onerror = () => reject(transaction.error);
                    };
                });
                return await writeFile("sizes", "data.bin", "f".repeat(3000));
                """)
            // Where WebKit refuses the file system even in a store on disk,
            // the rest is still measured; the file system isn't asked of it.
            let wroteFile = stored as? Int == 3000
            if !wroteFile {
                print("\(Self.label) Storage: the page couldn't write its file: \(String(describing: stored))")
            }

            let overview = try await DeveloperApplication.overview(in: session, address: address)
            func size(_ name: String) -> Double? { overview.sizes.first { $0.name == name }?.bytes ?? nil }
            var expected: [(String, Double)] = [
                ("Local storage", Double(("perch-local".count + 2000) * 2)),
                ("Session storage", Double(("perch-session".count + 1500) * 2)),
                ("IndexedDB", 10_000),
            ]
            if wroteFile { expected.append(("File system", 3_000)) }
            print("\(Self.label) Storage: usage \(overview.usage.map { String($0) } ?? "nil"), sizes " + overview.sizes.map {
                "\($0.name) \($0.bytes.map { String($0) } ?? "nil")\($0.approximate ? "~" : "")"
            }.joined(separator: ", "))
            let breakdown = try XCTUnwrap(overview.breakdown)
            for (name, bytes) in expected {
                let measured = try XCTUnwrap(size(name), "\(name) was measured")
                XCTAssertGreaterThanOrEqual(measured, bytes, name)
                let segment = try XCTUnwrap(breakdown.segments.first { $0.name == name }, "\(name) in the bar")
                XCTAssertGreaterThanOrEqual(segment.bytes, bytes, name)
                XCTAssertGreaterThan(segment.fraction, 0, name)
            }
            XCTAssertGreaterThanOrEqual(breakdown.total, expected.reduce(0) { $0 + $1.1 })
            XCTAssertEqual(breakdown.segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
            XCTAssertEqual(overview.counts.first { $0.0 == "Local storage" }?.1, 1)
            XCTAssertEqual(overview.counts.first { $0.0 == "Session storage" }?.1, 1)
            XCTAssertEqual(overview.counts.first { $0.0 == "IndexedDB databases" }?.1, 1)
            if wroteFile {
                XCTAssertEqual(overview.counts.first { $0.0 == "File system entries" }?.1, 2, "the folder and its file")
            }
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Application: Origin private file system

    func testOriginPrivateFileSystemTreeSizePreviewAndDelete() async throws {
        let live = try await openPage([
            "/opfs": .init(type: "text/html", body: "<!doctype html><title>OPFS fixture</title><p>opfs</p>"),
        ], persistent: true)
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/opfs")
        let text = String(repeating: "Hello from Perch's file system test.\n", count: 12)
        do {
            try await navigate(live, to: "/opfs", title: "OPFS fixture")
            let written = try await page(web, Self.opfsWriter + "return await writeFile('notes', 'hello.txt', text);",
                                         ["text": text])
            guard written as? Int == text.utf8.count else {
                throw XCTSkip("WebKit refused the origin private file system: \(String(describing: written))")
            }

            let snapshot = try await DeveloperApplication.read(.init(section: .fileSystem), in: session, address: address)
            XCTAssertEqual(snapshot.columns.count, 4, "\(snapshot.columns)")
            XCTAssertEqual(snapshot.rows.map(\.values.first), ["notes", "    hello.txt"], "\(snapshot.rows.map(\.values))")
            let folder = try XCTUnwrap(snapshot.rows.first)
            let file = try XCTUnwrap(snapshot.rows.dropFirst().first)
            XCTAssertEqual(Array(folder.values.prefix(3)), ["notes", "Folder", String(text.utf8.count)], "a folder's size is what it holds")
            XCTAssertEqual(Array(file.values.prefix(3)), ["    hello.txt", "File", String(text.utf8.count)])
            XCTAssertNotEqual(file.values[3], "—", "the file's modified date")
            XCTAssertTrue(folder.details.contains(["Path", "/notes"]), "\(folder.details)")
            XCTAssertTrue(file.details.contains(["Path", "/notes/hello.txt"]), "\(file.details)")
            XCTAssertTrue(file.details.contains(["Preview", text]), "the preview is the file's text: \(file.details)")
            XCTAssertFalse(folder.details.contains { $0.first == "Preview" })
            XCTAssertTrue(snapshot.deletable)

            // Delete the file through the panel: the folder stays, now empty.
            let fileItem = try XCTUnwrap(file.item)
            try await DeveloperApplication.delete([fileItem], in: session)
            let afterFile = try await DeveloperApplication.read(.init(section: .fileSystem), in: session, address: address)
            XCTAssertEqual(afterFile.rows.map { Array($0.values.prefix(3)) }, [["notes", "Folder", "0"]])
            let left = try await page(web, """
                const root = await navigator.storage.getDirectory();
                const folder = await root.getDirectoryHandle("notes");
                const names = [];
                for await (const [name] of folder.entries()) names.push(name);
                return names.length;
                """) as? Int
            XCTAssertEqual(left, 0, "the file is gone from the page's own file system")

            // And the folder.
            let folderItem = try XCTUnwrap(afterFile.rows.first?.item)
            try await DeveloperApplication.delete([folderItem], in: session)
            let empty = try await DeveloperApplication.read(.init(section: .fileSystem), in: session, address: address)
            XCTAssertTrue(empty.rows.isEmpty, "\(empty.rows.map(\.values))")
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    /// `writeFile(folder, name, text)`: makes the folder and the file in the
    /// origin private file system and answers the file's size, or what went
    /// wrong. createWritable where WebKit has it, else a worker's sync
    /// access handle.
    private static let opfsWriter = """
        async function writeFile(folderName, fileName, text) {
            try {
                const root = await navigator.storage.getDirectory();
                const folder = await root.getDirectoryHandle(folderName, { create: true });
                const handle = await folder.getFileHandle(fileName, { create: true });
                if (typeof handle.createWritable === "function") {
                    const writable = await handle.createWritable();
                    await writable.write(text);
                    await writable.close();
                } else {
                    const source = `onmessage = async (event) => {
                        try {
                            const root = await navigator.storage.getDirectory();
                            const folder = await root.getDirectoryHandle(event.data.folder);
                            const handle = await folder.getFileHandle(event.data.file);
                            const access = await handle.createSyncAccessHandle();
                            const bytes = new TextEncoder().encode(event.data.text);
                            access.truncate(0);
                            access.write(bytes, { at: 0 });
                            access.flush();
                            access.close();
                            postMessage("ok");
                        } catch (error) { postMessage(String(error)); }
                    };`;
                    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: "text/javascript" })));
                    const answer = await new Promise((resolve) => {
                        worker.onmessage = (event) => resolve(event.data);
                        worker.onerror = (event) => resolve("worker error: " + event.message);
                        worker.postMessage({ folder: folderName, file: fileName, text });
                    });
                    worker.terminate();
                    if (answer !== "ok") return "worker: " + answer;
                }
                return (await handle.getFile()).size;
            } catch (error) {
                return String(error && (error.name + ": " + error.message));
            }
        }

        """

    // MARK: Application: Reporting API

    func testReportingAPIReadsTheEndpointAndTheCSPViolationReports() async throws {
        let live = try await openTab([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Reporting start</title><p>start</p>"),
            "/reporting": .init(type: "text/html", body: """
                <!doctype html><title>Reporting fixture</title>
                <p>reporting</p>
                <script>window.perchInline = true;</script>
                """, headers: [
                    "Content-Security-Policy-Report-Only: script-src 'self'; report-to csp",
                    "Reporting-Endpoints: csp=\"/reports\"",
                ]),
        ], path: "/start", title: "Reporting start", shared: true)
        defer { live.window.close() }
        let session = live.session
        let web = live.page
        let address = live.server.url("/reporting")
        do {
            DeveloperApplicationProbe.shared.watch(web)
            try await navigate(live, to: "/reporting", title: "Reporting fixture")
            try await waitForDocument(address, in: session)
            try await waitForProbe(in: web)
            let inline = try await page(web, "return window.perchInline === true;") as? Bool
            XCTAssertEqual(inline, true, "report-only: the inline script ran")
            // A second violation after the page is up, which the script hears for certain.
            let late = try await page(web, """
                const script = document.createElement("script");
                script.textContent = "window.perchLate = true;";
                document.body.appendChild(script);
                return window.perchLate === true;
                """) as? Bool
            XCTAssertEqual(late, true, "report-only: the inserted script ran")

            // The endpoint, from the document's headers as Network recorded them.
            let recorded = await DeveloperApplicationMore.documentDetails(address.absoluteString, in: session)
            let details = try XCTUnwrap(recorded, "Network's record of the document")
            let endpoints = DeveloperReportingHeaders.endpoints(DeveloperResponseHeaders(details.responseHeaders), document: address)
            XCTAssertEqual(endpoints, [DeveloperReportingEndpoint(name: "csp", url: live.server.url("/reports").absoluteString,
                                                                  source: "Reporting-Endpoints")])

            // The reports the page's ReportingObserver and violation events saw.
            var snapshot: [String: Any]?
            var reports: [DeveloperReport] = []
            try await waitAsync("a CSP violation report", seconds: 12, state: {
                "early \(String(describing: snapshot?["early"])), reports \(reports.map { "\($0.type)/\($0.source)/\($0.directive ?? "-")/\($0.blockedURL ?? "-")" })"
            }) {
                snapshot = await DeveloperApplicationProbe.snapshot(in: web)
                reports = DeveloperReport.parse(snapshot?["reports"] as? [Any] ?? [])
                return reports.filter { $0.type == "csp-violation" }.count >= 2
            }
            // A moment for the observer's batch, which can come after the events.
            try await Task.sleep(for: .milliseconds(1_500))
            snapshot = await DeveloperApplicationProbe.snapshot(in: web)
            reports = DeveloperReport.parse(snapshot?["reports"] as? [Any] ?? [])
            XCTAssertEqual(snapshot?["early"] as? Bool, true, "the reporting script ran ahead of the page")
            let violations = reports.filter { $0.type == "csp-violation" }
            print("\(Self.label) Reporting: \(reports.count) reports: " + reports.map {
                "\($0.type) via \($0.source), directive \($0.directive ?? "-"), blocked \($0.blockedURL ?? "-")"
            }.joined(separator: "; ") + "; endpoint asked: \(live.server.requests.contains("/reports"))")
            for report in violations {
                XCTAssertEqual(report.url, address.absoluteString)
                XCTAssertTrue(report.directive?.hasPrefix("script-src") == true, "\(report.body)")
                XCTAssertEqual(report.blockedURL, "inline", "\(report.body)")
                XCTAssertGreaterThan(report.time, 0)
                if let disposition = report.body.first(where: { $0[0] == "disposition" }) {
                    XCTAssertEqual(disposition[1], "report", "report-only")
                }
            }
            // Both inline scripts, each once: a violation the ReportingObserver
            // and the violation event both saw is listed as the observer's.
            XCTAssertEqual(violations.count, 2, "\(violations.map { "\($0.source) \($0.time)" })")

            // Clear reports empties the list.
            await DeveloperApplicationProbe.clearReports(in: web)
            let cleared = await DeveloperApplicationProbe.snapshot(in: web)
            XCTAssertEqual((cleared?["reports"] as? [Any])?.count, 0)
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    // MARK: Support

    private struct Live {
        let server: LocalPageServer
        let page: WKWebView
        let window: NSWindow
        let tab: Tab
        let session: DeveloperToolsSession
        let browser: Browser?
        /// DevTools opened as the app does, through DeveloperTools.shared.
        let shared: Bool
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private typealias ModelSettings = (mode: DeveloperLighthouseMode, formFactor: DeveloperLighthouseFormFactor,
                                       categories: Set<DeveloperLighthouseCategoryID>)

    /// The panel's choices are settings: put back as they were.
    private func restore(_ model: DeveloperLighthouseModel, _ saved: ModelSettings) {
        model.mode = saved.mode
        model.formFactor = saved.formFactor
        model.categories = saved.categories
    }

    /// A bare page view on `/start`, in an on-screen borderless window off
    /// to the side (a page in no window now and then stops answering the
    /// inspector), with a DevTools session attached and ready. The test
    /// then navigates, so what the tools hear comes after they're listening.
    /// `persistent` gives the page a data store of its own on disk, removed
    /// after the test: WebKit has no origin private file system in an
    /// ephemeral one ("UnknownError: The operation failed for an unknown
    /// transient reason").
    private func openPage(_ pages: [String: LocalPageServer.Page], persistent: Bool = false) async throws -> Live {
        _ = NSApplication.shared
        var all = pages
        all["/start"] = .init(type: "text/html", body: "<!doctype html><title>Application start</title><p>start</p>")
        let server = try LocalPageServer(all)
        let configuration = WKWebViewConfiguration()
        if persistent {
            let identifier = UUID()
            storeIdentifiers.append(identifier)
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = Self.window(for: page)
        page.load(URLRequest(url: server.url("/start")))
        do {
            try await wait("page to load") { page.title == "Application start" }
        } catch {
            window.close()
            throw error
        }
        let tab = Tab(shy: true)
        return try await attach(server: server, page: page, window: window, tab: tab, browser: nil,
                                session: DeveloperToolsSession(tab: tab, web: page, after: nil), shared: false)
    }

    /// A private tab of a real Browser, its page in the same kind of
    /// window, at `path`, with a DevTools session on it: Lighthouse's and
    /// the Application panel's user scripts live alongside the tab's own,
    /// which Browser swaps in at each navigation. `shared` opens DevTools
    /// as the app does, so the Application panel's early script keeps
    /// following the tab.
    private func openTab(_ pages: [String: LocalPageServer.Page], path: String, title: String,
                         shared: Bool = false) async throws -> Live {
        _ = NSApplication.shared
        let server = try LocalPageServer(pages)
        let browser = Browser(record: WindowRecord())
        browser.newShyTab()
        guard let tab = browser.active, tab.shy else {
            browser.closeAll()
            throw Failure("no private tab")
        }
        let page: WKWebView = tab.web
        let window = Self.window(for: page)
        tab.go(to: server.url(path))
        do {
            try await wait("page to load") { page.title == title && !page.isLoading }
        } catch {
            browser.closeAll()
            window.close()
            throw error
        }
        let session: DeveloperToolsSession
        if shared {
            guard DeveloperTools.shared.open(in: browser, panel: .storage), let opened = DeveloperTools.shared.session,
                  opened.web === page else {
                browser.closeAll()
                window.close()
                throw Failure("DevTools didn't open for the tab")
            }
            session = opened
        } else {
            session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        }
        return try await attach(server: server, page: page, window: window, tab: tab, browser: browser, session: session,
                                shared: shared)
    }

    private static func window(for page: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        return window
    }

    private func attach(server: LocalPageServer, page: WKWebView, window: NSWindow, tab: Tab, browser: Browser?,
                        session: DeveloperToolsSession, shared: Bool) async throws -> Live {
        watched = session
        let live = Live(server: server, page: page, window: window, tab: tab, session: session, browser: browser,
                        shared: shared)
        do {
            try await wait("inspector") { session.ready }
        } catch {
            await finish(live)
            live.window.close()
            throw error
        }
        return live
    }

    /// Closes DevTools fully, then lets the run loop settle with the page,
    /// its tab, the browser and the window all still alive; then the
    /// browser's tabs are closed, and it settles again before anything is
    /// let go (see DeveloperTestSupport). A store of the test's own loses
    /// its data here and is removed in tearDown, once its page is gone.
    private func finish(_ live: Live) async {
        DeveloperApplicationProbe.shared.stop()
        if live.shared, DeveloperTools.shared.session === live.session {
            await DeveloperTools.shared.close()?.value
        }
        await DeveloperTestSupport.finish(live.session, page: live.page, keeping: live.tab, live.server, live.window,
                                          live.browser as Any)
        let store = live.page.configuration.websiteDataStore
        if store.isPersistent {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        if let browser = live.browser {
            browser.closeAll()
            for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(60)) }
            withExtendedLifetime((browser, live.tab, live.page, live.window)) {}
        }
    }

    /// Data stores made for one test, removed once their pages are gone.
    private var storeIdentifiers: [UUID] = []

    override func tearDown() async throws {
        for identifier in storeIdentifiers {
            // The page's process lets the store go a moment after the view.
            for attempt in 0..<10 {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                    break
                } catch {
                    if attempt == 9 { print("\(Self.label) data store \(identifier) not removed: \(error)") }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        storeIdentifiers = []
        try await super.tearDown()
    }

    /// The panel's back/forward cache test. What it threw is recorded
    /// before teardown, whose reports can stand in for it in XCTest's log,
    /// with where the page was.
    private func testBackForwardCache(_ live: Live, _ address: URL) async throws -> DeveloperBackForwardCacheOutcome {
        let web = live.page
        do {
            return try await DeveloperApplicationMore.testBackForwardCache(in: live.session, address: address)
        } catch {
            let back = web.backForwardList
            let message = "testBackForwardCache threw \((error as? LocalizedError)?.errorDescription ?? "\(error)"): "
                + "at \(web.url?.absoluteString ?? "nil"), loading \(web.isLoading), canGoBack \(web.canGoBack), "
                + "back \(back.backList.map(\.url.absoluteString)), current \(back.currentItem?.url.absoluteString ?? "nil"), "
                + "session web \(live.session.web === web), ready \(live.session.ready)"
            print("\(Self.label) Back/forward cache: \(message)")
            XCTFail(message)
            throw error
        }
    }

    /// Loads `path` and waits for it; a nil title is a page without one.
    private func navigate(_ live: Live, to path: String, title: String?) async throws {
        live.page.load(URLRequest(url: live.server.url(path)))
        try await wait("\(path) to load", seconds: 15, state: {
            "at \(live.page.url?.absoluteString ?? "nil"), title \(live.page.title ?? "nil"), loading \(live.page.isLoading)"
        }) {
            live.page.url?.path() == path && (title == nil || live.page.title == title) && !live.page.isLoading
        }
    }

    /// Until Network has the document's request, whose headers the panels read.
    private func waitForDocument(_ address: URL, in session: DeveloperToolsSession) async throws {
        try await wait("Network's record of \(address.path())", state: {
            "requests \(session.requests.map { "\($0.type) \($0.url)" }.suffix(6))"
        }) {
            session.requests.contains { $0.url == address.absoluteString && $0.status != nil }
        }
    }

    /// Until the Application panel's early script answers in the page.
    private func waitForProbe(in web: WKWebView) async throws {
        try await waitAsync("the Application panel's script in the page") {
            await DeveloperApplicationProbe.snapshot(in: web) != nil
        }
    }

    private func page(_ page: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    private static func nodes(_ audit: DeveloperLighthouseAudit?) -> [DeveloperLighthouseNode] {
        (audit?.details?.items ?? []).compactMap { item in
            if case .node(let node)? = item["node"] { return node }
            return nil
        }
    }

    private static func selectors(_ audit: DeveloperLighthouseAudit?) -> [String] { nodes(audit).map(\.selector) }

    private static func urls(_ audit: DeveloperLighthouseAudit?) -> [String] {
        (audit?.details?.items ?? []).compactMap { item in
            if case .url(let url)? = item["url"] { return url }
            return nil
        }
    }

    /// The scored audits that failed, for messages.
    private static func failing(_ report: DeveloperLighthouseReport) -> String {
        report.audits.values.filter { $0.scored && !$0.passed }.map { "\($0.id) \($0.score ?? -1)" }.sorted()
            .joined(separator: ", ")
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperLighthouseApplicationLiveTests", state: { [watched] in
            var parts: [String] = []
            if let watched {
                parts.append("ready \(watched.ready), message \(watched.message ?? "none")")
            }
            if let state { parts.append(state()) }
            return parts.joined(separator: "; ")
        }, until: condition)
    }

    /// As `wait`, for a condition that has to ask the page.
    private func waitAsync(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                           until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if await condition() { return }
        try await wait(action, seconds: 0, state: state) { false }
    }
}
