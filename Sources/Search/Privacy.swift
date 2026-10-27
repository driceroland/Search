import WebKit

// Two of WebKit's own privacy features that Safari turns on and a
// WKWebView doesn't get unless it asks.
//
// Global Privacy Control: every request carries Sec-GPC: 1, and a page that
// reads navigator.globalPrivacyControl finds it true. It is how a browser
// says you don't want your data sold or shared, and some laws (California's,
// Colorado's) make a site honour it. WebKit has it from macOS 27, per
// navigation, set in Browser's policy decision. Reached by selector, so
// Search builds against an SDK without it; on a WebKit without it there is
// nothing to set, nothing is sent and the switch isn't shown.
//
// Click IDs: the gclid, fbclid and the like that an ad network adds to a
// link so the site it leads to can tell whose click on which ad it was.
// WebKit takes them off the address before the page loads; utm_ tags, which
// only name a campaign, stay, as in Safari. One of WebKit's feature flags,
// as FrameRate's is. The names come from the system's own list (WebPrivacy),
// which is not CleanLink.tracking: the two disagree on some (mc_eid, _hsenc,
// si…), so a copied clean link and a loaded address can differ. Unlike
// CleanLink, the flag can't spare an address that carries a signature: it is
// set per WKPreferences, not per navigation.
//
// Both on unless turned off in Settings › Privacy. A private tab always
// has both, as in Safari's Private Browsing.
//
// Pages made through a Tab follow a switch from their next load. The side
// panel's get the click-ID flag and GPC when they are made, from
// Web.configuration, and keep them until they are made again; an
// extension's offscreen documents get neither.

/// Settings › Privacy › Tell sites not to sell or share your data.
enum PrivacySignal {
    @MainActor static var on = true

    /// Whether this Mac's WebKit can send it at all: the setter is there.
    static let possible = WKWebpagePreferences.instancesRespond(to: setter)

    /// For one navigation, from Browser's policy decision, so a switch
    /// moved in Settings reaches open tabs from their next load.
    @MainActor static func apply(to preferences: WKWebpagePreferences, shy: Bool) {
        set(on || shy, in: preferences)
    }

    /// What a view starts with, for pages whose navigations aren't decided
    /// by a Browser (the side panel's).
    @MainActor static func apply(to configuration: WKWebViewConfiguration, shy: Bool) {
        set(on || shy, in: configuration.defaultWebpagePreferences)
    }

    private static let setter = NSSelectorFromString("setGlobalPrivacyControlEnabled:")

    private static func set(_ on: Bool, in preferences: WKWebpagePreferences) {
        guard preferences.responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Setter.self)(preferences, setter, on)
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

    /// Whether to offer the switch: the flag is there, on a macOS where it
    /// was seen to take the IDs off (27.2). macOS 26 has the flag too, but
    /// whether its WebPrivacy list strips anything there is unchecked.
    static var possible: Bool {
        guard flag != nil else { return false }
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Before a page's view is made: in Web.configuration, and again as a
    /// Tab builds its view (a new tab, one opened by a site, one woken from
    /// sleep), in case the switch moved since its configuration was made.
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
