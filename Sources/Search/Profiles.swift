import AppKit
import SwiftUI
import WebKit

// Profiles: whole separate browsers in one app, as in Chrome, Safari and
// Arc. A profile holds its own spaces (and so their tabs, pins and groups),
// its own cookies, sign-ins and site storage, its own history and its own
// bookmarks. A window belongs to one profile for its whole life, as in
// Chrome and Safari: its column shows that profile's spaces and nothing of
// any other's — not their dots, not ⌃1–⌃9, not ⌃Tab, not Move to Space,
// not the history the field offers. With Settings › Profiles in one window
// on, the windows of several profiles take turns in one place instead, and
// the space's menu, ⌃1–⌃9 and the swipe reach every profile's spaces (see
// OneWindow.swift); each window still holds its own profile's alone.
//
// There is always one, "Personal": everything there was before profiles,
// left where it was — the same store, files and spaces — so nobody's data
// moves. Until a second one is made in Settings › Tabs › Profiles, nothing
// about profiles shows anywhere.
//
// Shared by every profile, on purpose: the settings, the extensions (one
// WKWebExtensionController for the app; one per profile would run each
// extension's worker once per profile), the passwords in the keychain (as
// Safari's profiles share theirs), downloads, and the icons of sites.
// Never synced anywhere.

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Its first space: what a window of the profile shows with spaces
    /// off. Any space can be deleted while the profile keeps another; the
    /// home's going makes the next one in the order the home (Personal's
    /// too, kept in profiles.json; an older Search reads the first back).
    var home: UUID
    var icon: String? = nil
    var colour: Int? = nil

    var tint: Color? { colour.flatMap { $0 > 0 && Spaces.colours.indices.contains($0) ? Spaces.colours[$0] : nil } }

    static let personalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
    var isPersonal: Bool { id == Profile.personalID }
    static let personal = Profile(id: personalID, name: "Personal", home: Space.firstID)
}

