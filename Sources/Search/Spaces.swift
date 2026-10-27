import SwiftUI
import WebKit

// Spaces: separate sets of tabs in the one window, each with its own
// cookies and sign-ins, and a downloads folder of its own if you like.
//
// Off unless turned on in Settings › Tabs. Until then there is one space,
// the first, and nothing about it shows: its tabs are the session there
// has always been and its sites use the store there has always been, so
// turning spaces on signs nobody out.
//
// A space's sites live in its profile's WebKit store, or one of its own
// made by identifier; history and bookmarks are its profile's (see
// Profiles.swift); the passwords in the keychain, settings and extensions
// are shared by every space. Switching swaps the row of tabs:
// the ones left behind are parked, their sound paused, and they sleep
// after half an hour as any tab does, pins included unless their site may
// send notifications (Sleep.swift). ⌃1–⌃9 switch, as in Arc.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours` — from before spaces had icons; kept so an
    /// older list still reads.
    var colour: Int
    /// Its icon, one of `Spaces.icons`.
    var icon: String?
    /// Signed in wherever the first space is — the same cookies and
    /// sign-ins, only the tabs its own — rather than a store of its own.
    /// Chosen when it is made; nil, for a space from before the choice, is
    /// a store of its own.
    var sharesSignIns: Bool?
    /// Where this space's downloads go; nil for the folder in Settings.
    var downloads: String?
    /// The profile it belongs to (see Profiles.swift); nil for Personal,
    /// which every space from before profiles is in.
    var profile: UUID?

    var profileID: UUID { profile ?? Profile.personalID }

    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Space.firstID }

    /// The icon it shows: its own, or a house for the first and a
    /// briefcase for any other that has none yet.
    var symbol: String { icon.flatMap { Spaces.icons.contains($0) ? $0 : nil } ?? (isFirst ? "house" : "briefcase") }
}

enum Spaces {
    static let colours: [Color] = [
        Color(red: 0.45, green: 0.47, blue: 0.52), // slate
        Color(red: 0.26, green: 0.52, blue: 0.96), // blue
        Color(red: 0.20, green: 0.66, blue: 0.45), // green
        Color(red: 0.96, green: 0.62, blue: 0.20), // orange
        Color(red: 0.90, green: 0.33, blue: 0.40), // red
        Color(red: 0.62, green: 0.40, blue: 0.90), // violet
    ]
    static let colourNames = ["Slate", "Blue", "Green", "Orange", "Red", "Violet"]

    /// The icons a space can wear: Apple's own symbols, drawn in one weight
    /// and one grey, grouped as work, thinking, leisure and life.
    static let icons = [
        "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
        "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
        "music.note", "film", "paintpalette", "camera", "house", "book",
        "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
    ]
    static let iconNames = [
        "Work", "Office", "Desktop", "Laptop", "Code", "Terminal",
        "AI", "Thinking", "Ideas", "Games", "Leisure", "Café",
        "Music", "Film", "Art", "Photos", "Home", "Reading",
        "Studies", "Shopping", "Travel", "Sport", "Nature", "Personal",
    ]

    private static var file: URL { Store.file("spaces.json") }

