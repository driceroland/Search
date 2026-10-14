import Foundation
import XCTest
@testable import Search

/// A folder's extension keeps only the links that lead inside it.
@available(macOS 15.4, *)
final class ExtensionFolderLinkTests: XCTestCase {
    func testLinksLeadingOutOrNowhereAreTakenOut() throws {
        let files = FileManager.default
        let top = files.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)", isDirectory: true)
        let package = top.appendingPathComponent("package", isDirectory: true)
        let outside = top.appendingPathComponent("outside", isDirectory: true)
        try files.createDirectory(at: package.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: top) }
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        try Data("0".utf8).write(to: package.appendingPathComponent("a.js"))
        func link(_ name: String, _ to: String) throws {
            try files.createSymbolicLink(atPath: package.appendingPathComponent(name).path, withDestinationPath: to)
        }
        try link("in.js", "a.js")
        try link("chain.js", "in.js")
        try link("sub/up.js", "../a.js")
        try link("out.js", secret.path)
        try link("sub/escape.js", "../../outside/secret.txt")
        try link("folder", outside.path)
        try link("nowhere.js", "/nonexistent-\(UUID().uuidString)")
        try link("via.js", "folder/secret.txt")

        try Extensions.unlinkOutside(package)

        func present(_ name: String) -> Bool {
            (try? files.attributesOfItem(atPath: package.appendingPathComponent(name).path)) != nil
        }
        for kept in ["a.js", "in.js", "chain.js", "sub/up.js"] { XCTAssertTrue(present(kept), "\(kept) was taken out") }
        for gone in ["out.js", "sub/escape.js", "folder", "nowhere.js", "via.js"] { XCTAssertFalse(present(gone), "\(gone) was kept") }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "secret", "a file outside was touched")
    }
}
