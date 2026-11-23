import XCTest
@testable import Search

/// Automatic workspace folders: a localhost server's
/// /.well-known/appspecific/com.chrome.devtools.json names its folder,
/// which Sources › Workspace offers with Connect.
@MainActor
final class DeveloperAutomaticWorkspaceTests: XCTestCase {
    private let uuid = "53b029bb-c989-4dca-969b-835fecec3717"

    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testOnlyLocalhostPagesAreAsked() {
        XCTAssertEqual(DeveloperWorkspace.devToolsJSONURL(for: "http://localhost:3000/app?x=1")?.absoluteString,
                       "http://localhost:3000/.well-known/appspecific/com.chrome.devtools.json")
        XCTAssertEqual(DeveloperWorkspace.devToolsJSONURL(for: "https://127.0.0.1:8443/")?.absoluteString,
                       "https://127.0.0.1:8443/.well-known/appspecific/com.chrome.devtools.json")
        XCTAssertNil(DeveloperWorkspace.devToolsJSONURL(for: "https://example.com/"))
        XCTAssertNil(DeveloperWorkspace.devToolsJSONURL(for: "http://localhost.example.com/"))
        XCTAssertNil(DeveloperWorkspace.devToolsJSONURL(for: "file:///Users/me/index.html"))
        XCTAssertNil(DeveloperWorkspace.devToolsJSONURL(for: nil))
        XCTAssertTrue(DeveloperWorkspace.allowsAutomaticFolders("http://LOCALHOST:5173/"))
    }

    func testParsesWorkspaceRootAndUUID() {
        let parsed = DeveloperWorkspace.devToolsJSON(json(#"{"workspace":{"root":"/Users/me/app/","uuid":"\#(uuid)"}}"#))
        XCTAssertEqual(parsed, DeveloperWorkspace.DevToolsJSON(root: "/Users/me/app", uuid: uuid))
        // Other keys are fine; the uuid is kept lowercased.
        let upper = DeveloperWorkspace.devToolsJSON(json(#"{"version":1,"workspace":{"root":"/srv/site","uuid":"\#(uuid.uppercased())"}}"#))
        XCTAssertEqual(upper?.uuid, uuid)
    }

    func testRejectsInvalidFiles() {
        let invalid = [
            "",
            "not json",
            "[]",
            #"{}"#,
            #"{"workspace":"/Users/me/app"}"#,
            #"{"workspace":{"root":"/Users/me/app"}}"#,
            #"{"workspace":{"uuid":"\#(uuid)"}}"#,
            #"{"workspace":{"root":"relative/app","uuid":"\#(uuid)"}}"#,
            #"{"workspace":{"root":"/Users/me/app","uuid":"not-a-uuid"}}"#,
            #"{"workspace":{"root":42,"uuid":"\#(uuid)"}}"#,
        ]
        for text in invalid {
            XCTAssertNil(DeveloperWorkspace.devToolsJSON(json(text)), text)
        }
    }

    func testOffersOnlyAFolderThatExists() {
        let data = json(#"{"workspace":{"root":"/Users/me/app","uuid":"\#(uuid)"}}"#)
        let offered = DeveloperWorkspace.automaticFolder(from: data, origin: "http://localhost:3000") { $0 == "/Users/me/app" }
        XCTAssertEqual(offered, DeveloperWorkspace.AutomaticFolder(origin: "http://localhost:3000", root: "/Users/me/app", uuid: uuid))
        XCTAssertEqual(offered?.name, "app")
        XCTAssertNil(DeveloperWorkspace.automaticFolder(from: data, origin: "http://localhost:3000") { _ in false })
    }

    func testConnectAddsTheFolderAndTheOfferGoes() throws {
        let suite = "DeveloperAutomaticWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try DeveloperLocalOverrides.writeText("1", to: folder.appendingPathComponent("app.js"))
        let root = folder.standardizedFileURL.path

        let workspace = DeveloperWorkspace(defaults: defaults)
        let page = "http://localhost:3000/"
        XCTAssertTrue(workspace.automaticFoldersEnabled)
        let offered = DeveloperWorkspace.AutomaticFolder(origin: "http://localhost:3000", root: root, uuid: uuid)
        workspace.offer(offered)
        XCTAssertEqual(workspace.automaticFolder(for: page), offered)
        XCTAssertNil(workspace.automaticFolder(for: "http://localhost:4000/"))

        // Off in Settings › Workspace: nothing is offered.
        defaults.set(false, forKey: DeveloperWorkspace.automaticFoldersKey)
        XCTAssertNil(workspace.automaticFolder(for: page))
        defaults.set(true, forKey: DeveloperWorkspace.automaticFoldersKey)

        // Only Connect adds it; then it is a workspace folder, no longer offered.
        XCTAssertTrue(workspace.folders.isEmpty)
        workspace.connect(offered)
        XCTAssertEqual(workspace.folders.map(\.path), [root])
        XCTAssertEqual(workspace.folders.map(\.origin), ["http://localhost:3000"])
        XCTAssertNil(workspace.automaticFolder(for: page))
        XCTAssertEqual(workspace.mapping(for: "http://localhost:3000/app.js", page: page)?.path, "app.js")
    }
}