    /// Every space of every profile, the first one first — made on the
    /// spot if there is no list yet.
    static func read() -> [Space] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
        var first = saved.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0)
        // The first space is Personal's, whatever a file says.
        first.profile = nil
        return [first] + saved.filter { !$0.isFirst }
    }

    /// One profile's spaces, its first space first: what a window of that
    /// profile shows, and all it shows.
    static func read(profile: UUID) -> [Space] {
        let mine = read().filter { $0.profileID == profile }
        let home = profile == Profile.personalID ? Space.firstID
            : (Profiles.read().first { $0.id == profile }?.home ?? mine.first?.id ?? Space.firstID)
        return mine.filter { $0.id == home } + mine.filter { $0.id != home }
    }

    /// The whole list, every profile's spaces.
    static func write(_ spaces: [Space]) {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        MainActor.assumeIsolated { known = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        // Every window's list follows (see Browser.init).
        NotificationCenter.default.post(name: changed, object: spaces)
    }

    /// One profile's spaces as a window now has them, in their order: the
    /// other profiles' are kept as the file has them.
    static func write(_ spaces: [Space], profile: UUID) {
        let mine = spaces.map { space -> Space in
            var space = space
            space.profile = profile == Profile.personalID ? nil : profile
            return space
        }
        write(read().filter { $0.profileID != profile } + mine)
    }

    /// The list of spaces changed, in one window or another.
    static let changed = Notification.Name("SearchSpacesChanged")

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// Every space of every profile by its id, as the file last had them:
    /// which profile each is in, and whether it shares that profile's store.
    @MainActor static var known: [UUID: Space] = Dictionary(read().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// The profile a space is in: Personal for one that isn't known.
    @MainActor static func profile(of id: UUID) -> UUID { known[id]?.profileID ?? Profile.personalID }

    /// The store a space's tabs use: its profile's — Personal's being the
    /// store there always was — for the first space of each profile and any
    /// space made signed in with the others; a store of its own otherwise.
    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        let space = known[id]
        let profile = space?.profileID ?? Profile.personalID
        if id == Space.firstID || space?.sharesSignIns == true
            || (profile != Profile.personalID && Profiles.shared.profile(profile).home == id) {
            return Profiles.store(profile)
        }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
        stores[id] = made
        return made
    }

    /// The shared store and every space's own made so far. Not a private
    /// tab's: each has a store of its own, out of this list on purpose, so
    /// tracking prevention stays on there whatever the switch says.
    @MainActor static var everyStore: [WKWebsiteDataStore] {
        [Store.websites] + Profiles.madeStores + stores.values
    }

    /// The stores one profile's tabs use: its own and its spaces' own.
    @MainActor static func stores(of profile: UUID) -> [WKWebsiteDataStore] {
        var found: [WKWebsiteDataStore] = [Profiles.store(profile)]
        for space in read(profile: profile) {
            let store = store(for: space.id)
            if !found.contains(where: { $0 === store }) { found.append(store) }
        }
        return found
    }

    /// A space's store and everything in it, gone. What it holds — cookies,
    /// sign-ins, storage, caches — is emptied at once. The store itself
    /// WebKit won't remove while this run still holds on to it, however
    /// closed its tabs, so it is written down and removed at the next
    /// launch if the tries in between don't manage.
    @MainActor static func erase(_ id: UUID) {
        guard id != Space.firstID else { return }
        // And once more a moment later, for what its closing tabs were
        // still writing — the cache of the page on screen, for one.
        let store = store(for: id)
        // The space's downloads would have kept its store, and asked with
        // its cookies again: they go with it.
        stores[id] = nil
        eraseStore(store, id: id)
    }

    /// A store made by identifier, emptied now and removed once WebKit lets
    /// it go: a space's own, or a profile's (see Profiles.delete).
    /// `store`: nil for one never opened this run, removed by its id alone.
    @MainActor static func eraseStore(_ store: WKWebsiteDataStore?, id: UUID) {
        if let store {
            guard store !== Store.websites else { return }
            Browsers.all.first?.forgetDownloads(of: store)
            let everything = WKWebsiteDataStore.allWebsiteDataTypes()
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
            }
        }
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        sweep()
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
    }

    /// Every store of a deleted space that is still there, tried again.
    @MainActor static func sweep() {
        for text in Store.settings.stringArray(forKey: "spaces.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    // Gone already is as good as removed; anything else is
                    // tried again later.
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "spaces.erasing")
            }
        }
    }
}

/// A space's row of tabs while another space is on screen.
struct Parked {
    var tabs: [Tab]
    var active: Tab.ID?
    var splits: [TabSplit] = []
    /// Its groups, as its file has them: kept here so that writing the row,
    /// or coming back to the space, doesn't read and decode the file again
    /// on the main thread. Nil when unknown, for the file to say.
    var groups: [TabGroup]? = nil