@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    /// Every profile, in the order the user put them: Personal first
    /// unless moved (see move). The order is profiles.json's own.
    @Published private(set) var list: [Profile]

    private init() { list = Profiles.read() }

    /// More than one: only then does anything about profiles show.
    var several: Bool { list.count > 1 }

    func profile(_ id: UUID) -> Profile { list.first { $0.id == id } ?? .personal }

    // MARK: - the file

    private nonisolated static var file: URL { Store.file("profiles.json") }

    nonisolated static func read() -> [Profile] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let personal = saved.first(where: \.isPersonal).map { Profile(id: Profile.personalID, name: $0.name, home: $0.home, icon: $0.icon, colour: $0.colour) } ?? .personal
        let others = saved.filter { !$0.isPersonal }
        // Where Personal stands in the file is where it was moved to; a file
        // without it (only ever written by hand) has it first.
        guard let at = saved.firstIndex(where: \.isPersonal) else { return [personal] + others }
        var list = others
        list.insert(personal, at: min(saved[..<at].filter { !$0.isPersonal }.count, list.count))
        return list
    }

    private func write() {
        let snapshot = list
        // A list with only Personal, named as it always was, is no file at all.
        if snapshot.count == 1, snapshot[0] == .personal {
            try? FileManager.default.removeItem(at: Profiles.file)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Profiles.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Profiles.file, options: .atomic)
    }

    // MARK: - what each holds

    /// Each profile's own store, made once: WebKit shares processes between
    /// views that ask for the same store object.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// The cookies and sign-ins its spaces share. Personal's is the store
    /// there always was; any other's is WebKit's store under the profile's
    /// own identifier.
    static func store(_ id: UUID) -> WKWebsiteDataStore {
        if id == Profile.personalID {
            let shared = Store.websites
            BrowserProxy.shared.attach(shared)
            return shared
        }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
        BrowserProxy.shared.attach(made)
        stores[id] = made
        return made
    }

    /// The profile stores made so far, Personal's aside.
    static var madeStores: [WKWebsiteDataStore] { Array(stores.values) }

    private static var histories: [UUID: History] = [:]
    private static var bookmarkLists: [UUID: Bookmarks] = [:]

    /// Its history: Personal's in history.json, as always; another's in a
    /// file of its own.
    static func history(_ id: UUID) -> History {
        if let made = histories[id] { return made }
        let made = History(file: id == Profile.personalID ? "history.json" : "history-\(id.uuidString).json")
        histories[id] = made
        return made
    }

    /// Quitting: every history made so far, written now.
    static func flushHistories() {
        for history in histories.values { history.flush() }
    }

    static func bookmarks(_ id: UUID) -> Bookmarks {
        if let made = bookmarkLists[id] { return made }
        let made = Bookmarks(file: id == Profile.personalID ? "bookmarks.json" : "bookmarks-\(id.uuidString).json")
        bookmarkLists[id] = made
        return made
    }

    // MARK: - making, renaming, deleting

    /// A new profile and its first space, which shares the profile's own
    /// store: signed out of everything, with nothing in its history.
    /// `home`: the space it starts with, for one made by an import.
    @discardableResult
    func add(named name: String, home: Space? = nil) -> Profile {
        let id = UUID()
        var space = home ?? Space(id: UUID(), name: name, colour: 0, icon: "house")
        space.profile = id
        space.sharesSignIns = true
        let made = Profile(id: id, name: name, home: space.id)
        list.append(made)
        write()
        Spaces.write(Spaces.read() + [space])
        return made
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].name = name
        write()
    }

    func setIcon(_ id: UUID, to icon: String?) {
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].icon = icon.flatMap { Spaces.icons.contains($0) ? $0 : nil }
        write()
    }

    func setColour(_ id: UUID, to colour: Int) {
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].colour = colour > 0 ? colour : nil
        write()
    }

    /// One place to the left (-1) or right (1), with its spaces: the order
    /// of the space's menu, ⌃1–⌃9 and the swipe with profiles in one window.
    func move(_ id: UUID, by step: Int) {
        guard let at = list.firstIndex(where: { $0.id == id }), list.indices.contains(at + step) else { return }
        list.swapAt(at, at + step)
        write()
    }

    /// Its home deleted: the space that takes its place.
    func rehome(_ id: UUID, to space: UUID) {
        guard let at = list.firstIndex(where: { $0.id == id }), list[at].home != space else { return }
        list[at].home = space
        write()
    }

    /// A profile and all it holds, gone: its windows close, its spaces go
    /// with their tabs and pins, and its cookies, sign-ins, site data,
    /// history and bookmarks are erased from this Mac. Personal stays.
    func delete(_ id: UUID) {
        guard id != Profile.personalID, list.contains(where: { $0.id == id }) else { return }
        // Never left without a window: one of Personal's first, if no other
        // profile has one open.
        if Browsers.all.contains(where: { $0.profileID == id && $0.isOpen }),
           !Browsers.all.contains(where: { $0.profileID != id && $0.isOpen && !$0.isPopup }) {
            Browsers.open(profile: Profile.personalID)
        }
        for browser in Browsers.all where browser.profileID == id { Browsers.discard(browser) }
        OneWindow.tidy()
        let all = Spaces.read()
        let gone = all.filter { $0.profileID == id }
        Spaces.write(all.filter { $0.profileID != id })
        for space in gone {
            Session.erase(space: space.id)
            Pins.forget(space.id)
            // A space with sign-ins of its own has a store of its own.
            if space.sharesSignIns != true { Spaces.erase(space.id) }
        }
        Pins.forgetShared(of: id)
        Spaces.eraseStore(Profiles.stores.removeValue(forKey: id), id: id)
        Profiles.histories.removeValue(forKey: id)?.retire()
        Profiles.bookmarkLists.removeValue(forKey: id)?.retire()
        Archive.forget(profile: id)
        // Never opened this run: their files go all the same.
        for name in ["history-\(id.uuidString).json", "bookmarks-\(id.uuidString).json"] {
            Disk.remove(Store.file(name))
        }
        Shared.forgetDownloadAddresses()
        Store.settings.removeObject(forKey: "space.current.\(id.uuidString)")
        list.removeAll { $0.id == id }
        write()
    }

    /// The spaces a profile holds, for Settings.
    func spaces(of id: UUID) -> [Space] { Spaces.read(profile: id) }
}

