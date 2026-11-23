import Foundation
import XCTest
@testable import Search

/// The tabs Search closed by itself (Archive.swift): newest first, a month
/// and five hundred at most, each profile's apart, and still there after
/// a relaunch.
@MainActor
final class ArchiveTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var files: [String] = []

    override func tearDown() {
        for name in files { try? FileManager.default.removeItem(at: Store.file(name)) }
        files = []
        super.tearDown()
    }

    /// An archive on a file of its own, removed with the test.
    private func fresh() -> Archive {
        let name = "archive-test-\(UUID().uuidString).json"
        files.append(name)
        return Archive(file: name)
    }

    private func site(_ i: Int) -> URL { URL(string: "https://site\(i).example/page")! }

    func testAddsNewestFirstAndMovesARepeatToTheTop() {
        let archive = fresh()
        let now = Date()
        archive.add(site(1), title: "One", at: now.addingTimeInterval(-60))
        archive.add(site(2), title: "Two", at: now.addingTimeInterval(-30))
        XCTAssertEqual(archive.tabs.map(\.title), ["Two", "One"])
        archive.add(site(1), title: "One again", at: now)
        XCTAssertEqual(archive.tabs.map(\.title), ["One again", "Two"], "one line per page")
    }

    func testKeepsNoMoreThanTheCapAndTheNewest() {
        let archive = fresh()
        let start = Date().addingTimeInterval(-3_600)
        for i in 0..<(Archive.cap + 40) {
            archive.add(site(i), title: "Tab \(i)", at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(archive.tabs.count, Archive.cap)
        XCTAssertEqual(archive.tabs.first?.url, site(Archive.cap + 39))
        XCTAssertFalse(archive.tabs.contains { $0.url == site(39) }, "the oldest went")
        XCTAssertTrue(archive.tabs.contains { $0.url == site(40) })
    }

    func testAMonthOldTabGoes() {
        let archive = fresh()
        let now = Date()
        archive.add(site(1), title: "Old", at: now.addingTimeInterval(-Archive.lasts - 60))
        archive.add(site(2), title: "Recent", at: now.addingTimeInterval(-86_400))
        XCTAssertEqual(archive.tabs.map(\.title), ["Recent"], "past its month, it is not kept")
        // Not listed past its month even before anything else is added.
        XCTAssertEqual(archive.listed(now: now.addingTimeInterval(Archive.lasts)).count, 0)
    }

    func testSearchMatchesTitleAndAddress() {
        let archive = fresh()
        archive.add(URL(string: "https://docs.example/swift")!, title: "Swift Guide")
        archive.add(URL(string: "https://news.example/today")!, title: "Headlines")
        XCTAssertEqual(archive.listed(matching: "swift").map(\.title), ["Swift Guide"])
        XCTAssertEqual(archive.listed(matching: "NEWS today").map(\.title), ["Headlines"])
        XCTAssertEqual(archive.listed(matching: "nothing").count, 0)
        XCTAssertEqual(archive.listed().count, 2)
    }

    func testRemoveAndClear() {
        let archive = fresh()
        archive.add(site(1), title: "One")
        archive.add(site(2), title: "Two")
        archive.remove(archive.tabs[0].id)
        XCTAssertEqual(archive.tabs.map(\.title), ["One"])
        archive.clear()
        XCTAssertTrue(archive.tabs.isEmpty)
    }

    func testNoNameOrPasswordIsKept() {
        let archive = fresh()
        archive.add(URL(string: "https://me:secret@site.example/x")!, title: "Signed")
        XCTAssertEqual(archive.tabs.first?.url.absoluteString, "https://site.example/x")
    }

    func testSurvivesARelaunch() {
        let archive = fresh()
        let closed = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded())
        archive.add(site(1), title: "One", at: closed.addingTimeInterval(-1))
        archive.add(site(2), title: "Two", at: closed)
        Disk.drain()
        let again = Archive(file: archive.file.lastPathComponent)
        XCTAssertEqual(again.tabs, archive.tabs)
        XCTAssertEqual(again.tabs.first?.closed, closed)

        again.clear()
        Disk.drain()
        XCTAssertTrue(Archive(file: archive.file.lastPathComponent).tabs.isEmpty)
    }

}
