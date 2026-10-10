import AppKit
import Carbon.HIToolbox

// Shortcuts on a keyboard layout that doesn't type Latin letters.
//
// With a Russian layout on, the key that types W types Ц, and an event's
// characters are the layout's: a shortcut matched by its character (⌘W
// closing a tab, ⌘R reloading, ⌘T opening one) never fires, while the
// same shortcut in the menus does. macOS reads a menu's shortcut through
// the Latin layout that goes with the one in use (US, or Dvorak for someone
// who types Dvorak) whenever the one in use can't type Latin. These read
// the key the same way. A layout that types Latin is left as it is: on
// AZERTY, ⌘A is the key that types A.

extension NSEvent {
    /// `charactersIgnoringModifiers`, lowercased, read through the Latin
    /// layout when the one in use isn't Latin and ⌘, ⌃ or ⌥ is held.
    var shortcutCharacters: String {
        (isShortcutChord ? KeyLayout.latin(keyCode, shift: modifierFlags.contains(.shift)) : nil)
            ?? charactersIgnoringModifiers?.lowercased() ?? ""
    }

    /// `characters(byApplyingModifiers: [])`, lowercased, read through the
    /// Latin layout when the one in use isn't Latin and ⌘, ⌃ or ⌥ is held.
    var shortcutKey: String {
        (isShortcutChord ? KeyLayout.latin(keyCode, shift: false) : nil)
            ?? characters(byApplyingModifiers: [])?.lowercased() ?? ""
    }

    /// Plain typing never asks the system for the layout: the key monitor
    /// sees every key press.
    private var isShortcutChord: Bool {
        !modifierFlags.isDisjoint(with: [.command, .control, .option])
    }
}

enum KeyLayout {
    /// What the key types in the Latin layout macOS pairs with the one in
    /// use, lowercased; nil while the layout in use types Latin itself, or
    /// when the system can't say.
    static func latin(_ keyCode: UInt16, shift: Bool) -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !isLatin(current),
              let latin = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(latin, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue())
        else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var typed = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay),
            shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, typed.count, &length, &typed
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: typed, count: length).lowercased()
    }

    private static func isLatin(_ source: TISInputSource) -> Bool {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
