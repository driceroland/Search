import Foundation

/// Sync with iCloud and Handoff, on for a new install (Drice, 22 Nov 2026),
/// as on the iPhone, so people find their tabs there without looking for a
/// switch. Nobody already using Search finds either turned on by an update:
/// they keep what they had, and the What's New card offers both first.
///
/// A new install meets the two switches, on, on the welcome's first page
/// (Welcome.swift), and nothing starts before the welcome is left: Skip,
/// Start browsing or any way out of it. Quit during the welcome and nothing
/// has synced or been handed off; the welcome comes back at the next launch,
/// switches on again.
///
/// New or not is settled once, the first time a build with this runs, and
/// written down, so a new install's second launch (which finds the lines the
/// first one left) isn't taken for one from before.
enum SyncDefault {
    static let key = "icloud.default"
    static let new = "new"
    static let existing = "existing"

    /// Lines only a Search that has run before leaves: the welcome walked
    /// through, a choice of what tabs wear, the passkey lines every launch
    /// has written since 1.0.1, the window's frame AppKit keeps, and either
    /// switch already set.
    static let traces = ["welcomed", "glyph", "passkeys.for", "passkeys.entitled",
                         "NSWindow Frame search", ICloudSync.onKey, "handoff"]

    /// One time only, before Preferences reads or writes a line: a Search
    /// folder (`ranBefore`) or any trace means an install from before.
    static func settle(_ store: UserDefaults, ranBefore: Bool) {
        guard store.string(forKey: key) == nil else { return }
        let before = ranBefore || traces.contains { store.object(forKey: $0) != nil }
        store.set(before ? existing : new, forKey: key)
    }

    static func isNew(_ store: UserDefaults) -> Bool { store.string(forKey: key) == new }

    /// Where the welcome's two switches start: on for a new install that
    /// hasn't been through the welcome yet; otherwise as they are, so the
    /// welcome opened again from the menu changes nothing unless asked.
    static func starts(new: Bool, welcomed: Bool, syncOn: Bool, handoffOn: Bool) -> (sync: Bool, handoff: Bool) {
        new && !welcomed ? (true, true) : (syncOn, handoffOn)
    }

    /// The same, for this Mac as it stands.
    @MainActor static func startsNow() -> (sync: Bool, handoff: Bool) {
        starts(new: isNew(Store.settings), welcomed: Shared.prefs.welcomed,
               syncOn: ICloudSync.shared.on, handoffOn: Shared.prefs.handoff)
    }

    /// The welcome left: the two switches as they stand there take effect,
    /// and only now. Sync where this build can't reach iCloud keeps the
    /// choice and waits (ICloudSync.turnOnOrWait).
    @MainActor static func welcomeLeft(sync: Bool, handoff: Bool, prefs: Preferences, icloud: ICloudSync) {
        if prefs.handoff != handoff { prefs.handoff = handoff }
        if sync, !icloud.on { icloud.turnOnOrWait() }
        if !sync, icloud.on { icloud.turnOff() }
    }
}
