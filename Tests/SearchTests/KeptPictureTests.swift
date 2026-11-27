import AppKit
import WebKit
import XCTest
@testable import Search

/// A sleeping tab's picture is kept in a file, not in memory (Sleep.swift,
/// KeptPicture): the same bytes back, gone with the picture, and never
/// written for a private tab.
@MainActor
final class KeptPictureTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let jpeg = Data((0..<4096).map { UInt8($0 % 251) })

    func testItIsReadBackFromItsFile() throws {
        let kept = KeptPicture(jpeg, inMemory: false)
        XCTAssertTrue(kept.isOnDisk)
        XCTAssertEqual(kept.bytes, jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(kept.path)))
    }

    func testTheFileGoesWithThePicture() throws {
        var kept: KeptPicture? = KeptPicture(jpeg, inMemory: false)
        let path = try XCTUnwrap(kept?.path)
        kept = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAPrivatePictureIsNeverWritten() {
        let kept = KeptPicture(jpeg, inMemory: true)
        XCTAssertFalse(kept.isOnDisk)
        XCTAssertNil(kept.path)
        XCTAssertEqual(kept.bytes, jpeg)
    }

    func testASleepingTabKeepsItsPictureInAFileAndLosesItWhenItWakes() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let page = Tab(configuration: Web.configuration(space: browser.spaceID))
        page.restore(url: URL(string: "https://example.com/kept")!, title: "Kept")
        browser.insert(page, at: browser.tabs.count)
        _ = page.web
        page.sleep(picture: jpeg)
        XCTAssertEqual(page.keptPicture, jpeg)
        XCTAssertTrue(page.asleep)
        _ = page.wake()
        XCTAssertNil(page.keptPicture)
    }
}
