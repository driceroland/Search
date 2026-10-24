import WebKit

// Two of WebKit's own privacy features that Safari turns on and a
// WKWebView doesn't get unless it asks.
//
// Global Privacy Control: every request carries Sec-GPC: 1, and a page that
// reads navigator.globalPrivacyControl finds it true. It is how a browser
// says you don't want your data sold or shared, and some laws (California's,
// Colorado's) make a site honour it. WebKit has it from macOS 27, per
// navigation; it is set in Browser's policy decision, and on an older
// WebKit there is nothing to set and nothing is sent.
//
// Click IDs: the gclid, fbclid and the like that an ad network adds to a
// link so the site it leads to can tell whose click on which ad it was.
// WebKit takes them off the address before the page loads, from its own
// list; utm_ tags, which only name a campaign, stay, as in Safari. One of
// WebKit's feature flags, as FrameRate's is, and a WebKit without it is
// left alone.
//
// Both on unless turned off in Settings › Privacy. A private tab always
// has both, as it keeps cross-site tracking prevention.

/// Settings › Privacy › Tell sites not to sell or share your data.
enum PrivacySignal {
    @MainActor static var on = true

    /// Whether this Mac's WebKit can send it at all.
    static var possible: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// For one navigation, from Browser's policy decision, so a switch
    /// moved in Settings reaches open tabs from their next load.
    @MainActor static func apply(to preferences: WKWebpagePreferences, shy: Bool) {
        if #available(macOS 27, *) { preferences.globalPrivacyControlEnabled = on || shy }
    }

    /// What a view starts with, for pages whose navigations aren't decided
    /// by a Browser (the side panel's, an extension's offscreen page).
    @MainActor static func apply(to configuration: WKWebViewConfiguration, shy: Bool) {
        if #available(macOS 27, *) { configuration.defaultWebpagePreferences.globalPrivacyControlEnabled = on || shy }
    }
}

/// Settings › Privacy › Remove click trackers from links.
enum ClickIDs {
    /// What Settings says. Told to every open page at once: WebKit reads it
    /// on each navigation, so a switch moved reaches their next load.
    @MainActor static var on = true {
        didSet {
            guard on != oldValue else { return }
            for page in Web.pages.allObjects {
                apply(to: page.configuration.preferences, shy: !page.configuration.websiteDataStore.isPersistent)
            }
        }
    }

    /// Whether this Mac's WebKit has the flag.
    static var possible: Bool { flag != nil }

    /// Before a page's view is made: a new tab, one opened by a site, and
    /// one woken from sleep.
    @MainActor static func apply(to preferences: WKPreferences, shy: Bool) {
        set(on || shy, in: preferences)
    }

    // MARK: - WebKit's switch

    /// Not in the public framework, so each step is asked first. Looked up
    /// once, as FrameRate's is.
    private static let flag: NSObject? = {
        let list = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: list),
              let all = type.perform(list)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return all.first { $0.value(forKey: "key") as? String == "FilterLinkDecorationByDefaultEnabled" }
    }()

    private static func set(_ on: Bool, in preferences: WKPreferences) {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard let flag, preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on, flag)
    }
}
