import XCTest
@testable import Search

/// windows.json while the app is still launching: the windows open written,
/// then last time's not yet brought back, each window once (see
/// Browsers.carried).
@MainActor
final class WindowCarryTests: XCTestCase {
    private func window(_ frame: String) -> WindowRecord {
        var record = WindowRecord()
        record.frame = frame
        return record
    }

    func testSavingDuringLaunchWritesEachWindowOnce() {
        // Last time: the first window, then three others not yet restored.
        let last = [window("old first"), window("a"), window("b"), window("c")]
        var file = last
        // Open before they come back: the first window, a new one, and one
        // of last time's, as they are now.
        var first = window("first 0")
        var opened = window("new 0")
        var a = last[1]
        a.frame = "a now 0"
        for save in 1...6 {
            first.frame = "first \(save)"
            opened.frame = "new \(save)"
            a.frame = "a now \(save)"
            file = Browsers.carried([first, opened, a], over: file)
            let ids = file.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "save \(save) wrote a window twice")
            XCTAssertEqual(ids, [first.id, opened.id, a.id, last[2].id, last[3].id],
                           "save \(save): the open windows, then the ones not yet back, none lost")
            XCTAssertEqual(file[1].frame, "new \(save)")
            XCTAssertEqual(file[2].frame, "a now \(save)", "the open window's state wins over the stored one")
        }
    }

    func testFileAlreadyDoubledUpIsWrittenOnce() {
        let b = window("b"), c = window("c")
        let doubled = [window("old first"), b, c, b, c, b, c]
        let first = window("first")
        XCTAssertEqual(Browsers.carried([first], over: doubled).map(\.id), [first.id, b.id, c.id])
    }

    func testNothingStoredWritesTheOpenWindows() {
        let first = window("first"), other = window("other")
        XCTAssertEqual(Browsers.carried([first, other], over: []).map(\.id), [first.id, other.id])
    }
}
