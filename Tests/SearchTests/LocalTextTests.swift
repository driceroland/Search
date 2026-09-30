import Foundation
import XCTest
@testable import Search

final class LocalTextTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("local text \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, _ data: Data) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    func testTextIsItsWhole() throws {
        let text = Data("all:\n\techo 你好\n".utf8)
        XCTAssertEqual(LocalText.contents(of: try make("Makefile", text)), text)
    }

    func testEmptyFileIsText() throws {
        XCTAssertEqual(LocalText.contents(of: try make("empty", Data())), Data())
    }

    func testBinaryIsNotText() throws {
        XCTAssertNil(LocalText.contents(of: try make("blob", Data([0x50, 0x4b, 0x03, 0x00, 0x14]))))
        XCTAssertNil(LocalText.contents(of: try make("latin", Data([0x63, 0x61, 0x66, 0xe9]))))
    }

    func testFileOverTheLimitIsNotShown() throws {
        let file = try make("big.log", Data(repeating: 0x61, count: 100))
        XCTAssertNotNil(LocalText.contents(of: file, limit: 100))
        XCTAssertNil(LocalText.contents(of: file, limit: 99))
    }

    func testMissingFileAndFolderAreNotText() {
        XCTAssertNil(LocalText.contents(of: folder.appendingPathComponent("missing")))
        XCTAssertNil(LocalText.contents(of: folder))
    }
}
