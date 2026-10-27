import WebKit
import XCTest
@testable import Search

/// WebKit's extension errors are WKNSError proxies, not NSError instances.
/// Search reads them without Swift's Error bridging, which crashed 1.0.7 on
/// macOS 15 when 1Password's button recorded an error on its context.
@available(macOS 15.4, *)
final class ExtensionErrorsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testWebKitsOwnErrorsAreReadWithoutBridging() async throws {
        // A permission WebKit doesn't know is recorded as a warning.
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Errors", "version": "1",
            "permissions": ["notARealPermission"],
            "background": ["service_worker": "missing.js"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let found = try await WKWebExtension(resourceBaseURL: root)
        let raw = found.value(forKey: "errors") as? NSArray
        XCTAssertGreaterThan(raw?.count ?? 0, 0, "the manifest should give WebKit something to report")
        let read = Extensions.errors(in: raw)
        XCTAssertEqual(read.count, raw?.count)
        for error in read {
            XCTAssertFalse(error.domain.isEmpty)
            XCTAssertFalse(error.text.isEmpty)
        }

        let context = WKWebExtensionContext(for: found)
        XCTAssertEqual(Extensions.errors(of: context).count, (context.value(forKey: "errors") as? NSArray)?.count)
    }

    func testAnythingButAnErrorIsSkipped() {
        let error = NSError(domain: WKWebExtensionContext.errorDomain, code: WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue, userInfo: [NSLocalizedDescriptionKey: "worker"])
        let read = Extensions.errors(in: [error, "not an error", NSNull(), 3] as NSArray)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.domain, WKWebExtensionContext.errorDomain)
        XCTAssertEqual(read.first?.code, WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue)
        XCTAssertEqual(read.first?.text, "worker")
        XCTAssertTrue(Extensions.errors(in: nil).isEmpty)
    }
}
