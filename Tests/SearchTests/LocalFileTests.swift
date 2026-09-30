import Foundation
import XCTest
@testable import Search

final class LocalFileTests: XCTestCase {
    /// WebKit loads nothing, and says nothing, when the file is not under the
    /// folder it was told it may read: the folder has to be spelled the way
    /// the file is.
    func testFolderIsSpelledLikeTheFile() {
        for path in ["/private/tmp/page.html", "/private/etc/notes.pdf", "/tmp/page.html"] {
            let file = URL(fileURLWithPath: path)
            XCTAssertTrue(file.path.hasPrefix(file.readableFolder.path + "/"), path)
        }
    }

    func testFileInAWideFolderReadsOnlyItself() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for file in [home.appendingPathComponent("a.pdf"), URL(fileURLWithPath: "/a.pdf"),
                     URL(fileURLWithPath: "/Volumes/Disk/a.pdf")] {
            XCTAssertEqual(file.readableFolder, file, file.path)
        }
    }

    func testFileBesideItsPicturesReadsItsFolder() {
        let file = URL(fileURLWithPath: "/Users/someone/site/page.html")
        XCTAssertEqual(file.readableFolder.path, "/Users/someone/site")
    }
}
