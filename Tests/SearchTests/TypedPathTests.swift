import Foundation
import XCTest
@testable import Search

final class TypedPathTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("typed path \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, in parent: URL? = nil) throws -> URL {
        let file = (parent ?? folder).appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return file
    }

    func testPathOfAFileIsThatFile() throws {
        let file = try make("my report.pdf")
        XCTAssertEqual(Address.url(from: file.path), file)
    }

    func testPathWithTildeIsInTheHomeFolder() throws {
        let file = try make("tilde-\(UUID().uuidString).txt", in: FileManager.default.homeDirectoryForCurrentUser)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(Address.url(from: "~/" + file.lastPathComponent), file)
    }

    /// Text that starts like a path but names nothing here is still a phrase
    /// for the search engine, and a folder has no page to show.
    func testPathOfNothingOrOfAFolderIsNotAnAddress() {
        XCTAssertNil(Address.url(from: folder.appendingPathComponent("missing.pdf").path))
        XCTAssertNil(Address.url(from: folder.path))
        XCTAssertNil(Address.url(from: "/r/swift"))
    }

    func testAddressesAreAsTheyWere() {
        XCTAssertEqual(Address.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(Address.url(from: "file:///tmp/a.html")?.absoluteString, "file:///tmp/a.html")
        XCTAssertNil(Address.url(from: "hello world"))
    }
}