    /// The row as it is drawn while it passes during a swipe between spaces,
    /// the same way it is drawn on screen: each group under its heading,
    /// folded or not as it was left — a folded one shows only the tab in
    /// front, if that is in it — then the loose tabs. Drawn flat, every tab
    /// in a folded group came out for the length of the swipe and went back
    /// in as the space landed. A pair's other half isn't a row of its own.
    @MainActor func drawn(groupsOn: Bool, splitView: Bool) -> (groups: [DrawnGroup], loose: [Tab]) {
        let stands: (Tab) -> Bool = { tab in
            !splitView || !splits.contains { $0.tabs.contains(tab.id) && $0.left != tab.id }
        }
        let front = splits.first { pair in active.map(pair.tabs.contains) ?? false }?.left ?? active
        let kept = groupsOn ? (groups ?? []) : []
        var shown: [DrawnGroup] = []
        var inGroups = Set<UUID>()
        for group in kept {
            let members = tabs.filter { $0.pin == nil && $0.groupID == group.id && stands($0) }
            // A group lasts as long as its tabs (see removeEmptyGroup).
            guard !members.isEmpty else { continue }
            inGroups.insert(group.id)
            shown.append(DrawnGroup(group: group, tabs: group.collapsed ? members.filter { $0.id == front } : members))
        }
        let loose = tabs.filter { tab in
            tab.pin == nil && stands(tab) && !(tab.groupID.map(inGroups.contains) ?? false)
        }
        return (shown, loose)
    }

    /// One group of a row drawn off screen, and the tabs it shows.
    struct DrawnGroup: Identifiable {
        let group: TabGroup
        let tabs: [Tab]
        var id: UUID { group.id }
    }
}

extension Browser {
    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// Where a download lands: the space's folder, or the one in Settings.
    var downloadsFolder: URL {
        guard prefs.usesSpaces, let path = space.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    /// ⌃1–⌃9, and the menu on the space's dot.
    func switchSpace(to id: UUID) {
        guard prefs.usesSpaces else { return }
        enter(id)
    }

    func enter(_ id: UUID) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        cancelTabEdit()
        if floater.showing { land() }
        writeSession(now: true)
        for tab in tabs where visibleTabIDs.contains(tab.id) { tab.touch() }

        // The row on screen is parked as it is, sound and all: music or a
        // stream keeps playing in the space you left, as it does in a tab
        // you left. ⌘⇧M, or its speaker, stops it.
        parked[spaceID] = Parked(tabs: tabs, active: activeID, splits: splits, groups: tabGroups)

        spaceID = id
        sitePanelFollowsSpace()
        // A space kept in memory has its groups with it; one that isn't is
        // read whole just below (restoreSession), groups included.
        tabGroups = parked[id]?.groups ?? []
        // The space new pages are made in, when this is the window in front;
        // and the one to come back to, when this is the oldest window.
        if Browsers.front === self || Browsers.front == nil { Spaces.current = id }
        // The oldest window's space is the one the app comes back to; each
        // profile's last space, the one a window of it opens at.
        if Browsers.primary === self { Store.settings.set(id.uuidString, forKey: "space.current") }
        Store.settings.set(id.uuidString, forKey: "space.current.\(profileID.uuidString)")
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            // Nothing in front there (a fresh start, see Session.startFresh):
            // an empty tab beside its pins, as at launch, not the first pin.
            // One that has gone from the row falls to its first tab that isn't a pin.
            let front = back.active.map { active in
                back.tabs.contains { $0.id == active } ? active : (back.tabs.first { $0.pin == nil } ?? back.tabs[0]).id
            }
            showRow(back.tabs, active: front, splits: back.splits, blank: true)
            for tab in tabs where visibleTabIDs.contains(tab.id) {
                if !tab.wake() { tab.revive() }
            }
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        editing = active?.isBlank ?? true
        typed = ""
        // A row read from its file just now may hold tabs whose time ran out
        // while it wasn't in memory (see Closing.swift).
        closeLeftAlone()
        askFocus()
        // Beside the space's icon when the tabs are on screen (SpaceDot);
        // folded away, at the bottom.
        if folded && !peeking { announce(space.name) }
    }

