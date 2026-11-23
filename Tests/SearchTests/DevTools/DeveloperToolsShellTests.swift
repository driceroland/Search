import AppKit
import XCTest
@testable import Search

@MainActor
final class DeveloperToolsShellTests: XCTestCase {
    private func action(_ keyCode: UInt16, _ key: String = "", _ flags: NSEvent.ModifierFlags = [],
                        _ state: DeveloperToolsKeyState = .init()) -> DeveloperToolsKeyAction? {
        DeveloperToolsKeyRouting.action(keyCode: keyCode, key: key, flags: flags, state: state)
    }

    // MARK: Keys

    func testCommandMenuAndOpenFileKeys() {
        XCTAssertEqual(action(35, "p", [.command, .shift]), .commandMenu(">"))
        XCTAssertEqual(action(35, "p", [.command]), .commandMenu(""))
        XCTAssertEqual(action(31, "o", [.command]), .commandMenu(""))
        // ⌥⌘P and friends stay the browser's.
        XCTAssertNil(action(35, "p", [.command, .option]))
    }

    func testPanelDockDeviceAndZoomKeys() {
        XCTAssertEqual(action(33, "[", [.command]), .stepPanel(-1))
        XCTAssertEqual(action(30, "]", [.command]), .stepPanel(1))
        XCTAssertEqual(action(2, "d", [.command, .shift]), .toggleDockSide)
        XCTAssertEqual(action(46, "m", [.command, .shift]), .toggleDeviceToolbar)
        XCTAssertEqual(action(24, "=", [.command]), .zoom(1))
        XCTAssertEqual(action(24, "+", [.command, .shift]), .zoom(1))
        XCTAssertEqual(action(27, "-", [.command]), .zoom(-1))
        XCTAssertEqual(action(29, "0", [.command]), .zoom(0))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f1), .settings)
        // Modifier keys the routing doesn't care about (fn on F-keys) are ignored.
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f1, "", [.function]), .settings)
    }

    func testEscapeTogglesTheDrawerOnlyWhereNothingElseWantsIt() {
        let esc = DeveloperToolsKeyRouting.escape
        XCTAssertEqual(action(esc, "\u{1b}", [], .init(focus: .panel)), .toggleDrawer)
        XCTAssertEqual(action(esc, "\u{1b}", [], .init(focus: .code)), .toggleDrawer)
        XCTAssertNil(action(esc, "\u{1b}", [], .init(focus: .field)))
        XCTAssertNil(action(esc, "\u{1b}", [], .init(focus: .editor)))
        XCTAssertNil(action(esc, "\u{1b}", [], .init(focus: .panel, picking: true)))
        XCTAssertNil(action(esc, "\u{1b}", [.command]))
    }

    func testCommandMenuTakesItsNavigationKeys() {
        let open = DeveloperToolsKeyState(focus: .field, commandMenuOpen: true)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.escape, "", [], open), .commandMenuClose)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.down, "", [], open), .commandMenuMove(1))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.up, "", [], open), .commandMenuMove(-1))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.returnKey, "\r", [], open), .commandMenuRun)
        // Typing goes to the field.
        XCTAssertNil(action(0, "a", [], open))
        // Closed, the arrows are the panel's own.
        XCTAssertNil(action(DeveloperToolsKeyRouting.down, "", [], .init(focus: .field)))
    }

    func testDebuggerKeysStepOnlyWhilePaused() {
        let paused = DeveloperToolsKeyState(paused: true)
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f8), .debugger("pause"))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f8, "", [], paused), .debugger("resume"))
        XCTAssertEqual(action(42, "\\", [.command], paused), .debugger("resume"))
        XCTAssertNil(action(DeveloperToolsKeyRouting.f10))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f10, "", [], paused), .debugger("stepOver"))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f11, "", [], paused), .debugger("stepInto"))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f11, "", [.shift], paused), .debugger("stepOut"))
        XCTAssertEqual(action(39, "'", [.command], paused), .debugger("stepOver"))
        XCTAssertEqual(action(41, ";", [.command], paused), .debugger("stepInto"))
        XCTAssertEqual(action(41, ":", [.command, .shift], paused), .debugger("stepOut"))
        XCTAssertNil(action(41, ";", [.command]))
        XCTAssertEqual(action(DeveloperToolsKeyRouting.f8, "", [.command]), .toggleBreakpoints)
    }

    // MARK: Command menu

    func testCommandMenuModesByPrefix() {
        XCTAssertEqual(DeveloperCommandMenuMode.parse(">clear").mode, .commands)
        XCTAssertEqual(DeveloperCommandMenuMode.parse("> clear").query, "clear")
        XCTAssertEqual(DeveloperCommandMenuMode.parse("!snip").mode, .snippets)
        XCTAssertEqual(DeveloperCommandMenuMode.parse(":12").mode, .line)
        XCTAssertEqual(DeveloperCommandMenuMode.parse("@render").mode, .symbols)
        XCTAssertEqual(DeveloperCommandMenuMode.parse("?").mode, .help)
        XCTAssertEqual(DeveloperCommandMenuMode.parse("app.js").mode, .files)
        XCTAssertEqual(DeveloperCommandMenuMode.parse("app.js").query, "app.js")
        XCTAssertEqual(DeveloperCommandMenuMode.parse("").mode, .files)
    }

    func testGoToLineReadsLineAndColumn() {
        XCTAssertEqual(DeveloperCommandMenuMode.line("12")?.line, 12)
        XCTAssertNil(DeveloperCommandMenuMode.line("12")?.column)
        XCTAssertEqual(DeveloperCommandMenuMode.line("12:5")?.column, 5)
        XCTAssertNil(DeveloperCommandMenuMode.line(""))
        XCTAssertNil(DeveloperCommandMenuMode.line("abc"))
    }

    func testCommandFilterKeepsOrderWithoutQueryAndRanksMatches() {
        let titles = ["Show Console", "Clear console", "Show Network", "Disable cache"]
        XCTAssertEqual(DeveloperCommandMenuMode.filter(titles, "") { $0 }, titles)
        let found = DeveloperCommandMenuMode.filter(titles, "clear") { $0 }
        XCTAssertEqual(found.first, "Clear console")
        XCTAssertFalse(found.contains("Show Network"))
        XCTAssertTrue(DeveloperCommandMenuMode.filter(titles, "zzz") { $0 }.isEmpty)
    }

    func testSymbolOffsetsBecomeLinesAndColumns() {
        let units = Array("let a\nfunction b() {}\n".utf16)
        XCTAssertEqual(DeveloperCommandMenu.position(of: 0, in: units).line, 1)
        let b = DeveloperCommandMenu.position(of: 15, in: units)
        XCTAssertEqual(b.line, 2)
        XCTAssertEqual(b.column, 10)
    }

    // MARK: Tab strip

    func testPanelsStepRoundTheStrip() {
        let tabs = ["Elements", "Console", "Sources"]
        XCTAssertEqual(DeveloperTabStrip.step(tabs, from: "Console", by: 1), "Sources")
        XCTAssertEqual(DeveloperTabStrip.step(tabs, from: "Sources", by: 1), "Elements")
        XCTAssertEqual(DeveloperTabStrip.step(tabs, from: "Elements", by: -1), "Sources")
        XCTAssertEqual(DeveloperTabStrip.step(tabs, from: "Missing", by: 1), "Elements")
        XCTAssertNil(DeveloperTabStrip.step([String](), from: nil, by: 1))
    }

    func testOverflowKeepsTheSelectedTabInTheStrip() {
        let widths: [CGFloat] = [50, 50, 50, 50]
        let all = DeveloperTabStrip.overflow(widths: widths, available: 400, selected: 3, chevron: 22)
        XCTAssertEqual(all.shown, [0, 1, 2, 3])
        XCTAssertTrue(all.hidden.isEmpty)

        let tight = DeveloperTabStrip.overflow(widths: widths, available: 130, selected: 0, chevron: 22)
        XCTAssertEqual(tight.shown, [0, 1])
        XCTAssertEqual(tight.hidden, [2, 3])

        let selectedLast = DeveloperTabStrip.overflow(widths: widths, available: 130, selected: 3, chevron: 22)
        XCTAssertEqual(selectedLast.shown, [0, 3])
        XCTAssertEqual(selectedLast.hidden, [1, 2])
    }

    func testPanelOrderIsKeptAndRepaired() {
        XCTAssertEqual(DeveloperPanelLayout.normalized([]), DeveloperPanel.strip)
        // Unknown names and drawer tools drop out; missing panels come back.
        let order = DeveloperPanelLayout.normalized(["Network", "Bogus", "Sensors", "Elements"])
        XCTAssertEqual(Set(order), Set(DeveloperPanel.strip))
        XCTAssertEqual(order.firstIndex(of: .network)! < order.firstIndex(of: .elements)!, true)
        XCTAssertFalse(order.contains(.sensors))

        var layout = DeveloperPanelLayout()
        layout.move(.security, to: .elements)
        XCTAssertEqual(layout.order.first, .security)
        layout.closed = [.performance]
        layout.inDrawer = [.storage]
        XCTAssertFalse(layout.shown.contains(.performance))
        XCTAssertFalse(layout.shown.contains(.storage))
    }

    func testRenderingAndSensorsAreDrawerTools() {
        XCTAssertEqual(DeveloperPanel.rendering.drawerTool, .rendering)
        XCTAssertEqual(DeveloperPanel.sensors.drawerTool, .sensors)
        XCTAssertNil(DeveloperPanel.elements.drawerTool)
        XCTAssertFalse(DeveloperPanel.strip.contains(.rendering))
        XCTAssertFalse(DeveloperPanel.console.closeable)
        XCTAssertTrue(DeveloperPanel.security.closeable)
        for item in [DeveloperDrawerItem.tool(.networkConditions), .panel(.security)] {
            XCTAssertEqual(DeveloperDrawerItem(id: item.id), item)
        }
        XCTAssertNil(DeveloperDrawerItem(id: "panel:Sensors"))
    }

    // MARK: Splitters, zoom, counters

    func testDockCanTakeAlmostTheWholeWindow() {
        XCTAssertEqual(DeveloperDockLayout.extent(5_000, in: 800, vertical: true), 800 - DeveloperDockLayout.pageMinimum)
        XCTAssertEqual(DeveloperDockLayout.extent(10, in: 800, vertical: true), 182)
        XCTAssertEqual(DeveloperDockLayout.extent(10, in: 1_000, vertical: false), 270)
        XCTAssertEqual(DeveloperDockLayout.extent(600, in: 1_000, vertical: false), 600)
        let undocked = DeveloperDockLayout(in: CGSize(width: 900, height: 600), position: .window, extent: 300)
        XCTAssertEqual(undocked.page, CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertNil(undocked.inspector)
    }

    func testDrawerHeightIsClamped() {
        XCTAssertEqual(DeveloperDrawerLayout.height(10, in: 500), DeveloperDrawerLayout.minimum)
        XCTAssertEqual(DeveloperDrawerLayout.height(900, in: 500), 500 - DeveloperDrawerLayout.panelMinimum)
        XCTAssertEqual(DeveloperDrawerLayout.height(200, in: 500), 200)
    }

    func testZoomStepsThroughChromesLevels() {
        XCTAssertEqual(DeveloperToolsZoom.zoomed(1, by: 1), 1.1)
        XCTAssertEqual(DeveloperToolsZoom.zoomed(1, by: -1), 0.9)
        XCTAssertEqual(DeveloperToolsZoom.zoomed(1.5, by: 0), 1)
        XCTAssertEqual(DeveloperToolsZoom.zoomed(3, by: 1), 3)
        XCTAssertEqual(DeveloperToolsZoom.zoomed(0.5, by: -1), 0.5)
    }

    func testIssueCountersCountErrorsAndWarnings() {
        var repeated = DeveloperToolsSession.ConsoleLine(level: "error", text: "boom")
        repeated.repeatCount = 3
        let lines = [
            repeated,
            DeveloperToolsSession.ConsoleLine(level: "warning", text: "careful"),
            DeveloperToolsSession.ConsoleLine(level: "log", text: "hi"),
        ]
        let counts = DeveloperIssueCounts.count(lines)
        XCTAssertEqual(counts.errors, 3)
        XCTAssertEqual(counts.warnings, 1)
    }
}
