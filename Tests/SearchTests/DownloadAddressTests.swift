import AppKit
import Foundation
import XCTest
@testable import Search

/// Copy Address on a download's row (#853): the address the file came
/// from, on the row while it runs and on the row kept after it, for
/// another download app to take.
@MainActor
final class DownloadAddressTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testRunningDownloadKeepsTheAddressItWasAskedWith() {
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip?sig=abc")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: nil)

        XCTAssertEqual(entry.address, URL(string: "https://example.test/archive.zip?sig=abc"))
    }

    func testResumedDownloadWithoutARequestHasNoAddress() {
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: nil)

        XCTAssertNil(entry.address)
    }

    func testKeptRowRemembersTheAddressAndOlderRowsDoNot() throws {
        let address = "https://example.test/archive.zip?sig=abc"
        let keep = Keep(name: "archive.zip", from: "example.test", address: address,
                        path: "/Users/me/Downloads/archive.zip", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(keep.source, URL(string: address))

        let old = #"{"name":"archive.zip","from":"example.test","path":"/Users/me/Downloads/archive.zip","date":0}"#
        let decoded = try JSONDecoder().decode(Keep.self, from: Data(old.utf8))
        XCTAssertNil(decoded.address)
        XCTAssertNil(decoded.source)
    }

    func testCopyAddressPutsTheAddressOnTheClipboardAsItIs() {
        let board = NSPasteboard(name: NSPasteboard.Name("search.downloadaddress.test.\(getpid())"))
        defer { board.releaseGlobally() }
        let address = URL(string: "https://example.test/archive.zip?id=42&utm_source=x")!

        DownloadsPanel.copyAddress(address, to: board)

        XCTAssertEqual(board.string(forType: .string), address.absoluteString)
    }
}
