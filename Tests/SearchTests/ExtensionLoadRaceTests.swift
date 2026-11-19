import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionLoadRaceTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-load-race-\(getpid())", 1)
        super.setUp()
    }

    private func loaded(_ id: String, _ extensions: Extensions) -> Int {
        extensions.controller.extensionContexts.filter { $0.uniqueIdentifier == id }.count
    }

    /// Polls until `id` has a context, or `limit` seconds pass.
    private func waitForContext(_ id: String, _ extensions: Extensions, limit: TimeInterval = 5) async throws -> Bool {
        let end = Date().addingTimeInterval(limit)
        while Date() < end {
            if extensions.contexts[id] != nil { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testSwitchedOffWhileLoadingStaysOffAndOnlyNewestLoadLands() async throws {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("load-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(#"{"manifest_version": 3, "name": "Load race", "version": "1.0"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let id = Crx.unpackedID(for: URL(fileURLWithPath: Crx.realPath(of: source), isDirectory: true))
        defer { extensions.remove(id) }

        extensions.installFolder(at: source, confirm: false)
        let installed = try await waitForContext(id, extensions)
        XCTAssertTrue(installed, "the installed extension never loaded")
        XCTAssertEqual(loaded(id, extensions), 1)

        // Off, on, and off again before that load lands.
        extensions.setEnabled(id, false)
        extensions.setEnabled(id, true)
        extensions.setEnabled(id, false)
        let cameBack = try await waitForContext(id, extensions, limit: 2)
        XCTAssertFalse(cameBack, "a switched-off extension was loaded by the load already in flight")
        XCTAssertEqual(loaded(id, extensions), 0)

        // On twice: two loads in flight, one context in the controller.
        extensions.setEnabled(id, true)
        extensions.setEnabled(id, true)
        let on = try await waitForContext(id, extensions)
        XCTAssertTrue(on, "switched back on, it never loaded")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(loaded(id, extensions), 1)
        XCTAssertTrue(extensions.contexts[id]?.isLoaded == true)
    }
}
