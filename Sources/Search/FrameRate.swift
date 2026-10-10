import IOKit.ps
import WebKit

// Pages at 120 Hz, on a screen that can go that fast, like a MacBook Pro's.
//
// WebKit holds a page's animations, and the scrolling it draws itself, to
// about 60 frames a second even on a 120 Hz screen. That's Safari's default
// too, and it is the cheaper one: a page that animates at 120 draws twice as
// often, and in a short test on a 120 Hz MacBook Pro, a page with one CSS
// animation took about half again as much energy (Activity Monitor's 10 → 15).
// A page that is standing still costs nothing either way. So 60 unless
// asked for, in Settings › General: never, only while the Mac is on its
// power adapter (where the extra energy costs nothing in battery), or always.
//
// Never, WebKit's flag is not touched at all: a page gets whatever this Mac's
// WebKit does on its own, the same as Safari.

/// Settings › General › Pages at 120 Hz.
enum FastPages: String, CaseIterable, Identifiable {
    case never, onPower, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .onPower: return "On power"
        case .always: return "Always"
        }
    }
}

enum FrameRate {
    /// What Settings says. `fast` follows it, and, for "on power", follows
    /// the power adapter too.
    @MainActor static var mode = FastPages.never {
        didSet {
            if mode == .onPower { watchPower() }
            update()
        }
    }

    /// Whether pages are being drawn past 60 right now.
    ///
    /// Told to every open page at once, and the pages on screen nudged into
    /// using it (see nudge).
    @MainActor static var fast = false {
        didSet {
            guard fast != oldValue else { return }
            if fast {
                for page in Web.pages.allObjects { apply(to: page.configuration.preferences) }
            } else {
                // Only the pages this changed are given WebKit's own rate
                // back; the rest were never touched.
                for preferences in changed.allObjects { set(true, in: preferences) }
                changed.removeAllObjects()
            }
            nudge()
        }
    }

    /// The flag reaches an open page at once, but WebKit only works out the
    /// page's rate again when the page is hidden or shown — which is why
    /// switching away from a tab and back made it follow. So the pages on
    /// screen are hidden for a turn of the run loop and shown again: long
    /// enough for WebKit to hear both, too short to be seen. Pages not on
    /// screen work it out when they next are.
    @MainActor private static func nudge() {
        let shown = Web.pages.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        for page in shown { page.isHidden = true }
        DispatchQueue.main.async {
            for page in shown { page.isHidden = false }
        }
    }

    @MainActor private static func update() {
        fast = mode == .always || (mode == .onPower && onPower)
    }

    /// The Mac is on its adapter, or has no battery to spare: only a laptop
    /// running on its battery says otherwise.
    private static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (source as String) != kIOPSBatteryPowerValue
    }

    /// Told when the adapter is plugged or pulled, from now on. Made once:
    /// a mode other than "on power" just ignores what it hears.
    @MainActor private static var watching = false

    @MainActor private static func watchPower() {
        guard !watching,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  Task { @MainActor in FrameRate.update() }
              }, nil)?.takeRetainedValue()
        else { return }
        watching = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// The preferences this has taken past 60, so switching off can undo
    /// exactly those and nothing else.
    @MainActor private static let changed = NSHashTable<WKPreferences>.weakObjects()

    /// Before a page's view is made, which is when WebKit reads the flag:
    /// a new tab, one opened by a site, and one woken from sleep.
    @MainActor static func apply(to preferences: WKPreferences) {
        guard fast, near60 != nil else { return }
        set(false, in: preferences)
        changed.add(preferences)
    }

    /// Whether the page holds itself near 60, as its WebKit has it — nil
    /// where this WebKit has no such flag. For the bench.
    static func prefersNear60(_ preferences: WKPreferences) -> Bool? {
        let get = NSSelectorFromString("_isEnabledForFeature:")
        guard let flag = near60, preferences.responds(to: get) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(preferences.method(for: get), to: Getter.self)(preferences, get, flag)
    }

    // MARK: - WebKit's switch

    /// The switch is one of WebKit's feature flags, the list Safari shows
    /// under Develop › Feature Flags. It isn't in the public framework, so
    /// each step is asked first, and a WebKit without it is left alone.
    /// Looked up once: the list has a few hundred entries, and walking it
    /// for every tab would be for nothing.
    private static let near60: NSObject? = {
        let list = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: list),
              let all = type.perform(list)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return all.first { $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled" }
    }()

    private static func set(_ on: Bool, in preferences: WKPreferences) {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard let flag = near60, preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on, flag)
    }
}
