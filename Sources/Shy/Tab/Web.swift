import Combine
import ImageIO
import SwiftUI
import WebKit

enum Web {
    /// Where Shy's own page scripts run, and where their messages come
    /// from: a world of their own beside the page's. They see the same page,
    /// and the page sees none of them — no variable of theirs, and no
    /// `window.webkit`, which Safari never shows a page and which sites read
    /// as an app's embedded web view rather than a browser. Google answered
    /// that with a CAPTCHA every few searches, and refused sign-ins as "not
    /// secure" (24 Sep 2026). Only Shy's passkey patch has to stand in
    /// the page's own world, and nothing there leads back to it.
    @MainActor static let world = WKContentWorld.world(name: "Shy")

    /// Every handler of Shy's taken off a controller: in its own world,
    /// and in the page's, where they all were before 24 Sep 2026 — a tab
    /// opened by a link inherits its opener's configuration, handlers
    /// included, and registering a name twice is a hard crash.
    @MainActor static func release(_ controller: WKUserContentController) {
        for name in [ScrollRelay.name, VeilRelay.name, FormRelay.name, ImageRelay.name, MediaKeys.name,
                     StoreRelay.name, PasskeyRelay.name, MiddleRelay.name, IconRelay.name, PopupGestureRelay.name,
                     TranslateRelay.name, DevTools.name] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
    }

    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// — web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids.
        //
        // This hardly ever runs. Safari can't be removed from modern macOS,
        // so reading the installed Safari above should always work. The
        // formula only matters if that read fails.
        //
        // From macOS 26 Safari shares its number; before, it was 3 ahead (14 -> 17, 15 -> 18).
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return os >= 26 ? "\(os).0" : "\(os + 3).0"
    }

    /// One pool for every tab. The property is deprecated and said to do
    /// nothing now, but a configuration without it gets a pool of its own
    /// when its view is made — so every new tab started a web process from
    /// cold, fonts registered and all, on the main thread, before its page
    /// could begin: 41 to 59 ms from a bookmark or Return to the load
    /// starting, the window stuck meanwhile. Sharing one lets WebKit have
    /// the next process ready: 9 to 10 ms, for the same memory and the same
    /// number of processes (measured with ./bench bookmark URL new, 24 Sep 2026).
    /// It also carries Shy's geolocation provider (see SiteLocation),
    /// which asks macOS nothing until a page you allowed wants a position.
    static let pool: WKProcessPool = {
        let pool = WKProcessPool()
        SiteLocation.provide(pool)
        return pool
    }()

    /// `space`: the space the tab belongs to, when it is not the one on
    /// screen — a parked row made ahead of time (see Spaces.swift).
    /// `store`: a shy tab's own, for one opened from it — a link followed
    /// out of a private page is still signed in to whatever that page was.
    static func configuration(shy: Bool = false, space: UUID? = nil, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces on, each space's tabs share a store of that space's.
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: space ?? Spaces.current) })
        // Web notifications go through the store (see Notifications.swift);
        // a private tab's is left without, and a page there is refused.
        if !shy { let kept = config.websiteDataStore; MainActor.assumeIsolated { SiteNotifications.shared.attach(kept) } }
        config.processPool = Web.pool
        // A test run's pretend camera and microphone (see ExtensionCapture).
        if #available(macOS 15.4, *), Store.testing { ExtensionCapture.mockDevices(config.preferences) }
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions lets one in, and WebKit then lets in only that one.
        // The controller has to be there when the view is made; it can't be
        // added after.
        // Its profile's extensions, never another's: the profile whose store
        // it was handed, or its space's.
        if #available(macOS 15.4, *) {
            MainActor.assumeIsolated {
                let profile = store.flatMap(Profiles.owner(of:)) ?? Spaces.profile(of: space ?? Spaces.current)
                let extensions = Extensions.of(profile)
                if !shy || extensions.contexts.values.contains(where: \.hasAccessToPrivateData) { extensions.attach(config) }
            }
        }
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = Web.userAgentName
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        // WebKit's synchronous popup check rejects async POST sign-ins.
        // The UI delegate instead consumes a recent trusted interaction
        // recorded in Shy's isolated world (see PopupGesture.swift).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Sound waits for a click, as everywhere; video too when Settings
        // says videos wait (Never Auto-Play, in Safari's words).
        config.mediaTypesRequiringUserActionForPlayback = Web.playback
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        inspector(config.preferences)
        NativePiP.allow(config.preferences)
        Web.fileIsolation(config)
        return config
    }

    /// A page on this Mac is an origin of its own, as in Safari, Chrome and
    /// Firefox: it may show the pictures and styles in its folder, but its
    /// scripts can't fetch another file there, or the folder's listing — a
    /// page from Downloads reading the bank statement beside it. Today's
    /// WebKit already says so; this says it whatever WebKit's default is.
    static func fileIsolation(_ config: WKWebViewConfiguration, on: Bool = true) {
        config.preferences.setValue(!on, forKey: "allowFileAccessFromFileURLs")
        config.setValue(!on, forKey: "allowUniversalAccessFromFileURLs")
    }

    /// What a page may not play until it is clicked or a key pressed: sound,
    /// and video as well with Settings › General › Videos wait for a click.
    static var playback: WKAudiovisualMediaTypes {
        Store.settings.bool(forKey: Preferences.waitsKey) ? .all : .audio
    }

    /// Every page view there is, for the bench.
    @MainActor static let pages = NSHashTable<PageView>.weakObjects()

    /// WebKit's "developer extras": Inspect Element in a page's right-click
    /// menu, and the Web Inspector the View menu opens (see Inspector.swift).
    /// isInspectable alone only lets Safari's Develop menu reach the page.
    /// The name is outside the public framework, so it is asked first.
    /// A page the Web Inspector reaches, as every tab's is: Safari's Develop
    /// menu and Inspect Element both. The side panel's website follows the
    /// same rule through this.
    @MainActor static func inspectable(_ web: WKWebView) {
        if #available(macOS 13.3, *) { web.isInspectable = true }
        inspector(web.configuration.preferences)
    }

    static func inspector(_ preferences: WKPreferences, on: Bool = true) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }
}

