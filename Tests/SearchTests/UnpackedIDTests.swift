import XCTest
@testable import Search

/// The id an extension loaded from a folder gets (Crx.unpackedID): the one
/// Chrome gives it from the folder's path, which is what native messaging
/// hosts list. Never from the manifest's "key".
final class UnpackedIDTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("unpacked-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String, manifest: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        return url
    }

    // A made-up public key, and the id Chrome would work out from it.
    private let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGi" // gitleaks:allow (bytes 1, 2, 3… in base64, not a real key)
    private let keyID = "gmamnbkpnmopddmcggdjbipgakiejpfc"

    func testTheIdComesFromThePath() {
        // StopTheMadness Pro's bundled folder, and the id its host lists for Chrome.
        let path = "/Applications/StopTheMadness Pro.app/Contents/MacOS/StopTheMadness Chrome.app/Contents/Resources/chromium"
        XCTAssertEqual(Crx.unpackedID(for: URL(fileURLWithPath: path, isDirectory: true)), "paflpghjhdjaeapkeiophohkhagfcjih")
    }

    func testAKeyInTheManifestIsIgnored() throws {
        let keyed = try folder("keyed", manifest: ["name": "A", "key": key])
        XCTAssertNotEqual(Crx.unpackedID(for: keyed), keyID)
        let withKey = Crx.unpackedID(for: keyed)
        try JSONSerialization.data(withJSONObject: ["name": "A"]).write(to: keyed.appendingPathComponent("manifest.json"))
        XCTAssertEqual(Crx.unpackedID(for: keyed), withKey)
    }

    func testFoldersWithTheSameKeyDiffer() throws {
        let one = try folder("one", manifest: ["name": "A", "key": key])
        let two = try folder("two", manifest: ["name": "A", "key": key])
        XCTAssertNotEqual(Crx.unpackedID(for: one), Crx.unpackedID(for: two))
    }

    func testFoldersWithoutAKeyDifferAndALinkLeadsToItsFolder() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let two = try folder("two", manifest: ["name": "A"])
        XCTAssertNotEqual(Crx.unpackedID(for: one), Crx.unpackedID(for: two))
        XCTAssertEqual(Crx.unpackedID(for: one).count, 32)
        XCTAssertTrue(Crx.unpackedID(for: one).allSatisfy { ("a"..."p").contains($0) })

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        XCTAssertEqual(Crx.unpackedID(for: link), Crx.unpackedID(for: one))
    }

    func testReloadRefusesAFolderThatNowLeadsElsewhere() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let path = Crx.realPath(of: one)
        let item = Installed(id: Crx.unpackedID(for: one), name: "A", version: "1", enabled: true, fromStore: false, permissions: [], source: path)
        XCTAssertTrue(item.sourceKeepsID)

        // Moved, and a link left where it was: the stored path now leads
        // through the link, to a folder with another id.
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: one, to: moved)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: path), withDestinationURL: moved)
        XCTAssertFalse(item.sourceKeepsID)
    }

    func testAListWrittenBeforeIdsCameFromPathsStillReloads() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let json = #"[{"id": "local-1a2b3c4d", "name": "A", "version": "1", "enabled": true, "fromStore": false, "permissions": [], "source": "\#(one.path)"}]"#
        let list = try JSONDecoder().decode([Installed].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.source, one.path)
        XCTAssertEqual(list.first?.sourceKeepsID, true)

        let store = #"[{"id": "\#(keyID)", "name": "B", "version": "1", "enabled": true, "fromStore": true, "permissions": []}]"#
        XCTAssertEqual(try JSONDecoder().decode([Installed].self, from: Data(store.utf8)).first?.sourceKeepsID, true)
    }
}
