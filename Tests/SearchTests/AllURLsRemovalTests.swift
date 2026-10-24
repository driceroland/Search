import AppKit
import WebKit
import XCTest
@testable import Search

/// <all_urls>, once given, is held as *://*/* as well (Extensions.fence),
/// so giving it back must take both: permissions.remove reaches
/// "permissions.removeWebsites" for that (#675).
@available(macOS 15.4, *)
@MainActor
final class AllURLsRemovalTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "all-urls-removal-\(getpid())", 1)
        super.setUp()
    }

    private func fixture() async throws -> (URL, WKWebExtension) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("all-urls-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "All URLs", "version": "1",
            "host_permissions": ["https://www.figma.com/*"],
            "optional_host_permissions": ["<all_urls>"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return (folder, try await WKWebExtension(resourceBaseURL: folder))
    }

    func testGivingBackEveryWebsiteTakesBothPatternsAndKeepsNamedHosts() async throws {
        let (folder, ext) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = WKWebExtensionContext(for: ext)
        Extensions.grantSites(context)
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "<all_urls>"))
        Extensions.fence(context)
        let site = URL(string: "https://example.com/")!
        XCTAssertTrue(context.hasAccess(to: site), "given: every website")
        XCTAssertTrue(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "*://*/*" })

        // The shim answers only with a browser window to answer for.
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        let reply = try await ExtensionShims.answer(["api": "permissions.removeWebsites", "args": []],
                                                    from: context, owner: Extensions.shared) as? [String: Any]
        XCTAssertEqual(reply?["value"] as? Bool, true, "\(String(describing: reply))")
        // fence() runs again after any grant: it must not bring it back.
        Extensions.fence(context)
        let left = Set(context.grantedPermissionMatchPatterns.keys.map(\.string))
        XCTAssertFalse(left.contains("*://*/*"), "\(left)")
        XCTAssertFalse(left.contains("<all_urls>"), "\(left)")
        XCTAssertFalse(context.hasAccess(to: site), "given back: no website but those named")
        XCTAssertTrue(context.hasAccess(to: URL(string: "https://www.figma.com/file/x")!), "a named host stays: \(left)")
    }
}
