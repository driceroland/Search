import Foundation
import XCTest
@testable import Search

final class BrowserDiscoveryTests: XCTestCase {
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

}
