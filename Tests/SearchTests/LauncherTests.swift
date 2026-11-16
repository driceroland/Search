import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Search

@MainActor
final class LauncherTests: XCTestCase {
    private static let keys = ["launcher.on", "launcher.key"]

    override class func setUp() {
        setenv("SEARCH_PROBE", "launcher-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        Self.keys.forEach { Store.settings.removeObject(forKey: $0) }
    }

    override func tearDown() async throws {
        Self.keys.forEach { Store.settings.removeObject(forKey: $0) }
    }

    func testOffUntilAskedForAndNoKeyTaken() {
        let prefs = Preferences()
        XCTAssertFalse(prefs.launcher)
        XCTAssertNil(prefs.launcherKey)
    }

    func testChosenKeyIsKeptAndTakenAway() {
        let prefs = Preferences()
        prefs.launcher = true
        prefs.launcherKey = LauncherKey(combo: KeyCombo("k", option: true), code: 40)
        let again = Preferences()
        XCTAssertTrue(again.launcher)
        XCTAssertEqual(again.launcherKey, LauncherKey(combo: KeyCombo("k", option: true), code: 40))
        prefs.launcherKey = nil
        XCTAssertNil(Preferences().launcherKey)
        XCTAssertNil(Store.settings.data(forKey: "launcher.key"))
    }

    func testAnUnreadableKeyIsNone() {
        Store.settings.set(Data("not a key".utf8), forKey: "launcher.key")
        XCTAssertNil(Preferences().launcherKey)
    }

    func testOfferedKeyIsShiftCommandSpaceAndOursToGive() {
        XCTAssertEqual(LauncherKey.suggested.combo.display, "⇧⌘Space")
        XCTAssertEqual(LauncherKey.suggested.code, UInt16(kVK_Space))
        XCTAssertTrue(LauncherKey.suggested.combo.isUsable)
        XCTAssertFalse(KeyCombo.isReserved(LauncherKey.suggested.combo))
        // Spotlight's own, without ⇧, never is.
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("space")))
    }

    func testCarbonGetsTheModifiersHeld() {
        XCTAssertEqual(HotKey.modifiers(of: LauncherKey.suggested.combo), UInt32(cmdKey | shiftKey))
        XCTAssertEqual(HotKey.modifiers(of: KeyCombo("k", command: false, option: true, control: true)),
                       UInt32(optionKey | controlKey))
        XCTAssertEqual(HotKey.modifiers(of: KeyCombo("f5", command: false)), 0)
    }

    func testMacOSsOwnKeysAreToldApart() {
        let code = kHISymbolicHotKeyCode as String
        let flags = kHISymbolicHotKeyModifiers as String
        let on = kHISymbolicHotKeyEnabled as String
        // As macOS 26 lists them: ⇧⌘3, Mission Control's ⌃↑ with fn, and
        // ⇧⌘4 switched off in System Settings.
        let entries: [[String: Any]] = [
            [code: kVK_ANSI_3, flags: cmdKey | shiftKey, on: true],
            [code: kVK_UpArrow, flags: controlKey | 0x20000, on: true],
            [code: kVK_ANSI_4, flags: cmdKey | shiftKey, on: false],
        ]
        func used(_ key: Int, _ held: Int) -> Bool {
            HotKey.usedByMacOS(code: UInt16(key), modifiers: UInt32(held), in: entries)
        }
        XCTAssertTrue(used(kVK_ANSI_3, cmdKey | shiftKey))
        XCTAssertTrue(used(kVK_UpArrow, controlKey))
        // Held with one more modifier, it is a key of its own.
        XCTAssertFalse(used(kVK_ANSI_3, cmdKey | shiftKey | optionKey))
        XCTAssertFalse(used(kVK_ANSI_4, cmdKey | shiftKey))
        XCTAssertFalse(used(kVK_Space, cmdKey | shiftKey))
    }

    func testKeyStandsAsideOnlyWithAWindowOfSearchInFront() {
        XCTAssertTrue(Launcher.standsAside(active: true, windowShowing: true))
        // Search in front with every window closed or in the Dock.
        XCTAssertFalse(Launcher.standsAside(active: true, windowShowing: false))
        // Another app in front of Search's windows.
        XCTAssertFalse(Launcher.standsAside(active: false, windowShowing: true))
        XCTAssertFalse(Launcher.standsAside(active: false, windowShowing: false))
    }
}
