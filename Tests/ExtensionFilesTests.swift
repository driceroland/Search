import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case check(String)

    var description: String {
        switch self {
        case .check(let message): message
        }
    }
}

@main
private struct ExtensionFilesTests {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Extension Swap Tests – \(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let staged = root.appendingPathComponent(".staging café", isDirectory: true)
        let target = root.appendingPathComponent("Installed extension 東京", isDirectory: true)

        try testFreshInstall(staged: staged, target: target)
        print("PASS fresh install")

        try testReplacementAndCleanup(staged: staged, target: target)
        print("PASS atomic replacement and old-folder cleanup")

        try testMissingStagingRetry(staged: staged, target: target)
        print("PASS missing staging preserves target and can be retried")

        try testImmutableTarget(staged: staged, target: target)
        print("PASS immutable target failure preserves both directories")

        try testImmutableStaging(staged: staged, target: target)
        print("PASS immutable staging failure preserves both directories")
    }

    private static func testFreshInstall(staged: URL, target: URL) throws {
        try makeExtension(at: staged, version: "1.0", asset: "first install")
        try require(!FileManager.default.fileExists(atPath: target.path), "fresh-install target unexpectedly exists")

        try ExtensionFiles.replace(staged, at: target)

        try require(!FileManager.default.fileExists(atPath: staged.path), "fresh install left staging behind")
        try verifyExtension(at: target, version: "1.0", asset: "first install")
    }

    private static func testReplacementAndCleanup(staged: URL, target: URL) throws {
        try makeExtension(at: target, version: "1.0", asset: "old asset")
        try makeExtension(at: staged, version: "2.0", asset: "new asset")

        try ExtensionFiles.replace(staged, at: target)

        try verifyExtension(at: target, version: "2.0", asset: "new asset")
        try verifyExtension(at: staged, version: "1.0", asset: "old asset")

        try FileManager.default.removeItem(at: staged)
        try verifyExtension(at: target, version: "2.0", asset: "new asset")
    }

    private static func testMissingStagingRetry(staged: URL, target: URL) throws {
        try makeExtension(at: target, version: "1.0", asset: "kept asset")
        try require(!FileManager.default.fileExists(atPath: staged.path), "staging unexpectedly exists before missing-stage test")

        try expectFailure("missing staging") { try ExtensionFiles.replace(staged, at: target) }
        try verifyExtension(at: target, version: "1.0", asset: "kept asset")
        try expectFailure("repeated missing staging") { try ExtensionFiles.replace(staged, at: target) }
        try verifyExtension(at: target, version: "1.0", asset: "kept asset")

        try makeExtension(at: staged, version: "2.0", asset: "retried asset")
        try ExtensionFiles.replace(staged, at: target)
        try verifyExtension(at: target, version: "2.0", asset: "retried asset")
        try verifyExtension(at: staged, version: "1.0", asset: "kept asset")
    }

    private static func testImmutableTarget(staged: URL, target: URL) throws {
        try reset(staged: staged, target: target)
        try makeExtension(at: target, version: "1.0", asset: "protected old asset")
        try makeExtension(at: staged, version: "2.0", asset: "staged new asset")

        try withImmutable(target, clearPaths: [target, staged]) {
            try expectFailure("immutable target") { try ExtensionFiles.replace(staged, at: target) }
            try verifyExtension(at: target, version: "1.0", asset: "protected old asset")
            try verifyExtension(at: staged, version: "2.0", asset: "staged new asset")
        }

        try verifyExtension(at: target, version: "1.0", asset: "protected old asset")
    }

    private static func testImmutableStaging(staged: URL, target: URL) throws {
        try reset(staged: staged, target: target)
        try makeExtension(at: target, version: "1.0", asset: "old asset")
        try makeExtension(at: staged, version: "2.0", asset: "protected staged asset")

        try withImmutable(staged, clearPaths: [target, staged]) {
            try expectFailure("immutable staging") { try ExtensionFiles.replace(staged, at: target) }
            try verifyExtension(at: target, version: "1.0", asset: "old asset")
            try verifyExtension(at: staged, version: "2.0", asset: "protected staged asset")
        }

        try verifyExtension(at: target, version: "1.0", asset: "old asset")
    }

    private static func makeExtension(at folder: URL, version: String, asset: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let assets = folder.appendingPathComponent("assets", isDirectory: true)
        try files.createDirectory(at: assets, withIntermediateDirectories: true)
        let manifest = "{\"name\":\"Swap Test\",\"version\":\"\(version)\"}"
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data(asset.utf8).write(to: assets.appendingPathComponent("icon data.txt"))
    }

    private static func verifyExtension(at folder: URL, version: String, asset: String) throws {
        let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        try require(manifest == "{\"name\":\"Swap Test\",\"version\":\"\(version)\"}", "unexpected manifest at \(folder.path): \(manifest)")
        let icon = try String(contentsOf: folder.appendingPathComponent("assets/icon data.txt"), encoding: .utf8)
        try require(icon == asset, "unexpected asset at \(folder.path): \(icon)")
    }

    private static func reset(staged: URL, target: URL) throws {
        for path in [staged, target] where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private static func expectFailure(_ operation: String, _ body: () throws -> Void) throws {
        var failed = false
        do {
            try body()
        } catch {
            failed = true
        }
        try require(failed, "expected \(operation) to fail")
    }

    private static func withImmutable(_ path: URL, clearPaths: [URL], _ body: () throws -> Void) throws {
        try setFlags(UInt32(UF_IMMUTABLE), at: path)
        var fullyCleared = false
        defer {
            if !fullyCleared {
                for candidate in clearPaths { try? setFlags(0, at: candidate) }
            }
        }

        var bodyError: Error?
        do { try body() } catch { bodyError = error }

        var clearError: Error?
        for candidate in clearPaths {
            do { try setFlags(0, at: candidate) }
            catch { if clearError == nil { clearError = error } }
        }
        fullyCleared = clearError == nil
        if let clearError { throw clearError }
        if let bodyError { throw bodyError }
    }

    private static func setFlags(_ flags: UInt32, at path: URL) throws {
        let result = path.path.withCString { chflags($0, flags) }
        guard result == 0 else {
            throw TestFailure.check("chflags(\(path.path)) failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure.check(message) }
    }
}