    /// Every other space's row, made ahead of time, so the column can show
    /// the next space beside this one while two fingers bring it in.
    func preloadSpaces() {
        for space in spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    /// The icon a new space gets unless told: the first no space wears yet.
    var freeIcon: String {
        let used = Set(spaces.map(\.symbol))
        return Spaces.icons.first { !used.contains($0) } ?? "briefcase"
    }

    /// A new space — signed in where the others are, or starting afresh with
    /// its own cookies and sign-ins. By default it starts empty and on screen.
    func addSpace(named name: String, icon: String? = nil, sharesSignIns: Bool = true) {
        makingSpace = false
        let made = Space(id: UUID(), name: name, colour: 0, icon: icon ?? freeIcon, sharesSignIns: sharesSignIns,
                         profile: profileID == Profile.personalID ? nil : profileID)
        spaces.append(made)
        Spaces.write(spaces, profile: profileID)
        if let afterSpaceCreated {
            self.afterSpaceCreated = nil
            afterSpaceCreated(made)
        } else {
            switchSpace(to: made.id)
        }
    }

    /// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index), from != index else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        Spaces.write(spaces, profile: profileID)
    }

    /// "New Space…": the card for a new space, in the column or the bar.
    func askForSpace(then onCreated: ((Space) -> Void)? = nil) {
        afterSpaceCreated = onCreated
        // In place, where the next space would come in, in the column or the
        // bar alike; a question only while the tabs are folded out of sight.
        if !folded || peeking {
            let here = spaces.firstIndex { $0.id == spaceID } ?? 0
            SpaceSwipe.shared.start(for: self)
            SpaceSwipe.shared.slide(self, to: spaces.count, from: here)
        } else {
            Ask.newSpace(
                then: { name, shared in self.addSpace(named: name, sharesSignIns: shared) },
                cancelled: { self.cancelSpaceCreation() }
            )
        }
    }

    func cancelSpaceCreation() {
        afterSpaceCreated = nil
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[at].name = name
        Spaces.write(spaces, profile: profileID)
    }

    func setSpaceIcon(_ id: UUID, to icon: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].icon = icon
        Spaces.write(spaces, profile: profileID)
    }

    func setSpaceDownloads(_ id: UUID, to folder: URL?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].downloads = folder?.path
        Spaces.write(spaces, profile: profileID)
    }

    /// The profile's first space: the one a window shows with spaces off,
    /// and the one that can't be deleted.
    var homeSpaceID: UUID { spaces.first?.id ?? Space.firstID }

    /// A space, its tabs, and its cookies and sign-ins, gone. The first one
    /// of the profile stays: it is where everything was before there were spaces.
    func deleteSpace(_ id: UUID) {
        guard id != Space.firstID, id != homeSpaceID, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceID == id { switchSpace(to: homeSpaceID) }
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        let shared = spaces[at].sharesSignIns == true
        spaces.remove(at: at)
        Spaces.write(spaces, profile: profileID)
        Session.erase(space: id)
        // Gone from the other windows too: their rows there, and the space
        // itself if one was showing it (the list's change moves it).
        for other in Browsers.all where other !== self { other.forget(space: id) }
        Pins.forget(id)
        // A space signed in with the others has nothing of its own to erase:
        // its cookies are theirs.
        if !shared { Spaces.erase(id) }
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        enter(homeSpaceID)
        for (_, row) in parked { for tab in row.tabs { tab.close() } }
        parked = [:]
    }
}

// MARK: - the dot

