import WebKit
import XCTest
@testable import Search

/// How far up a page opened from disk may read (#1342): two folders, never
/// the home folder or a folder directly in it, however the path is spelled.
/// A folder of the temporary directory stands in for the home folder.
@available(macOS 14, *)
final class FileReadRootTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("readroot-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Docs/site/a/b"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Docs/link"), withDestinationURL: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testTwoFoldersUpWithinAFolderOfHome() {
        let folder = home.appendingPathComponent("Docs/site/a/b")
        XCTAssertEqual(WKWebView.readRoot(folder, home: home).path, home.appendingPathComponent("Docs/site").path)
    }

    func testNeverAFolderDirectlyInHome() {
        let folder = home.appendingPathComponent("Docs/site/a")
        XCTAssertEqual(WKWebView.readRoot(folder, home: home).path, home.appendingPathComponent("Docs/site").path)
    }

    /// A link to the home folder is the home folder: Docs/link/Docs/site
    /// is Docs/site, and Docs/link/Docs is Docs, a folder directly in home.
    func testALinkToHomeIsHome() {
        let folder = home.appendingPathComponent("Docs/link/Docs/site/a")
        XCTAssertEqual(WKWebView.readRoot(folder, home: home).path,
                       home.appendingPathComponent("Docs/link/Docs/site").path)
    }

    /// The home folder in another case is the home folder (APFS ignores case).
    func testAnotherCaseIsHome() throws {
        let upper = URL(fileURLWithPath: home.path.uppercased())
        try XCTSkipUnless(FileManager.default.fileExists(atPath: upper.path), "case-sensitive volume")
        let folder = upper.appendingPathComponent("DOCS/SITE/A")
        XCTAssertEqual(WKWebView.readRoot(folder, home: home).path, upper.appendingPathComponent("DOCS/SITE").path)
    }

    func testSameItemFollowsLinks() {
        XCTAssertTrue(WKWebView.sameItem(home.appendingPathComponent("Docs/link"), home))
        XCTAssertFalse(WKWebView.sameItem(home.appendingPathComponent("Docs"), home))
        XCTAssertFalse(WKWebView.sameItem(home.appendingPathComponent("missing"), home))
    }

    func testTheDataVolumeIsAVolume() {
        XCTAssertTrue(WKWebView.isVolume(URL(fileURLWithPath: "/")))
        XCTAssertFalse(WKWebView.isVolume(home))
    }
}
