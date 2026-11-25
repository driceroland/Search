import AppKit
import Carbon.HIToolbox

// Shortcuts on a keyboard layout that doesn't type Latin letters, or that
// types other letters while ⌘ is held.
//
// With a Russian layout on, the key that types W types Ц, and an event's
// characters are the layout's: a shortcut matched by its character (⌘W
// closing a tab, ⌘R reloading, ⌘T opening one) never fires, while the
// same shortcut in the menus does. macOS reads a menu's shortcut through
// the Latin layout that goes with the one in use (US, or Dvorak for someone
// who types Dvorak) whenever the one in use can't type Latin. These read
// the key the same way.
//
// "Dvorak – QWERTY ⌘" types Dvorak, but with ⌘ held each key is its QWERTY
// self, and the menus follow that: ⌘T is the key QWERTY calls T. The
// event's charactersIgnoringModifiers is still the Dvorak letter, so these
// read a ⌘ chord through the layout's own ⌘ keys whenever that layout
// gives the key another character under ⌘ (#1077). Any other layout that
// types Latin is left as it is: on AZERTY, ⌘A is the key that types A, and
// on plain Dvorak ⌘T is the key that types T, as in Safari.

extension NSEvent {
    /// `charactersIgnoringModifiers`, lowercased, read through the Latin
    /// layout when the one in use isn't Latin and ⌘, ⌃ or ⌥ is held, and
    /// through the layout's ⌘ keys when ⌘ is held and it has its own.
    var shortcutCharacters: String {
        KeyLayout.shortcut(keyCode, flags: modifierFlags, shift: modifierFlags.contains(.shift),
                           typed: charactersIgnoringModifiers)
    }

    /// `characters(byApplyingModifiers: [])`, lowercased, read the same way
    /// with ⇧ left out.
    var shortcutKey: String {
        KeyLayout.shortcut(keyCode, flags: modifierFlags, shift: false,
                           typed: characters(byApplyingModifiers: []))
    }
}

enum KeyLayout {
    /// A keyboard layout: its `uchr` data, and whether it types Latin.
    struct Layout {
        let data: Data
        let isLatin: Bool

        init?(_ source: TISInputSource) {
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
            isLatin = KeyLayout.isLatin(source)
        }

        init(data: Data, isLatin: Bool) {
            self.data = data
            self.isLatin = isLatin
        }

        /// What the key types with these Carbon modifiers held, nil when
        /// it types nothing.
        func type(_ keyCode: UInt16, modifiers: Int, action: Int = kUCKeyActionDown) -> String? {
            data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var dead: UInt32 = 0
                var length = 0
                var typed = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(action), UInt32(modifiers >> 8) & 0xFF, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, typed.count, &length, &typed
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: typed, count: length)
            }
        }

        /// What the key types with ⌘ held, lowercased, when the layout
        /// gives it another character under ⌘ than without — Dvorak –
        /// QWERTY ⌘'s QWERTY keys; nil on a layout where ⌘ changes nothing.
        func underCommand(_ keyCode: UInt16, shift: Bool) -> String? {
            guard let plain = type(keyCode, modifiers: 0), let command = type(keyCode, modifiers: cmdKey),
                  plain.lowercased() != command.lowercased()
            else { return nil }
            return (shift ? type(keyCode, modifiers: cmdKey | shiftKey) : command)?.lowercased()
        }
    }

    /// The key a shortcut is: `typed` lowercased, unless a chord (⌘, ⌃ or
    /// ⌥) is held on a layout that isn't Latin — then what the key types
    /// in `latin`, the Latin layout paired with it — or ⌘ is held on a
    /// layout with ⌘ keys of its own — then what it types with ⌘.
    static func shortcut(
        _ keyCode: UInt16, flags: NSEvent.ModifierFlags, shift: Bool, typed: String?,
        current: Layout?, latin: () -> Layout?
    ) -> String {
        let fallback = typed?.lowercased() ?? ""
        // Plain typing never asks the system for the layout: the key
        // monitor sees every key press.
        guard !flags.isDisjoint(with: [.command, .control, .option]), let current else { return fallback }
        if !current.isLatin {
            return latin()?.type(keyCode, modifiers: shift ? shiftKey : 0, action: kUCKeyActionDisplay)?
                .lowercased() ?? fallback
        }
        if flags.contains(.command), let key = current.underCommand(keyCode, shift: shift) { return key }
        return fallback
    }

    /// The same, read through the layout in use.
    static func shortcut(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, shift: Bool, typed: String?) -> String {
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return typed?.lowercased() ?? "" }
        return shortcut(keyCode, flags: flags, shift: shift, typed: typed, current: inUse, latin: pairedLatin)
    }

    /// The layout in use: the keyboard layout's keys, and whether the
    /// input source in use types Latin — under an input method (Japanese,
    /// Chinese) the keyboard layout is Latin while the source isn't.
    private static var inUse: Layout? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let keys = TISCopyCurrentKeyboardLayoutInputSource().flatMap { Layout($0.takeRetainedValue()) }
        return Layout(data: keys?.data ?? Data(), isLatin: isLatin(current))
    }

    private static func pairedLatin() -> Layout? {
        TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap { Layout($0.takeRetainedValue()) }
    }

    private static func isLatin(_ source: TISInputSource) -> Bool {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
