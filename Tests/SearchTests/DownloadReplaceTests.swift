import XCTest
@testable import Search

/// A download saved over a file that is there, after the save panel's
/// Replace: WebKit refuses to write over a file, so it failed at once and a
/// retry made "Photo 1 2.jpg" beside the old one (#1598).
final class DownloadReplaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNothingThereIsLeftAsIs() {
        let file = root.appendingPathComponent("Photo 1.jpg")
        var removed: [URL] = []
        XCTAssertEqual(Browser.clearing(file, remove: { removed.append($0) }), file)
        XCTAssertEqual(removed, [])
    }

    func testReplacedFileMakesWay() throws {
        let file = root.appendingPathComponent("Photo 1.jpg")
        try Data("old".utf8).write(to: file)
        let to = Browser.clearing(file, remove: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(to, file, "the name you chose is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the old file is out of the way")
    }

    func testFileThatWontGoGetsAFreeName() throws {
        let file = root.appendingPathComponent("Photo 1.jpg")
        try Data("old".utf8).write(to: file)
        let to = Browser.clearing(file, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(to.lastPathComponent, "Photo 1 2.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the old file is left alone")
    }
}
