import XCTest
import AppKit
@testable import Search

@MainActor
final class ShortcutsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "search.tests.shortcuts.\(UUID().uuidString)")
    }

    private func event(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    func testCombosFromEvents() {
        XCTAssertEqual(KeyCombo(event: event("t", code: 17, .command)), KeyCombo("t"))
        XCTAssertEqual(KeyCombo(event: event("T", code: 17, [.command, .shift])), KeyCombo("t", shift: true))
        // ⌘+ arrives as = or +, with or without ⇧; all of them are Zoom In.
        XCTAssertEqual(KeyCombo(event: event("=", code: 24, .command)), KeyCombo("+"))
        XCTAssertEqual(KeyCombo(event: event("+", code: 24, [.command, .shift])), KeyCombo("+"))
        XCTAssertEqual(KeyCombo(event: event("\u{F702}", code: 123, .command)), KeyCombo("left"))
        XCTAssertEqual(KeyCombo("t", shift: true, option: true, control: true).display, "⌃⌥⇧⌘T")
        XCTAssertEqual(KeyCombo("left").display, "⌘←")
        XCTAssertFalse(KeyCombo("t", command: false).isUsable)
        XCTAssertFalse(KeyCombo("t", command: false, shift: true).isUsable)
        XCTAssertTrue(KeyCombo("f5", command: false).isUsable)
        XCTAssertNotNil(KeyCombo("f5", command: false).swiftUI)
    }

    func testRegistryIsConsistent() {
        let ids = Command.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every id is unique")
        let keys = Command.all.compactMap(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count, "no two defaults share a key")
        XCTAssertTrue(keys.allSatisfy { !KeyCombo.reserved.contains($0) })
        XCTAssertTrue(keys.allSatisfy(\.isUsable))
    }

    func testOverridesDisableAndReset() {
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.key(for: "file.newTab"), KeyCombo("t"))
        XCTAssertFalse(store.isModified("file.newTab"))

        store.assign(KeyCombo("t", option: true), to: "file.newTab")
        XCTAssertEqual(store.key(for: "file.newTab"), KeyCombo("t", option: true))
        XCTAssertEqual(store.command(matching: KeyCombo("t", option: true))?.id, "file.newTab")
        XCTAssertNil(store.command(matching: KeyCombo("t")))
        XCTAssertTrue(store.isModified("file.newTab"))

        // Survives a relaunch.
        XCTAssertEqual(ShortcutStore(defaults: defaults).key(for: "file.newTab"), KeyCombo("t", option: true))

        store.disable("file.newTab")
        XCTAssertTrue(store.isDisabled("file.newTab"))
        XCTAssertNil(store.key(for: "file.newTab"))
        XCTAssertNil(store.command(matching: KeyCombo("t", option: true)))

        store.setConflict(.websiteFirst, for: "file.newTab")
        store.reset("file.newTab")
        XCTAssertEqual(store.key(for: "file.newTab"), KeyCombo("t"))
        XCTAssertEqual(store.conflict(for: "file.newTab"), .appFirst)
        XCTAssertFalse(store.isModified("file.newTab"))

        // A command that never had a key isn't "disabled".
        XCTAssertFalse(store.isDisabled("tabs.pin"))
    }

    func testAssigningATakenKeyMovesIt() {
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.owner(of: KeyCombo("r"), except: "tabs.pin")?.id, "view.reload")
        store.assign(KeyCombo("r"), to: "tabs.pin")
        XCTAssertEqual(store.command(matching: KeyCombo("r"))?.id, "tabs.pin")
        XCTAssertTrue(store.isDisabled("view.reload"))
        store.resetAll()
        XCTAssertEqual(store.command(matching: KeyCombo("r"))?.id, "view.reload")
        XCTAssertFalse(store.anyModified)
    }

    func testConflicts() {
        let store = ShortcutStore(defaults: defaults)
        store.setAllConflicts(.prompt)
        XCTAssertEqual(store.conflict(for: "view.reload"), .prompt)
        store.setAllConflicts(.appFirst)
        XCTAssertFalse(store.anyModified)

        XCTAssertEqual(KeyRoute.decide(.appFirst, pageHasFocus: true), .run)
        XCTAssertEqual(KeyRoute.decide(.websiteFirst, pageHasFocus: true), .hand)
        XCTAssertEqual(KeyRoute.decide(.prompt, pageHasFocus: true), .hand)
        XCTAssertEqual(KeyRoute.decide(.websiteFirst, pageHasFocus: false), .run)
        XCTAssertEqual(KeyRoute.decide(.prompt, pageHasFocus: false), .run)
    }
}
