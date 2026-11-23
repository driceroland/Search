import XCTest
@testable import Search

/// Performance › Insights' delivery checks (DeveloperPerformanceInsightsDelivery):
/// LCP request discovery, the network dependency tree, image delivery,
/// font display, cache lifetimes, the viewport and modern HTTP, each over
/// a hand-built recording, and the request details the recording keeps
/// for them.
final class DeveloperPerformanceInsightsDeliveryTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Insights = DeveloperPerformanceInsights

    private func request(_ url: String, _ type: String, _ start: Double, _ end: Double,
                         _ extra: [String: String] = [:]) -> Timing {
        Timing(type: "NetworkRequest", start: start, end: end,
               data: extra.merging(["url": url, "resourceType": type]) { $1 })
    }

    private func info(_ data: [String: String]) -> Timing {
        Timing(type: "PageInfo", start: 5, end: 5, data: data.merging(["url": "https://example.com/"]) { $1 })
    }

    private func json(_ value: [[String: Any]]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private let document = ["responseOffset": "200", "status": "200", "protocol": "h2", "source": "network"]

    private func failed(_ insight: DeveloperPerformanceInsight?) -> Bool {
        if case .fail = insight?.verdict { return true }
        return false
    }

    private func passed(_ insight: DeveloperPerformanceInsight?) -> Bool {
        if case .pass = insight?.verdict { return true }
        return false
    }

    // MARK: LCP request discovery

    private func lcpLoad(_ page: [String: String], image: [String: String]) -> DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/", "Document", 0, 0.4, document),
            request("https://example.com/hero.jpg", "Image", 0.9, 1.2, image),
            Timing(type: "PageTiming", start: 1.5, end: 1.5, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
            info(page.merging(["lcpURL": "https://example.com/hero.jpg"]) { $1 }),
        ])
    }

    func testLCPRequestDiscoveryChecksPriorityDiscoveryAndLazyLoading() throws {
        let bad = try XCTUnwrap(Insights.lcpDiscovery(lcpLoad(
            ["lcpTag": "IMG", "lcpLoading": "lazy"],
            image: ["initiatorType": "script", "initiator": "https://example.com/app.js"])))
        XCTAssertTrue(failed(bad))
        XCTAssertEqual(bad.rows.prefix(3).map(\.failing), [true, true, true])
        // From the document's first byte (200 ms) to the image's request (900 ms).
        XCTAssertEqual(bad.headline, "Est savings 700 ms")

        let good = try XCTUnwrap(Insights.lcpDiscovery(lcpLoad(
            ["lcpTag": "IMG", "lcpLoading": "", "lcpFetchPriority": "high"],
            image: ["initiatorType": "parser", "initiator": "https://example.com/"])))
        XCTAssertTrue(passed(good))
        XCTAssertEqual(good.rows.prefix(3).map(\.failing), [false, false, false])
        XCTAssertEqual(good.headline, "hero.jpg")

        // A preload makes it discoverable whoever asked; a stylesheet's background isn't.
        let preloaded = lcpLoad(["lcpTag": "DIV", "lcpPreloaded": "true"], image: ["initiatorType": "other"])
        XCTAssertTrue(Insights.isDiscoverable(Insights.request(for: "https://example.com/hero.jpg", in: preloaded),
                                              document: Insights.mainDocument(preloaded), profile: preloaded))
        let background = lcpLoad(["lcpTag": "DIV", "lcpInitiator": "css"], image: [:])
        XCTAssertFalse(Insights.isDiscoverable(Insights.request(for: "https://example.com/hero.jpg", in: background),
                                               document: Insights.mainDocument(background), profile: background))

        // A recording from before these were read has no card.
        XCTAssertNil(Insights.lcpDiscovery(lcpLoad([:], image: [:])))
    }

    // MARK: Network dependency tree

    func testNetworkDependencyTreeFollowsInitiatorsFromTheDocument() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/", "Document", 0, 0.3, document),
            request("https://example.com/app.css", "Stylesheet", 0.35, 0.6,
                    ["initiatorType": "parser", "initiator": "https://example.com/"]),
            request("https://example.com/font.woff2", "Font", 0.65, 0.9,
                    ["initiatorType": "parser", "initiator": "https://example.com/app.css"]),
            // Low priority, an image: not critical.
            request("https://example.com/later.js", "Script", 0.4, 0.5,
                    ["initiatorType": "parser", "initiator": "https://example.com/", "priority": "low"]),
            request("https://example.com/hero.jpg", "Image", 0.4, 0.8,
                    ["initiatorType": "parser", "initiator": "https://example.com/"]),
            Timing(type: "PageTiming", start: 1.5, end: 1.5, data: ["kind": "LCP", "name": "Largest Contentful Paint"]),
        ])
        let chains = Insights.criticalChains(profile)
        XCTAssertEqual(chains.map { profile.network[$0.request].url },
                       ["https://example.com/", "https://example.com/app.css", "https://example.com/font.woff2"])
        XCTAssertEqual(chains.map(\.depth), [0, 1, 2])
        let tree = try XCTUnwrap(Insights.networkDependencyTree(profile))
        XCTAssertTrue(failed(tree), "a chain two deep")
        XCTAssertEqual(tree.headline, "Max critical path latency 900 ms")
        XCTAssertEqual(tree.rows.map(\.label), ["", "  ", "    "].enumerated().map { index, indent in
            indent + ["example.com", "app.css", "font.woff2"][index]
        })
        XCTAssertTrue(tree.rows.allSatisfy(\.failing))

        // Without initiators there's no tree to draw.
        let plain = DeveloperPerformanceProfile([request("https://example.com/", "Document", 0, 0.3)])
        XCTAssertNil(Insights.networkDependencyTree(plain))
    }

    // MARK: Improve image delivery

    func testImageDeliveryFindsOversizedLegacyFormatAndGIFImages() throws {
        let images: [[String: Any]] = [
            // 2000×1000 shown at 400×200 on a 2× screen.
            ["src": "https://example.com/big.jpg", "nw": 2000, "nh": 1000, "dw": 400, "dh": 200],
            // 100×100 WebP, about right.
            ["src": "https://example.com/small.webp", "nw": 100, "nh": 100, "dw": 100, "dh": 100],
        ]
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/", "Document", 0, 0.3, document),
            request("https://example.com/big.jpg", "Image", 0.4, 0.9, ["mimeType": "image/jpeg", "transferSize": "500000"]),
            request("https://example.com/small.webp", "Image", 0.4, 0.5, ["mimeType": "image/webp", "transferSize": "1500"]),
            request("https://example.com/anim.gif", "Image", 0.4, 1.0, ["mimeType": "image/gif", "transferSize": "300000"]),
            request("https://example.com/logo.svg", "Image", 0.4, 0.5, ["mimeType": "image/svg+xml", "transferSize": "90000"]),
            info(["pageImages": json(images), "devicePixelRatio": "2"]),
        ])
        let findings = Insights.imageFindings(profile)
        XCTAssertEqual(findings.map(\.url), ["https://example.com/big.jpg", "https://example.com/anim.gif"])
        let big = findings[0]
        XCTAssertEqual(big.reasons.count, 2, "a modern format and a smaller size")
        // Resizing to 800×400 of 2000×1000 saves 84% of it; the larger of the two.
        XCTAssertEqual(big.wasted, 500_000 * (1 - 320_000.0 / 2_000_000), accuracy: 1)
        XCTAssertTrue(findings[1].reasons[0].contains("video"))
        let insight = try XCTUnwrap(Insights.imageDelivery(profile))
        XCTAssertTrue(failed(insight))
        XCTAssertEqual(insight.rows.count, 2)
        XCTAssertTrue(insight.headline?.hasPrefix("Est savings") == true)
    }

    /// Reloaded, the image comes from the cache: little or nothing is
    /// transferred, but it is as oversized as ever.
    func testImageDeliveryJudgesACachedImageByItsOwnSize() throws {
        let images: [[String: Any]] = [["src": "http://127.0.0.1/big.png", "nw": 1200, "nh": 1200, "dw": 40, "dh": 40]]
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("http://127.0.0.1/", "Document", 0, 0.3, document),
            request("http://127.0.0.1/big.png", "Image", 0.4, 0.5,
                    ["mimeType": "image/png", "transferSize": "0", "decodedSize": "21480", "source": "memory-cache"]),
            info(["pageImages": json(images), "devicePixelRatio": "2"]),
        ])
        let findings = Insights.imageFindings(profile)
        XCTAssertEqual(findings.map(\.url), ["http://127.0.0.1/big.png"])
        XCTAssertTrue(failed(try XCTUnwrap(Insights.imageDelivery(profile))))
    }

    // MARK: Font display

    func testFontDisplayFlagsFontsThatHideText() throws {
        let faces: [[String: Any]] = [
            ["family": "\"Brand\"", "display": "auto", "urls": ["https://example.com/brand.woff2"]],
            ["family": "Body", "display": "swap", "urls": ["https://example.com/body.woff2"]],
            ["family": "Quick", "display": "fallback", "urls": ["https://example.com/quick.woff2"]],
        ]
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/brand.woff2", "Font", 0.5, 1.3),
            request("https://example.com/body.woff2", "Font", 0.5, 1.0),
            request("https://example.com/quick.woff2", "Font", 0.5, 0.8),
            info(["fontFaces": json(faces)]),
        ])
        let insight = try XCTUnwrap(Insights.fontDisplay(profile))
        XCTAssertTrue(failed(insight))
        XCTAssertEqual(insight.rows.map(\.label), ["brand.woff2", "quick.woff2"])
        // The load (800 ms) under auto's 3 s block; fallback blocks 100 ms at most.
        XCTAssertEqual(insight.rows.map(\.value), ["800 ms", "100 ms"])
        XCTAssertEqual(insight.rows[0].detail, "font-display: auto · Brand")
        XCTAssertEqual(insight.headline, "Est savings 800 ms")

        XCTAssertTrue(passed(Insights.fontDisplay(DeveloperPerformanceProfile([info(["fontFaces": "[]"])]))))
        XCTAssertNil(Insights.fontDisplay(DeveloperPerformanceProfile([info([:])])))
    }

    // MARK: Use efficient cache lifetimes

    func testCacheLifetimesFlagShortLivedStaticResources() throws {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 5),
            request("https://example.com/", "Document", 0, 0.3, document),
            request("https://example.com/app.js", "Script", 0.4, 0.6,
                    ["status": "200", "transferSize": "10000", "cacheControl": "max-age=600", "source": "network"]),
            request("https://example.com/hero.jpg", "Image", 0.4, 0.9,
                    ["status": "200", "transferSize": "40000", "source": "network"]),
            // A year: fine. no-store: meant not to be cached.
            request("https://example.com/vendor.js", "Script", 0.4, 0.6,
                    ["status": "200", "transferSize": "90000", "cacheControl": "public, max-age=31536000"]),
            request("https://example.com/private.css", "Stylesheet", 0.4, 0.6,
                    ["status": "200", "transferSize": "5000", "cacheControl": "no-store"]),
        ])
        let findings = Insights.cacheFindings(profile)
        XCTAssertEqual(findings.map(\.url), ["https://example.com/hero.jpg", "https://example.com/app.js"])
        XCTAssertEqual(findings.map(\.lifetime), [0, 600])
        // No lifetime: a repeat visit never finds it, so all of it is wasted.
        XCTAssertEqual(findings[0].wasted, 40_000, accuracy: 1e-6)
        let insight = try XCTUnwrap(Insights.cacheLifetimes(profile))
        XCTAssertTrue(failed(insight))
        XCTAssertEqual(insight.rows.map(\.value), ["None · 40.0 kB", "10 m · 10.0 kB"])

        // A recording without the headers can't say.
        XCTAssertNil(Insights.cacheLifetimes(DeveloperPerformanceProfile([
            request("https://example.com/app.js", "Script", 0, 1, ["status": "200"]),
        ])))
    }

    // MARK: Optimize viewport for mobile

    func testViewportNeedsWidthDeviceWidth() throws {
        func viewport(_ content: String?) -> DeveloperPerformanceInsight? {
            // As the page sends it: the content as JSON, null without the tag.
            Insights.viewport(DeveloperPerformanceProfile([info(["viewport": content.map { "\"\($0)\"" } ?? "null"])]))
        }
        XCTAssertTrue(passed(viewport("width=device-width, initial-scale=1")))
        XCTAssertTrue(failed(viewport("width=1024")))
        let missing = try XCTUnwrap(viewport(nil))
        XCTAssertTrue(failed(missing))
        XCTAssertEqual(missing.headline, "No viewport meta tag")
        XCTAssertNil(Insights.viewport(DeveloperPerformanceProfile([info([:])])))
    }

    // MARK: Modern HTTP

    func testModernHTTPFlagsOriginsWithSeveralHTTP1Requests() throws {
        var timings = [Timing(type: "RecordingBounds", start: 0, end: 5),
                       request("https://example.com/", "Document", 0, 0.3, document)]
        for index in 0..<6 {
            timings.append(request("https://static.example.com/\(index).js", "Script", 0.4, 0.6, ["protocol": "http/1.1"]))
        }
        // Fewer than six from an origin, a cached one, and a local server aren't counted.
        for index in 0..<3 {
            timings.append(request("https://few.example.net/\(index).png", "Image", 0.4, 0.6, ["protocol": "http/1.1"]))
            timings.append(request("http://localhost:8080/\(index).js", "Script", 0.4, 0.6, ["protocol": "http/1.1"]))
            timings.append(request("http://localhost:8080/\(index + 3).js", "Script", 0.4, 0.6, ["protocol": "http/1.1"]))
        }
        let profile = DeveloperPerformanceProfile(timings)
        let origins = Insights.legacyOrigins(profile)
        XCTAssertEqual(origins.map(\.origin), ["https://static.example.com"])
        let insight = try XCTUnwrap(Insights.modernHTTP(profile))
        XCTAssertTrue(failed(insight))
        XCTAssertEqual(insight.headline, "6 requests over HTTP/1.1")
        XCTAssertEqual(insight.rows.first?.detail, "http/1.1")

        let modern = DeveloperPerformanceProfile([request("https://example.com/", "Document", 0, 0.3, document)])
        XCTAssertTrue(passed(Insights.modernHTTP(modern)))
        XCTAssertNil(Insights.modernHTTP(DeveloperPerformanceProfile([request("https://example.com/", "Document", 0, 1)])))
    }

    // MARK: The recording

    func testAMemoryCacheHitTakesItsSizeFromContentLength() throws {
        var recording = DeveloperPerformanceNetworkRecording()
        recording.capture("Network.requestServedFromMemoryCache", params: [
            "requestId": "4", "timestamp": 10.1,
            "resource": ["url": "https://example.com/big.png", "type": "Image",
                         "response": ["status": 200, "mimeType": "image/png",
                                      "headers": ["Content-Length": "21480"]]],
        ], targetID: nil)
        let image = try XCTUnwrap(recording.timings(from: 10, to: 11).first { $0.data["url"] == "https://example.com/big.png" })
        XCTAssertEqual(image.data["decodedSize"], "21480")
        XCTAssertEqual(image.data["source"], "memory-cache")
    }

    func testTheRecordingKeepsCacheProtocolAndInitiatorDetails() throws {
        var recording = DeveloperPerformanceNetworkRecording()
        recording.capture("Network.requestWillBeSent", params: [
            "requestId": "2", "timestamp": 10.0, "type": "Script", "request": ["url": "https://example.com/app.js"],
            "initiator": ["type": "parser", "url": "https://example.com/"],
        ], targetID: nil)
        recording.capture("Network.responseReceived", params: [
            "requestId": "2", "timestamp": 10.2, "type": "Script",
            "response": ["status": 200, "mimeType": "text/javascript", "source": "network",
                         "headers": ["Cache-Control": "max-age=60", "Expires": "Thu, 01 Jan 1970 00:00:00 GMT"]],
        ], targetID: nil)
        recording.capture("Network.loadingFinished", params: [
            "requestId": "2", "timestamp": 10.5,
            "metrics": ["protocol": "h2", "priority": "high", "responseBodyBytesReceived": 300,
                        "responseBodyDecodedSize": 900],
        ], targetID: nil)
        recording.capture("Network.requestWillBeSent", params: [
            "requestId": "3", "timestamp": 10.3, "type": "Image", "request": ["url": "https://example.com/a.png"],
            "initiator": ["type": "script", "stackTrace": ["callFrames": [["url": ""], ["url": "https://example.com/app.js"]]]],
        ], targetID: nil)
        let timings = recording.timings(from: 10, to: 11)
        let script = try XCTUnwrap(timings.first { $0.data["url"] == "https://example.com/app.js" })
        XCTAssertEqual(script.data["cacheControl"], "max-age=60")
        XCTAssertEqual(script.data["protocol"], "h2")
        XCTAssertEqual(script.data["priority"], "high")
        XCTAssertEqual(script.data["initiatorType"], "parser")
        XCTAssertEqual(script.data["initiator"], "https://example.com/")
        XCTAssertEqual(script.data["decodedSize"], "900")
        let image = try XCTUnwrap(timings.first { $0.data["url"] == "https://example.com/a.png" })
        XCTAssertEqual(image.data["initiator"], "https://example.com/app.js")

        let bar = try XCTUnwrap(DeveloperPerformanceProfile(timings).network.first { $0.url.hasSuffix("app.js") })
        XCTAssertEqual(bar.cacheHeaders["cache-control"], "max-age=60")
        XCTAssertEqual(bar.networkProtocol, "h2")
        XCTAssertEqual(bar.decodedSize, 900)
    }

    func testThePagesInsightFactsReachTheProfile() throws {
        let page: [String: Any] = [
            "url": "https://example.com/", "viewport": "\"width=device-width\"", "pageImages": "[]",
            "fontFaces": "[]", "lcpTag": "IMG", "ignored": "x",
        ]
        let timings = DeveloperPerformancePageTimings.timings(page, sync: (page: 0, timeline: 0), bounds: 0...1)
        let info = try XCTUnwrap(timings.first { $0.type == "PageInfo" })
        XCTAssertEqual(info.data["viewport"], "\"width=device-width\"")
        XCTAssertEqual(info.data["lcpTag"], "IMG")
        XCTAssertNil(info.data["ignored"])
        let profile = DeveloperPerformanceProfile(timings)
        XCTAssertEqual(DeveloperPerformanceInsightsPage.viewport(profile.pageInfo), .some("width=device-width"))
    }
}
