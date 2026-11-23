import Foundation
import XCTest
@testable import Search

/// The Application panel's Back/forward cache, Reporting API, Frames and
/// Storage additions: their header parsing, blocker guesses and storage math
/// (DeveloperApplicationMore.swift).
final class DeveloperApplicationMoreTests: XCTestCase {
    private func headers(_ pairs: [[String]]) -> DeveloperResponseHeaders { DeveloperResponseHeaders(pairs: pairs) }

    // MARK: Header parsing

    func testHeaderValuesAreCaseInsensitiveAndFoldRepeats() {
        let list = headers([["Cache-Control", "no-cache"], ["cache-control", "no-store"], ["X", "1"]])
        XCTAssertEqual(list.value("CACHE-CONTROL"), "no-cache, no-store")
        XCTAssertNil(list.value("Missing"))
    }

    func testSplitKeepsQuotedAndBracketedSeparators() {
        XCTAssertEqual(DeveloperHeaderParsing.split(#"a="x,y", b=(1 2), {"c":[1,2]}"#, at: ","),
                       [#"a="x,y""#, "b=(1 2)", #"{"c":[1,2]}"#])
        XCTAssertEqual(DeveloperHeaderParsing.unquoted(#""a\"b""#), #"a"b"#)
        XCTAssertEqual(DeveloperHeaderParsing.unquoted("plain"), "plain")
    }

    func testCacheControlDirectives() {
        XCTAssertEqual(DeveloperHeaderParsing.cacheDirectives("private, No-Store, max-age=0"), ["private", "no-store", "max-age"])
        XCTAssertEqual(DeveloperHeaderParsing.cacheDirectives(nil), [])
    }

    func testIsolationPolicies() {
        let coop = DeveloperHeaderParsing.isolationPolicy(#"same-origin; report-to="coop-endpoint""#)
        XCTAssertEqual(coop?.value, "same-origin")
        XCTAssertEqual(coop?.reportTo, "coop-endpoint")
        let coep = DeveloperHeaderParsing.isolationPolicy("Require-Corp")
        XCTAssertEqual(coep?.value, "require-corp")
        XCTAssertNil(coep?.reportTo)
        XCTAssertNil(DeveloperHeaderParsing.isolationPolicy(nil))
        XCTAssertNil(DeveloperHeaderParsing.isolationPolicy("  "))
    }

    func testContentSecurityPolicyDirectives() {
        let policies = DeveloperHeaderParsing.contentSecurityPolicy("default-src 'self'; Script-Src 'self' cdn.example; upgrade-insecure-requests, img-src *")
        XCTAssertEqual(policies.count, 2)
        XCTAssertEqual(policies[0].map(\.name), ["default-src", "script-src", "upgrade-insecure-requests"])
        XCTAssertEqual(policies[0][1].value, "'self' cdn.example")
        XCTAssertEqual(policies[0][2].value, "")
        XCTAssertEqual(policies[1].first?.name, "img-src")
    }

    func testPermissionsPolicyAndFeaturePolicy() {
        let modern = DeveloperHeaderParsing.permissionsPolicy(#"camera=(), geolocation=(self "https://maps.example"), fullscreen=*"#)
        XCTAssertEqual(modern.map(\.feature), ["camera", "geolocation", "fullscreen"])
        XCTAssertEqual(modern.map(\.allowlist), ["none", "self https://maps.example", "*"])
        let legacy = DeveloperHeaderParsing.permissionsPolicy("camera 'none'; Microphone 'self' https://a.example", legacy: true)
        XCTAssertEqual(legacy.map(\.feature), ["camera", "microphone"])
        XCTAssertEqual(legacy.map(\.allowlist), ["'none'", "'self' https://a.example"])
    }

    // MARK: Reporting API

    func testReportingEndpointsFromEveryHeader() {
        let document = URL(string: "https://site.example/app/page")!
        let list = headers([
            ["Reporting-Endpoints", #"default="https://reports.example/main", csp="/csp-reports""#],
            ["Report-To", #"{"group":"old","max_age":10886400,"endpoints":[{"url":"https://old.example/r"}]}, {"max_age":1,"endpoints":[{"url":"rel"}]}"#],
            ["Content-Security-Policy", "default-src 'self'; report-uri /csp-legacy https://other.example/r"],
            ["Content-Security-Policy-Report-Only", "img-src *; report-uri /csp-legacy"],
        ])
        let endpoints = DeveloperReportingHeaders.endpoints(list, document: document)
        XCTAssertEqual(endpoints.map(\.name), ["default", "csp", "old", "default", "report-uri", "report-uri"])
        XCTAssertEqual(endpoints.map(\.url), [
            "https://reports.example/main", "https://site.example/csp-reports", "https://old.example/r",
            "https://site.example/app/rel", "https://site.example/csp-legacy", "https://other.example/r",
        ])
        XCTAssertEqual(endpoints.map(\.source), ["Reporting-Endpoints", "Reporting-Endpoints", "Report-To", "Report-To",
                                                 "CSP report-uri", "CSP report-uri"])
    }

    func testMalformedReportToIsIgnored() {
        let endpoints = DeveloperReportingHeaders.endpoints(headers([["Report-To", "{not json"]]), document: nil)
        XCTAssertTrue(endpoints.isEmpty)
    }

    func testReportsFlattenBodiesAndDropEchoedViolations() {
        let raw: [Any] = [
            ["type": "deprecation", "url": "https://a.example/", "time": 1000, "source": "ReportingObserver",
             "body": ["id": "WebSQL", "message": "Gone soon", "lineNumber": 12, "nested": ["x": "y"], "empty": NSNull()]],
            ["type": "csp-violation", "url": "https://a.example/", "time": 2000, "source": "ReportingObserver",
             "body": ["blockedURL": "https://evil.example/x.js", "effectiveDirective": "script-src-elem"]],
            ["type": "csp-violation", "url": "https://a.example/", "time": 2500, "source": "securitypolicyviolation",
             "body": ["blockedURL": "https://evil.example/x.js", "effectiveDirective": "script-src-elem"]],
            ["type": "csp-violation", "url": "https://a.example/", "time": 9000, "source": "securitypolicyviolation",
             "body": ["blockedURL": "inline", "effectiveDirective": "style-src-attr"]],
        ]
        let reports = DeveloperReport.parse(raw)
        XCTAssertEqual(reports.map(\.type), ["deprecation", "csp-violation", "csp-violation"])
        XCTAssertEqual(reports[0].body, [["id", "WebSQL"], ["lineNumber", "12"], ["message", "Gone soon"], ["nested.x", "y"]])
        XCTAssertEqual(reports[1].source, "ReportingObserver")
        XCTAssertEqual(reports[2].blockedURL, "inline")
    }

    // MARK: Back/forward cache

    func testSignalsFromProbePageAndDocument() {
        let document = DeveloperRequestDetails([
            "url": "https://a.example/", "method": "POST",
            "response": ["status": 200, "headers": [["Cache-Control", "private, no-store"]]],
        ])
        let signals = DeveloperBackForwardCacheSignals(
            probe: ["early": true, "unload": 2, "beforeunload": 1, "sockets": 1, "peers": 0, "capture": 0,
                    "channels": 1, "transactions": 3],
            page: ["onunload": true, "media": 1, "opener": false], document: document)
        XCTAssertTrue(signals.probed)
        XCTAssertTrue(signals.early)
        XCTAssertEqual(signals.unloadListeners, 2)
        XCTAssertTrue(signals.unloadHandler)
        XCTAssertEqual(signals.openSockets, 1)
        XCTAssertEqual(signals.activeTransactions, 3)
        XCTAssertEqual(signals.playingMedia, 1)
        XCTAssertEqual(signals.cacheControl, "private, no-store")
        XCTAssertEqual(signals.method, "POST")
        XCTAssertTrue(signals.documentRecorded)

        let reasons = DeveloperBackForwardCacheAdvisor.reasons(signals)
        XCTAssertEqual(reasons.first?.kind, .likely)
        XCTAssertTrue(reasons[0].title.contains("no-store"))
        XCTAssertTrue(reasons.contains { $0.title.contains("POST") })
        XCTAssertTrue(reasons.contains { $0.title == "3 unload handlers" })
        XCTAssertTrue(reasons.contains { $0.title == "1 open WebSocket" })
        XCTAssertTrue(reasons.contains { $0.title == "3 IndexedDB transactions in progress" })
        XCTAssertTrue(reasons.contains { $0.title == "1 open BroadcastChannel" })
        XCTAssertTrue(reasons.contains { $0.title.contains("beforeunload") })
        XCTAssertTrue(reasons.contains { $0.title.contains("playing") })
        XCTAssertFalse(reasons.contains { $0.title.contains("opener") })
        // Likely reasons come before possible ones they were found after.
        let kinds = reasons.map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(2)), [.likely, .likely])

        XCTAssertEqual(DeveloperBackForwardCacheAdvisor.caveats(signals).count, 1)
    }

    func testCleanPageHasNoReasonsButSaysWhatItCouldNotSee() {
        let signals = DeveloperBackForwardCacheSignals(probe: nil, page: nil, document: nil)
        XCTAssertFalse(signals.probed)
        XCTAssertTrue(DeveloperBackForwardCacheAdvisor.reasons(signals).isEmpty)
        let caveats = DeveloperBackForwardCacheAdvisor.caveats(signals)
        XCTAssertEqual(caveats.count, 3)
        XCTAssertTrue(caveats[0].contains("WebKit does not report"))

        var late = DeveloperBackForwardCacheSignals(probe: ["early": false], page: nil, document: nil)
        XCTAssertTrue(DeveloperBackForwardCacheAdvisor.caveats(late).contains { $0.contains("after the page did") })
        late.status = 404
        late.liveCaptureTracks = 2
        late.openPeerConnections = 1
        let reasons = DeveloperBackForwardCacheAdvisor.reasons(late)
        XCTAssertEqual(reasons.map(\.kind), [.possible, .likely, .likely])
        XCTAssertTrue(reasons[1].title.contains("2 live tracks"))
    }

    // MARK: Storage

    func testBreakdownAddsWhatTheEstimateHoldsBeyondTheMeasuredParts() {
        let breakdown = DeveloperStorageBreakdown(usage: 1000, parts: [
            .init(name: "Local storage", bytes: 200, inQuota: false),
            .init(name: "IndexedDB", bytes: 300, inQuota: true),
            .init(name: "Cache storage", bytes: 100, inQuota: true),
            .init(name: "Cookies", bytes: 0, inQuota: false),
            .init(name: "Service workers", bytes: nil, inQuota: true),
        ])
        XCTAssertEqual(breakdown.segments.map(\.name), ["Local storage", "IndexedDB", "Cache storage", "Other"])
        XCTAssertEqual(breakdown.segments.map(\.bytes), [200, 300, 100, 600])
        XCTAssertEqual(breakdown.total, 1200)
        XCTAssertEqual(breakdown.segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertEqual(breakdown.segments[0].fraction, 200.0 / 1200, accuracy: 1e-9)
    }

    func testBreakdownWithoutEstimateOrWithMeasuredPartsOverIt() {
        let over = DeveloperStorageBreakdown(usage: 100, parts: [.init(name: "IndexedDB", bytes: 400, inQuota: true)])
        XCTAssertEqual(over.segments.map(\.name), ["IndexedDB"])
        XCTAssertEqual(over.segments.first?.fraction, 1)
        let none = DeveloperStorageBreakdown(usage: nil, parts: [.init(name: "Local storage", bytes: nil, inQuota: false)])
        XCTAssertTrue(none.segments.isEmpty)
        XCTAssertEqual(none.total, 0)
    }

    // MARK: Frames

    private func frameTree() -> DeveloperFrameNode? {
        DeveloperFrameNode.parse([
            "frame": ["id": "top", "url": "https://a.example/", "securityOrigin": "https://a.example", "mimeType": "text/html"],
            "resources": [
                ["url": "https://a.example/app.js", "type": "Script", "mimeType": "text/javascript"],
                ["url": "https://a.example/logo.png", "type": "Image", "mimeType": "image/png"],
                ["url": "https://a.example/site.css", "type": "StyleSheet", "mimeType": "text/css"],
                ["url": "https://a.example/font.woff2", "type": "Font", "mimeType": "font/woff2"],
            ],
            "childFrames": [
                ["frame": ["id": "one", "url": "https://b.example/", "securityOrigin": "https://b.example"]],
                ["frame": ["id": "two", "url": "http://c.example/", "securityOrigin": "http://c.example", "name": "ad"],
                 "childFrames": [["frame": ["id": "deep", "url": "https://d.example/", "securityOrigin": "https://d.example"]]]],
            ],
        ])
    }

    func testFramePathsFollowWindowFramesOrder() throws {
        let root = try XCTUnwrap(frameTree())
        XCTAssertEqual(DeveloperFrameDetails.path(to: "top", in: root), [])
        XCTAssertEqual(DeveloperFrameDetails.path(to: "one", in: root), [0])
        XCTAssertEqual(DeveloperFrameDetails.path(to: "deep", in: root), [1, 0])
        XCTAssertNil(DeveloperFrameDetails.path(to: "gone", in: root))
    }

    func testFrameSectionsFromHeadersAndContext() throws {
        let root = try XCTUnwrap(frameTree())
        let list = headers([
            ["Cross-Origin-Opener-Policy", #"same-origin; report-to="coop""#],
            ["Cross-Origin-Embedder-Policy", "require-corp"],
            ["Content-Security-Policy", "default-src 'self'"],
            ["Permissions-Policy", "camera=(), geolocation=(self)"],
        ])
        let context = DeveloperFrameDetails.Context(secure: true, crossOriginIsolated: true, allowedFeatures: ["fullscreen"], owner: nil)
        let sections = DeveloperFrameDetails.sections(root, context: context, headers: list)
        XCTAssertEqual(sections.map(\.title), ["Document", "Security & Isolation", "Permissions Policy"])
        let security = Dictionary(uniqueKeysWithValues: sections[1].rows.map { ($0[0], $0[1]) })
        XCTAssertEqual(security["Cross-origin isolated"], "Yes")
        XCTAssertEqual(security["Cross-Origin-Opener-Policy"], "same-origin (report-to: coop)")
        XCTAssertEqual(security["Cross-Origin-Embedder-Policy"], "require-corp")
        XCTAssertEqual(security["Content-Security-Policy"], "default-src 'self'")
        XCTAssertFalse(sections[0].rows.contains { $0[0] == "Owner element" })
        XCTAssertEqual(sections[2].rows, [["Allowed features", "fullscreen"], ["camera", "none"], ["geolocation", "self"]])

        let child = try XCTUnwrap(root.find("two"))
        let unrecorded = DeveloperFrameDetails.sections(child, context: .init(owner: #"<iframe name="ad">"#), headers: nil)
        let document = Dictionary(uniqueKeysWithValues: unrecorded[0].rows.map { ($0[0], $0[1]) })
        XCTAssertEqual(document["Owner element"], #"<iframe name="ad">"#)
        XCTAssertEqual(document["Name"], "ad")
        let childSecurity = Dictionary(uniqueKeysWithValues: unrecorded[1].rows.map { ($0[0], $0[1]) })
        XCTAssertEqual(childSecurity["Secure context"], "No")
        XCTAssertEqual(childSecurity["Cross-origin isolated"], "—")
        XCTAssertEqual(childSecurity["Cross-Origin-Opener-Policy"], "Not recorded")
        XCTAssertEqual(unrecorded[2].rows, [["Permissions-Policy", "Not recorded"]])
    }

    func testFrameResourcesInChromesOrderAndWhereTheyOpen() throws {
        let root = try XCTUnwrap(frameTree())
        XCTAssertEqual(DeveloperFrameDetails.orderedGroups(root).map(\.title), ["Scripts", "Stylesheets", "Images", "Fonts"])
        XCTAssertTrue(DeveloperFrameDetails.opensInSources("Script"))
        XCTAssertTrue(DeveloperFrameDetails.opensInSources("StyleSheet"))
        XCTAssertFalse(DeveloperFrameDetails.opensInSources("Image"))
        XCTAssertFalse(DeveloperFrameDetails.opensInSources("Font"))
    }

    // MARK: Extension storage

    func testExtensionPagesAreRecognised() {
        XCTAssertEqual(DeveloperExtensionStorage.extensionID(of: URL(string: "chrome-extension://abcdef/options.html")), "abcdef")
        XCTAssertNil(DeveloperExtensionStorage.extensionID(of: URL(string: "https://abcdef.example/")))
        XCTAssertNil(DeveloperExtensionStorage.extensionID(of: nil))
    }
}
