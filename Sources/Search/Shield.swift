import CryptoKit
import WebKit

// The ad blocker. The built-in list is prepared at launch. Tabs can also
// have a second list with the rules their user added in Settings.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    private let store: WKContentRuleListStore?
    private let settings: UserDefaults

    convenience init() {
        self.init(store: WKContentRuleListStore.default())
    }

    init(store: WKContentRuleListStore?, settings: UserDefaults = Store.settings) {
        self.store = store
        self.settings = settings
        paused = Set(settings.stringArray(forKey: "shield.paused") ?? [])
    }

    private(set) var list: WKContentRuleList?
    private var customLists: [WKContentRuleList] = []
    private var preparing = false
    private var restoringCustomFilters = false

    // The list is prepared in the background at launch, and a page that
    // starts loading before it is ready makes its first requests without
    // it: the controller gets the list a moment later, after the ad and
    // tracker requests have gone. The tab restored in front started loading
    // 50–150 ms before the list was ready. So the first loads wait for it,
    // at most a second, once per launch: after that nothing waits, even on
    // Try again in Settings.
    private var held: [() -> Void] = []
    private var settled = false

    /// Runs `load` now, or, while the list is being prepared, once it is
    /// ready, compiling it failed, or a second has passed.
    func whenReady(_ load: @escaping () -> Void) {
        guard !settled, enabled, preparing || restoringCustomFilters else { return load() }
        if held.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.release() }
            }
        }
        held.append(load)
    }

    func setRestoringCustomFilters(_ restoring: Bool) {
        guard restoring != restoringCustomFilters else { return }
        restoringCustomFilters = restoring
        releaseIfReady()
    }

    private func releaseIfReady() {
        if !preparing && !restoringCustomFilters { release() }
    }

    private func release() {
        settled = true
        let loads = held
        held = []
        loads.forEach { $0() }
    }

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    @Published private(set) var paused: Set<String>

    static func normalizedHost(_ text: String) -> String? {
        SiteAccess.host(from: text)
    }

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains { Self.matches($0, host: host) }
    }

    private static func matches(_ site: String, host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == site { return true }
        // Single-label hosts can be paused exactly, never as a suffix.
        return site.contains(".") && host.hasSuffix("." + site)
    }

    func pause(_ host: String, _ off: Bool) {
        var sites = paused
        if off { sites.insert(host) } else { sites.remove(host) }
        savePaused(sites)
    }

    func resumeBlocking(on host: String) {
        savePaused(paused.filter { !Self.matches($0, host: host) })
    }

    private func savePaused(_ sites: Set<String>) {
        guard sites != paused else { return }
        paused = sites
        settings.set(sites.sorted(), forKey: "shield.paused")
        apply()
    }

    private final class Page {
        var host: String?
        var builtIn: WKContentRuleList?
        var custom: [WKContentRuleList] = []
    }

    private let pages = NSMapTable<WKUserContentController, Page>.weakToStrongObjects()

    /// The tab keeps the host of the last main-frame navigation decision, even
    /// when a rule list is still compiling or its current URL hasn't changed.
    func tune(_ controller: WKUserContentController, for host: String?) {
        let page = pages.object(forKey: controller) ?? Page()
        page.host = host
        pages.setObject(page, forKey: controller)
        set(controller, page: page, on: enabled && !isPaused(on: host))
    }

    private func set(_ controller: WKUserContentController, page: Page, on: Bool) {
        let builtIn = on ? list : nil
        let custom = on ? customLists : []
        if page.builtIn !== builtIn {
            if let old = page.builtIn { controller.remove(old) }
            if let builtIn { controller.add(builtIn) }
            page.builtIn = builtIn
        }
        if !page.custom.elementsEqual(custom, by: { $0 === $1 }) {
            page.custom.forEach { controller.remove($0) }
            custom.forEach { controller.add($0) }
            page.custom = custom
        }
    }

    func setCustomList(_ lists: [WKContentRuleList]) {
        guard !customLists.elementsEqual(lists, by: { $0 === $1 }) else { return }
        customLists = lists
        apply()
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        // Playwire's ad stack and the scripts that come with it to bring ads
        // back past a blocker, or to see one (albumoftheyear.org): each a
        // whole-domain block in EasyList, as the beacon is in EasyPrivacy.
        "intergient.com", "btloader.com", "ad-delivery.net", "mentorsticks.com",
        "dns-finder.com", "confiant-integrations.net", "cloudflareinsights.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    ///
    /// The second half are the boxes a site keeps open for the ad while it
    /// loads: with the ad blocked they stay, empty, a banner's height of
    /// nothing (#159). Each is a whole class name from EasyList's generic
    /// hiding list, matched as a whole word: an element whose class is
    /// `ad-slot` goes, one whose class merely contains "ad" stays.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
    ]

    /// Slots with names too plain, or too much a site's own, to hide
    /// everywhere — AS and El País call theirs just `.ad` — hidden only on
    /// the sites EasyList's own site rules hide them on.
    private static let slotsBySite: [(sites: [String], selector: String)] = [
        (["*as.com", "*elpais.com"], ".ad"),
        (["*theguardian.com"], ".top-fronts-banner-ad-container"),
        (["*independent.co.uk", "*the-independent.com"], "#billboard-wrapper"),
        (["*cnn.com"], ".ad-slot-header__wrapper"),
        (["*albumoftheyear.org"], ".headerAd, .homePageAdSquare"),
    ]

    /// Reddit's own promoted posts: custom elements the page puts straight
    /// in its light DOM (the feed, a post's comments, the sidebar), so a
    /// plain hiding rule reaches them. Only reddit.com; a normal post is a
    /// `shreddit-post`, never one of these. Test runs can add a local
    /// stand-in for Reddit (`test.redditHosts`).
    private static let reddit = [
        "shreddit-ad-post", "shreddit-comments-page-ad", "shreddit-sidebar-ad",
        "shreddit-dynamic-ad-link", "comment-tree-ad", ".promotedlink",
    ]

    static var redditSites: [String] {
        let extra = Store.testing ? (Store.settings.stringArray(forKey: "test.redditHosts") ?? []) : []
        return ["*reddit.com"] + extra.map { "*" + $0 }
    }

    static func networkFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        // WebKit's canonical HTTP URLs end the host with a port or a slash.
        return "^https?://([^/]+\\.)?\(escaped)[:/]"
    }

    func compile() {
        guard list == nil, !preparing else { return }
        trouble = nil
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            return [
                "trigger": [
                    "url-filter": Shield.networkFilter(for: domain),
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])
        // YouTube's ad reports and ad paths (see YouTubeAds.swift).
        rules += YouTubeAds.rules
        rules += Shield.slotsBySite.map { entry in
            [
                "trigger": ["url-filter": ".*", "if-domain": entry.sites],
                "action": ["type": "css-display-none", "selector": entry.selector],
            ]
        }

        rules.append([
            "trigger": ["url-filter": ".*", "if-domain": Shield.redditSites],
            "action": ["type": "css-display-none", "selector": Shield.reddit.joined(separator: ", ")],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            trouble = "Couldn't build the block list"
            return
        }

        guard let store else {
            trouble = "WebKit has nowhere to compile it"
            return
        }
        // Dictionary order isn't stable between launches; the sorted JSON is
        // both the rules WebKit sees and the identity of their compiled form.
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identifier = "office-shield-" + hash
        preparing = true
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let found {
                    self.ready(found, store: store, identifier: identifier)
                } else {
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] compiled, error in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            guard let compiled else {
                                self.preparing = false
                                self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                                self.releaseIfReady()
                                return
                            }
                            self.ready(compiled, store: store, identifier: identifier)
                        }
                    }
                }
            }
        }
    }

    private func ready(_ compiled: WKContentRuleList, store: WKContentRuleListStore, identifier: String) {
        preparing = false
        list = compiled
        // Tabs that opened while this was still preparing get it now.
        apply()
        releaseIfReady()
        // Leave other users of WebKit's store alone, including extensions.
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for old in identifiers ?? [] where old != identifier
                && !old.hasPrefix(CustomFilters.identifierPrefix)
                && (old == "office-shield" || old.hasPrefix("office-shield-")) {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    /// Register new tabs even if neither list is ready yet.
    func protect(_ controller: WKUserContentController) {
        tune(controller, for: pages.object(forKey: controller)?.host)
    }

    /// Reuse each controller's main-frame host across all windows and spaces.
    func apply() {
        for controller in pages.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            guard let page = pages.object(forKey: controller) else { continue }
            set(controller, page: page, on: enabled && !isPaused(on: page.host))
        }
    }
}
