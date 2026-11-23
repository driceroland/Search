import XCTest
@testable import Search

/// Lantern's arithmetic, as Perch implements Lighthouse's simulated
/// throttling: TCP's handshakes and slow start, connection reuse per
/// origin, DNS, CPU slowdown, the load's graph, the metrics' blends, and the
/// estimates a Navigation run's metric audits take. Also View treemap's tree
/// and layout.
final class DeveloperLighthouseLanternTests: XCTestCase {
    private typealias Lantern = DeveloperLighthouseLantern
    private typealias Request = DeveloperLighthouseLantern.Request
    private typealias CPUTask = DeveloperLighthouseLantern.CPUTask

    private let mobile = Lantern.Settings.mobileSlow4G

    private func connection(warmed: Bool = false, ssl: Bool = false, server: Double = 0) -> Lantern.Connection {
        Lantern.Connection(rtt: 150, throughput: mobile.throughput, serverLatency: server, ssl: ssl, h2: false, warmed: warmed)
    }

    private func document(_ bytes: Double = 1_000) -> Request {
        Request(url: "http://a.test/", resourceType: "Document", start: 0, end: 50, transferSize: bytes, isMainDocument: true)
    }

    // MARK: TCP

    func testThroughputCapsTheCongestionWindow() {
        XCTAssertEqual(Lantern.maximumSaturatedConnections(rtt: 150, throughput: mobile.throughput), 21)
        XCTAssertEqual(Lantern.maximumSaturatedConnections(rtt: 40, throughput: Lantern.Settings.desktopDense4G.throughput), 35)
    }

    func testAColdConnectionPaysTheHandshakeAndTLS() {
        // SYN, SYN ACK, ACK with the request, then the response's way back: two round trips.
        XCTAssertEqual(Lantern.download(connection(), bytes: 1_000).timeElapsed, 300, accuracy: 1e-9)
        // TLS with False Start adds one.
        XCTAssertEqual(Lantern.download(connection(ssl: true), bytes: 1_000).timeElapsed, 450, accuracy: 1e-9)
        // DNS and the server's time come on top.
        XCTAssertEqual(Lantern.download(connection(server: 30), bytes: 1_000, dnsResolutionTime: 300).timeElapsed,
                       630, accuracy: 1e-9)
    }

    func testAWarmConnectionSkipsTheHandshake() {
        XCTAssertEqual(Lantern.download(connection(warmed: true), bytes: 1_000).timeElapsed, 150, accuracy: 1e-9)
    }

    func testSlowStartDoublesTheWindowEachRoundTrip() {
        // The first 10 segments (14,600 bytes) come with the first byte; the
        // rest takes another round trip, with the window doubled to 20.
        let download = Lantern.download(connection(), bytes: 20_000)
        XCTAssertEqual(download.timeElapsed, 450, accuracy: 1e-9)
        XCTAssertEqual(download.congestionWindow, 20)
        XCTAssertEqual(download.bytesDownloaded, 20_000)
    }

    // MARK: The simulator

