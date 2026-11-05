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

    func testCopyAddressOffersOnlyWhatAnotherAppCanFetch() {
        func address(_ text: String) -> String? { Keep.address(of: URL(string: text)) }

        // A signed link only works exactly as it was asked.
        let signed = "https://cdn.example.test/a%20b.zip?x-amz-signature=a%2Fb+c&y=1#part"
        XCTAssertEqual(address(signed), signed)
        XCTAssertEqual(address("http://example.test/a.zip"), "http://example.test/a.zip")
        XCTAssertEqual(address("https://me:made-up@example.test/a.zip"), "https://example.test/a.zip")

        XCTAssertNil(address("blob:https://example.test/1234"))
        XCTAssertNil(address("data:text/plain,hello"))
        XCTAssertNil(address("file:///tmp/a.zip"))
        XCTAssertNil(Keep.address(of: nil))
        XCTAssertNil(FetchEntry(name: "a.zip", request: nil, webView: nil).address)
    }

    func testAListWrittenBeforeAddressesStillReads() throws {
        let written = #"[{"name":"a.zip","from":"example.test","path":"/tmp/a.zip","date":0}]"#
        let list = try JSONDecoder().decode([Keep].self, from: Data(written.utf8))
        XCTAssertEqual(list.first?.name, "a.zip")
        XCTAssertNil(list.first?.address)
    }

    func testAnAddressSurvivesTheListsFile() throws {
        let keep = Keep(name: "a.zip", from: "example.test", path: "/tmp/a.zip", date: Date(timeIntervalSince1970: 0),
                        address: "https://example.test/a.zip")
        let read = try JSONDecoder().decode(Keep.self, from: JSONEncoder().encode(keep))
        XCTAssertEqual(read, keep)
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
        XCTAssertTrue(try XCTUnwrap(entry.errorDescription).contains("doesn't let this download pause"))
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
        let start = try XCTUnwrap(fetches.beginRetry(entry, destination: { target }))

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