extension Profiles {
    /// Profile 1–9 (Settings › Shortcuts): the Nth in the profiles' order,
    /// as File › Profile would bring it. Nothing past the last (#1437).
    static func go(index: Int, from browser: Browser) {
        let list = shared.list
        guard shared.several, list.indices.contains(index), list[index].id != browser.profileID else { return }
        Browsers.open(profile: list[index].id)
    }

    /// Next Profile and Previous Profile: the one after or before this
    /// window's, round from the last to the first (#1437).
    static func step(_ step: Int, from browser: Browser) {
        let list = shared.list
        guard shared.several, let here = list.firstIndex(where: { $0.id == browser.profileID }) else { return }
        go(index: (here + step + list.count) % list.count, from: browser)
    }
}

extension Browsers {
    /// A window of this profile: the one already open in front, or a new
    /// one at the space it was last in, its tabs read back from the
    /// profile's own files when no window of it is open.
    /// With profiles in one window, the profile's window takes the place of
    /// the one in front instead (see OneWindow.swift).
    @discardableResult
    static func open(profile id: UUID) -> Browser {
        if OneWindow.on, let here = front, here.isOpen, !here.isPopup, here.profileID != id {
            return join(profile: id, from: here)
        }
        if let open = all.last(where: { $0.profileID == id && ($0.isOpen || $0.tucked) && !$0.isPopup }) {
            show(open)
            return open
        }
        let browser = Browser(record: WindowRecord(space: lastSpace(profile: id)))
        open(browser, frame: nil)
        return browser
    }

    /// The space a profile's window was last in, or its home.
    static func lastSpace(profile id: UUID) -> UUID {
        Store.settings.string(forKey: "space.current.\(id.uuidString)").flatMap(UUID.init)
            .flatMap { last in Spaces.read(profile: id).first { $0.id == last }?.id }
            ?? Profiles.shared.profile(id).home
    }
}

// MARK: - the switcher

/// The profile this window is in, as a letter in a circle: beside the
/// space's icon, only once there is more than one profile. A click opens
/// the list; choosing another brings its window, as in Chrome.
struct ProfileBadge: View {
    /// Its width in the row across the top.
    static let width: CGFloat = Door.width

    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared
    @State private var hovering = false

    private var name: String { profiles.profile(browser.profileID).name }

