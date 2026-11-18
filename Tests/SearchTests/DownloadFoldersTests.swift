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
}
