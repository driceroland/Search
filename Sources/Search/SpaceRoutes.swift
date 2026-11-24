import SwiftUI

// Send links to a space (idea 255; #595, #721): links to chosen sites open
// in their space, with its sign-ins, as Arc's Air Traffic Control does.
// After @AdityaAmitK's #596 and #722, made smaller.
//
// Off unless turned on in Settings › Spaces & Pins, and only with spaces on.
// A rule is a site, its subdomains with it, and a space; the most specific
// site wins. It sends:
//
// - a link from another app (Search as the Mac's browser);
// - a link a page opens in a new tab — a target="_blank" click, ⌘-click,
//   the middle button, Open Link in New Tab — from a page in another space.
//
// The tab opens in that space, and the window that has it, or this one
// switched to it, comes to it. A link followed in its own tab, an address
// typed, a private tab's links, a window the page sizes ("Sign in with…",
// which needs its opener) and anything that isn't http or https stay where
// they are. So does a link whose rule names a space that has gone: the rule
// is passed over, and the link opens as it always did.
//
// Everything else, if chosen: a web link from another app that no rule
// names opens in that one space, the way Arc sends everything else to one.
// Only links from other apps: a page's new-tab links with no rule stay in
// its space, or every link a page opened would leave it. A small window or
// the panel asking which space, if on, still comes first for those.

struct SpaceRoute: Equatable, Identifiable {
    /// A host, lowercased, without www.: "notion.so".
    var site: String
    var space: UUID
    var id: String { site }

    /// As it is kept in the settings: a plain dictionary, readable with
    /// `defaults read`.
    var plist: [String: String] { ["site": site, "space": space.uuidString] }

    init(site: String, space: UUID) {
        self.site = site
        self.space = space
    }

    init?(plist: Any) {
        guard let entry = plist as? [String: String],
              let site = entry["site"].flatMap(SpaceRoutes.site), let space = entry["space"].flatMap(UUID.init)
        else { return nil }
        self.init(site: site, space: space)
    }
}

enum SpaceRoutes {
    static let key = "spaces.links"
    static let rulesKey = "spaces.links.rules"
    static let otherKey = "spaces.links.other"

    // MARK: - sites

    /// What was typed, as the site a rule keeps: "https://www.Notion.so/x",
    /// "notion.so" and "*.notion.so" are all "notion.so". Nil for anything
    /// that isn't a host.
    static func site(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("*.") { text.removeFirst(2) }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URLComponents(string: text)?.host else { return nil }
        return clean(host)
    }

    /// The site of a web address; nil for anything but http and https.
    static func site(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return nil }
        return clean(host.lowercased())
    }

    private static func clean(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        guard !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":" })
        else { return nil }
        // An IPv6 address as it is; a name has no empty label, and one with
        // no dot is only ever localhost.
        if host.contains(":") { return host }
        guard host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              host.contains(".") || host == "localhost"
        else { return nil }
        return host
    }

    // MARK: - matching

    /// The rule for an address: the one whose site is its host or a domain
    /// of it, the longest such site when more than one is.
    static func match(_ url: URL, in routes: [SpaceRoute]) -> SpaceRoute? {
        guard let host = site(of: url) else { return nil }
        return routes
            .filter { host == $0.site || (!host.contains(":") && host.hasSuffix("." + $0.site)) }
            .max { $0.site.count < $1.site.count }
    }

    /// The space a rule sends an address to: only while the setting and
    /// spaces are both on, and only a space that is still there.
    static func space(for url: URL, routes: [SpaceRoute], on: Bool, spaces: [UUID: Space]) -> Space? {
        guard on, let route = match(url, in: routes) else { return nil }
        return spaces[route.space]
    }

    @MainActor static func space(for url: URL) -> Space? {
        let prefs = Shared.prefs
        return space(for: url, routes: prefs.spaceRoutes, on: prefs.usesSpaces && prefs.sendsLinksToSpaces,
                     spaces: Spaces.known)
    }

    /// The space a link from another app is sent to: its rule's, else the
    /// one chosen for everything else, if it is a web link and that space
    /// is still there.
    static func space(forOutside url: URL, routes: [SpaceRoute], other: UUID?, on: Bool,
                      spaces: [UUID: Space]) -> Space? {
        guard on, site(of: url) != nil else { return nil }
        return space(for: url, routes: routes, on: on, spaces: spaces) ?? other.flatMap { spaces[$0] }
    }

    @MainActor static func space(forOutside url: URL) -> Space? {
        let prefs = Shared.prefs
        return space(forOutside: url, routes: prefs.spaceRoutes, other: prefs.spaceForOtherLinks,
                     on: prefs.usesSpaces && prefs.sendsLinksToSpaces, spaces: Spaces.known)
    }

    /// One site to one space, in place of any rule the site had.
    @MainActor static func set(_ site: String, to space: UUID) {
        var routes = Shared.prefs.spaceRoutes
        if let at = routes.firstIndex(where: { $0.site == site }) {
            routes[at].space = space
        } else {
            routes.append(SpaceRoute(site: site, space: space))
        }
        Shared.prefs.spaceRoutes = routes
    }

    @MainActor static func remove(_ site: String) {
        Shared.prefs.spaceRoutes.removeAll { $0.site == site }
    }

    // MARK: - windows

    /// The window that is to show `space`: one on screen already in it, the
    /// one in front first; otherwise `source`, or a window of the space's
    /// profile, switched to it. Nil if it couldn't be.
    @MainActor static func window(for space: Space, from source: Browser) -> Browser? {
        let windows = ([Browsers.front].compactMap { $0 } + Browsers.all.reversed()).filter { $0.isOpen && !$0.isPopup }
        if let shown = windows.first(where: { $0.spaceID == space.id }) { return shown }
        let window = space.profileID == source.profileID ? source : Browsers.open(profile: space.profileID)
        guard window.prefs.usesSpaces else { return nil }
        window.switchSpace(to: space.id)
        // With profiles in one window, the switch can bring that profile's
        // window into this one's place (see OneWindow.swift).
        return ([window] + Browsers.all.reversed()).first { $0.isOpen && !$0.isPopup && $0.spaceID == space.id }
    }

    /// The spaces a rule can name, with the profile's name before each once
    /// there is more than one profile.
    @MainActor static var choices: [(id: UUID, name: String)] {
        let profiles = Profiles.shared
        return Spaces.read().map { space in
            (space.id, profiles.several ? "\(profiles.profile(space.profileID).name) › \(space.name)" : space.name)
        }
    }
}

