import XCTest
@testable import Search

/// Settings › Workspace › Folder exclude pattern: what it leaves out of a
/// workspace folder's files.
@MainActor
final class DeveloperWorkspaceExcludePatternTests: XCTestCase {
    func testDefaultPatternMatchesChromesFolders() {
        let expression = DeveloperWorkspace.excludeExpression(DeveloperWorkspace.defaultExcludePattern)
        XCTAssertNotNil(expression)
        let match = { (path: String, folder: Bool) in
            DeveloperWorkspace.matchesExcludePattern(path, isFolder: folder, expression: expression)
        }
        XCTAssertTrue(match("node_modules", true))
        XCTAssertTrue(match("packages/app/node_modules", true))
        XCTAssertTrue(match("bower_components", true))
        XCTAssertTrue(match(".git", true))
        XCTAssertTrue(match(".svn", true))
        XCTAssertTrue(match("images/Thumbs.db", false))
        XCTAssertFalse(match("src", true))
        XCTAssertFalse(match("src/node_modules.js", false))
        XCTAssertFalse(match("src/app.js", false))
        // A folder named like a file the pattern names isn't that file.
        XCTAssertFalse(match("my_node_modules", true))
    }

    func testInvalidOrEmptyPatternLeavesNothingOut() {
        XCTAssertFalse(DeveloperWorkspace.isValidExcludePattern("/node_modules/|("))
        XCTAssertTrue(DeveloperWorkspace.isValidExcludePattern(""))
        XCTAssertTrue(DeveloperWorkspace.isValidExcludePattern(DeveloperWorkspace.defaultExcludePattern))
        XCTAssertNil(DeveloperWorkspace.excludeExpression("("))
        XCTAssertNil(DeveloperWorkspace.excludeExpression(""))
        XCTAssertFalse(DeveloperWorkspace.matchesExcludePattern("node_modules", isFolder: true, expression: nil))
    }

    func testPatternAppliesWhenListingAndIsKept() throws {
        let suite = "DeveloperWorkspaceExcludePatternTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try DeveloperLocalOverrides.writeText("1", to: folder.appendingPathComponent("src/app.js"))
        try DeveloperLocalOverrides.writeText("2", to: folder.appendingPathComponent("node_modules/lib/index.js"))
        try DeveloperLocalOverrides.writeText("3", to: folder.appendingPathComponent("dist/bundle.js"))

        let workspace = DeveloperWorkspace(defaults: defaults)
        XCTAssertEqual(workspace.excludePattern, DeveloperWorkspace.defaultExcludePattern)
        workspace.add(folder, origin: "http://localhost:3000")
        let item = try XCTUnwrap(workspace.folders.first)
        XCTAssertEqual(Set(workspace.files(in: item)), ["src/app.js", "dist/bundle.js"])

        workspace.setExcludePattern("/dist/")
        XCTAssertEqual(Set(workspace.files(in: item)), ["src/app.js", "node_modules/lib/index.js"])

        // An invalid pattern is ignored: nothing is left out by it.
        workspace.setExcludePattern("/dist/|(")
        XCTAssertEqual(Set(workspace.files(in: item)), ["src/app.js", "node_modules/lib/index.js", "dist/bundle.js"])

        let again = DeveloperWorkspace(defaults: defaults)
        XCTAssertEqual(again.excludePattern, "/dist/|(")
    }
}
