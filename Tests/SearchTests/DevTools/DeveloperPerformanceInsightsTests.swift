import XCTest
@testable import Search

/// Performance › Insights: each check's findings over a hand-built
/// recording, and the request details the recording keeps for them.
final class DeveloperPerformanceInsightsTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Insights = DeveloperPerformanceInsights

    private func request(_ url: String, _ type: String, _ start: Double, _ end: Double,
                         _ extra: [String: String] = [:]) -> Timing {
        Timing(type: "NetworkRequest", start: start, end: end,
               data: extra.merging(["url": url, "resourceType": type]) { $1 })
    }

    /// A page load: its document, a stylesheet and a 3rd party script that
    /// held up the first paint, the LCP image, a script that forced a
    /// layout, shifts, and a slow click.
    private var load: DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/", "Document", 0, 0.5,
                    ["responseOffset": "300", "encoding": "br", "transferSize": "5000", "status": "200", "protocol": "h2",
                     "contentType": "text/html; charset=utf-8"]),
            request("https://example.com/app.css", "Stylesheet", 0.35, 0.6,
                    ["transferSize": "2000", "initiator": "https://example.com/", "initiatorType": "parser"]),
            request("https://cdn.thirdparty.net/lib.js", "Script", 0.4, 0.7, ["transferSize": "20000"]),
            request("https://example.com/hero.jpg", "Image", 0.8, 1.2),
            Timing(type: "PageTiming", start: 0.9, end: 0.9, data: ["kind": "FCP", "name": "First Contentful Paint"]),
            Timing(type: "PageTiming", start: 1.5, end: 1.5, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
            Timing(type: "LayoutShift", start: 1.0, end: 1.0, data: ["score": "0.08", "index": "0", "nodes": "img#hero"]),
            Timing(type: "LayoutShift", start: 1.3, end: 1.3, data: ["score": "0.05", "index": "1", "nodes": "p.intro\nimg#hero"]),
            Timing(type: "FunctionCall", start: 2.0, end: 2.1, data: ["scriptName": "https://cdn.thirdparty.net/lib.js"]),
            // Layout from inside script: a forced reflow.
            Timing(type: "Layout", start: 2.05, end: 2.07, depth: 1, stack: ["measure (app.js:10)"]),
            // Layout on its own isn't.
            Timing(type: "Layout", start: 3.0, end: 3.01),
            Timing(type: "EventDispatch", start: 4.0, end: 4.3, data: ["type": "click"]),
            Timing(type: "PageInfo", start: 5, end: 5,
                   data: ["url": "https://example.com/", "lcpURL": "https://example.com/hero.jpg",
                          "domElements": "1600", "domDepth": "20", "domChildren": "30", "lcpTag": "IMG",
                          "viewport": "\"width=device-width\"", "pageImages": "[]", "fontFaces": "[]"]),
        ])
    }

    private func insight(_ kind: DeveloperPerformanceInsight.Kind, _ insights: [DeveloperPerformanceInsight]) throws
        -> DeveloperPerformanceInsight {
        try XCTUnwrap(insights.first { $0.kind == kind }, "no \(kind) insight")
    }

    private func failed(_ insight: DeveloperPerformanceInsight) -> Bool {
        if case .fail = insight.verdict { return true }
        return false
    }

    private func passed(_ insight: DeveloperPerformanceInsight) -> Bool {
        if case .pass = insight.verdict { return true }
        return false
    }

    func testPageInfoAndRequestDetailsReachTheProfile() throws {
        let profile = load
        XCTAssertFalse(profile.events.contains { $0.type == "PageInfo" })
        XCTAssertEqual(profile.pageInfo["domElements"], "1600")
        let document = try XCTUnwrap(Insights.mainDocument(profile))
        XCTAssertEqual(document.url, "https://example.com/")
        XCTAssertEqual(try XCTUnwrap(document.responseStart), 300, accuracy: 1e-6)
        XCTAssertEqual(document.encoding, "br")
        XCTAssertEqual(document.transferSize, 5000)
    }

    func testLCPBreakdownSplitsLCPIntoItsPhases() throws {
        let lcp = try insight(.lcpBreakdown, Insights.all(load))
        XCTAssertTrue(passed(lcp), "1.5 s is a good LCP")
        XCTAssertEqual(lcp.headline, "LCP 1.5 s")
        XCTAssertEqual(lcp.rows.map(\.label),
                       ["Time to first byte", "Resource load delay", "Resource load duration", "Element render delay"])
        let lengths = lcp.ranges.map { $0.upperBound - $0.lowerBound }
        XCTAssertEqual(lengths.count, 4)
        for (length, expected) in zip(lengths, [300.0, 500, 400, 300]) { XCTAssertEqual(length, expected, accuracy: 1e-6) }

        // A text LCP, with no image to load: the first byte, then rendering.
        let text = DeveloperPerformanceProfile([
            request("https://example.com/", "Document", 0, 0.5, ["responseOffset": "1000"]),
            Timing(type: "PageTiming", start: 3, end: 3, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
        ])
        let slow = try XCTUnwrap(Insights.lcpBreakdown(text))
        XCTAssertTrue(failed(slow), "3 s is a poor LCP")
        XCTAssertEqual(slow.rows.map(\.label), ["Time to first byte", "Element render delay"])
        XCTAssertEqual(slow.rows.map(\.value), ["500 ms", "2.5 s"], "the response can't come after the request ended")

        // Without the page load, there's no breakdown.
        let late = DeveloperPerformanceProfile([
            Timing(type: "PageTiming", start: 3, end: 3, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
        ])
        let info = try XCTUnwrap(Insights.lcpBreakdown(late))
        XCTAssertTrue(info.rows.isEmpty)
        XCTAssertNil(Insights.lcpBreakdown(DeveloperPerformanceProfile()))
    }

    func testRenderBlockingRequestsFinishedBeforeFirstContentfulPaint() throws {
        let blocking = try insight(.renderBlocking, Insights.all(load))
        XCTAssertTrue(failed(blocking))
        XCTAssertEqual(blocking.headline, "2 requests")
        XCTAssertEqual(blocking.rows.map(\.label), ["lib.js", "app.css"], "longest first")
        XCTAssertEqual(blocking.rows.map(\.value), ["300 ms", "250 ms"])
        XCTAssertEqual(blocking.ranges.count, 2)

        // One still loading when the page painted didn't hold it up.
        let late = DeveloperPerformanceProfile([
            request("https://example.com/late.css", "Stylesheet", 0.1, 2),
            Timing(type: "PageTiming", start: 1, end: 1, data: ["kind": "FCP", "name": "First Contentful Paint"]),
        ])
        XCTAssertTrue(passed(try XCTUnwrap(Insights.renderBlocking(late))))
    }

    func testLongTasksCountTotalBlockingTimeAndWhatRan() throws {
        let profile = load
        let long = try insight(.longTasks, Insights.all(profile))
        XCTAssertTrue(failed(long))
        XCTAssertEqual(Insights.totalBlockingTime(profile), 300, accuracy: 1e-6)
        XCTAssertEqual(long.headline, "2 long tasks · total blocking time 300 ms")
        XCTAssertEqual(long.rows.map(\.label), ["Event: click", "Function call — lib.js"])
        XCTAssertEqual(long.rows.map(\.value), ["300 ms", "100 ms"])
        XCTAssertEqual(long.rows[1].detail, "Layout")
        XCTAssertEqual(long.events.count, 2)
    }

    func testForcedReflowIsLayoutInsideScript() throws {
        let profile = load
        let reflows = Insights.forcedReflows(profile)
        XCTAssertEqual(reflows.count, 1)
        XCTAssertEqual(reflows.first?.source, "measure (app.js:10)")
        let forced = try insight(.forcedReflow, Insights.all(profile))
        XCTAssertTrue(failed(forced))
        XCTAssertEqual(forced.headline, "Total reflow time 20 ms")
        XCTAssertEqual(forced.rows.first?.label, "measure (app.js:10)")
        let event = try XCTUnwrap(forced.rows.first?.event)
        XCTAssertEqual(profile.events[event].type, "Layout")
        XCTAssertEqual(profile.events[event].start, 2_050, accuracy: 1e-6)
    }

    func testLayoutShiftCulpritsAreTheWorstClustersNodes() throws {
        let profile = load
        let shifts = try insight(.layoutShifts, Insights.all(profile))
        XCTAssertTrue(failed(shifts), "0.13 is over 0.1")
        XCTAssertEqual(shifts.headline, "Worst cluster 0.1300")
        XCTAssertEqual(shifts.rows.count, 2)
        XCTAssertEqual(Insights.culprits(profile), ["img#hero", "p.intro"])
    }

    func testINPBreakdownIsTheSlowestInteractionsPhases() throws {
        let inp = try insight(.inpBreakdown, Insights.all(load))
        XCTAssertTrue(failed(inp), "300 ms is over 200 ms")
        XCTAssertEqual(inp.headline, "click 300 ms")
        XCTAssertEqual(inp.rows.map(\.label), ["Input delay", "Processing duration", "Presentation delay"])
        XCTAssertEqual(inp.rows.map(\.value), ["0 ms", "300 ms", "0 ms"])
        XCTAssertEqual(inp.rows.map(\.failing), [false, true, false], "the longest phase is the one to look at")
        XCTAssertNil(Insights.inpBreakdown(DeveloperPerformanceProfile()))
    }

    func testThirdPartiesGroupTransferAndMainThreadTimeBySite() throws {
        let profile = load
        let usage = Insights.thirdPartyUsage(profile)
        XCTAssertEqual(usage.map(\.site), ["thirdparty.net"])
        let party = try XCTUnwrap(usage.first)
        XCTAssertEqual(party.transferSize, 20_000)
        XCTAssertEqual(party.requests, 1)
        // The script's own time, the layout it forced aside.
        XCTAssertEqual(party.mainThreadTime, 80, accuracy: 1e-6)
        let third = try insight(.thirdParties, Insights.all(profile))
        XCTAssertEqual(third.rows.first?.value, "20.0 kB · 80 ms")

        XCTAssertEqual(Insights.site("a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(Insights.site("www.example.com"), "example.com")
        XCTAssertEqual(Insights.site("localhost"), "localhost")
        XCTAssertEqual(Insights.site("192.168.0.10"), "192.168.0.10")
    }

    func testDocumentRequestLatencyChecksRedirectsServerAndCompression() throws {
        let quick = try insight(.documentLatency, Insights.all(load))
        XCTAssertTrue(passed(quick))
        XCTAssertEqual(quick.rows.map(\.label), ["Avoids redirects", "Server responds quickly", "Applies text compression"])

        let slow = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 3),
            request("https://example.com/", "Document", 0.2, 1.5,
                    ["redirects": "2", "redirectOffset": "200", "responseOffset": "900", "status": "200",
                     "transferSize": "40000"]),
        ])
        let latency = try XCTUnwrap(Insights.documentLatency(slow))
        XCTAssertTrue(failed(latency))
        XCTAssertEqual(latency.rows.map(\.label), ["Had redirects", "Server responded slowly", "No compression applied"])
        XCTAssertTrue(latency.rows.allSatisfy(\.failing))
        XCTAssertEqual(latency.rows[0].value, "2 · 200 ms")
        XCTAssertEqual(try XCTUnwrap(latency.ranges.first).lowerBound, 0, accuracy: 1e-6, "from the first redirect")
        // A tiny document needn't be compressed.
        let tiny = DeveloperPerformanceProfile([
            request("https://example.com/", "Document", 0, 0.1, ["responseOffset": "50", "transferSize": "600"]),
        ])
        XCTAssertTrue(passed(try XCTUnwrap(Insights.documentLatency(tiny))))
    }

    func testDOMSizeFailsOverChromesLimits() throws {
        let dom = try insight(.domSize, Insights.all(load))
        XCTAssertTrue(failed(dom))
        XCTAssertEqual(dom.headline, "1,600 elements")
        XCTAssertEqual(dom.rows.map(\.failing), [true, false, false])
        XCTAssertNil(Insights.domSize(DeveloperPerformanceProfile()))
    }

    func testFailingInsightsComeFirst() throws {
        let insights = Insights.all(load)
        let firstPass = try XCTUnwrap(insights.firstIndex { passed($0) })
        XCTAssertFalse(insights[firstPass...].contains { failed($0) })
        // Without the page's scripts there is nothing to judge JavaScript by.
        XCTAssertEqual(Set(insights.map(\.kind)),
                       Set(DeveloperPerformanceInsight.Kind.allCases).subtracting([.duplicatedJavaScript, .legacyJavaScript]))
    }

    func testTheRecordingKeepsResponseDetailsAndRedirects() throws {
        var recording = DeveloperPerformanceNetworkRecording()
        recording.capture("Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 10.0, "type": "Document", "request": ["url": "http://example.com/"],
        ], targetID: nil)
        recording.capture("Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 10.1, "type": "Document", "request": ["url": "https://example.com/"],
            "redirectResponse": ["status": 301],
        ], targetID: nil)
        recording.capture("Network.responseReceived", params: [
            "requestId": "1", "timestamp": 10.3, "type": "Document",
            "response": ["status": 200, "mimeType": "text/html", "headers": ["Content-Encoding": "gzip"]],
        ], targetID: nil)
        recording.capture("Network.dataReceived", params: [
            "requestId": "1", "timestamp": 10.4, "dataLength": 9000, "encodedDataLength": 1000,
        ], targetID: nil)
        recording.capture("Network.loadingFinished", params: [
            "requestId": "1", "timestamp": 10.5,
            "metrics": ["responseHeaderBytesReceived": 200, "responseBodyBytesReceived": 3000],
        ], targetID: nil)
        let timings = recording.timings(from: 10, to: 11)
        XCTAssertEqual(timings.count, 2)
        let hop = try XCTUnwrap(timings.first { $0.data["redirect"] == "true" })
        XCTAssertEqual(hop.data["url"], "http://example.com/")
        let moved = try XCTUnwrap(timings.first { $0.data["redirect"] == nil })
        XCTAssertEqual(moved.data["encoding"], "gzip")
        XCTAssertEqual(moved.data["status"], "200")
        XCTAssertEqual(moved.data["transferSize"], "3200")
        XCTAssertEqual(moved.data["redirects"], "1")
        XCTAssertEqual(try XCTUnwrap(Double(moved.data["responseOffset"] ?? "")), 200, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(Double(moved.data["redirectOffset"] ?? "")), 100, accuracy: 1e-6)

        let profile = DeveloperPerformanceProfile(timings)
        let document = try XCTUnwrap(Insights.mainDocument(profile))
        XCTAssertEqual(document.url, "https://example.com/")
        XCTAssertEqual(document.redirects, 1)
        XCTAssertEqual(Insights.navigationStart(document), 0, accuracy: 1e-6)
    }
}
