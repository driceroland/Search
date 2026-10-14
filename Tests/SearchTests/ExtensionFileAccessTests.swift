import AppKit
import WebKit
import XCTest
@testable import Search

/// Files on this Mac are never an extension's, whatever its manifest names,
/// as in Chrome with "Allow access to file URLs" left off.
@available(macOS 15.4, *)
@MainActor
final class ExtensionFileAccessTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "sec-file-access-\(getpid())", 1)
        super.setUp()
    }

    func testFilesAreNeverGrantedButSitesAre() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Files", "version": "1",
            "host_permissions": ["file:///*", "https://example.com/*"],
            "content_scripts": [["matches": ["file://*/*", "<all_urls>"], "js": ["c.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("0".utf8).write(to: folder.appendingPathComponent("c.js"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))

        Extensions.grantSites(context)
        Extensions.fence(context)

        let file = try XCTUnwrap(URL(string: "file:///Users/someone/notes.html"))
        let site = try XCTUnwrap(URL(string: "https://example.com/page"))
        XCTAssertFalse(context.hasAccess(to: file), "a file was given")
        XCTAssertTrue(context.hasAccess(to: site), "a named site was not given")
        XCTAssertFalse(context.grantedPermissionMatchPatterns.keys.contains { Extensions.reachesFiles($0) })

        // A file pattern granted some other way is still outweighed by the fence.
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "file:///*"))
        XCTAssertTrue(context.hasAccess(to: file), "WebKit no longer gives a granted file pattern: this test proves nothing")
        Extensions.fence(context)
        XCTAssertFalse(context.hasAccess(to: file), "the fence let a file through")
    }

    func testOnlyFilePatternsReachFiles() throws {
        XCTAssertTrue(Extensions.reachesFiles(try WKWebExtension.MatchPattern(string: "file:///*")))
        XCTAssertTrue(Extensions.withheld(try WKWebExtension.MatchPattern(string: "file://*/*")))
        XCTAssertFalse(Extensions.withheld(try WKWebExtension.MatchPattern(string: "https://*/*")))
        XCTAssertFalse(Extensions.withheld(WKWebExtension.MatchPattern.allURLs()))
    }
}
