import XCTest
@testable import Search

/// Sources ▸ Workspace: page addresses matched to files in a folder mapped
/// to the page's origin, read from and saved to disk.
@MainActor
final class DeveloperWorkspaceTests: XCTestCase {
    func testOriginAndPathParts() {
        XCTAssertEqual(DeveloperWorkspace.origin(of: "http://LocalHost:8080/app.js?v=2"), "http://localhost:8080")
        XCTAssertEqual(DeveloperWorkspace.origin(of: "https://example.test/"), "https://example.test")
        XCTAssertNil(DeveloperWorkspace.origin(of: "webpack://app/./src/App.tsx"))
        XCTAssertNil(DeveloperWorkspace.origin(of: "data:text/plain,hi"))

        XCTAssertEqual(DeveloperWorkspace.components(of: "http://localhost:8080/static/js/app.js?v=2#x"), ["static", "js", "app.js"])
        XCTAssertEqual(DeveloperWorkspace.components(of: "http://localhost:8080/"), ["index.html"])
        XCTAssertEqual(DeveloperWorkspace.components(of: "http://localhost:8080/docs/"), ["docs", "index.html"])
        XCTAssertEqual(DeveloperWorkspace.components(of: "http://localhost:8080/my%20file.css"), ["my file.css"])
        // Authored files from source maps go by their own paths.
        XCTAssertEqual(DeveloperWorkspace.components(of: "webpack://app/./src/App.tsx"), ["src", "App.tsx"])
        XCTAssertEqual(DeveloperWorkspace.components(of: "webpack:///src/util/math.ts"), ["src", "util", "math.ts"])
    }

    func testMatchPrefersTheLongestSharedPathThenTheShortest() {
        let files = ["src/app.js", "public/js/app.js", "old/js/app.js", "app.js"]
        // Same name, deepest shared tail; only the name shared, the shortest path.
        XCTAssertEqual(DeveloperWorkspace.match(["static", "app.js"], among: files), "app.js")
        XCTAssertEqual(DeveloperWorkspace.match(["public", "js", "app.js"], among: files), "public/js/app.js")
        XCTAssertEqual(DeveloperWorkspace.match(["src", "app.js"], among: files), "src/app.js")
        // Two equally good: the one nearer the folder's top, then by name.
        XCTAssertEqual(DeveloperWorkspace.match(["x", "js", "app.js"], among: ["public/js/app.js", "old/js/app.js"]), "old/js/app.js")
        XCTAssertNil(DeveloperWorkspace.match(["main.js"], among: files))
        XCTAssertNil(DeveloperWorkspace.match([], among: files))
    }

    func testFolderMapsPageFilesAndAuthoredFilesAndSaves() throws {
        let suite = "DeveloperWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let write = { (path: String, text: String) in
            try DeveloperLocalOverrides.writeText(text, to: folder.appendingPathComponent(path))
        }
        try write("public/index.html", "<!doctype html>")
        try write("public/app.js", "console.log(1)")
        try write("public/style.css", "body { color: red }")
        try write("src/App.tsx", "export const App = 1")
        try write("node_modules/lib/app.js", "// excluded")
        try write(".git/config", "// hidden")

        let workspace = DeveloperWorkspace(defaults: defaults)
        let page = "http://127.0.0.1:4000/"
        workspace.add(folder, origin: "http://127.0.0.1:4000")
        XCTAssertEqual(workspace.folders(for: page).count, 1)
        XCTAssertTrue(workspace.folders(for: "http://127.0.0.1:5000/").isEmpty)

        XCTAssertEqual(workspace.mapping(for: "http://127.0.0.1:4000/app.js?v=1", page: page)?.path, "public/app.js")
        XCTAssertEqual(workspace.mapping(for: "http://127.0.0.1:4000/", page: page)?.path, "public/index.html")
        XCTAssertEqual(workspace.content(for: "http://127.0.0.1:4000/style.css", page: page), "body { color: red }")
        XCTAssertEqual(workspace.mapping(for: "webpack://app/./src/App.tsx", page: page)?.path, "src/App.tsx")
        // Another origin, a file not in the folder, hidden and excluded folders.
        XCTAssertNil(workspace.mapping(for: "http://127.0.0.1:5000/app.js", page: page))
        XCTAssertNil(workspace.mapping(for: "http://127.0.0.1:4000/missing.js", page: page))
        XCTAssertNil(workspace.mapping(for: "http://127.0.0.1:4000/config", page: page))

        // ⌘S writes the file; a script then waits for a reload.
        try workspace.save(url: "http://127.0.0.1:4000/app.js", page: page, content: "console.log(2)")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("public/app.js"), encoding: .utf8), "console.log(2)")
        XCTAssertEqual(workspace.content(for: "http://127.0.0.1:4000/app.js", page: page), "console.log(2)")
        XCTAssertTrue(workspace.needsReload.contains("http://127.0.0.1:4000/app.js"))
        workspace.pageNavigated()
        XCTAssertTrue(workspace.needsReload.isEmpty)
        XCTAssertThrowsError(try workspace.save(url: "http://127.0.0.1:4000/missing.js", page: page, content: ""))

        // Kept per origin across launches.
        let again = DeveloperWorkspace(defaults: defaults)
        XCTAssertEqual(again.folders.map(\.origin), ["http://127.0.0.1:4000"])
        XCTAssertEqual(again.mapping(for: "http://127.0.0.1:4000/app.js", page: page)?.path, "public/app.js")
        again.remove(try XCTUnwrap(again.folders.first))
        XCTAssertNil(again.mapping(for: "http://127.0.0.1:4000/app.js", page: page))
        XCTAssertTrue(DeveloperWorkspace(defaults: defaults).folders.isEmpty)
    }
}
