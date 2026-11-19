import AppKit
import Carbon.HIToolbox

// One key that reaches Search from whichever app is in front: the one that
// raises the address field over it (Launcher.swift).
//
// Carbon's hot keys are still how macOS gives an app a key of its own
// system-wide. Nothing to ask permission for, no watching every key typed
// as a global event monitor would need Accessibility to do: macOS hands
// over this one combination and nothing else, and only while it is
// registered. The app in front never sees it then, so it is registered only
// while the launcher wants it (see Launcher.refresh).

/// "SrcL", for telling this key's events from anyone else's.
private let launcherSignature: OSType = 0x5372_634C

@MainActor
enum HotKey {
    private static var registered: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// What is registered now, to leave it be when asked for it again.
    private static var current: (code: UInt32, modifiers: UInt32)?

    /// Called on the main thread each time the key is pressed.
    static var pressed: (() -> Void)?

    /// Carbon's modifier flags for a key Settings recorded.
    nonisolated static func modifiers(of combo: KeyCombo) -> UInt32 {
        var flags: UInt32 = 0
        if combo.command { flags |= UInt32(cmdKey) }
        if combo.shift { flags |= UInt32(shiftKey) }
        if combo.option { flags |= UInt32(optionKey) }
        if combo.control { flags |= UInt32(controlKey) }
        return flags
    }

    /// The key, in place of any other: noErr, or why macOS wouldn't have
    /// it — another app's already, or one it keeps for itself.
    @discardableResult
    static func set(code: UInt16, modifiers: UInt32) -> OSStatus {
        if let current, registered != nil, current.code == UInt32(code), current.modifiers == modifiers { return noErr }
        clear()
        installHandler()
        var key: EventHotKeyRef?
        let id = EventHotKeyID(signature: launcherSignature, id: 1)
        let status = RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &key)
        guard status == noErr, let key else { return status == noErr ? OSStatus(eventInternalErr) : status }
        registered = key
        current = (UInt32(code), modifiers)
        return noErr
    }

    /// The key given back to the app in front.
    static func clear() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
        current = nil
    }

    static var isSet: Bool { registered != nil }

    /// One of macOS's own keys, switched on in System Settings › Keyboard ›
    /// Keyboard Shortcuts: a screenshot, Mission Control, Spotlight, the
    /// input sources. Carbon registers one of those all the same and it
    /// never comes, so Settings turns it down instead. Another app's key
    /// can't be told apart this way: macOS doesn't say whose a key is.
    static func usedByMacOS(code: UInt16, modifiers: UInt32) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return usedByMacOS(code: code, modifiers: modifiers, in: entries)
    }

    /// The same, against the list macOS gives. Its arrows and function keys
    /// carry fn as well, which a key Settings records never does.
    nonisolated static func usedByMacOS(code: UInt16, modifiers: UInt32, in entries: [[String: Any]]) -> Bool {
        let held = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return entries.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  entry[kHISymbolicHotKeyCode as String] as? Int == Int(code),
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(truncatingIfNeeded: flags) & held == modifiers & held
        }
    }

    /// Once, for as long as the app runs: the key's presses come to the
    /// application's own event target.
    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == launcherSignature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.pressed?() } }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
