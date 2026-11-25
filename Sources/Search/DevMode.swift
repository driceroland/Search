import AppKit
import SwiftUI

// Developer Mode, site by site (byearc's "developer view", Cra's Developer
// Mode): the page's whole address and a slim bar of the tools you reach for
// while building a site — Web Inspector, a reload that skips the cache, and
// a cache kept off for the site's reloads.
//
// On by itself for a site on this Mac — localhost, 127.0.0.1, [::1], and
// names ending in .localhost or .test — unless Settings › About › Developer
// says otherwise; turned on or off for any site from its site card or with
// ⇧⌥⌘I, and remembered for that site. Nothing changes for any other site:
// someone who never opens a local server never sees it.
//
// The bar floats over the page's bottom corner, as the link bubble does,
// rather than taking a line of the window: the page keeps its size, which
// is what a developer is looking at. × turns it off for the site.

@MainActor
final class DevMode: ObservableObject {
    static let shared = DevMode()

    /// The settings key for the choices made site by site.
    nonisolated static let sitesKey = "developer.sites"
    /// The settings key for local sites turning it on by themselves.
    nonisolated static let localKey = "developer.local"

    /// Sites turned on (true) or off (false) by hand, by host.
    @Published private(set) var sites: [String: Bool]
    /// The same for private tabs, which remember nothing: for as long as
    /// Search runs.
    @Published private var shySites: [String: Bool] = [:]
    /// Sites whose reloads skip the cache, until Search quits: a switch you
    /// flip while working, not a setting to find again weeks later.
    @Published private(set) var cacheOff: Set<String> = []

    init(store: UserDefaults = Store.settings) {
        self.store = store
        sites = store.dictionary(forKey: Self.sitesKey) as? [String: Bool] ?? [:]
    }

    private let store: UserDefaults

    /// Whether a site on this Mac turns it on by itself (Settings › About ›
    /// Developer). Set here only by unit tests.
    var localOverride: Bool?
    var local: Bool { localOverride ?? Shared.prefs.developerLocal }

    /// The host as kept: lowercased, without IPv6's brackets.
    static func host(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    /// A name or address that only ever means this Mac, or one a developer
    /// gave a site of their own: localhost and its subdomains, the loopback
    /// addresses, and .test, which is never a real site (RFC 6761).
    static func isLocal(_ host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" || host == "0.0.0.0" { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".test") { return true }
        // 127.0.0.0/8, written out in full.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127"
            && parts.allSatisfy { part in !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && UInt8(part) != nil }
    }

    /// Whether the page at `url` is in Developer Mode.
    func isOn(_ url: URL?, shy: Bool) -> Bool {
        guard let host = Self.host(of: url) else { return false }
        if shy, let chosen = shySites[host] { return chosen }
        if let chosen = sites[host] { return chosen }
        return local && Self.isLocal(host)
    }

    func isOn(_ tab: Tab) -> Bool { isOn(tab.pageAddress, shy: tab.shy) }

    /// Turned on or off for the site at `url`. Back to what it would be by
    /// itself, nothing is kept.
    func set(_ on: Bool, for url: URL?, shy: Bool) {
        guard let host = Self.host(of: url) else { return }
        let byItself = local && Self.isLocal(host)
        if shy {
            shySites[host] = on
            return
        }
        if on == byItself { sites[host] = nil } else { sites[host] = on }
        if sites.isEmpty { store.removeObject(forKey: Self.sitesKey) } else { store.set(sites, forKey: Self.sitesKey) }
    }

    func toggle(_ tab: Tab) { set(!isOn(tab), for: tab.pageAddress, shy: tab.shy) }

    /// Whether reloads of the site at `url` skip the cache.
    func skipsCache(_ url: URL?) -> Bool {
        guard let host = Self.host(of: url) else { return false }
        return cacheOff.contains(host)
    }

    func setSkipsCache(_ on: Bool, for url: URL?) {
        guard let host = Self.host(of: url) else { return }
        if on { cacheOff.insert(host) } else { cacheOff.remove(host) }
    }
}

extension Browser {
    /// ⇧⌥⌘I, and the site card's switch: Developer Mode for the site in front.
    func toggleDeveloperMode() {
        guard let tab = active, DevMode.host(of: tab.pageAddress) != nil else { return }
        DevMode.shared.toggle(tab)
    }
}

/// The bar, over the page's bottom corner while its site is in Developer
/// Mode: the whole address, then the tools.
struct DevBar: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var mode = DevMode.shared
    /// For Settings' switch for local sites.
    @ObservedObject private var prefs = Shared.prefs

    var body: some View {
        if mode.isOn(tab), let url = tab.pageAddress {
            let noCache = mode.skipsCache(url)
            HStack(spacing: 2) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .help("Developer Mode")
                // The whole address, selectable to copy a part of it.
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.trailing, 6)
                Divider().frame(height: 14)
                tool("hammer", "Web Inspector", keys: "view.inspector") { browser.toggleWebInspector() }
                tool("arrow.clockwise", "Reload Ignoring Cache", keys: "view.reloadOrigin") {
                    tab.reload(fromOrigin: true)
                }
                tool(noCache ? "externaldrive.fill.badge.xmark" : "externaldrive.badge.xmark",
                     noCache ? "Cache Off for This Site's Reloads — Turn On" : "Turn Cache Off for This Site's Reloads",
                     on: noCache) {
                    mode.setSkipsCache(!noCache, for: url)
                }
                tool("xmark", "Turn Off Developer Mode for This Site", keys: "view.developerMode") {
                    mode.set(false, for: url, shy: tab.shy)
                }
                .padding(.trailing, 3)
            }
            .frame(height: 26)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
            .padding(10)
            .transition(.opacity)
        }
    }

    private func tool(_ symbol: String, _ help: String, keys: String? = nil, on: Bool = false,
                      action: @escaping () -> Void) -> some View {
        let shown = keys.flatMap { ShortcutStore.shared.display($0) }.map { "\(help) (\($0))" } ?? help
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : Palette.muted)
                .frame(width: 22, height: 22)
                .background(on ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shown)
        .accessibilityLabel(help)
    }
}
