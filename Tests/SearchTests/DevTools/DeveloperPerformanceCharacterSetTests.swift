import XCTest
@testable import Search

/// Performance › Insights › Declare a character set (devtools-frontend's
/// CharacterSet): the document's Content-Type charset, or a `<meta charset>`
/// within its first 1,024 bytes.
final class DeveloperPerformanceCharacterSetTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Insights = DeveloperPerformanceInsights
    typealias Page = DeveloperPerformanceInsightsPage

    private func profile(contentType: String?, meta: String?) -> DeveloperPerformanceProfile {
        var data = ["url": "https://example.com/", "resourceType": "Document", "responseOffset": "100"]
        if let contentType { data["contentType"] = contentType }
        var timings = [Timing(type: "NetworkRequest", start: 0, end: 0.3, data: data)]
        if let meta {
            timings.append(Timing(type: "PageInfo", start: 1, end: 1,
                                  data: ["url": "https://example.com/", "charsetMeta": meta]))
        }
        return DeveloperPerformanceProfile(timings)
    }

    private func passed(_ insight: DeveloperPerformanceInsight) -> Bool {
        if case .pass = insight.verdict { return true }
        return false
    }

    func testTheContentTypeHeadersCharsetIsRead() {
        XCTAssertEqual(Page.charset(contentType: "text/html; charset=utf-8"), "utf-8")
        XCTAssertEqual(Page.charset(contentType: "text/html;CHARSET=\"ISO-8859-1\""), "ISO-8859-1")
        XCTAssertEqual(Page.charset(contentType: "text/html; boundary=x; charset = windows-1252 "), "windows-1252")
        XCTAssertNil(Page.charset(contentType: "text/html"))
        XCTAssertNil(Page.charset(contentType: "text/html; charset="))
        XCTAssertNil(Page.charset(contentType: "charset=utf-8"), "the media type comes first")
        XCTAssertNil(Page.charset(contentType: nil))
    }

    func testTheMetaTagIsReadFromThePage() {
        XCTAssertEqual(Page.charsetMeta([:]), nil, "not asked")
        XCTAssertEqual(Page.charsetMeta(["charsetMeta": "null"]), .some(nil), "asked, and there is none")
        XCTAssertEqual(Page.charsetMeta(["charsetMeta": "{\"charset\":\" utf-8 \",\"end\":80}"]),
                       .some(Page.CharsetMeta(charset: "utf-8", end: 80)))
        XCTAssertEqual(Page.charsetMeta(["charsetMeta": "{\"charset\":\"utf-8\"}"]),
                       .some(Page.CharsetMeta(charset: "utf-8", end: -1)))
    }

    func testAHeaderCharsetPasses() throws {
        let insight = try XCTUnwrap(Insights.characterSet(profile(contentType: "text/html; charset=utf-8", meta: nil)))
        XCTAssertTrue(passed(insight))
        XCTAssertEqual(insight.headline, "Declared in the Content-Type header")
        XCTAssertEqual(insight.rows.map(\.value), ["utf-8"])
    }

    func testAnEarlyMetaTagPasses() throws {
        let early = profile(contentType: "text/html", meta: "{\"charset\":\"utf-8\",\"end\":120}")
        let insight = try XCTUnwrap(Insights.characterSet(early))
        XCTAssertTrue(passed(insight))
        XCTAssertEqual(insight.headline, "Declared by <meta charset>")
        XCTAssertEqual(insight.rows.map(\.value), ["No charset", "utf-8"])
        XCTAssertFalse(insight.rows.contains { $0.failing })
    }

    func testALateMetaTagFails() throws {
        let late = profile(contentType: "text/html", meta: "{\"charset\":\"utf-8\",\"end\":2048}")
        let insight = try XCTUnwrap(Insights.characterSet(late))
        XCTAssertFalse(passed(insight))
        XCTAssertEqual(insight.headline, "<meta charset> comes too late")
        XCTAssertTrue(insight.rows.allSatisfy(\.failing))
        XCTAssertEqual(insight.rows[1].detail, "Ends at byte 2,048, past the first 1,024 bytes")
        // The header settles it, wherever the tag is.
        let both = profile(contentType: "text/html; charset=utf-8", meta: "{\"charset\":\"utf-8\",\"end\":2048}")
        XCTAssertTrue(passed(try XCTUnwrap(Insights.characterSet(both))))
    }

    func testNoDeclarationFails() throws {
        let insight = try XCTUnwrap(Insights.characterSet(profile(contentType: "text/html", meta: "null")))
        XCTAssertFalse(passed(insight))
        XCTAssertEqual(insight.headline, "No character set declared")
        XCTAssertEqual(insight.rows.map(\.value), ["No charset", "Missing"])
    }

    func testLeftOutWithNothingToJudgeBy() {
        XCTAssertNil(Insights.characterSet(profile(contentType: "text/html", meta: nil)))
        XCTAssertNil(Insights.characterSet(profile(contentType: nil, meta: nil)))
        XCTAssertNil(Insights.characterSet(DeveloperPerformanceProfile()))
    }

    func testTheRecordingKeepsTheContentTypeHeader() throws {
        var recording = DeveloperPerformanceNetworkRecording()
        recording.capture("Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 10.0, "type": "Document", "request": ["url": "https://example.com/"],
        ], targetID: nil)
        recording.capture("Network.responseReceived", params: [
            "requestId": "1", "timestamp": 10.1, "type": "Document",
            "response": ["status": 200, "mimeType": "text/html", "headers": ["Content-Type": "text/html; charset=utf-8"]],
        ], targetID: nil)
        recording.capture("Network.loadingFinished", params: ["requestId": "1", "timestamp": 10.2], targetID: nil)
        let profile = DeveloperPerformanceProfile(recording.timings(from: 10, to: 11))
        let document = try XCTUnwrap(Insights.mainDocument(profile))
        XCTAssertEqual(document.contentType, "text/html; charset=utf-8")
    }
}
