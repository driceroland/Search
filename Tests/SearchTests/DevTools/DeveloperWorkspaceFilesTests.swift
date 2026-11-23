import XCTest
@testable import Search

/// Sources ▸ Workspace's menus: New file, Exclude folder, Rename…, and the
/// folder's tree.
@MainActor
final class DeveloperWorkspaceFilesTests: XCTestCase {
    private func makeWorkspace() throws -> (DeveloperWorkspace, DeveloperWorkspace.Folder, URL, () -> Void) {
        let suite = "DeveloperWorkspaceFilesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        for (path, text) in [("public/app.js", "1"), ("public/js/lib.js", "2"), ("src/App.tsx", "3"), ("README.md", "4")] {
            try DeveloperLocalOverrides.writeText(text, to: url.appendingPathComponent(path))
        }
        let workspace = DeveloperWorkspace(defaults: defaults)
        workspace.add(url, origin: "http://127.0.0.1:4000")
        let folder = try XCTUnwrap(workspace.folders.first)
        return (workspace, folder, url, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        })
    }

    func testNewFileNames() {
        XCTAssertEqual(DeveloperWorkspace.newFileName(existing: []), "NewFile")
        XCTAssertEqual(DeveloperWorkspace.newFileName(existing: ["NewFile"]), "NewFile1")
        XCTAssertEqual(DeveloperWorkspace.newFileName(existing: ["NewFile", "NewFile1"]), "NewFile2")
    }

    func testNewFileIsMadeInTheFolderAndListed() throws {
        let (workspace, folder, url, cleanUp) = try makeWorkspace()
        defer { cleanUp() }
        XCTAssertEqual(try workspace.createFile(in: "public", of: folder), "public/NewFile")
        XCTAssertEqual(try workspace.createFile(in: "public", of: folder), "public/NewFile1")
        XCTAssertEqual(try workspace.createFile(in: "", of: folder), "NewFile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("public/NewFile").path))
        XCTAssertTrue(workspace.files(in: folder).contains("public/NewFile1"))
        XCTAssertTrue(workspace.files(in: folder).contains("NewFile"))
        // `..` can't climb out of the folder.
        XCTAssertEqual(try workspace.createFile(in: "../..", of: folder), "NewFile1")
    }

    func testExcludedFolderIsLeftOutAndKept() throws {
        let (workspace, folder, _, cleanUp) = try makeWorkspace()
        defer { cleanUp() }
        let page = "http://127.0.0.1:4000/"
        XCTAssertEqual(workspace.mapping(for: "http://127.0.0.1:4000/js/lib.js", page: page)?.path, "public/js/lib.js")
        workspace.exclude("public/js", in: folder)
        XCTAssertFalse(workspace.files(in: folder).contains("public/js/lib.js"))
        XCTAssertTrue(workspace.files(in: folder).contains("public/app.js"))
        XCTAssertNil(workspace.mapping(for: "http://127.0.0.1:4000/js/lib.js", page: page))
        XCTAssertEqual(workspace.excluded[folder.id], ["public/js"])
        // A folder holding it takes its place.
        workspace.exclude("public", in: folder)
        XCTAssertEqual(workspace.excluded[folder.id], ["public"])
        XCTAssertEqual(workspace.files(in: folder).sorted(), ["README.md", "src/App.tsx"])
        XCTAssertTrue(DeveloperWorkspace.isExcluded("public/x/y.js", by: ["public"]))
        XCTAssertFalse(DeveloperWorkspace.isExcluded("publications/y.js", by: ["public"]))
        // Removing the folder forgets what was excluded.
        workspace.remove(folder)
        XCTAssertNil(workspace.excluded[folder.id])
    }

    func testRename() throws {
        let (workspace, folder, url, cleanUp) = try makeWorkspace()
        defer { cleanUp() }
        XCTAssertEqual(try workspace.rename("src/App.tsx", in: folder, to: "Main.tsx"), "src/Main.tsx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("src/Main.tsx").path))
        XCTAssertEqual(try workspace.rename("public/js", in: folder, to: "scripts"), "public/scripts")
        XCTAssertTrue(workspace.files(in: folder).contains("public/scripts/lib.js"))
        XCTAssertThrowsError(try workspace.rename("public/app.js", in: folder, to: "a/b"))
        XCTAssertThrowsError(try workspace.rename("public/app.js", in: folder, to: "scripts"), "taken")
        XCTAssertThrowsError(try workspace.rename("README.md", in: folder, to: "  "))
    }

    func testTreeRowsFoldersFirstOpenOnlyWhenExpanded() {
        let files = ["b.js", "src/z.js", "src/a/x.js", "lib/y.js", "a.js"]
        XCTAssertEqual(DeveloperWorkspace.rows(files, expanded: []).map(\.path), ["lib", "src", "a.js", "b.js"])
        let open = DeveloperWorkspace.rows(files, expanded: ["src", "src/a"])
        XCTAssertEqual(open.map(\.path), ["lib", "src", "src/a", "src/a/x.js", "src/z.js", "a.js", "b.js"])
        XCTAssertEqual(open.map(\.depth), [0, 0, 1, 2, 1, 0, 0])
        XCTAssertEqual(open.filter(\.isFolder).map(\.name), ["lib", "src", "a"])
        XCTAssertEqual(DeveloperWorkspace.directories(of: ["src/a/x.js", "b.js"]), ["src", "src/a"])
    }
}
