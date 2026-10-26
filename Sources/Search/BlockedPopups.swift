import SwiftUI
import WebKit

// A window a page asked for and didn't get, as Safari shows it (idea 354).
//
// A page may open a window only for a click or a key pressed just before
// (PopupGesture.swift). Refused, it used to vanish without a word, and a
// site that opens its answers in a window some seconds after the click
// (hark.com's, a work site behind a VPN) simply did nothing. Now the tab
// keeps the last few refused, and a small sign beside its title says so.
// A click on the sign offers each one, to open in a tab of its own as if
// you had clicked its link, and Always Allow for the site.
//
// What Always Allow changes, and nothing else: on that site's own pages —
// the page itself, or a frame of the same site in it — window.open, a
// target=_blank link and a form posted to a new window open a tab without
// a click just before, as they would with one, opener and all. A frame of
// another site on the page (an advertisement) still needs its own click;
// WebKit's sandbox still refuses a sandboxed frame without allow-popups;
// one click still makes one tab. Nothing opens by itself from the sign.

/// One refused window: where WebKit said it would go, if anywhere.
struct BlockedPopup: Identifiable, Equatable {
    let id = UUID()
    let url: URL?
}

enum BlockedPopups {
    /// How many a tab keeps, newest last.
    static let kept = 5

    /// The address a refused window may be opened at from the sign: a web
    /// page, nothing else. javascript:, data:, blob:, file: and about: are
    /// never opened — run outside the page that made them, they are either
    /// nothing (about:blank, written into by its opener) or a way in.
    static func openable(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// The site a page is on, for the allow list: its registrable domain
    /// (hark.com for app.hark.com), for web pages only.
    static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return site(scheme: url.scheme ?? "", host: url.host() ?? "")
    }

    static func site(scheme: String, host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard ["http", "https"].contains(scheme.lowercased()), !host.isEmpty else { return nil }
        return Vault.registrable(host)
    }

    /// Whether a window asked for with no click just before opens anyway:
    /// the tab's page is on a site you allowed, and the frame asking is that
    /// page or a frame of the same site. An opaque (sandboxed) frame has no
    /// site and never qualifies.
    static func allows(_ sites: Set<String>, top: URL?, frameScheme: String, frameHost: String) -> Bool {
        guard let site = site(of: top), sites.contains(site),
              let asker = self.site(scheme: frameScheme, host: frameHost) else { return false }
        return asker == site
    }

    /// A refused window joins the tab's list: once per address, the oldest
    /// going past `kept`. An advertisement asking ten times a second is one
    /// line, and the tab isn't redrawn for each time.
    static func noting(_ url: URL?, in list: [BlockedPopup]) -> [BlockedPopup]? {
        let url = url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        guard !list.contains(where: { $0.url == url }) else { return nil }
        return Array((list + [BlockedPopup(url: url)]).suffix(kept))
    }

    /// The address as the menu shows it: the host without www, then the
    /// path (the line cuts its middle when it's long).
    static func label(_ url: URL) -> String {
        var rest = url.path()
        if let query = url.query(), !query.isEmpty { rest += "?" + query }
        if rest == "/" { rest = "" }
        return String((SiteCard.site(url) + rest).prefix(300))
    }
}

// MARK: - the tab and the browser

extension Tab {
    func noteBlocked(_ url: URL?) {
        if let list = BlockedPopups.noting(url, in: blockedPopups) { blockedPopups = list }
    }
}

extension Browser {
    /// Whether a window this tab's page asks for with no click just before
    /// opens all the same (see the top of this file).
    func popupsAllowed(_ tab: Tab, from frame: WKFrameInfo, top: URL?) -> Bool {
        BlockedPopups.allows(prefs.popupSites.union(tab.popupSites), top: top,
                             frameScheme: frame.securityOrigin.protocol, frameHost: frame.securityOrigin.host)
    }