    func testTheDocumentAloneTakesDNSHandshakeAndServerTime() throws {
        let graph = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: []))
        let simulation = Lantern.simulate(graph, nodes: graph.all, settings: mobile)
        // DNS 2 RTT (300) + handshake and request (225) + server (30, the default) + response (75).
        XCTAssertEqual(simulation.timeInMs, 630, accuracy: 1e-6)
    }

    func testAWarmConnectionIsReusedOnTheSameOrigin() throws {
        var script = Request(url: "http://a.test/app.js", resourceType: "Script", start: 60, end: 100, transferSize: 1_000)
        script.initiatorURL = "http://a.test/"
        script.connectionReused = true
        let reused = try XCTUnwrap(Lantern.graph(requests: [document(), script], tasks: []))
        // 630 for the document, then a round trip and the server on its warm connection.
        XCTAssertEqual(Lantern.simulate(reused, nodes: reused.all, settings: mobile).timeInMs, 810, accuracy: 1e-6)

        script.connectionReused = false
        let fresh = try XCTUnwrap(Lantern.graph(requests: [document(), script], tasks: []))
        // A new connection's handshake, the host already resolved.
        XCTAssertEqual(Lantern.simulate(fresh, nodes: fresh.all, settings: mobile).timeInMs, 960, accuracy: 1e-6)
    }

    func testCPUTasksAreSlowedDownAndLayoutByHalfAsMuch() throws {
        let task = CPUTask(start: 60, end: 160)
        let graph = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: [task]))
        XCTAssertEqual(Lantern.simulate(graph, nodes: graph.all, settings: mobile).timeInMs, 630 + 400, accuracy: 1e-6)

        var layout = task
        layout.didLayout = true
        let laidOut = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: [layout]))
        XCTAssertEqual(Lantern.simulate(laidOut, nodes: laidOut.all, settings: mobile).timeInMs, 630 + 200, accuracy: 1e-6)

        // Desktop doesn't slow the CPU.
        let desktop = Lantern.Settings.desktopDense4G
        let fast = Lantern.simulate(graph, nodes: graph.all, settings: desktop)
        XCTAssertEqual(fast.timings[1].map { $0.duration } ?? 0, 100, accuracy: 1e-6)
    }

    // MARK: The graph

    func testRequestsAndTasksAreLinkedAsLanternLinksThem() throws {
        var script = Request(url: "http://a.test/app.js", resourceType: "Script", start: 60, end: 110, transferSize: 1_000)
        script.initiatorURL = "http://a.test/"
        var xhr = Request(url: "http://a.test/api", resourceType: "XHR", start: 130, end: 200, transferSize: 100)
        xhr.initiatorType = "script"
        var image = Request(url: "http://a.test/i.png", resourceType: "Image", start: 70, end: 90, transferSize: 100)
        image.initiatorURL = "http://elsewhere.test/unknown.js"
        let tasks = [
            CPUTask(start: 120, end: 150, scriptURLs: ["http://a.test/app.js"], installs: ["timer:1"]),
            CPUTask(start: 300, end: 340, fires: "timer:1"),
        ]
        let graph = try XCTUnwrap(Lantern.graph(requests: [document(), script, xhr, image], tasks: tasks))
        XCTAssertEqual(graph.root, 0)
        XCTAssertEqual(graph.nodes[1].dependencies, [0], "The script, on the document that asked for it")
        XCTAssertEqual(graph.nodes[3].dependencies, [0], "An unknown initiator leaves it on the document")
        XCTAssertEqual(graph.nodes[4].dependencies, [1], "The task, on the script it evaluated")
        XCTAssertEqual(graph.nodes[2].dependencies, [0, 4], "The XHR, on the document (no initiator) and the task that sent it")
        XCTAssertEqual(graph.nodes[5].dependencies, [4], "The timer, on the task that installed it")
    }

    func testShortTasksArePrunedAndTheirEdgesPassThrough() throws {
        let tasks = [
            CPUTask(start: 60, end: 65, installs: ["timer:1"]),
            CPUTask(start: 100, end: 200, fires: "timer:1"),
        ]
        let graph = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: tasks))
        XCTAssertEqual(graph.nodes.count, 2, "The 5 ms task goes")
        XCTAssertEqual(graph.nodes[1].dependencies, [0], "Its dependent takes its dependency")
        XCTAssertEqual(graph.task(1)?.start, 100)
    }

    func testTheTimelinesTopLevelRecordsBecomeTasks() {
        typealias Timing = DeveloperToolsSession.Timing
        let tasks = Lantern.tasks(fromTimeline: [
            Timing(type: "EvaluateScript", start: 1.0, end: 1.2, depth: 0, data: ["url": "http://a.test/app.js"]),
            Timing(type: "Layout", start: 1.1, end: 1.15, depth: 1),
            Timing(type: "TimerInstall", start: 1.12, end: 1.12, depth: 1, data: ["timerId": "3"]),
            Timing(type: "NetworkRequest", start: 1.0, end: 3.0, depth: 0),
            Timing(type: "TimerFire", start: 2.0, end: 2.1, depth: 0, data: ["timerId": "3"]),
        ])
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first?.scriptURLs, ["http://a.test/app.js"])
        XCTAssertEqual(tasks.first?.didLayout, true)
        XCTAssertEqual(tasks.first?.installs, ["timer:3"])
        XCTAssertEqual(tasks.last?.fires, "timer:3")
    }

    // MARK: Metrics

    func testFirstContentfulPaintWaitsForRenderBlockingRequestsOnly() throws {
        var css = Request(url: "http://a.test/s.css", resourceType: "Stylesheet", start: 60, end: 100, transferSize: 1_000)
        css.initiatorURL = "http://a.test/"
        css.renderBlocking = true
        var image = Request(url: "http://a.test/i.png", resourceType: "Image", start: 60, end: 120, transferSize: 50_000)
        image.initiatorURL = "http://a.test/"
        let graph = try XCTUnwrap(Lantern.graph(requests: [document(), css, image], tasks: []))
        let estimates = Lantern.estimates(graph, observed: .init(fcp: 150), settings: mobile)
        // The document (630), then the stylesheet on a new connection (330); the image isn't waited for.
        XCTAssertEqual(estimates.fcp.optimistic, 960, accuracy: 1e-6)
        XCTAssertEqual(estimates.fcp.pessimistic, 960, accuracy: 1e-6)
        XCTAssertEqual(estimates.fcp.value, 960, accuracy: 1e-6)
        XCTAssertNil(estimates.lcp, "No LCP was observed")
        XCTAssertGreaterThanOrEqual(estimates.speedIndex?.value ?? 0, estimates.fcp.value)
    }

    func testSpeedIndexCoefficientsScaleWithTheRoundTrip() {
        let slow = Lantern.speedIndexCoefficients(rtt: 150)
        XCTAssertEqual(slow.intercept, -250, accuracy: 1e-9)
        XCTAssertEqual(slow.optimistic, 1.4, accuracy: 1e-9)
        XCTAssertEqual(slow.pessimistic, 0.65, accuracy: 1e-9)
        let fast = Lantern.speedIndexCoefficients(rtt: 40)
        XCTAssertEqual(fast.intercept, -250 / 12, accuracy: 1e-9)
        XCTAssertEqual(fast.optimistic, 0.575, accuracy: 1e-9)
        XCTAssertEqual(fast.pessimistic, 0.5125, accuracy: 1e-9)
        XCTAssertEqual(slow.blend(1_000, 2_000), -250 + 1_400 + 1_300, accuracy: 1e-9)
        // A positive intercept is scaled down for loads under a second.
        XCTAssertEqual(Lantern.Coefficients(intercept: 100, optimistic: 1, pessimistic: 0).blend(500, 0), 550, accuracy: 1e-9)
    }

    func testLayoutBasedSpeedIndexWeighsLayoutsByTheLogOfTheirLength() throws {
        let tasks = [
            CPUTask(start: 0, end: 8, didLayout: true),
            CPUTask(start: 100, end: 116, didLayout: true),
        ]
        let graph = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: tasks))
        let simulation = Lantern.Simulation(timeInMs: 1_016, timings: [
            1: .init(start: 0, end: 8), 2: .init(start: 1_000, end: 1_016),
        ])
        // (log2(8) × max(8, 500) + log2(16) × 1016) / (3 + 4)
        XCTAssertEqual(Lantern.layoutBasedSpeedIndex(graph, simulation, fcp: 500), (3 * 500 + 4 * 1_016) / 7, accuracy: 1e-9)
    }

    func testBlockingTimeCountsTheSimulatedTasksBetweenFCPAndTTI() throws {
        let graph = try XCTUnwrap(Lantern.graph(requests: [document()], tasks: [CPUTask(start: 60, end: 140)]))
        let simulation = Lantern.Simulation(timeInMs: 1_300, timings: [1: .init(start: 1_000, end: 1_300)])
        XCTAssertEqual(Lantern.blockingTime(graph, simulation, from: 900, to: 2_000), 250, accuracy: 1e-9)
        XCTAssertEqual(Lantern.blockingTime(graph, simulation, from: 1_100, to: 2_000), 150, accuracy: 1e-9)
        XCTAssertEqual(Lantern.blockingTime(graph, simulation, from: 2_000, to: 1_000), 0)
    }

    // MARK: A run

    private func input(throttling: DeveloperLighthouseThrottling) -> DeveloperLighthouseInput {
        var page = DeveloperLighthousePage()
        page.url = "http://a.test/"
        let request = DeveloperLighthouseRequest(url: "http://a.test/", type: "Document", mimeType: "text/html", status: 200,
                                                 transferSize: 1_000, startedAt: 100, endedAt: 100.05, receivedAt: 100.02)
        var metrics = DeveloperLighthouseMetrics(fcp: 60, ttfb: 20)
        metrics.responseStart = 20
        var input = DeveloperLighthouseInput(mode: .navigation, formFactor: .mobile, categories: [.performance],
                                             requestedURL: page.url, page: page, requests: [request], metrics: metrics, issues: [])
        input.throttling = throttling
        return input
    }

    func testANavigationRunsFCPIsSimulated() throws {
        let estimates = try XCTUnwrap(Lantern.estimate(for: input(throttling: .simulated)))
        XCTAssertEqual(estimates.fcp.value, 630, accuracy: 1e-6)
        XCTAssertFalse(estimates.fromTrace)

        let report = DeveloperLighthouseRules.report(input(throttling: .simulated))
        let fcp = try XCTUnwrap(report.audit("first-contentful-paint"))
        XCTAssertEqual(fcp.numericValue ?? 0, 630, accuracy: 1e-6)
        XCTAssertTrue(fcp.warnings.contains { $0.hasPrefix("Simulated") })
        XCTAssertEqual(report.throttling, .simulated)
        XCTAssertNotNil(report.simulation)
        let settings = try XCTUnwrap(DeveloperLighthouseLHR.object(report)["configSettings"] as? [String: Any])
        XCTAssertEqual(settings["throttlingMethod"] as? String, "simulate")

        let unthrottled = DeveloperLighthouseRules.report(input(throttling: .none))
        XCTAssertEqual(unthrottled.audit("first-contentful-paint")?.numericValue, 60)
        XCTAssertNil(unthrottled.simulation)
    }

    // MARK: View treemap

    func testTheTreemapSplitsAScriptByItsMapsModules() throws {
        // Three sources starting at columns 0, 40 and 70 of one line.
        let map = try DeveloperSourceMap(json: [
            "version": 3,
            "sources": ["webpack:///src/a.js", "webpack:///src/lib/b.js", "webpack:///node_modules/x/index.js"],
            "mappings": "AAAA,wCCAA,8BCAA",
        ], base: nil)
        let script = DeveloperLighthouseTreemap.Script(url: "http://a.test/app.js", text: String(repeating: "x", count: 100), map: map)
        let coverage = [DeveloperCoverageMath.Entry(url: "http://a.test/app.js", kind: .javaScript, total: 100, unused: 25)]
        let roots = DeveloperLighthouseTreemap.nodes([script], coverage: coverage)
        let root = try XCTUnwrap(roots.first)
        XCTAssertEqual(root.resourceBytes, 100)
        XCTAssertEqual(root.unusedBytes, 25)
        XCTAssertEqual(root.children.map(\.name), ["src", "node_modules/x/index.js"])
        XCTAssertEqual(root.children.first?.children.map(\.name), ["a.js", "lib/b.js"])
        XCTAssertEqual(root.children.first?.resourceBytes, 70)
    }

    func testTheSquarifiedLayoutKeepsEachAreaInProportion() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rect = CGRect(x: 0, y: 0, width: 6, height: 4)
        let frames = DeveloperLighthouseTreemap.squarify(values, in: rect)
        XCTAssertEqual(frames.count, values.count)
        for (value, frame) in zip(values, frames) {
            XCTAssertEqual(Double(frame.width * frame.height), value, accuracy: 1e-6)
            XCTAssertTrue(rect.insetBy(dx: -1e-6, dy: -1e-6).contains(frame))
        }
    }
}

final class DeveloperLighthouseTreemapSizeTests: XCTestCase {
    func testSmallScriptsKeepTheirSize() {
        XCTAssertEqual(DeveloperLighthouseTreemapView.size(300), "300 B")
        XCTAssertEqual(DeveloperLighthouseTreemapView.size(1536), "1.5 KiB")
        XCTAssertEqual(DeveloperLighthouseTreemapView.size(20 * 1024), "20 KiB")
    }
}
