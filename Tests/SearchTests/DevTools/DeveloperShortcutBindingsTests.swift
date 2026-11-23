import AppKit
import XCTest
@testable import Search

/// Settings › Shortcuts, customisable: the user's keys stored, looked up by
/// DevTools' key routing, checked for conflicts, and matched from a preset.
@MainActor
final class DeveloperShortcutBindingsTests: XCTestCase {
    private func state(_ panel: DeveloperPanel, paused: Bool = false) -> DeveloperToolsKeyState {
        DeveloperToolsKeyState(focus: .panel, paused: paused, panel: panel)
    }

    func testDefaultsAreTheRoutingsOwnKeys() {
        let bindings = DeveloperShortcutBindings()
        for action in DeveloperShortcutAction.allCases {
            XCTAssertFalse(bindings.isCustomised(action), action.rawValue)
            XCTAssertFalse(bindings.isOverridden(action), action.rawValue)
        }
        // With nothing changed, the routing answers as it always has.
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 35, key: "p", flags: [.command, .shift],
                                                       state: state(.elements), shortcuts: bindings), .commandMenu(">"))
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 31, key: "o", flags: .command,
                                                       state: state(.performance), shortcuts: bindings),
                       .performanceProfile(save: false))
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: DeveloperToolsKeyRouting.f8, key: "", flags: [],
                                                       state: state(.sources), shortcuts: bindings), .debugger("pause"))
        // Every default key of an action routes to that action.
        for action in DeveloperShortcutAction.allCases {
            guard let first = action.defaults.first else {
                XCTFail(action.rawValue)
                continue
            }
            let input = first.routingInput
            var keyState = state(action.panel ?? .elements, paused: true)
            keyState.searchResultsShown = true
            let routed = DeveloperToolsKeyRouting.action(keyCode: input.keyCode, key: input.key, flags: input.flags,
                                                         state: keyState)
            XCTAssertEqual(routed.flatMap { DeveloperShortcutAction($0) }, action, action.rawValue)
        }
    }

    func testShortcutsReadFromEventsAndDisplay() {
        XCTAssertEqual(DeveloperShortcut(keyCode: 35, key: "P", flags: [.command, .shift, .capsLock]),
                       DeveloperShortcut("p", [.command, .shift]))
        XCTAssertEqual(DeveloperShortcut(keyCode: 100, key: "", flags: []).key, "F8")
        XCTAssertEqual(DeveloperShortcut(keyCode: 121, key: "", flags: .command).key, "PageDown")
        XCTAssertEqual(DeveloperShortcut("p", [.command, .shift]).display, "⇧⌘P")
        XCTAssertEqual(DeveloperShortcut("f", [.command, .option]).display, "⌥⌘F")
        XCTAssertEqual(DeveloperShortcut("F11", .shift).display, "⇧F11")
        XCTAssertEqual(DeveloperShortcut("-", .command).display, "⌘−")
        XCTAssertEqual(DeveloperShortcut("e", [.control, .shift]).display, "⌃⇧E")
        // Plain letters would be typing; function keys and modified keys may be recorded.
        XCTAssertFalse(DeveloperShortcut("h").canBeRecorded)
        XCTAssertFalse(DeveloperShortcut("h", .shift).canBeRecorded)
        XCTAssertFalse(DeveloperShortcut("Return").canBeRecorded)
        XCTAssertTrue(DeveloperShortcut("F5").canBeRecorded)
        XCTAssertTrue(DeveloperShortcut("j", .command).canBeRecorded)
        XCTAssertTrue(DeveloperShortcut("l", .option).canBeRecorded)
    }

    func testStoredAsJSONAndKeptAcrossLaunches() throws {
        let suite = "DeveloperShortcutBindingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DeveloperShortcutStore(defaults: defaults)
        XCTAssertEqual(store.bindings, DeveloperShortcutBindings())
        store.set([DeveloperShortcut("j", .command)], for: .toggleDockSide)
        let data = try XCTUnwrap(defaults.data(forKey: DeveloperShortcutStore.key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil((json["overrides"] as? [String: Any])?["toggleDockSide"])

        let again = DeveloperShortcutStore(defaults: defaults)
        XCTAssertEqual(again.bindings.shortcuts(for: .toggleDockSide), [DeveloperShortcut("j", .command)])
        XCTAssertTrue(again.bindings.isOverridden(.toggleDockSide))

        // Reset to default; setting a preset's own keys is no override either.
        again.reset(.toggleDockSide)
        XCTAssertFalse(again.bindings.isOverridden(.toggleDockSide))
        again.set(DeveloperShortcutAction.toggleDockSide.defaults, for: .toggleDockSide)
        XCTAssertFalse(again.bindings.isOverridden(.toggleDockSide))
        XCTAssertNil(defaults.data(forKey: DeveloperShortcutStore.key))
    }

    func testUserKeysRunTheActionAndTheOldKeysDoNot() {
        var bindings = DeveloperShortcutBindings()
        bindings.set([DeveloperShortcut("j", .command)], for: .toggleDockSide)
        // ⌘J now toggles the dock side; ⇧⌘D no longer does.
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 38, key: "j", flags: .command,
                                                       state: state(.elements), shortcuts: bindings), .toggleDockSide)
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: 2, key: "d", flags: [.command, .shift],
                                                     state: state(.elements), shortcuts: bindings))
        XCTAssertNil(bindings.customAction(for: DeveloperShortcut("d", [.command, .shift]), panel: .elements))

        // A panel's action only in that panel, still under the routing's conditions.
        bindings.set([DeveloperShortcut("l", .command)], for: .clearConsole)
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 37, key: "l", flags: .command,
                                                       state: state(.console), shortcuts: bindings), .clearConsole)
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: 37, key: "l", flags: .command,
                                                     state: state(.network), shortcuts: bindings))
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: 40, key: "k", flags: .command,
                                                     state: state(.console), shortcuts: bindings))

        bindings.set([DeveloperShortcut("F6")], for: .stepOver)
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 97, key: "", flags: [],
                                                       state: state(.sources, paused: true), shortcuts: bindings),
                       .debugger("stepOver"))
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: 97, key: "", flags: [],
                                                     state: state(.sources), shortcuts: bindings))
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: DeveloperToolsKeyRouting.f10, key: "", flags: [],
                                                     state: state(.sources, paused: true), shortcuts: bindings))

        // Taking ⌘O from Load profile leaves it to nothing in Performance,
        // and Open file keeps it elsewhere.
        bindings.set([DeveloperShortcut("l", [.command, .shift])], for: .loadProfile)
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: 31, key: "o", flags: .command,
                                                     state: state(.performance), shortcuts: bindings))
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 31, key: "o", flags: .command,
                                                       state: state(.network), shortcuts: bindings), .commandMenu(""))
    }

    func testConflicts() {
        var bindings = DeveloperShortcutBindings()
        XCTAssertTrue(bindings.conflicts(for: .toggleDockSide).isEmpty)
        bindings.set([DeveloperShortcut("p", [.command, .shift])], for: .toggleDockSide)
        XCTAssertEqual(bindings.conflicts(for: .toggleDockSide), [.commandMenu])
        XCTAssertEqual(bindings.conflicts(DeveloperShortcut("p", [.command, .shift]), for: .settings),
                       [.commandMenu, .toggleDockSide])
        // Panels apart don't conflict: ⌘E records in Network and in Performance.
        XCTAssertTrue(bindings.conflicts(DeveloperShortcut("e", .command), for: .recordNetwork).isEmpty)
        // A panel's key conflicts with every panel's.
        XCTAssertEqual(bindings.conflicts(DeveloperShortcut("o", .command), for: .loadProfile), [.openFile])
        // The panel's own action wins a key it shares with every panel's.
        bindings.set([DeveloperShortcut("j", .command)], for: .clearConsole)
        bindings.set([DeveloperShortcut("j", .command)], for: .toggleDrawer)
        XCTAssertEqual(bindings.customAction(for: DeveloperShortcut("j", .command), panel: .console), .clearConsole)
        XCTAssertEqual(bindings.customAction(for: DeveloperShortcut("j", .command), panel: .network), .toggleDrawer)
    }

    func testVisualStudioCodePreset() {
        var bindings = DeveloperShortcutBindings()
        bindings.set([DeveloperShortcut("j", .command)], for: .toggleDockSide)
        bindings.apply(.visualStudioCode)
        // A preset drops the user's own keys.
        XCTAssertFalse(bindings.isOverridden(.toggleDockSide))
        XCTAssertEqual(bindings.shortcuts(for: .pauseResume), [DeveloperShortcut("F5"), DeveloperShortcut("\\", .command)])
        XCTAssertEqual(bindings.shortcuts(for: .commandMenu).first, DeveloperShortcut("p", [.command, .shift]))
        XCTAssertTrue(bindings.shortcuts(for: .commandMenu).contains(DeveloperShortcut("F1")))
        XCTAssertEqual(bindings.shortcuts(for: .toggleDockSide), DeveloperShortcutAction.toggleDockSide.defaults)
        // The preset's keys are what Reset to default goes back to.
        XCTAssertFalse(bindings.isOverridden(.pauseResume))
        XCTAssertTrue(bindings.isCustomised(.pauseResume))
        // No action shares a key in the preset.
        for action in DeveloperShortcutAction.allCases where action != .openFile && action != .loadProfile {
            XCTAssertTrue(bindings.conflicts(for: action).isEmpty, action.rawValue)
        }

        // F5 pauses, F8 no longer does; F1 opens the command menu, ⌘, Settings.
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 96, key: "", flags: [],
                                                       state: state(.sources), shortcuts: bindings), .debugger("pause"))
        XCTAssertNil(DeveloperToolsKeyRouting.action(keyCode: DeveloperToolsKeyRouting.f8, key: "", flags: [],
                                                     state: state(.sources), shortcuts: bindings))
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: DeveloperToolsKeyRouting.f1, key: "", flags: [],
                                                       state: state(.elements), shortcuts: bindings), .commandMenu(">"))
        XCTAssertEqual(DeveloperToolsKeyRouting.action(keyCode: 43, key: ",", flags: .command,
                                                       state: state(.elements), shortcuts: bindings), .settings)

        bindings.apply(.devTools)
        XCTAssertEqual(bindings, DeveloperShortcutBindings())
    }

    func testSettingsListsEveryActionOnce() {
        let listed = DeveloperToolsShortcuts.actions
        XCTAssertEqual(Set(listed), Set(DeveloperShortcutAction.allCases))
        XCTAssertEqual(listed.count, DeveloperShortcutAction.allCases.count)
        XCTAssertEqual(DeveloperShortcutPreset.allCases.map(\.title), ["DevTools (default)", "Visual Studio Code"])
    }
}
