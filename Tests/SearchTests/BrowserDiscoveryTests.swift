import Foundation
import XCTest
@testable import Search

final class BrowserDiscoveryTests: XCTestCase {
    func testExtensionOnlyProfileIsDiscoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = root.appendingPathComponent("Default/Extensions", isDirectory: true)
        let id = "dfpnncgnidnmgipnpgfgfdmanngkhblg"
        try FileManager.default.createDirectory(at: extensions.appendingPathComponent(id), withIntermediateDirectories: true)
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)

        XCTAssertEqual(source.profiles.map(\.lastPathComponent), ["Default"])
        XCTAssertEqual(Chromium.preview(of: source, profile: "Default").extensions, [id])
    }

    func testBrowserWithoutSupportedPasswordKeyKeepsOtherData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("Login Data"))
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", importsPasswords: false, rootOverride: root)

        XCTAssertEqual(source.profiles.map(\.lastPathComponent), ["Default"])
        XCTAssertTrue(source.files().isEmpty)
        XCTAssertEqual(Chromium.preview(of: source, profile: nil).passwords, 0)
    }

}
