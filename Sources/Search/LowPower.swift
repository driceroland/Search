import Foundation

// The Mac's Low Power Mode, followed by the browser too.
//
// Turned on in System Settings › Battery, Low Power Mode asks the Mac to
// spend less: a slower processor, a dimmer screen, less done in the
// background. A browser that went on drawing pages at 120 and keeping
// twenty idle pages alive would be spending what the person just asked to
// save. So while it is on, two things change:
//
// - Pages are held to 60 frames a second, whatever Settings › General ›
//   Pages at 120 Hz says (see FrameRate.swift).
// - Tabs left alone sleep after ten minutes, as on Sooner, unless the pace
//   chosen is already that soon (see Sleep.swift).
//
// Both come back as they were the moment Low Power Mode goes off. Settings ›
// General › Save energy in Low Power Mode turns the whole thing off; it is
// on unless turned off, since Low Power Mode is already something chosen.

enum LowPower {
    /// What Settings says: whether the browser follows the Mac at all.
    @MainActor static var follows = true {
        didSet {
            guard follows != oldValue else { return }
            changed()
        }
    }

    /// Low Power Mode as the bench has it, standing in for the Mac's own
    /// switch, which only an administrator can turn from a script. Nil is
    /// the Mac's.
    @MainActor static var testing: Bool? {
        didSet { changed() }
    }

    /// Whether the browser is saving energy right now: followed, and the
    /// Mac in Low Power Mode.
    @MainActor static var on: Bool {
        follows && (testing ?? ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Told when Low Power Mode goes on or off, from now on. Made once, at
    /// launch: with the setting off, what it hears changes nothing.
    @MainActor private static var watching: NSObjectProtocol?

    @MainActor static func watch() {
        guard watching == nil else { return }
        // Posted on whichever thread noticed, so it is heard on the main one.
        watching = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    /// Everything that follows Low Power Mode, told it may have changed.
    /// The tabs' wait is read afresh at each look (Browser.sleepAfter), so
    /// only the pages' rate needs telling.
    @MainActor private static func changed() {
        FrameRate.update()
    }
}