/// The space on screen, as its icon: at the column's foot, or before the
/// tabs in the row. One icon however many spaces there are; a click opens
/// the menu. When the space changes the icon turns over the way the spaces
/// went — out on one side, the next one in from the other.
struct SpaceDot: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false
    /// What is drawn, a step behind the browser: the space changes in a
    /// frame with nothing animated (see SpaceSwipe.slide), and the icon
    /// turns over just after, on a change of its own.
    @State private var shown: (key: String, symbol: String)?
    /// The space's name, for a moment after a switch (see naming()).
    @State private var named: String?
    @State private var naming = 0

    static let width: CGFloat = 26

    private var symbol: String { browser.makingSpace ? "plus" : browser.space.symbol }
    private var key: String { browser.makingSpace ? "new" : "\(browser.spaceID.uuidString)-\(browser.space.symbol)" }

    var body: some View {
        Button { SpaceMenu.show(for: browser) } label: {
            ZStack {
                Image(systemName: shown?.symbol ?? symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .id(shown?.key ?? key)
                    // The way the tabs go: sideways in the column; in the bar
                    // across the top, up for the next space, down going back.
                    .transition(.push(from: browser.prefs.sidebar
                        ? (browser.spaceStep > 0 ? .trailing : .leading)
                        : (browser.spaceStep > 0 ? .bottom : .top)))
            }
            .frame(width: SpaceDot.width, height: 26)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — ⌃1–⌃9, or two fingers \(browser.prefs.sidebar ? "sideways" : "up or down") over the tabs, to switch")
        .onChange(of: key) { _, now in
            let symbol = symbol
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { shown = (now, symbol) }
            }
        }
        .onChange(of: browser.spaceID) { _, _ in name() }
        // The name, beside the icon that stands for it, the moment you get
        // there — right of it in the bar, over the first tabs (below, the
        // page would cover it), above it at the column's foot — and
        // gone again: the icon alone is what stays. Over whatever is there,
        // taking no click and moving nothing.
        .overlay(alignment: browser.prefs.sidebar ? .bottomLeading : .leading) {
            if let named {
                Text(named)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Palette.ground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
                    .offset(x: browser.prefs.sidebar ? 0 : SpaceDot.width + 4, y: browser.prefs.sidebar ? -30 : 0)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: browser.prefs.sidebar ? .bottomLeading : .leading)))
            }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: named)
    }

    private func name() {
        guard !browser.makingSpace else { return }
        naming += 1
        let turn = naming
        named = browser.space.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard turn == naming else { return }
            named = nil
        }
    }
}

/// The dot's menu: the spaces, then what can be done to the one on screen.
@MainActor
enum SpaceMenu {
    /// Menu items call back into Swift through this.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var actions: [Action] = []

    private static func item(_ title: String, key: String = "", checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        item.target = action
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .control
        item.state = checked ? .on : .off
        return item
    }

    static func show(for browser: Browser) {
        menu(for: browser).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The menu itself, for show() to pop up, and for the bench to read.
    static func menu(for browser: Browser) -> NSMenu {
        actions = []
        let menu = NSMenu()
        for (index, space) in browser.spaces.enumerated() {
            let entry = item(space.name, key: index < 9 ? "\(index + 1)" : "", checked: space.id == browser.spaceID) {
                browser.switchSpace(to: space.id)
            }
            entry.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Space…") { browser.askForSpace() })
        // The profiles, once there is more than one (see Profiles.swift).
        if Profiles.shared.several {
            menu.addItem(.separator())
            let profiles = NSMenu()
            for entry in ProfileMenu.items(for: browser) { profiles.addItem(entry) }
            let holder = NSMenuItem(title: "Profile: \(Profiles.shared.profile(browser.profileID).name)", action: nil, keyEquivalent: "")
            holder.submenu = profiles
            menu.addItem(holder)
        }
        menu.addItem(.separator())
        let here = browser.space
        menu.addItem(item("Rename “\(here.name)”…") {
            Ask.name("Rename Space", placeholder: here.name, initial: here.name, confirm: "Rename") { browser.renameSpace(here.id, to: $0) }
        })
        let icons = NSMenu()
        for (symbol, name) in zip(Spaces.icons, Spaces.iconNames) {
            let choice = item(name, checked: here.symbol == symbol) { browser.setSpaceIcon(here.id, to: symbol) }
            choice.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            icons.addItem(choice)
        }
        let icon = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        icon.submenu = icons
        menu.addItem(icon)
        // The order is the swipe's, and ⌃1–⌃9's.
        if let at = browser.spaces.firstIndex(where: { $0.id == here.id }) {
            if at > 0 { menu.addItem(item("Move Left") { browser.moveSpace(here.id, to: at - 1) }) }
            if at < browser.spaces.count - 1 { menu.addItem(item("Move Right") { browser.moveSpace(here.id, to: at + 1) }) }
        }
        // Every group of this space, folded or opened at once, as in Arc.
        if browser.prefs.usesTabGroups, !browser.tabGroups.isEmpty {
            menu.addItem(.separator())
            let fold = item("Fold All Groups") { browser.foldAllGroups(true) }
            fold.isEnabled = browser.canFoldAllGroups
            let unfold = item("Unfold All Groups") { browser.foldAllGroups(false) }
            unfold.isEnabled = browser.canUnfoldAllGroups
            menu.autoenablesItems = false
            menu.addItem(fold)
            menu.addItem(unfold)
            menu.addItem(.separator())
        }
        let folder = here.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        menu.addItem(item(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(here.id, to: $0) }
        })
        if folder != nil {
            menu.addItem(item("Downloads to the Folder in Settings") { browser.setSpaceDownloads(here.id, to: nil) })
        }
        if !here.isFirst, here.id != browser.homeSpaceID {
            menu.addItem(.separator())
            menu.addItem(item("Delete “\(here.name)”…") {
                Ask.sure("Delete “\(here.name)”?", detail: "Its tabs close, and its cookies and sign-ins are erased from this Mac. History and bookmarks stay.", confirm: "Delete") {
                    browser.deleteSpace(here.id)
                }
            })
        }
        return menu
    }
}

/// The few questions a space's menu asks, as sheets on the window. The
/// bookmarks list borrows `name` for Rename….
@MainActor
enum Ask {
    /// A test run's answer to `sure`, in place of a sheet that a probe
    /// started hidden can't show (`ui confirm on|off`). Never set otherwise.
    @MainActor static var testing: Bool?

