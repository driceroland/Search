import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

@MainActor
final class FetchEntryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testFailedResumeDataAllowsResumeWithoutOriginalRequest() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1, 2, 3]))

        XCTAssertEqual(entry.state, .failed)
        XCTAssertTrue(entry.canResume)
        XCTAssertFalse(entry.canRetry)
        XCTAssertEqual(try XCTUnwrap(Fetches().beginResume(entry)?.resumeData), Data([1, 2, 3]))
    }

    func testPauseWithoutResumeDataBecomesRetryableWithVisibleReason() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)

        entry.stopped(.pause, data: nil)

        XCTAssertEqual(entry.state, .failed)
        XCTAssertFalse(entry.canResume)
        XCTAssertTrue(entry.canRetry)
        XCTAssertTrue(try XCTUnwrap(entry.errorDescription).contains("could not be paused"))
    }

    func testBeginResumeRejectsDuplicateActionWhileWebKitStarts() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1]))
        let fetches = Fetches()

        let first = try XCTUnwrap(fetches.beginResume(entry))

        XCTAssertTrue(fetches.accepts(first))
        XCTAssertNil(fetches.beginResume(entry))
    }

    func testRemovingPendingStartInvalidatesItsCallback() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: nil)
        let fetches = Fetches()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("retry.zip")
        let start = try XCTUnwrap(fetches.beginRetry(entry, destination: target))

        XCTAssertTrue(fetches.accepts(start))
        fetches.removeStarting(entry)

        XCTAssertFalse(fetches.accepts(start))
        XCTAssertNil(entry.request)
        XCTAssertNil(entry.webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
