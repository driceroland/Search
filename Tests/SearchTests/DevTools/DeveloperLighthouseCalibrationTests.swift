import XCTest
@testable import Search

/// Where Perch's Lighthouse numbers were checked against Chrome's on the
/// same workload: Total Blocking Time from WebKit's task bounds, which
/// issues cost Best Practices, the viewport in the report, and what the
/// Performance monitor's rows count.
final class DeveloperLighthouseCalibrationTests: XCTestCase {
    private typealias Lantern = DeveloperLighthouseLantern

    /// A run whose page clock starts at timeline second 100 (the document's
    /// response came at 100.02 s, 20 ms into the page's clock).
    private func input(trace: [Lantern.CPUTask]?) -> DeveloperLighthouseInput {
        var page = DeveloperLighthousePage()
        page.url = "http://a.test/"
        let request = DeveloperLighthouseRequest(url: "http://a.test/", type: "Document", mimeType: "text/html", status: 200,
                                                 transferSize: 1_000, startedAt: 100, endedAt: 100.05, receivedAt: 100.02)
        var metrics = DeveloperLighthouseMetrics(fcp: 60, taskSource: .eventLoopGaps, ttfb: 20)
        metrics.responseStart = 20
        var input = DeveloperLighthouseInput(mode: .navigation, formFactor: .desktop, categories: [.performance],
                                             requestedURL: page.url, page: page, requests: [request], metrics: metrics, issues: [])
        input.traceTasks = trace
        return input
    }

    func testBlockingTimeCountsTasksJustOverTheCutoffOnly() throws {
        // The TBT fixture's tasks: 45, 49, 51, 55, 80 and 120 ms, from 100 ms
        // in, 30 ms apart. Over 50 ms: 1 + 5 + 30 + 70 = 106 (Chrome: 107).
        var at = 100.1
        var trace: [Lantern.CPUTask] = []
        for ms in [45.0, 49, 51, 55, 80, 120] {
            trace.append(.init(start: at, end: at + ms / 1_000))
            at += ms / 1_000 + 0.030
        }
        let tasks = try XCTUnwrap(Lantern.pageTasks(input(trace: trace)))
        XCTAssertEqual(tasks.first?.start ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(tasks.map { $0.duration.rounded() }, [45, 49, 51, 55, 80, 120])
        XCTAssertEqual(DeveloperLighthouseMetrics.totalBlockingTime(tasks, after: 60), 106, accuracy: 1e-6)
        // The timer loop's gaps hold each task plus the 4 ms nested-timer clamp:
        // 49 ms tasks start counting, and the total runs long.
        let gaps = tasks.map { (start: $0.start, duration: $0.duration + 4) }
        XCTAssertEqual(DeveloperLighthouseMetrics.totalBlockingTime(gaps, after: 60), 125, accuracy: 1e-6)
        // A 50 ms task blocks for nothing.
        XCTAssertEqual(DeveloperLighthouseMetrics.totalBlockingTime([(start: 100, duration: 50)], after: 60), 0)
    }

    func testTraceTasksNeedADocumentToPlaceThem() {
        XCTAssertNil(Lantern.pageTasks(input(trace: nil)))
        var placeless = input(trace: [.init(start: 100.1, end: 100.2)])
        placeless.requests = []
        XCTAssertNil(Lantern.pageTasks(placeless))
        // Work from before the navigation isn't the load's.
        XCTAssertEqual(Lantern.pageTasks(input(trace: [.init(start: 99, end: 99.5), .init(start: 100.1, end: 100.2)]))?.count, 1)
    }

    func testOnlyLighthousesIssueTypesCostBestPractices() {
        XCTAssertFalse(DeveloperIssueCode.formInputWithNoLabel.countsInLighthouse)
        XCTAssertFalse(DeveloperIssueCode.ariaInvalidRole.countsInLighthouse)
        XCTAssertFalse(DeveloperIssueCode.corsAllowOrigin.countsInLighthouse)
        XCTAssertFalse(DeveloperIssueCode.quirksMode.countsInLighthouse)
        XCTAssertTrue(DeveloperIssueCode.mixedContent.countsInLighthouse)
        XCTAssertTrue(DeveloperIssueCode.cspInline.countsInLighthouse)
        XCTAssertTrue(DeveloperIssueCode.cookieSameSiteNoneInsecure.countsInLighthouse)
        XCTAssertTrue(DeveloperIssueCode.coepCorpMissing.countsInLighthouse)

        var run = input(trace: nil)
        run.categories = [.bestPractices]
        run.issues = [DeveloperLighthouseIssue(title: "No label associated with a form field", category: "Generic", count: 1,
                                               deprecation: false, scored: false)]
        XCTAssertEqual(DeveloperLighthouseRules.inspectorIssues(run).score, 1)
        run.issues?.append(DeveloperLighthouseIssue(title: "Mixed content", category: "Mixed Content", count: 2, deprecation: false))
        let failed = DeveloperLighthouseRules.inspectorIssues(run)
        XCTAssertEqual(failed.score, 0)
        XCTAssertEqual(failed.details?.items.count, 1)
    }

    func testTheReportRecordsTheViewportThePageHad() throws {
        var run = input(trace: nil)
        run.page.viewportWidth = 1_350
        run.page.viewportHeight = 940
        run.page.devicePixelRatio = 2
        let report = DeveloperLighthouseRules.report(run)
        XCTAssertEqual(report.viewport?.summary, "1350×940 CSS px at 2×")
        let environment = try XCTUnwrap(DeveloperLighthouseLHR.object(report)["environment"] as? [String: Any])
        let viewport = try XCTUnwrap(environment["viewport"] as? [String: Any])
        XCTAssertEqual(viewport["width"] as? Double, 1_350)
        XCTAssertEqual(viewport["devicePixelRatio"] as? Double, 2)
        XCTAssertTrue(DeveloperLighthouseHTML.html(report).contains("1350×940 CSS px at 2×"))
        XCTAssertNil(DeveloperLighthouseRules.report(input(trace: nil)).viewport)
    }

    func testTheMonitorSaysElementsAndExplainsTheHeap() {
        XCTAssertEqual(DeveloperPerformanceMetric.domNodes.title, "DOM elements")
        // Saved settings keep Chrome's name.
        XCTAssertEqual(DeveloperPerformanceMetric.domNodes.rawValue, "DOM Nodes")
        XCTAssertEqual(DeveloperPerformanceMetric.cpu.title, "CPU usage")
        XCTAssertTrue(DeveloperPerformanceMetric.jsHeap.about.contains("ArrayBuffer"))
        XCTAssertTrue(DeveloperPerformanceMetric.domNodes.about.contains("Text and comment nodes"))
    }
}
