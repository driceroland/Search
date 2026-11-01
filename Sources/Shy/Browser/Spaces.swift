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
// A space's sites live in a WebKit store of their own, made by identifier;
// history, bookmarks, the passwords in the keychain, settings and
// extensions are shared by every space. Switching swaps the row of tabs:
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
    /// The profile it is in (see Profiles.swift); nil for Personal.
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

    /// Every space, the first one first — made on the spot if there is no
    /// list yet.
    static func read() -> [Space] {
        let data = try? Data(contentsOf: file)
        let decoded = data.flatMap { try? JSONDecoder().decode([Space].self, from: $0) }
        // A list that doesn't read is set aside, not written over at the
        // next change: the spaces' stores would be left with no line to
        // delete them from.
        if data != nil, decoded == nil { Store.quarantine(file) }
        let saved = decoded ?? []
        let first = saved.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0)
        return [first] + saved.filter { !$0.isFirst }
    }

    static func write(_ spaces: [Space]) {
        MainActor.assumeIsolated { know(spaces) }
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        // Every window's list follows (see Browser.init).
        NotificationCenter.default.post(name: changed, object: spaces)
    }

    /// The list of spaces changed, in one window or another.
    static let changed = Notification.Name("ShySpacesChanged")

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// The spaces signed in as their profile is (see Space.sharesSignIns).
    @MainActor static var sharing: Set<UUID> = []
    /// The profile of each space not in Personal.
    @MainActor static var owners: [UUID: UUID] = [:]

    /// What the stores are made from: which spaces share their profile's,
    /// and whose profile each is.
    @MainActor static func know(_ spaces: [Space]) {
        sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))
        owners = Dictionary(spaces.compactMap { space in space.profile.map { (space.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    @MainActor static func profile(of id: UUID) -> UUID { owners[id] ?? Profile.personalID }

    /// The space whose own store this is, for one with sign-ins of its own.
    @MainActor static func space(owning store: WKWebsiteDataStore) -> UUID? {
        stores.first { $0.value === store }?.key
    }

    /// A space's store: its profile's, unless it has sign-ins of its own.
    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.firstID || sharing.contains(id) { return Profiles.store(profile(of: id)) }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: Store.webKitID(id))
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
        Browsers.acting.forgetDownloads(of: store)
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        }
        stores[id] = nil
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([Store.webKitID(id).uuidString])
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
    /// The row's tabs that aren't pins, as the column draws them while the
    /// row passes during a swipe between spaces: a pair's other half isn't
    /// a row of its own. Its pins and folders are drawn as on screen (see
    /// Folders.lines).
    @MainActor var loose: [Tab] {
        tabs.filter { tab in
            tab.pin == nil && !splits.contains { $0.tabs.contains(tab.id) && $0.left != tab.id }
        }
    }

    /// The tab in front, as the column marks it: a pair's left page.
    var front: Tab.ID? {
        splits.first { pair in active.map(pair.tabs.contains) ?? false }?.left ?? active
    }
}

extension Browser {
    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// Where a download lands: the space's folder, or the one in Settings.
    var downloadsFolder: URL {
        guard let path = space.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    /// ⌃1–⌃9, and the menu on the space's dot.
    func switchSpace(to id: UUID) {
        enter(id)
    }

    private func enter(_ id: UUID) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        cancelTabEdit()
        // A video playing in the tab on screen goes into picture in picture,
        // as it does when you go to another tab.
        leaving()
        writeSession(now: true)
        for tab in tabs where visibleTabIDs.contains(tab.id) { tab.touch() }

        // The row on screen is parked as it is, sound and all: music or a
        // stream keeps playing in the space you left, as it does in a tab
        // you left. ⌘⇧M, or its speaker, stops it.
        parked[spaceID] = Parked(tabs: tabs, active: activeID, splits: splits)

        spaceID = id
        // The space new pages are made in, when this is the window in front;
        // and the one to come back to, when this is the oldest window.
        if Browsers.front === self || Browsers.front == nil { Spaces.current = id }
        if usesFiles { Store.settings.set(id.uuidString, forKey: "space.current") }
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            // Nothing in front there (a fresh start, see Session.startFresh):
            // an empty tab beside its pins, as at launch, not the first pin.
            // One that has gone from the row falls to its first tab that isn't a pin.
            let front = back.active.map { active in
                back.tabs.contains { $0.id == active } ? active : (back.tabs.first { $0.pin == nil } ?? back.tabs[0]).id
            }
            showRow(back.tabs, active: front, splits: back.splits, blank: true)
            // Back in the space, on the tab whose video went out: home again.
            if let id = pictured, visibleTabIDs.contains(id) { unpicture() }
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
    /// A new space in a profile: signed in as that profile is. Sign-ins of
    /// its own (`sharesSignIns` false) are for the bench's tests of spaces
    /// from before profiles, and nothing else.
    func addSpace(named name: String, icon: String? = nil, profile: UUID? = nil, sharesSignIns: Bool = true) {
        makingSpace = false
        var made = Space(id: UUID(), name: name, colour: 0, icon: icon ?? freeIcon, sharesSignIns: sharesSignIns)
        let profile = profile ?? newSpaceProfile ?? profileID
        made.profile = profile == Profile.personalID ? nil : profile
        newSpaceProfile = nil
        spaces.append(made)
        Spaces.write(spaces)
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
        Spaces.write(spaces)
    }

    /// "New Space…": the card for a new space, in the column or the bar.
    /// `profile`: the one it starts in, the card's choice at first; the
    /// profile on screen when none is said.
    func askForSpace(in profile: UUID? = nil, then onCreated: ((Space) -> Void)? = nil) {
        afterSpaceCreated = onCreated
        newSpaceProfile = profile
        // In place, where the next space would come in, in the column or the
        // bar alike; a question only while the tabs are folded out of sight.
        if !folded || peeking {
            let here = spaces.firstIndex { $0.id == spaceID } ?? 0
            SpaceSwipe.shared.start(for: self)
            SpaceSwipe.shared.slide(self, to: spaces.count, from: here)
        } else {
            Ask.newSpace(in: profile ?? profileID,
                then: { name, profile in self.addSpace(named: name, profile: profile) },
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
        Spaces.write(spaces)
    }

    func setSpaceIcon(_ id: UUID, to icon: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].icon = icon
        Spaces.write(spaces)
    }

    func setSpaceDownloads(_ id: UUID, to folder: URL?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].downloads = folder?.path
        Spaces.write(spaces)
    }

    /// A space, its tabs, and its cookies and sign-ins, gone. The first one
    /// stays: it is where everything was before there were spaces.
    func deleteSpace(_ id: UUID) {
        guard id != Space.firstID, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceID == id { switchSpace(to: Space.firstID) }
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        let shared = spaces[at].sharesSignIns == true
        spaces.remove(at: at)
        Spaces.write(spaces)
        Session.erase(space: id)
        // Gone from the other windows too: their rows there, and the space
        // itself if one was showing it (the list's change moves it).
        for other in Browsers.all where other !== self { other.forget(space: id) }
        Browsers.forgetClosed(space: id)
        Pins.forget(id)
        // A space signed in with the others has nothing of its own to erase:
        // its cookies are theirs.
        if !shared { Spaces.erase(id) }
    }
}

// MARK: - the dot

/// The space on screen, as its icon: at the column's foot, or before the
/// tabs in the row. One icon however many spaces there are; a click opens
/// the drawer of spaces to go to (SpaceDrawer), a right-click the menu for
/// the one on screen (SpaceMenu). When the space changes the icon turns over the way the spaces
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
    @State private var drawer = false

    static let width: CGFloat = 26

    private var symbol: String { browser.makingSpace ? "plus" : browser.space.symbol }
    private var key: String { browser.makingSpace ? "new" : "\(browser.spaceID.uuidString)-\(browser.space.symbol)" }

    var body: some View {
        Button { drawer.toggle() } label: {
            ZStack {
                Image(systemName: shown?.symbol ?? symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .id(shown?.key ?? key)
                    // The way the tabs go: sideways in the column; in the bar
                    // across the top, up for the next space, down going back.
                    .transition(.push(from: (browser.spaceStep > 0 ? .trailing : .leading)
                       ))
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
        .overlay { RightClick { SpaceMenu.make(for: browser) } }
        .popover(isPresented: $drawer, arrowEdge: .top) {
            SpaceDrawer(browser: browser) { drawer = false }
        }
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — ⌃1–⌃9, or two fingers \("sideways") over the tabs, to switch")
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
        .overlay(alignment: .bottomLeading) {
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
                    .offset(x: 0, y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
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

/// The dot's right-click menu: what can be done to the space on screen.
/// Going to another, adding one and the order are the drawer's.
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

    static func make(for browser: Browser) -> NSMenu {
        actions = []
        let menu = NSMenu()
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
        // The profile it signs in, keeps history, bookmarks and passwords as.
        let profiles = NSMenu()
        for profile in Profiles.shared.list {
            profiles.addItem(item(profile.name, checked: here.profileID == profile.id) { browser.askToMove(here.id, to: profile.id) })
        }
        profiles.addItem(.separator())
        profiles.addItem(item("New Profile…") {
            Ask.name("New Profile", detail: "Signed out of everything, with no history, bookmarks or passwords. “\(here.name)” moves into it.",
                     placeholder: "Work", confirm: "Create") { name in
                browser.setProfile(Profiles.shared.add(named: name).id, of: here.id)
            }
        })
        let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profile.submenu = profiles
        menu.addItem(profile)
        let folder = here.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        menu.addItem(item(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(here.id, to: $0) }
        })
        if folder != nil {
            menu.addItem(item("Downloads to the Folder in Settings") { browser.setSpaceDownloads(here.id, to: nil) })
        }
        if !here.isFirst {
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

/// The dot's drawer: every space with its icon, name and ⌃ number. A click
/// goes there; dragging one up or down puts it in another place, which is
/// the swipe's order and ⌃1–⌃9's; + makes a new one.
struct SpaceDrawer: View {
    @ObservedObject var browser: Browser
    let close: () -> Void
    /// The space being carried, and how far.
    @State private var carried: UUID?
    @State private var travel: CGFloat = 0
    @State private var hovered: UUID?

    static let row: CGFloat = 30

    /// Where the carried space would land, from how far it has gone.
    private func landing(_ from: Int) -> Int {
        min(max(0, from + Int((travel / SpaceDrawer.row).rounded())), browser.spaces.count - 1)
    }

    var body: some View {
        let spaces = browser.spaces
        let from = carried.flatMap { id in spaces.firstIndex { $0.id == id } }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                entry(space, number: index)
                    .offset(y: offset(index, from: from))
                    .zIndex(space.id == carried ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { drag in
                                carried = space.id
                                travel = drag.translation.height
                            }
                            .onEnded { _ in
                                if let from { browser.moveSpace(space.id, to: landing(from)) }
                                carried = nil
                                travel = 0
                            }
                    )
            }
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 4)
            Button {
                close()
                // Once the drawer is away: the card comes in where it was.
                DispatchQueue.main.async { browser.askForSpace() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").frame(width: 18)
                    Text("New Space")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(hovered == SpaceDrawer.adding ? Palette.ink : Palette.muted)
                .padding(.horizontal, 8)
                .frame(height: SpaceDrawer.row)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovered == SpaceDrawer.adding ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? SpaceDrawer.adding : nil }
        }
        .padding(6)
        .frame(width: 220)
        .animation(Motion.quick, value: carried == nil ? 0 : landing(from ?? 0))
    }

    /// The + row's stand-in for a space under the pointer.
    private static let adding = UUID()

    /// The carried space follows the pointer; the ones it passes make room.
    private func offset(_ index: Int, from: Int?) -> CGFloat {
        guard let from else { return 0 }
        if index == from { return travel }
        let to = landing(from)
        if from < to, index > from, index <= to { return -SpaceDrawer.row }
        if from > to, index < from, index >= to { return SpaceDrawer.row }
        return 0
    }

    private func entry(_ space: Space, number index: Int) -> some View {
        let here = space.id == browser.spaceID
        let lit = here || hovered == space.id || carried == space.id
        return HStack(spacing: 8) {
            Image(systemName: space.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)
            Text(space.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if index < 9 {
                Text("⌃\(index + 1)")
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12.5, weight: here ? .medium : .regular))
        .foregroundStyle(here ? Palette.ink : Palette.ink.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: SpaceDrawer.row)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(here ? Palette.wash : lit ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? space.id : (hovered == space.id ? nil : hovered) }
        .onTapGesture {
            close()
            if !here { browser.switchSpace(to: space.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(here ? "\(space.name), the space on screen" : space.name)
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

    /// A new space's name, and the profile it is in — for when the column
    /// isn't there to hold the card.
    @MainActor static func newSpace(in profile: UUID, then: @escaping (String, UUID) -> Void, cancelled: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Space"
        alert.informativeText = "Its own tabs, signed in as its profile is."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "Work"
        let profiles = Profiles.shared.list
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        pick.addItems(withTitles: profiles.map(\.name))
        pick.selectItem(at: profiles.firstIndex { $0.id == profile } ?? 0)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(field)
        box.addSubview(pick)
        alert.accessoryView = box
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ok, !name.isEmpty else { cancelled(); return }
            then(name, profiles[max(0, pick.indexOfSelectedItem)].id)
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
