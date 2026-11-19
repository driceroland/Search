import Foundation
import WebKit

// Where an extension runs: Chrome's "Site access", per extension (#698).
//
// Settings › Extensions, an extension's "Runs on", and a right-click on its
// button. Every site it asked for (as ever, and the default), only the sites
// you name, or only where you click its button. Held in WebKit's own
// permissions: a site it isn't let onto is a site it has no grant for, so
// WebKit doesn't put its content scripts in those pages at all — which is
// what keeps a page it shouldn't be on as light as one with no extensions.

/// What an extension is let onto.
struct SiteAccess: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        /// Every site it asked for: what it always was.
        case all
        /// The sites you name, each with its subdomains.
        case some
        /// None until you click its button, then that tab's site, until the
        /// tab goes to another site.
        case click

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All sites"
            case .some: return "Some sites"
            case .click: return "On click"
            }
        }
    }

    var mode: Mode = .all
    /// The sites named for `some`, as hosts ("example.com"). Kept when
    /// another mode is picked, so going back to it brings them back.
    var hosts: [String] = []

    var restricted: Bool { mode != .all }

    // MARK: kept

    /// One dictionary per extension beside its others ("extensions.private.…"),
    /// written only once it isn't the default: an extension never touched
    /// has none, and reads as every site, as before there was a choice.
    static func key(_ id: String) -> String { "extensions.sites.\(id)" }

    static func of(_ id: String, in defaults: UserDefaults = Store.settings) -> SiteAccess {
        guard let kept = defaults.dictionary(forKey: key(id)) else { return SiteAccess() }
        let mode = (kept["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .all
        let hosts = ((kept["hosts"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(SiteAccess.host(from:)) }
        return SiteAccess(mode: mode, hosts: SiteAccess.unique(hosts))
    }

    func save(_ id: String, in defaults: UserDefaults = Store.settings) {
        if self == SiteAccess() { defaults.removeObject(forKey: SiteAccess.key(id)); return }
        defaults.set(["mode": mode.rawValue, "hosts": hosts], forKey: SiteAccess.key(id))
    }

    static func forget(_ id: String, in defaults: UserDefaults = Store.settings) {
        defaults.removeObject(forKey: key(id))
    }

    // MARK: hosts

    /// The host in what was typed — a site, an address, "*.site" — lower
    /// case, without "www." or a port. Nil for what names no site.
    static func host(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let parts = URLComponents(string: text), var host = parts.host, !host.isEmpty else { return nil }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !host.isEmpty, host.allSatisfy(allowed.contains), !host.hasPrefix("."), !host.contains("..") else { return nil }
        return host
    }

    /// Whether `host` is one of `hosts` or under one: example.com covers
    /// news.example.com, never notexample.com or example.com.evil.
    static func covers(_ hosts: [String], _ host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func covers(_ host: String) -> Bool {
        switch mode {
        case .all: return true
        case .some: return SiteAccess.covers(hosts, host)
        case .click: return false
        }
    }

    /// The site a page's address names, for "this site": web pages only.
    static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url.host()?.lowercased()
    }

    func adding(_ host: String) -> SiteAccess {
        var out = self
        out.mode = .some
        out.hosts = SiteAccess.unique(hosts + [host])
        return out
    }

    func removing(_ host: String) -> SiteAccess {
        var out = self
        // The site and anything named under it: taking example.com away
        // shouldn't leave news.example.com quietly allowed.
        out.hosts = hosts.filter { $0 != host && !$0.hasSuffix("." + host) && !host.hasSuffix("." + $0) }
        return out
    }

    private static func unique(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    // MARK: patterns

    /// What is left of one pattern an extension asked for, on `host` — and
    /// under it when `subdomains` — as a match pattern's text. The asked-for
    /// scheme and path are kept; nil when the two don't meet. A pattern
    /// narrower than the host is kept as it is.
    static func narrow(scheme: String, host asked: String, path: String, to host: String, subdomains: Bool) -> String? {
        let mine = subdomains && !isAddress(host) ? "*." + host : host
        if asked == "*" { return "\(scheme)://\(mine)\(path)" }
        if asked.hasPrefix("*.") {
            let base = String(asked.dropFirst(2))
            // Its wildcard covers the host: the host it is, then.
            if host == base || host.hasSuffix("." + base) { return "\(scheme)://\(mine)\(path)" }
            // Under the host: kept, when subdomains count.
            if subdomains, base.hasSuffix("." + host) { return "\(scheme)://\(asked)\(path)" }
            return nil
        }
        if asked == host || (subdomains && asked.hasSuffix("." + host)) { return "\(scheme)://\(asked)\(path)" }
        return nil
    }

    /// An IP address or a one-word host (localhost), which has no subdomains.
    private static func isAddress(_ host: String) -> Bool {
        !host.contains(".") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The patterns that let an extension onto `host` as far as it asked.
    @available(macOS 15.4, *)
    static func patterns(_ asked: Set<WKWebExtension.MatchPattern>, on host: String, subdomains: Bool) -> [WKWebExtension.MatchPattern] {
        var texts = Set<String>()
        for pattern in asked where !Extensions.withheld(pattern) {
            let text: String?
            if pattern.matchesAllURLs {
                text = narrow(scheme: "*", host: "*", path: "/*", to: host, subdomains: subdomains)
            } else if let scheme = pattern.scheme, let asked = pattern.host, let path = pattern.path {
                text = narrow(scheme: scheme, host: asked, path: path, to: host, subdomains: subdomains)
            } else {
                text = nil
            }
            if let text { texts.insert(text) }
        }
        return texts.sorted().compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    /// Extensions that only do their job everywhere: a password manager
    /// fills sign-ins on whatever site you're on. Told, never stopped.
    static func needsEverySite(name: String, said settings: [String: Any]) -> Bool {
        if settings["privacy.services.passwordSavingEnabled"] as? Bool == false { return true }
        let name = name.lowercased()
        return ["password", "passkey", "1password", "bitwarden", "lastpass", "dashlane", "keeper", "proton pass", "nordpass", "enpass", "roboform"]
            .contains { name.contains($0) }
    }
}

// MARK: - held in WebKit

@available(macOS 15.4, *)
extension Extensions {
    /// Sites given for a tab by a click, while "Runs on" isn't every site:
    /// by extension, then tab, the site and the patterns given for it.
    struct ClickGrant: Equatable {
        let host: String
        let patterns: [String]
    }

    /// Its sites, as "Runs on" has them: every one it asked for, or only
    /// those named. Run as it loads (before `fence`) and when "Runs on"
    /// changes.
    static func grantSites(_ context: WKWebExtensionContext, as access: SiteAccess) {
        guard access.mode == .some else {
            if access.mode == .all { grantSites(context) }
            return
        }
        let asked = context.webExtension.allRequestedMatchPatterns
        for host in access.hosts {
            for pattern in SiteAccess.patterns(asked, on: host, subdomains: true) {
                grant(pattern, in: context)
            }
        }
    }

    /// The website patterns it holds now: every grant but extension pages,
    /// files (refused, never granted) and its own sign-in address.
    private static func isWebsite(_ pattern: WKWebExtension.MatchPattern, of id: String) -> Bool {
        !withheld(pattern) && pattern.string != "https://\(id).chromiumapp.org/*"
    }

    /// "Runs on" changed while it runs: what it holds of websites made
    /// what it would hold loaded fresh, plus the sites clicks gave its tabs.
    /// The extension hears permissions.onAdded / onRemoved from WebKit, and
    /// its content scripts are left out of the next page loaded on a site
    /// it lost, without a reload. A page it was on keeps what its scripts
    /// already did until that page is loaded again.
    ///
    /// Only the difference is touched, and `fence` isn't run again (its
    /// refusals stand from `load`). WebKit puts an extension's content
    /// scripts into every open page a new grant covers, there and then, and
    /// leaves pages alone when a grant naming sites is taken out of the
    /// list (#705). A grant for every website is the exception both ways:
    /// given, WebKit swaps its per-site scripts for every-website ones; taken
    /// back, it leaves the every-website ones in place until they are built
    /// again (see `rebuildScripts`). Either way a page it may still run in
    /// gets its scripts once more — WebKit's, once per change.
    static func apply(_ access: SiteAccess, to context: WKWebExtensionContext, keeping clicks: [ClickGrant] = []) {
        let id = context.uniqueIdentifier
        // What it would hold, worked out on a context of its own that is
        // never loaded.
        let fresh = WKWebExtensionContext(for: context.webExtension)
        fresh.uniqueIdentifier = id
        grantSites(fresh, as: access)
        fence(fresh)
        let wanted = Set(fresh.grantedPermissionMatchPatterns.keys.filter { isWebsite($0, of: id) }.map(\.string))
            .union(clicks.flatMap(\.patterns))
        let held = context.grantedPermissionMatchPatterns.keys
        var gone = held.filter { isWebsite($0, of: id) && !wanted.contains($0.string) }
        var added = wanted.subtracting(held.map(\.string)).sorted().compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        // Every website held one way (<all_urls>) and wanted another
        // (*://*/*, see `fence`): kept as it is held.
        if held.contains(where: { isWebsite($0, of: id) && reachesEveryWebsite($0) }), added.contains(where: reachesEveryWebsite) {
            gone.removeAll(where: reachesEveryWebsite)
            added.removeAll(where: reachesEveryWebsite)
        }
        let goneText = Set(gone.map(\.string))
        func drop() {
            context.grantedPermissionMatchPatterns = context.grantedPermissionMatchPatterns.filter { !goneText.contains($0.key.string) }
        }
        guard gone.contains(where: reachesEveryWebsite) else {
            for pattern in added { grant(pattern, in: context) }
            if !gone.isEmpty { drop() }
            return
        }
        // Every website taken back: out of the list, built again from what
        // is left, then the sites it keeps. Granted before the rebuild, a
        // named site's scripts went into its open pages twice — once as the
        // every-website ones left, once in the rebuild.
        drop()
        rebuildScripts(context)
        for pattern in added { grant(pattern, in: context) }
    }

    // MARK: on click

    /// "Runs on" for an installed extension.
    func siteAccess(_ id: String) -> SiteAccess { SiteAccess.of(id) }

    func setSiteAccess(_ id: String, _ access: SiteAccess) {
        access.save(id)
        if !access.restricted { clickGrants[id] = nil }
        if let context = contexts[id] {
            Extensions.apply(access, to: context, keeping: Array((clickGrants[id] ?? [:]).values))
        }
        buttonsChanged()
    }

    /// Whether an extension asks for any website at all — one that doesn't
    /// has nothing for "Runs on" to choose.
    static func asksForSites(_ context: WKWebExtensionContext) -> Bool {
        context.webExtension.allRequestedMatchPatterns.contains { !withheld($0) }
    }

    /// Its button pressed on a tab whose site it isn't let onto: that site,
    /// as far as it asked, for this tab, until the tab goes to another
    /// site (Chrome's "on click"). Given before WebKit hears of the click,
    /// so the popup or onClicked finds the page reachable, and its content
    /// scripts run in the page as it is, without a reload.
    @discardableResult
    func grantClick(_ context: WKWebExtensionContext, on tab: Tab) -> Bool {
        let id = context.uniqueIdentifier
        let access = SiteAccess.of(id)
        guard access.restricted, let url = tab.address, let host = SiteAccess.site(of: url),
              !context.hasAccess(to: url) else { return false }
        let patterns = SiteAccess.patterns(context.webExtension.allRequestedMatchPatterns, on: host, subdomains: false)
        guard !patterns.isEmpty else { return false }
        // Never <all_urls>, an extension page or a file, so nothing for
        // `fence` to refuse. One held already isn't granted again (see
        // `grant`).
        for pattern in patterns { Extensions.grant(pattern, in: context) }
        clickGrants[id, default: [:]][tab.id] = ClickGrant(host: host, patterns: patterns.map(\.string))
        buttonsChanged()
        return true
    }

    /// "Run on This Site": the click's grant, without the click.
    func runHere(_ id: String, in target: Browser? = nil) {
        guard let context = contexts[id], let tab = (target ?? browser)?.active else { return }
        grantClick(context, on: tab)
    }

    /// Whether it may run on the tab in front now: by "Runs on", or by a
    /// click there.
    func runsHere(_ id: String, in target: Browser? = nil) -> Bool {
        guard let context = contexts[id], let url = (target ?? browser)?.active?.address else { return false }
        return context.hasAccess(to: url)
    }

    /// A tab went somewhere (or closed, `to` nil): a click's grant goes once
    /// the tab is off the site it was given for — unless another tab
    /// still holds it, or "Runs on" gives it anyway.
    func leftSite(_ tabID: Tab.ID, to url: URL?) {
        let host = SiteAccess.site(of: url)
        for (id, tabs) in clickGrants {
            guard let grant = tabs[tabID], grant.host != host else { continue }
            clickGrants[id]?[tabID] = nil
            if clickGrants[id]?.isEmpty == true { clickGrants[id] = nil }
            guard let context = contexts[id] else { continue }
            let access = SiteAccess.of(id)
            guard access.restricted else { continue }
            let stillHeld = Set((clickGrants[id] ?? [:]).values.flatMap(\.patterns))
            let gone = Set(grant.patterns).subtracting(stillHeld)
            guard !gone.isEmpty else { continue }
            Extensions.apply(access, to: context, keeping: Array((clickGrants[id] ?? [:]).values))
            buttonsChanged()
        }
    }
}