extension Browser {
    /// For a link from another app: the window a rule, or the space for
    /// everything else, sends it to, already in its space. Nil to open it as
    /// always.
    func routed(_ url: URL) -> Browser? {
        guard !isPopup, let space = SpaceRoutes.space(forOutside: url), space.id != spaceID else { return nil }
        return SpaceRoutes.window(for: space, from: self)
    }

    /// A link a page opens in a new tab, opened in front in the space a rule
    /// sends it to. False when no rule sends it out of the page's space.
    func sendToSpace(_ url: URL, from source: Tab?) -> Bool {
        guard !isPopup, let source, !source.shy, let space = SpaceRoutes.space(for: url) else { return false }
        // A small window's page is in the space chosen for it, if one was.
        let here = parked.first { $0.value.tabs.contains { $0 === source } }?.key
            ?? LittleWindow.holding(source.id)?.chosenSpace ?? spaceID
        guard space.id != here, let target = SpaceRoutes.window(for: space, from: self) else { return false }
        target.open(url, foreground: true)
        if target !== self { Browsers.show(target) }
        return true
    }

    /// A link a small window's page opens in a new tab, opened in front as
    /// sendToSpace opens one: in the space a rule sends it to, else the
    /// space chosen for that window (see Links.open). False when none was
    /// chosen, or this window shows the chosen space and isn't tucked: the
    /// page has its sign-ins, and the tab opens here as always. Never here
    /// instead: a space gone is asked about again, as Open in Search asks
    /// (LittleWindow.keep); with spaces off, nothing opens.
    func sendToChosenSpace(_ url: URL, from source: Tab?) -> Bool {
        guard let source, let chosen = LittleWindow.holding(source.id)?.chosenSpace else { return false }
        // Tucked: the browser kept out of sight for another profile's small
        // window, maybe at the chosen space itself (see Browsers.outOfSight).
        guard chosen != spaceID || tucked else { return false }
        let space = SpaceRoutes.space(for: url)?.id ?? chosen
        guard let target = Browsers.window(showing: space) else {
            if Spaces.known[space] == nil { LinkChooserPanel.shared.ask(url, sender: nil) }
            return true
        }
        target.open(url, foreground: true)
        if target !== self { Browsers.show(target) }
        return true
    }
}

/// Settings › Spaces & Pins, under Send links to a space: each site and its
/// space, a line to add one, and where everything else from other apps goes.
struct SpaceRouteList: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var profiles = Profiles.shared
    @State private var typed = ""
    @State private var chosen: UUID?

    var body: some View {
        let choices = SpaceRoutes.choices
        ForEach(prefs.spaceRoutes) { route in
            Rule()
            Line(route.site, choices.first { $0.id == route.space }.map { "Opens in \($0.name)" }
                 ?? "Its space is gone, so links open as usual") {
                Pill("Remove") { SpaceRoutes.remove(route.site) }
            }
        }
        Rule()
        HStack(spacing: 10) {
            TextField("notion.so", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onSubmit(add)
            Picker("Space", selection: Binding(get: { chosen ?? choices.first?.id }, set: { chosen = $0 })) {
                ForEach(choices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Pill("Add", action: add)
                .disabled(SpaceRoutes.site(typed) == nil)
                .opacity(SpaceRoutes.site(typed) == nil ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        Rule()
        Line("Everything else", "Default space for links that match no site") {
            // A deleted space shows as Current space, which is where links go then.
            Picker("Everything else", selection: Binding(
                get: { prefs.spaceForOtherLinks.flatMap { id in choices.contains { $0.id == id } ? id : nil } },
                set: { prefs.spaceForOtherLinks = $0 })) {
                Text("Current space").tag(UUID?.none)
                Divider()
                ForEach(choices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func add() {
        guard let site = SpaceRoutes.site(typed), let space = chosen ?? SpaceRoutes.choices.first?.id else { return }
        SpaceRoutes.set(site, to: space)
        typed = ""
    }
}
