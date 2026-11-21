import XCTest
@testable import Search

final class DownloadFoldersTests: XCTestCase {
    func testFolders() {
        XCTAssertEqual(Browser.downloadFolders("a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("photos/2026/a.jpg"), ["photos", "2026"])
        XCTAssertEqual(Browser.downloadFolders("/etc/a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("../a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("x/../../a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("x//a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("~/a.jpg"), [])
        XCTAssertEqual(Browser.downloadFolders("./a.jpg"), [])
    }

    /// A folder Search can't write to is found out before WebKit fails on
    /// it with "Cannot create file" (#1291), and nothing is left behind.
    func testCanWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("can-write-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        let open = root.appendingPathComponent("open")
        XCTAssertTrue(Browser.canWrite(in: open), "a missing folder is made")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: open.path), [])
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        XCTAssertFalse(Browser.canWrite(in: locked))
        XCTAssertFalse(Browser.canWrite(in: URL(fileURLWithPath: "/System/search-can-write")))
    }
}