    var body: some View {
        Button { ProfileMenu.show(for: browser) } label: {
            ProfileAvatar(profile: profiles.profile(browser.profileID), size: 17, emphasis: hovering)
                .frame(width: Self.width, height: 26)
                .background(
                    Door.shape
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Profile: \(name)")
        .accessibilityLabel("Profile \(name)")
        .animation(Motion.quick, value: hovering)
    }
}

/// The badge's menu: every profile, this window's checked, then New Profile….
@MainActor
enum ProfileMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private static var actions: [Action] = []

    private static func item(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.state = checked ? .on : .off
        return item
    }

    /// Its items, for the badge's menu and the dot's.
    static func items(for browser: Browser) -> [NSMenuItem] {
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Profiles", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        title.isEnabled = false
        var items: [NSMenuItem] = [title, .separator()]
        for profile in Profiles.shared.list {
            items.append(item(profile.name, checked: profile.id == browser.profileID) {
                if profile.id != browser.profileID { Browsers.open(profile: profile.id) }
            })
        }
        items.append(.separator())
        items.append(item("New Profile…") { askNew() })
        return items
    }

    static func show(for browser: Browser) {
        actions = []
        let menu = NSMenu()
        for entry in items(for: browser) { menu.addItem(entry) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Its name, then a window of its own.
    static func askNew() {
        Ask.name("New Profile", detail: OneWindow.on
                    ? "A separate set of spaces with its own sign-ins, history and bookmarks."
                    : "A separate set of spaces with its own sign-ins, history and bookmarks, in a window of its own.",
                 placeholder: "Work", confirm: "Create") { name in
            let made = Profiles.shared.add(named: name)
            Browsers.open(profile: made.id)
        }
    }
}

// MARK: - Settings

struct ProfileList: View {
    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared
    @State private var open: Set<UUID> = []

    var body: some View {
        ForEach(Array(profiles.list.enumerated()), id: \.element.id) { index, profile in
            if index > 0 { Rule() }
            let window = profile.id == browser.profileID ? browser
                : Browsers.all.first { $0.profileID == profile.id && !$0.isPopup }
            ProfileRow(profile: profile, current: profile.id == browser.profileID,
                       spaces: profiles.spaces(of: profile.id).count,
                       deletable: profiles.several && !profile.isPersonal,
                       expanded: isOpen(profile.id)) {
                withAnimation(Motion.quick) {
                    if isOpen(profile.id) { open.remove(profile.id) } else { open.insert(profile.id) }
                    if profile.id == browser.profileID { open.insert(Self.closedMark) }
                }
            }
            if isOpen(profile.id) {
                if let window {
                    SpaceRows(browser: window)
                } else {
                    let list = profiles.spaces(of: profile.id)
                    ForEach(list) { space in
                        Rule(inset: ProfileGrid.text)
                        SpaceLine(symbol: space.symbol, name: space.name, rename: nil, remove: nil)
                    }
                    Rule(inset: ProfileGrid.text)
                    Text("Open the profile to add or change its spaces")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, ProfileGrid.text)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        Rule()
        NewProfileRow()
    }

    private static let closedMark = UUID(uuidString: "00000000-0000-0000-0000-00000000C105")!

    private func isOpen(_ id: UUID) -> Bool {
        if id == browser.profileID {
            return open.contains(Self.closedMark) ? open.contains(id) : true
        }
        return open.contains(id)
    }
}

private struct SpaceRows: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ForEach(browser.spaces) { space in
            Rule(inset: ProfileGrid.text)
            SpaceLine(
                symbol: space.symbol, name: space.name,
                rename: { browser.renameSpace(space.id, to: $0) },
                remove: browser.canDeleteSpace(space.id) ? {
                    let own = Spaces.ownsStore(space.id)
                    Ask.sure("Delete “\(space.name)”?",
                             detail: own ? "Its tabs close, and its cookies and sign-ins are erased from this Mac. History and bookmarks stay."
                                         : "Its tabs and pins close. Your sign-ins, history and bookmarks stay.",
                             confirm: "Delete") {
                        browser.deleteSpace(space.id)
                    }
                } : nil)
        }
        Rule(inset: ProfileGrid.text)
        AddLine(title: "New Space…") {
            Ask.newSpace(then: { name, shared in
                browser.addSpace(named: name.isEmpty ? "Space \(browser.spaces.count + 1)" : name, sharesSignIns: shared)
            }, cancelled: {})
        }
    }
}

private struct SpaceLine: View {
    let symbol: String
    let name: String
    let rename: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ProfileGrid.gap) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .frame(width: 18)
            if let rename {
                InlineName(name: name, commit: rename)
            } else {
                Text(name).font(.system(size: 13)).foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 8)
            if let remove {
                QuickRemove(label: "Delete \(name)", act: remove)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.leading, ProfileGrid.text)
        .padding(.trailing, ProfileGrid.trailing)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private enum ProfileGrid {
    static let leading: CGFloat = 16
    static let chevron: CGFloat = 14
    static let avatar: CGFloat = 24
    static let gap: CGFloat = 10
    static let trailing: CGFloat = 16
    static let edge: CGFloat = 16
    static let icon: CGFloat = leading + chevron + gap
    static let text: CGFloat = icon + avatar + gap
}

private struct InlineName: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = false }
                    .onExitCommand { text = name; editing = false }
                    .onChange(of: focused) { _, now in if !now { save() } }
                    .onAppear { text = name; focused = true }
            } else {
                Text(name)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                    .help("Click to rename")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(editing ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.leading, -6)
        .frame(maxWidth: editing ? .infinity : nil, alignment: .leading)
        .accessibilityLabel(name)
        .accessibilityHint("Click to rename")
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != name { commit(trimmed) }
        editing = false
    }
}

