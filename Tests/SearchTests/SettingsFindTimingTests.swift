import XCTest
@testable import Search

/// Find a setting, one key at a time (idea 1333): each key's search over the
/// whole index stays well under a frame, and finds what it always found.
final class SettingsFindTimingTests: XCTestCase {
    /// What was typed, a key at a time.
    private let typing = ["dark", "tabs", "space", "video", "password", "sidebar", "download", "new tab",
                          "picture in picture", "keyboard shortcut", "cookies", "zoom"]

    func testEveryKeyIsFast() {
        let keys = typing.flatMap { word in (1...word.count).map { String(word.prefix($0)) } }
        _ = SettingsIndex.find("warm")
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<5 { for typed in keys { _ = SettingsIndex.find(typed) } }
        let each = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(keys.count * 5)
        // Building every row's words again took ~4 ms a key; a frame is 8–16.
        XCTAssertLessThan(each, 1, "ms per key")
    }

    func testFindsWhatItFound() {
        // The words worked out once match the row's words as they were
        // worked out at every key.
        func naive(_ typed: String) -> Set<String> {
            let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            return Set(SettingsIndex.items.filter { item in
                let hay = ([item.title, item.detail, item.more ?? "", SettingsIndex.group(item.group)?.title ?? "",
                            item.page.title] + item.words + item.keys).joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }.map(\.id))
        }
        for typed in typing + ["da", "ta", "dark mode", "sp"] {
            XCTAssertEqual(Set(SettingsIndex.find(typed).map(\.id)), naive(typed), typed)
        }
        // In the order of the sections, then of their groups.
        let pages = SettingsPanel.Page.allCases
        let found = SettingsIndex.find("ta")
        let ranks = found.map { (pages.firstIndex(of: $0.page) ?? 0) }
        XCTAssertEqual(ranks, ranks.sorted())
    }

    func testALetterAloneFindsWordsStartingWithIt() {
        let found = SettingsIndex.find("d")
        XCTAssertFalse(found.isEmpty)
        XCTAssertLessThan(found.count, SettingsIndex.items.count / 2, "Not every row with a d in it")
        XCTAssertTrue(found.contains { $0.id == "pages.dusk" }, "Darken pages")
    }
}
