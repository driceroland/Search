import Foundation
import XCTest
@testable import Search

/// History saves 1.5 s after a visit, so a burst of browsing is one write.
/// Quitting inside that pause used to lose the visit: nothing ran the write
/// still waiting.
@MainActor
final class HistoryQuitTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "history-quit-\(getpid())", 1)
        super.setUp()
    }

    func testAVisitJustBeforeQuittingIsWritten() throws {
        let profile = UUID()
        let file = Store.file("history-\(profile.uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = Profiles.history(profile)

        history.record(try XCTUnwrap(URL(string: "https://example.com/")), title: "Last page")
        // What applicationWillTerminate runs, well inside the 1.5 s pause.
        Browsers.flush()

        let data = try Data(contentsOf: file)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(written.compactMap { $0["url"] as? String }, ["https://example.com/"])
        XCTAssertEqual(written.compactMap { $0["title"] as? String }, ["Last page"])
    }
}
