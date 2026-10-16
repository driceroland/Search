import Foundation
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class ExtensionWorkerLinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func package(worker: String) throws -> URL {
        let folder = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Made Up", "version": "1.0",
                                       "background": ["service_worker": worker]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    func testWorkerLinkInsidePackageBecomesShimmedCopy() throws {
        let folder = try package(worker: "background-143.js")
        try "console.log('made up worker');\n".write(to: folder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("background-143.js").path, withDestinationPath: "background.js")

        try ExtensionShims.prepare(folder, fresh: true)

        let worker = folder.appendingPathComponent("background-143.js")
        XCTAssertEqual(try worker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        let source = try String(contentsOf: worker, encoding: .utf8)
        XCTAssertTrue(source.hasPrefix(ExtensionShims.marker))
        XCTAssertTrue(source.hasSuffix("console.log('made up worker');\n"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8), "console.log('made up worker');\n")
    }

    func testWorkerUnderLinkedFolderOutsidePackageIsLeftAlone() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bystander = outside.appendingPathComponent("bg.js")
        try "made up bystander\n".write(to: bystander, atomically: true, encoding: .utf8)
        let decoy = outside.appendingPathComponent("decoy.js")
        try "made up decoy\n".write(to: decoy, atomically: true, encoding: .utf8)

        let folder = try package(worker: "sub/bg.js")
        try "made up target\n".write(to: folder.appendingPathComponent("real.js"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: bystander)
        try FileManager.default.createSymbolicLink(atPath: bystander.path, withDestinationPath: folder.appendingPathComponent("real.js").path)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("sub").path, withDestinationPath: outside.path)

        try ExtensionShims.prepare(folder, fresh: true)

        XCTAssertEqual(try bystander.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bystander.path), folder.appendingPathComponent("real.js").path)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("real.js"), encoding: .utf8), "made up target\n")
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), "made up decoy\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(), ["bg.js", "decoy.js"])
    }
}