private struct QuickRemove: View {
    let label: String
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: "trash")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 26, height: 26)
                .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AddLine: View {
    let title: String
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: ProfileGrid.gap) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .padding(.leading, ProfileGrid.text)
            .padding(.trailing, ProfileGrid.trailing)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let current: Bool
    let spaces: Int
    let deletable: Bool
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var detail: String {
        let count = spaces == 1 ? "1 space" : "\(spaces) spaces"
        return current ? "This window · \(count)" : count
    }

    var body: some View {
        HStack(spacing: ProfileGrid.gap) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: ProfileGrid.chevron, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide spaces of \(profile.name)" : "Show spaces of \(profile.name)")
            ProfileIconPicker(profile: profile)
                .frame(width: ProfileGrid.avatar)
            VStack(alignment: .leading, spacing: 2) {
                InlineName(name: profile.name) { Profiles.shared.rename(profile.id, to: $0) }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if deletable {
                QuickRemove(label: "Delete \(profile.name)") {
                    Ask.sure("Delete “\(profile.name)”?",
                             detail: "Its windows close, its spaces go with their tabs and pins, and its cookies, sign-ins, history and bookmarks are erased from this Mac.",
                             confirm: "Delete", returnCancels: true) {
                        Profiles.shared.delete(profile.id)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            if !current { Pill("Open") { Browsers.open(profile: profile.id) } }
        }
        .padding(.leading, ProfileGrid.leading)
        .padding(.trailing, ProfileGrid.trailing)
        .padding(.vertical, ProfileGrid.edge)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct NewProfileRow: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Pill("New Profile…") { ProfileMenu.askNew() }
        }
        .padding(.horizontal, ProfileGrid.trailing)
        .padding(.vertical, 12)
    }
}

struct ProfileIconPicker: View {
    let profile: Profile
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ProfileAvatar(profile: profile, size: 24, emphasis: open)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Change Icon")
        .accessibilityLabel("Icon for \(profile.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Spaces.colours.indices, id: \.self) { i in
                        swatch(i)
                    }
                }
                Rule()
                cell(nil, help: "Letter") {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(Circle().strokeBorder(Palette.ink.opacity(0.6), lineWidth: 1.2))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 6), spacing: 4) {
                    ForEach(Array(zip(Spaces.icons, Spaces.iconNames)), id: \.0) { symbol, name in
                        cell(symbol, help: name) {
                            Image(systemName: symbol).font(.system(size: 14))
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func swatch(_ i: Int) -> some View {
        let chosen = (profile.colour ?? 0) == i
        return Button { Profiles.shared.setColour(profile.id, to: i) } label: {
            Circle()
                .fill(i == 0 ? Color.clear : Spaces.colours[i])
                .overlay(Circle().strokeBorder(i == 0 ? Palette.muted.opacity(0.6) : .clear, lineWidth: 1.2))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(chosen ? Palette.ink.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Spaces.colourNames[i])
    }

    private func cell<Content: View>(_ symbol: String?, help: String, @ViewBuilder _ content: () -> Content) -> some View {
        let chosen = profile.icon == symbol
        return Button {
            Profiles.shared.setIcon(profile.id, to: symbol)
            open = false
        } label: {
            content()
                .foregroundStyle(Palette.ink)
                .frame(width: 30, height: 30)
                .background(chosen ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(chosen ? Palette.ink.opacity(0.35) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ProfileAvatar: View {
    let profile: Profile
    let size: CGFloat
    var emphasis = false

    var body: some View {
        let tint = profile.tint
        Group {
            if let icon = profile.icon {
                Image(systemName: icon).font(.system(size: size * (tint == nil ? 0.76 : 0.56), weight: .semibold))
            } else {
                Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: size * 0.62, weight: .semibold))
            }
        }
        .foregroundStyle(tint != nil ? Color.white : (emphasis ? Palette.ink : Palette.muted))
        .frame(width: size, height: size)
        .background {
            if let tint {
                Circle().fill(tint.opacity(emphasis ? 1 : 0.9))
            } else if profile.icon == nil {
                Circle().strokeBorder(emphasis ? Palette.ink.opacity(0.5) : Palette.muted.opacity(0.6), lineWidth: 1.2)
            }
        }
    }
}