    /// `empty`: an empty name is an answer too (a bookmark's, see
    /// Bookmarks.askRename); otherwise it is taken as no answer.
    static func name(_ title: String, detail: String? = nil, placeholder: String, initial: String = "", confirm: String, empty: Bool = false, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, empty || !name.isEmpty { then(name) }
        }
    }

    /// A new space's name, and whether it keeps the sign-ins the others
    /// have — for when the column isn't there to hold the card.
    static func newSpace(then: @escaping (String, Bool) -> Void, cancelled: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Space"
        alert.informativeText = "Its own tabs. Signed in where your other spaces are, unless it starts afresh."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "Work"
        let fresh = NSButton(checkboxWithTitle: "Start signed out, with its own cookies", target: nil, action: nil)
        fresh.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(field)
        box.addSubview(fresh)
        alert.accessoryView = box
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ok, !name.isEmpty else { cancelled(); return }
            then(name, fresh.state != .on)
        }
    }

    /// `returnCancels`: Return is Cancel's, for a yes that can't be undone.
    static func sure(_ title: String, detail: String, confirm: String, returnCancels: Bool = false, then: @escaping () -> Void) {
        if Store.testing, let yes = testing {
            if yes { then() }
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let yes = alert.addButton(withTitle: confirm)
        yes.hasDestructiveAction = true
        let no = alert.addButton(withTitle: "Cancel")
        guard returnCancels else {
            show(alert) { ok in if ok { then() } }
            return
        }
        yes.keyEquivalent = ""
        no.keyEquivalent = "\r"
        // A button holds one key, and Cancel gave up Esc for Return: Esc is
        // caught here for it while the question is up.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.keyCode == 53 else { return event }
            no.performClick(nil)
            return nil
        }
        show(alert) { ok in
            if let escape { NSEvent.removeMonitor(escape) }
            if ok { then() }
        }
    }

    static func folder(then: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for This Space"
        panel.message = "Downloads in this space go here. Cancel keeps the folder it has."
        guard let window = Links.window else { return }
        panel.beginSheetModal(for: window) { answer in
            if answer == .OK, let url = panel.url { then(url) }
        }
    }

    private static func show(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        guard let window = Links.window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}

extension Browser {
    /// A space deleted in another window: this window's row there goes.
    func forget(space id: UUID) {
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        record.rows[id.uuidString] = nil
    }
}
