import XCTest
@testable import Search

/// Small Chrome DevTools features: APCA contrast,
/// console Expand all / Collapse all and history edits,
/// regex style filters and grid-auto-flow's dense checkbox.
@MainActor
final class DeveloperChromeParityTests: XCTestCase {
    // MARK: APCA

    func testAPCAMatchesKnownValues() {
        let white = DeveloperCSSColor.white, black = DeveloperCSSColor.black
        let gray = DeveloperCSSColor(red: 0x88, green: 0x88, blue: 0x88)
        XCTAssertEqual(DeveloperContrastFix.apca(gray, white), 63.056, accuracy: 0.01)
        XCTAssertEqual(DeveloperContrastFix.apca(black, white), 106.04, accuracy: 0.01)
        XCTAssertEqual(DeveloperContrastFix.apca(white, black), -107.885, accuracy: 0.01)
        XCTAssertEqual(DeveloperContrastFix.apca(white, white), 0)
        XCTAssertEqual(DeveloperContrastFix.apcaLabel(63.056), "Lc 63.1")
    }

    func testAPCALineSuggestsAPassingColor() throws {
        let gray = DeveloperCSSColor(red: 0x88, green: 0x88, blue: 0x88)
        let lines = DeveloperContrastFix.lines(foreground: gray, background: .white, large: false, apca: true)
        XCTAssertEqual(lines.map(\.level), ["APCA"])
        XCTAssertFalse(lines[0].passes)
        let fix = try XCTUnwrap(lines[0].fix)
        XCTAssertGreaterThanOrEqual(abs(DeveloperContrastFix.apca(fix, .white)), 75)
        XCTAssertTrue(DeveloperContrastFix.lines(foreground: gray, background: .white, large: true, apca: true)[0].passes)
    }

    // MARK: Console

    func testHistoryKeepsEditsToRecalledEntries() {
        var cursor = DeveloperConsoleHistoryCursor()
        let history = ["a", "b"]
        XCTAssertEqual(cursor.move(-1, from: "draft", in: history), "b")
        XCTAssertEqual(cursor.move(-1, from: "b edited", in: history), "a")
        XCTAssertEqual(cursor.move(1, from: "a", in: history), "b edited")
        XCTAssertEqual(cursor.move(1, from: "b edited", in: history), "draft")
        XCTAssertEqual(cursor.edits, [1: "b edited"])
        var empty = DeveloperConsoleHistoryCursor()
        XCTAssertNil(empty.move(-1, from: "x", in: []))
    }

    func testExpandAllAndCollapseAllSetEveryGroup() {
        typealias Line = DeveloperToolsSession.ConsoleLine
        let open = Line(level: "log", text: "open", details: ConsoleMessageDetails(type: "startGroup"))
        let closed = Line(level: "log", text: "closed", details: ConsoleMessageDetails(type: "startGroupCollapsed"))
        let lines = [open, closed, Line(level: "log", text: "x")]
        let store = DeveloperConsoleStore()
        store.expanded = ["stale"]
        store.setAllExpanded(true, lines: lines)
        XCTAssertEqual(store.toggledGroups, [closed.id])
        store.setAllExpanded(false, lines: lines)
        XCTAssertEqual(store.toggledGroups, [open.id])
        XCTAssertTrue(store.expanded.isEmpty)
        let rows = ConsoleLayout.rows(lines, levels: store.levels, filter: "", toggled: store.toggledGroups)
        XCTAssertTrue(rows.filter(\.opensGroup).allSatisfy(\.collapsed))
    }

    // MARK: Styles

    func testRegexStyleFilter() {
        XCTAssertTrue(DeveloperStyleFilter.matches("margin-top: 4px", "/^MARGIN-(top|left)/"))
        XCTAssertFalse(DeveloperStyleFilter.matches("padding-top: 4px", "/^margin/"))
        // An invalid pattern is plain text.
        XCTAssertTrue(DeveloperStyleFilter.matches("content: \"/(/\"", "/(/"))
        XCTAssertFalse(DeveloperStyleFilter.matches("color: red", "/(/"))
        XCTAssertTrue(DeveloperStyleFilter.matches("color: red", "COLOR"))
        XCTAssertTrue(DeveloperStyleFilter.matches("anything", ""))
    }

    func testGridAutoFlowDense() {
        let flow = DeveloperLayoutEditor.autoFlow("column dense")
        XCTAssertEqual(flow.direction, "column")
        XCTAssertTrue(flow.dense)
        XCTAssertNil(DeveloperLayoutEditor.autoFlow("dense").direction)
        XCTAssertFalse(DeveloperLayoutEditor.autoFlow(nil).dense)
        XCTAssertEqual(DeveloperLayoutEditor.autoFlow(direction: "row", dense: true), "row dense")
        XCTAssertEqual(DeveloperLayoutEditor.autoFlow(direction: nil, dense: true), "dense")
        XCTAssertNil(DeveloperLayoutEditor.autoFlow(direction: nil, dense: false))
    }
}
