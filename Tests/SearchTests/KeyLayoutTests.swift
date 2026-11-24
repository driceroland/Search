import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Search

/// Shortcuts read through each layout's own keys (#1077), from the layouts
/// installed with macOS: looked up by id, never switched on.
final class KeyLayoutTests: XCTestCase {
    private func layout(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> KeyLayout.Layout {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        guard let source = sources.first, let layout = KeyLayout.Layout(source) else {
            throw XCTSkip("\(id) isn't installed")
        }
        return layout
    }

    /// What a key is as a shortcut, with what the event says it typed
    /// with nothing but ⇧ (the layout's own, as AppKit gives it).
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, on current: KeyLayout.Layout,
                     latin: KeyLayout.Layout? = nil) -> String {
        let shift = flags.contains(.shift)
        let typed = current.type(code, modifiers: shift ? shiftKey : 0)
        return KeyLayout.shortcut(code, flags: flags, shift: shift, typed: typed, current: current, latin: { latin })
    }

    // Key codes by where the key sits on a US board.
    private let t: UInt16 = 17, w: UInt16 = 13, l: UInt16 = 37, k: UInt16 = 40, z: UInt16 = 6, p: UInt16 = 35

    /// Dvorak – QWERTY ⌘: ⌘ chords follow QWERTY, as the menus and Safari
    /// do. On main the Dvorak letter won: QWERTY T's key (Dvorak Y) was ⌘Y,
    /// and Dvorak T's key (QWERTY K) opened a tab.
    func testDvorakQwertyCommandFollowsQwertyWithCommand() throws {
        let layout = try layout("com.apple.keylayout.DVORAK-QWERTYCMD")
        XCTAssertEqual(layout.type(t, modifiers: 0), "y")
        XCTAssertEqual(key(t, .command, on: layout), "t")
        XCTAssertEqual(key(w, .command, on: layout), "w")
        XCTAssertEqual(key(l, .command, on: layout), "l")
        XCTAssertEqual(key(k, .command, on: layout), "k")
        XCTAssertEqual(key(t, [.command, .shift], on: layout), "t")
        XCTAssertEqual(key(w, [.command, .shift], on: layout), "w")
        // ⌃ or ⌥ alone, and plain typing, stay Dvorak.
        XCTAssertEqual(key(t, .control, on: layout), "y")
        XCTAssertEqual(key(t, [], on: layout), "y")
        // shortcutKey's reading: no ⇧.
        XCTAssertEqual(KeyLayout.shortcut(t, flags: [.command, .shift], shift: false, typed: "y",
                                          current: layout, latin: { nil }), "t")
    }

    /// Plain Dvorak: ⌘T is the key that types T, as in Safari.
    func testDvorakCommandFollowsDvorak() throws {
        let layout = try layout("com.apple.keylayout.Dvorak")
        XCTAssertEqual(key(k, .command, on: layout), "t")
        XCTAssertEqual(key(w, .command, on: layout), ",")
        XCTAssertEqual(key(p, .command, on: layout), "l")
        XCTAssertEqual(key(k, [.command, .shift], on: layout), "t")
    }

    /// AZERTY: ⌘W is the key that types W (code 6), ⌘Z the one at QWERTY's W.
    func testAzertyIsLeftAsItIs() throws {
        let layout = try layout("com.apple.keylayout.French")
        XCTAssertEqual(key(z, .command, on: layout), "w")
        XCTAssertEqual(key(w, .command, on: layout), "z")
        XCTAssertEqual(key(t, .command, on: layout), "t")
        XCTAssertEqual(key(l, .command, on: layout), "l")
        XCTAssertEqual(key(z, [.command, .shift], on: layout), "w")
    }

    /// US: nothing changes, ⇧ included — ⇧⌘] is still "}".
    func testUSIsLeftAsItIs() throws {
        let layout = try layout("com.apple.keylayout.US")
        XCTAssertEqual(key(t, .command, on: layout), "t")
        XCTAssertEqual(key(w, .command, on: layout), "w")
        XCTAssertEqual(key(l, .command, on: layout), "l")
        XCTAssertEqual(key(30, [.command, .shift], on: layout), "}")
        XCTAssertEqual(key(30, .command, on: layout), "]")
    }

    /// Cyrillic and Greek: a chord reads the paired Latin layout's key;
    /// plain typing keeps the layout's letter.
    func testCyrillicAndGreekReadTheLatinKey() throws {
        let us = try layout("com.apple.keylayout.US")
        for id in ["com.apple.keylayout.Russian", "com.apple.keylayout.Greek"] {
            let layout = try layout(id)
            XCTAssertFalse(layout.isLatin, id)
            XCTAssertEqual(key(w, .command, on: layout, latin: us), "w", id)
            XCTAssertEqual(key(t, .command, on: layout, latin: us), "t", id)
            XCTAssertEqual(key(l, .control, on: layout, latin: us), "l", id)
            XCTAssertNotEqual(key(w, [], on: layout, latin: us), "w", id)
        }
        // Russian paired with Dvorak: the Dvorak key, as macOS reads menus.
        let dvorak = try layout("com.apple.keylayout.Dvorak")
        XCTAssertEqual(key(k, .command, on: try layout("com.apple.keylayout.Russian"), latin: dvorak), "t")
    }
}
