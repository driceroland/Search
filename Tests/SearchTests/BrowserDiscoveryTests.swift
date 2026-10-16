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

    override class func setUp() {
        setenv("SEARCH_PROBE", "browser-import-\(ProcessInfo.processInfo.processIdentifier)", 1)
        super.setUp()
    }

    func testChosenFolderIsIgnoredByTestRunsAndNeverPersisted() {
        let source = Chromium.Source(name: "Fixture-\(UUID().uuidString)", folder: "Fixture", service: "", account: "", app: "")
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("other-browser")

        Chromium.useForSession(selected, for: source)

        XCTAssertTrue(Store.testing)
        XCTAssertNil(Chromium.chosenRoot(for: source.name))
        XCTAssertEqual(source.root, Chromium.base.appendingPathComponent(source.folder, isDirectory: true))
        XCTAssertNil(Store.settings.string(forKey: "import.folder.\(source.name)"))
    }

    func testReadableEmptyAndMissingFoldersKeepDifferentResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        let empty = source.discovery
        XCTAssertTrue(empty.profiles.isEmpty)
        XCTAssertNil(empty.error)
        XCTAssertTrue(Chromium.Unavailable(source: source, error: empty.error).message.contains("no browser profile"))

        source.rootOverride = root.appendingPathComponent("missing")
        let missing = source.discovery
        XCTAssertTrue(missing.profiles.isEmpty)
        XCTAssertNotNil(missing.error)
        XCTAssertTrue(Chromium.Unavailable(source: source, error: missing.error).message.contains("data folder was not found"))
    }

    func testDeniedFolderKeepsPermissionErrorAndRecoversAfterAccessIsRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        let denied = source.discovery
        XCTAssertTrue(denied.profiles.isEmpty)
        XCTAssertNotNil(denied.error)
        let message = Chromium.Unavailable(source: source, error: denied.error).message
        XCTAssertTrue(message.contains("macOS hasn't allowed Search"))
        XCTAssertTrue(message.contains("for this session"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertNil(source.discovery.error)
        XCTAssertEqual(source.profiles.map(\.lastPathComponent), ["Default"])
        let recovered = try XCTUnwrap(source.profiles.first)
        XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent("Bookmarks")), Data("{}".utf8))
    }

    func testDeniedProfileKeepsReadableSiblingAndReportsPermissionFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let denied = root.appendingPathComponent("Default")
        let readable = root.appendingPathComponent("Profile 1")
        for profile in [denied, readable] {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)

        let partial = source.discovery
        XCTAssertEqual(partial.profiles.map(\.lastPathComponent), ["Profile 1"])
        XCTAssertNotNil(partial.error)
        let message = Chromium.Unavailable(source: source, error: partial.error, partial: true).message
        XCTAssertTrue(message.contains("Some of Fixture's profiles"))
        XCTAssertTrue(message.contains("all of them"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        let restored = source.discovery
        XCTAssertNil(restored.error)
        XCTAssertEqual(Set(restored.profiles.map(\.lastPathComponent)), ["Default", "Profile 1"])
    }

    func testOrdinaryRootFilesAndEmptyProfilesDoNotBecomeReadFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Local State"))
        defer { try? FileManager.default.removeItem(at: root) }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        XCTAssertTrue(source.discovery.profiles.isEmpty)
        XCTAssertNil(source.discovery.error)
    }

    func testUnlistableProfileStillOffersKnownReadableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        // Traversal and a known file remain readable even without listing the directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: profile.path)
        let partial = source.discovery
        XCTAssertEqual(partial.profiles.map(\.lastPathComponent), ["Default"])
        XCTAssertNotNil(partial.error)
        XCTAssertEqual(try source.data("Bookmarks", in: profile), Data("{}".utf8))
    }

}