/// WKWebView can pause a page's media, but not mute it and let it keep
/// playing, the one thing a tab's own speaker does everywhere else. WebKit
/// has that mute one call down from the public framework: the one Safari's
/// own tabs use, the page's JavaScript none the wiser. The names are asked
/// for first, the way `inspector(_:on:)` above asks, and a WebKit without
/// them leaves the tab heard rather than falling over.
enum Muter {
    /// `_mediaMutedState` is a bitmask. Its low bit is the page's own
    /// sound, the only one a tab's speaker should touch: the others are the
    /// camera and the microphone, someone else's to turn off.
    static func set(_ muted: Bool, on web: WKWebView) {
        let get = NSSelectorFromString("_mediaMutedState")
        let set = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: get), web.responds(to: set) else { return }
        typealias Read = @convention(c) (AnyObject, Selector) -> UInt
        typealias Write = @convention(c) (AnyObject, Selector, UInt) -> Void
        let state = unsafeBitCast(web.method(for: get), to: Read.self)(web, get)
        unsafeBitCast(web.method(for: set), to: Write.self)(web, set, muted ? state | 1 : state & ~UInt(1))
    }
}

/// Sites you let play sound by themselves, from the site card: Safari's
/// per-site Allow All Auto-Play (#223). Every other site keeps the default,
/// sound waiting for a click. Remembered for the site, as its zoom is, and
/// never from a private tab. Settings › Videos wait for a click wins: with
/// it on, no site plays by itself.
///
/// WebKit takes it for each page as it loads, through the page's own
/// preferences, under a name outside the public framework — asked for
/// first, as `Muter` asks, so a WebKit without it only leaves the site
/// waiting for a click. Its values, checked on macOS 26: 0 the default,
/// 1 allow, 2 allow without sound, 3 deny. Allow lets video play whatever
/// `mediaTypesRequiringUserActionForPlayback` says, which is why the
/// global switch is asked here and not left to that.
enum Autoplay {
    /// Per profile (see SiteMemory): a site let play in one is not in
    /// another, nor can tell from it that the two are the same person.
    private static func key(_ host: String, _ profile: UUID) -> String { SiteMemory.key("autoplay.", host, profile) }

    static func allowed(_ host: String, in profile: UUID) -> Bool {
        Store.settings.bool(forKey: key(host, profile))
    }

    /// Off keeps nothing, as a site at the usual zoom keeps nothing.
    static func set(_ on: Bool, for host: String, in profile: UUID) {
        if on {
            Store.settings.set(true, forKey: key(host, profile))
        } else {
            Store.settings.removeObject(forKey: key(host, profile))
        }
    }

    /// For a page about to load at `url`, in a view made with `made`:
    /// allowed to play, held to what Settings › Videos wait for a click says
    /// now, or left alone. WebKit fixes `made` when the view is made, so a
    /// tab open before the switch moved — and a link opened from it, with a
    /// copy of its configuration — kept the old answer until it slept: with
    /// the switch off again, its videos still waited for a click. The page's
    /// own policy says what the switch says instead, from its next load.
    /// `profile`: whose sites may play, nil for a page that keeps nothing.
    static func apply(to preferences: WKWebpagePreferences, for url: URL, profile: UUID?,
                      made: WKAudiovisualMediaTypes) {
        let waits = Store.settings.bool(forKey: Preferences.waitsKey)
        let policy: Int
        if !waits, let profile, let host = url.host(), allowed(host, in: profile) {
            policy = 1
        } else if waits, !made.contains(.video) {
            policy = 3
        } else if !waits, made.contains(.video) {
            policy = 2
        } else {
            return
        }
        let set = NSSelectorFromString("_setAutoplayPolicy:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, policy)
    }
}
