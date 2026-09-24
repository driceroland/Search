import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for.
    @Published var bench: Bool {
        didSet { store.set(bench, forKey: "bench") }
    }
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// The column folded away whenever the pointer isn't at the left edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Tabs nobody has looked at for half an hour give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// Off unless asked for.
    @Published var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        bench = store.bool(forKey: "bench")
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sideHides = store.bool(forKey: "sidebar.hides")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        showsReading = store.object(forKey: "tabs.reading") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.bool(forKey: "spaces")
        let flicks = store.bool(forKey: "float.flicks")
        floatFlicks = flicks
        Float.flicks = flicks
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