    /// Open from the sign: a tab of its own beside this one, in front, as a
    /// clicked link would. A new page at the address WebKit gave, not the
    /// window the page asked for: it has no opener and the page can't
    /// reach into it. From a private tab, a private tab.
    @discardableResult
    func openBlocked(_ popup: BlockedPopup, from tab: Tab) -> Tab? {
        tab.blockedPopups.removeAll { $0.id == popup.id }
        guard let url = BlockedPopups.openable(popup.url) else { return nil }
        return open(url, foreground: true, from: tab)
    }

    /// Always Allow for the site the tab is on. Kept in Settings › Privacy;
    /// from a private tab, only for that tab, until it closes, and written
    /// nowhere. What was refused is put away: the next one opens.
    func allowPopups(from tab: Tab) {
        guard let site = BlockedPopups.site(of: tab.pageAddress) else { return }
        if tab.shy {
            tab.popupSites.insert(site)
        } else {
            prefs.popupSites.insert(site)
        }
        tab.blockedPopups = []
    }
}

// MARK: - the sign and its menu

/// The sign beside a tab's title while its page has had a window refused:
/// quiet, the size of the other marks there, and gone with the page.
struct PopupSign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted
    /// Drawn open, for a picture of it (tests).
    var shown = false

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if !tab.blockedPopups.isEmpty {
            Button { showing.toggle() } label: {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(hovering || showing || shown ? Palette.ink : colour.opacity(0.75))
                    .symbolEffect(.bounce, value: tab.blockedPopups.last?.id)
                    .frame(width: 17, height: 15)
                    .background(Palette.ink.opacity(hovering || showing || shown ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tab.blockedPopups.count == 1 ? "Pop-up blocked" : "\(tab.blockedPopups.count) pop-ups blocked")
            .accessibilityLabel("Pop-up blocked")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                BlockedPopupsMenu(browser: browser, tab: tab) { showing = false }
            }
            .animation(Motion.quick, value: hovering)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// What the sign offers: each refused window to open, newest first, and
/// Always Allow for the site.
struct BlockedPopupsMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let done: () -> Void

    var body: some View {
        let site = BlockedPopups.site(of: tab.pageAddress)
        let openable = tab.blockedPopups.reversed().compactMap { popup in
            BlockedPopups.openable(popup.url).map { (popup, $0) }
        }
        VStack(alignment: .leading, spacing: 0) {
            Text(tab.blockedPopups.count == 1 ? "Pop-up blocked" : "\(tab.blockedPopups.count) pop-ups blocked")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 16)
                .padding(.top, 11)
                .padding(.bottom, openable.isEmpty ? 9 : 3)
            if !openable.isEmpty {
                VStack(spacing: 1) {
                    ForEach(openable, id: \.0.id) { popup, url in
                        Item(symbol: "arrow.up.forward.square", title: "Open \(BlockedPopups.label(url))") {
                            browser.openBlocked(popup, from: tab)
                            done()
                        }
                        .help(url.absoluteString)
                    }
                }
                .padding(6)
            }
            if let site {
                Divider().overlay(Palette.hairline)
                Item(symbol: "checkmark.circle",
                     title: tab.shy ? "Allow Pop-ups from \(site) in This Tab" : "Always Allow Pop-ups from \(site)", lines: 2) {
                    browser.allowPopups(from: tab)
                    done()
                }
                .help(tab.shy ? "Only until this private tab closes" : "Settings › Privacy lists the sites you allow")
                .padding(6)
            }
        }
        .frame(width: 290, alignment: .leading)
        .popoverGround()
    }

    private struct Item: View {
        let symbol: String
        let title: String
        var lines = 1
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(lines).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: lines > 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// Settings › Privacy: the sites allowed to open pop-ups, each with a way
/// to take it back. Nothing shows while there are none.
struct PopupSiteList: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        ForEach(prefs.popupSites.sorted(), id: \.self) { site in
            Rule()
            Line(site, "Can open pop-ups without a click") {
                Pill("Remove") { prefs.popupSites.remove(site) }
            }
        }
    }
}
