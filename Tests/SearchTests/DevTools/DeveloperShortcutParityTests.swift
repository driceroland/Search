import AppKit
import XCTest
@testable import Search

/// Chrome DevTools' keyboard shortcuts in Perch (docs/devtools-shortcuts-parity.md):
/// which key means what in which panel, and the code editor's commands.
@MainActor
final class DeveloperShortcutParityTests: XCTestCase {
    private func action(_ keyCode: UInt16, _ key: String = "", _ flags: NSEvent.ModifierFlags = [],
                        _ state: DeveloperToolsKeyState = .init()) -> DeveloperToolsKeyAction? {
        DeveloperToolsKeyRouting.action(keyCode: keyCode, key: key, flags: flags, state: state)
    }

    private func panel(_ panel: DeveloperPanel, focus: DeveloperToolsKeyFocus = .panel) -> DeveloperToolsKeyState {
        DeveloperToolsKeyState(focus: focus, panel: panel)
    }

    // MARK: All panels

    func testGoToSymbolAndLineWorkFromAnyPanel() {
        XCTAssertEqual(action(31, "o", [.command, .shift], panel(.elements)), .commandMenu("@"))
        XCTAssertEqual(action(5, "g", [.control], panel(.sources)), .commandMenu(":"))
        // ⌃G is Go to line in Sources only.
        XCTAssertNil(action(5, "g", [.control], panel(.network)))
        XCTAssertEqual(action(35, "p", [.command], panel(.network)), .commandMenu(""))
        XCTAssertEqual(action(3, "f", [.command, .option], panel(.elements)), .searchAllFiles)
    }

