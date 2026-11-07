import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Whether an extension gets to talk to an app on this Mac, which Search
/// decides for itself: WebKit's nativeMessaging is granted to every
/// extension, for the shim's own line to Search (Extensions.load), so only
/// the manifest says who asked for it.
@available(macOS 15.4, *)
@MainActor
final class ExtensionNativePermissionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "native-permission-\(getpid())", 1)
        super.setUp()
    }

    /// An extension installed as Search installs one: prepared, which writes
    /// the shim in and nativeMessaging into its manifest, then read by WebKit
    /// from the package that leaves.
    private func installed(permissions: [String], optional: [String]) async throws -> (String, URL, WKWebExtensionContext) {
        let id = "probe-\(UUID().uuidString)"
        let folder = Extensions.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "manifest_version": 3, "name": "Native probe", "version": "1",
            "background": ["service_worker": "bg.js"],
        ]
        if !permissions.isEmpty { manifest["permissions"] = permissions }
        if !optional.isEmpty { manifest["optional_permissions"] = optional }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("// nothing\n".utf8).write(to: folder.appendingPathComponent("bg.js"))

        try ExtensionShims.prepare(folder, fresh: true)
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = id
        return (id, folder, context)
    }

    private func forget(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The one that was refused: an extension whose manifest names
    /// nativeMessaging among its optional permissions rather than among
    /// those it must have, as Bitwarden's does, which left its unlock with
    /// Touch ID unable to reach its host (#741). prepare then writes the
    /// permission into the required ones for the shim's own line and notes
    /// that it did, truthfully, so neither of WebKit's lists speaks for the
    /// extension and only the manifest can.
    func testOptionalNativeMessagingIsAskedFor() async throws {
        let (_, folder, context) = try await installed(permissions: ["storage"], optional: ["nativeMessaging"])
        defer { forget(folder) }

        XCTAssertTrue(Extensions.asksForNative(context))
    }

    /// Why it was refused: prepare puts nativeMessaging into permissions for
    /// the shim's own line, and WebKit leaves a permission named in both
    /// lists out of the optional ones. So neither of WebKit's two lists said
    /// the extension had asked, and .search-added said Search had added it.
    func testPreparedPackageLeavesWebKitWithNoOptionalPermission() async throws {
        let (_, folder, context) = try await installed(permissions: ["storage"], optional: ["nativeMessaging"])
        defer { forget(folder) }

        XCTAssertTrue(context.webExtension.requestedPermissions.contains(.nativeMessaging))
        XCTAssertFalse(context.webExtension.optionalPermissions.contains(.nativeMessaging))
        let added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String]
        XCTAssertEqual(added, ["nativeMessaging"])
        // The extension's own word for it, which prepare never touches.
        let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any]
        XCTAssertEqual(manifest?["optional_permissions"] as? [String], ["nativeMessaging"])
    }

    /// One that must have it, as uBlock's native host extensions do: allowed
    /// as before.
    func testRequiredNativeMessagingIsAskedFor() async throws {
        let (_, folder, context) = try await installed(permissions: ["nativeMessaging"], optional: [])
        defer { forget(folder) }

        XCTAssertTrue(Extensions.asksForNative(context))
    }

    /// One that never asked stays shut out, whatever Search wrote into its
    /// manifest for its own line.
    func testUnaskedNativeMessagingIsRefused() async throws {
        let (_, folder, context) = try await installed(permissions: ["storage"], optional: ["tabs"])
        defer { forget(folder) }

        XCTAssertTrue(context.webExtension.requestedPermissions.contains(.nativeMessaging))
        XCTAssertFalse(Extensions.asksForNative(context))
    }
}
