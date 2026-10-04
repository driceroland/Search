import Foundation
import XCTest
@testable import Search

final class AddressTests: XCTestCase {
    func testExistingPathsKeepTheirLiteralNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["report.pdf", "résumé #1? 100%.html"] {
            let file = folder.appendingPathComponent(name)
            try Data("local file".utf8).write(to: file)
            let url = try XCTUnwrap(Address.url(from: " \(file.path)\n"))
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, file.path)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
            XCTAssertEqual(Address.url(from: url.absoluteString), url)
        }
        XCTAssertNil(Address.url(from: folder.path))
        XCTAssertNil(Address.url(from: folder.appendingPathComponent("missing.pdf").path))
    }

    func testHomeRelativePath() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let file = #filePath
        try XCTSkipUnless(file.hasPrefix(home), "Checkout is outside the home directory")
        let url = try XCTUnwrap(Address.url(from: "~/" + file.dropFirst(home.count)))
        XCTAssertEqual(url.path, file)
    }

    func testAddressesAndSearchPhrasesKeepTheirMeaning() {
        XCTAssertEqual(Address.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(Address.url(from: "localhost:3000/test")?.absoluteString, "http://localhost:3000/test")
        XCTAssertEqual(Address.url(from: "https://example.com/a?q=b#c")?.absoluteString, "https://example.com/a?q=b#c")
        for text in ["", "two words", "./report.pdf", "person@example.com", "javascript:alert(1)"] {
            XCTAssertNil(Address.url(from: text), text)
        }
    }
}