    func testControlBacktickFocusesTheConsoleFromAnywhere() {
        XCTAssertEqual(action(DeveloperToolsKeyRouting.grave, "`", [.control], panel(.elements)), .focusConsole)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.grave, "`", [.control], panel(.sources, focus: .code)), .focusConsole)
    }

    func testQuestionMarkShowsSettingsOnlyWhenNothingTakesTyping() {
        XCTAssertEqual(action(44, "?", [.shift], panel(.elements)), .settings)
        XCTAssertNil(action(44, "?", [.shift], panel(.elements, focus: .field)))
        XCTAssertNil(action(44, "?", [.shift], panel(.console, focus: .editor)))
    }

    func testNumberKeysSwitchPanelsOnlyWhenTheSettingIsOn() {
        XCTAssertNil(action(18, "1", [.command], panel(.elements)))
        var on = panel(.elements)
        on.numberKeysSwitchPanels = true
        XCTAssertEqual(action(18, "1", [.command], on), .selectPanel(0))
        XCTAssertEqual(action(25, "9", [.command], on), .selectPanel(8))
        XCTAssertNil(action(29, "0", [.command, .option], on))
        // ⌘0 stays Reset zoom.
        XCTAssertEqual(action(29, "0", [.command], on), .zoom(0))
    }

    func testBrowserKeysThatMeanSomethingElseInDevToolsAreKept() {
        for key in ["f", "g", "e", "s", "p", "o", "/", "u"] {
            XCTAssertTrue(DeveloperToolsKeyRouting.keepsFromBrowser(key: key, flags: .command), key)
        }
        XCTAssertTrue(DeveloperToolsKeyRouting.keepsFromBrowser(key: "g", flags: [.command, .shift]))
        // The browser's tab, window and reload keys still work from DevTools.
        for key in ["w", "t", "n", "r", "l", "q", "1"] {
            XCTAssertFalse(DeveloperToolsKeyRouting.keepsFromBrowser(key: key, flags: .command), key)
        }
    }

    // MARK: Console

    func testConsoleClearKeys() {
        XCTAssertEqual(action(40, "k", [.command], panel(.console)), .clearConsole)
        XCTAssertEqual(action(40, "k", [.command], panel(.console, focus: .editor)), .clearConsole)
        XCTAssertEqual(action(37, "l", [.control], panel(.console, focus: .editor)), .clearConsole)
        XCTAssertEqual(action(37, "l", [.option], panel(.console)), .clearConsole)
        // In the filter field ⌥L and ⌃L are typing.
        XCTAssertNil(action(37, "l", [.option], panel(.console, focus: .field)))
        // ⌘K outside the Console stays the browser's.
        XCTAssertNil(action(40, "k", [.command], panel(.elements)))
    }

    func testFindIsThePanelsOwn() {
        XCTAssertEqual(action(3, "f", [.command], panel(.console)), .findInConsole)
        XCTAssertEqual(action(3, "f", [.command], panel(.network)), .findInNetwork)
        // Elements' and Sources' ⌘F are their own monitors' (asked first).
        XCTAssertNil(action(3, "f", [.command], panel(.elements)))
    }

    // MARK: Network

    func testNetworkRecordAndEscape() {
        XCTAssertEqual(action(14, "e", [.command], panel(.network)), .recordNetwork)
        var open = panel(.network)
        open.detailsOpen = true
        XCTAssertEqual(action(DeveloperToolsKeyRouting.escape, "\u{1b}", [], open), .closeDetails)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.escape, "\u{1b}", [], panel(.network)), .toggleDrawer)
        // Details open, but typing in a field: the field's Esc.
        open.focus = .field
        XCTAssertNil(action(DeveloperToolsKeyRouting.escape, "\u{1b}", [], open))
    }

    // MARK: Performance

    func testPerformanceRecordKeys() {
        XCTAssertEqual(action(14, "e", [.command], panel(.performance)), .recordPerformance(reload: false))
        XCTAssertEqual(action(14, "e", [.command, .shift], panel(.performance)), .recordPerformance(reload: true))
        XCTAssertNil(action(14, "e", [.command], panel(.elements)))
    }

    func testPerformanceSaveAndLoadProfileKeys() {
        XCTAssertEqual(action(1, "s", [.command], panel(.performance)), .performanceProfile(save: true))
        XCTAssertEqual(action(31, "o", [.command], panel(.performance)), .performanceProfile(save: false))
        XCTAssertEqual(action(31, "o", [.command], panel(.elements)), .commandMenu(""), "⌘O is Open file elsewhere")
        XCTAssertNil(action(1, "s", [.command], panel(.elements)))
        XCTAssertEqual(action(31, "o", [.command, .shift], panel(.performance)), .commandMenu("@"))
    }

    // MARK: Sources and the debugger

    func testSourcesPanelKeys() {
        XCTAssertEqual(action(16, "y", [.command, .shift], panel(.sources)), .toggleNavigator)
        XCTAssertEqual(action(4, "h", [.command, .shift], panel(.sources)), .toggleDebuggerSidebar)
        XCTAssertEqual(action(1, "s", [.command, .option], panel(.sources, focus: .code)), .saveAll)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.pageDown, "", [.command, .function], panel(.sources)), .sourceTab(1))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.pageUp, "", [.command], panel(.sources)), .sourceTab(-1))
        // ⇧⌘H elsewhere is the browser's.
        XCTAssertNil(action(4, "h", [.command, .shift], panel(.elements)))
    }

    func testCallFrameKeysOnlyWhilePaused() {
        var paused = panel(.sources)
        paused.paused = true
        XCTAssertEqual(action(47, ".", [.control], paused), .callFrame(1))
        XCTAssertEqual(action(43, ",", [.control], paused), .callFrame(-1))
        XCTAssertNil(action(47, ".", [.control], panel(.sources)))
    }

    func testSearchResultsExpandAndCollapseOnlyWithResults() {
        var shown = panel(.sources)
        shown.searchResultsShown = true
        let right = DeveloperToolsKeyRouting.rightBracket, left = DeveloperToolsKeyRouting.leftBracket
        XCTAssertEqual(action(right, "}", [.command, .option, .shift], shown), .searchResults(expanded: true))
        XCTAssertEqual(action(left, "{", [.command, .option, .shift], shown), .searchResults(expanded: false))
        XCTAssertNil(action(right, "}", [.command, .option, .shift], panel(.sources)))
    }

    func testOpenFileTabsStepRoundTheEnds() {
        let tabs = ["a", "b", "c"]
        XCTAssertEqual(DeveloperSourceTabs.adjacent(tabs, from: "c", by: 1), "a")
        XCTAssertEqual(DeveloperSourceTabs.adjacent(tabs, from: "a", by: -1), "c")
        XCTAssertEqual(DeveloperSourceTabs.adjacent(tabs, from: "b", by: 1), "c")
        XCTAssertEqual(DeveloperSourceTabs.adjacent(tabs, from: nil, by: 1), "a")
        XCTAssertEqual(DeveloperSourceTabs.adjacent(tabs, from: nil, by: -1), "c")
        XCTAssertNil(DeveloperSourceTabs.adjacent([String](), from: nil, by: 1))
    }

    // MARK: Toggle comment (⌘/)

    func testCommentAddsALineCommentAndKeepsTheCaretOnItsCode() {
        let edit = SourceEditing.toggleComment("let a = 1\nlet b = 2", selection: NSRange(location: 4, length: 0), language: .js)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 9))
        XCTAssertEqual(edit?.replacement, "// let a = 1")
        XCTAssertEqual(edit?.selection, NSRange(location: 7, length: 0))
    }

    func testCommentComesOffWhenEveryLineHasOne() {
        let text = "  // x\n  // y"
        let edit = SourceEditing.toggleComment(text, selection: NSRange(location: 0, length: 13), language: .js)
        XCTAssertEqual(edit?.replacement, "  x\n  y")
        XCTAssertEqual(edit?.selection, NSRange(location: 0, length: 7))
        let caret = SourceEditing.toggleComment("  // x", selection: NSRange(location: 6, length: 0), language: .js)
        XCTAssertEqual(caret?.replacement, "  x")
        XCTAssertEqual(caret?.selection, NSRange(location: 3, length: 0))
    }

    func testCommentGoesInAtTheSharedIndentAndSkipsBlankLines() {
        let edit = SourceEditing.toggleComment("a\n\n  b", selection: NSRange(location: 0, length: 5), language: .js)
        XCTAssertEqual(edit?.replacement, "// a\n\n//   b")
        // Some lines commented, some not: all get one.
        let mixed = SourceEditing.toggleComment("// a\nb", selection: NSRange(location: 0, length: 6), language: .js)
        XCTAssertEqual(mixed?.replacement, "// // a\n// b")
    }

    func testSelectionEndingAtALineStartLeavesThatLineOut() {
        let edit = SourceEditing.toggleComment("a\nb\nc", selection: NSRange(location: 0, length: 2), language: .js)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(edit?.replacement, "// a")
    }

    func testBlockCommentsForCSSAndHTML() {
        let css = SourceEditing.toggleComment("a { color: red; }", selection: NSRange(location: 0, length: 0), language: .css)
        XCTAssertEqual(css?.replacement, "/* a { color: red; } */")
        let back = SourceEditing.toggleComment("/* a { color: red; } */", selection: NSRange(location: 0, length: 0), language: .css)
        XCTAssertEqual(back?.replacement, "a { color: red; }")
        let html = SourceEditing.toggleComment("  <p>hi</p>", selection: NSRange(location: 3, length: 0), language: .html)
        XCTAssertEqual(html?.replacement, "  <!-- <p>hi</p> -->")
        XCTAssertNil(SourceEditing.toggleComment("{\"a\": 1}", selection: NSRange(location: 0, length: 0), language: .json))
    }

    // MARK: Select next occurrence (⌘D)

    func testNextOccurrenceStartsWithTheWordThenAddsEachNextOne() {
        let text = "foo bar foo baz foo"
        let word = SourceEditing.addNextOccurrence(text, selections: [NSRange(location: 1, length: 0)])
        XCTAssertEqual(word, [NSRange(location: 0, length: 3)])
        let two = SourceEditing.addNextOccurrence(text, selections: word ?? [])
        XCTAssertEqual(two, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        let three = SourceEditing.addNextOccurrence(text, selections: two ?? [])
        XCTAssertEqual(three?.last, NSRange(location: 16, length: 3))
        XCTAssertNil(SourceEditing.addNextOccurrence(text, selections: three ?? []))
    }

    func testNextOccurrenceGoesRoundToTheTop() {
        let text = "foo bar foo baz foo"
        let wrapped = SourceEditing.addNextOccurrence(text, selections: [NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)])
        XCTAssertEqual(wrapped?.last, NSRange(location: 0, length: 3))
        XCTAssertEqual(wrapped?.count, 3)
    }

    func testNextOccurrenceNeedsAWordAtTheCaret() {
        XCTAssertNil(SourceEditing.addNextOccurrence("a  b", selections: [NSRange(location: 2, length: 0)]))
        XCTAssertEqual(SourceEditing.wordRange("x = $el_1;", at: 6), NSRange(location: 4, length: 5))
    }

    // MARK: Matching bracket (⌃M)

    func testMatchingBracketCountsNesting() {
        let text = "f(a[b]{c})"
        XCTAssertEqual(SourceEditing.matchingBracket(text, at: 1), 9)
        XCTAssertEqual(SourceEditing.matchingBracket(text, at: 10), 1)
        XCTAssertEqual(SourceEditing.matchingBracket(text, at: 4), 5)
        XCTAssertEqual(SourceEditing.matchingBracket(text, at: 6), 8)
        XCTAssertNil(SourceEditing.matchingBracket("abc", at: 1))
        XCTAssertNil(SourceEditing.matchingBracket("(()", at: 0))
    }
}
