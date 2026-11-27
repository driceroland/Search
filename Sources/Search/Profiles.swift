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
        let personal = saved.first(where: \.isPersonal).map { Profile(id: Profile.personalID, name: $0.name, home: $0.home) } ?? .personal
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
        // macOS 12 and 13 keep only the one store: every profile signs in there.
        guard let made = WKWebsiteDataStore.identifiedCompat(id) else { return store(Profile.personalID) }
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
    static let width: CGFloat = 26

    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared
    @State private var hovering = false

    private var name: String { profiles.profile(browser.profileID).name }

    var body: some View {
        Button { ProfileMenu.show(for: browser) } label: {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 17, height: 17)
                .background(Circle().strokeBorder(hovering ? Palette.ink.opacity(0.5) : Palette.muted.opacity(0.6), lineWidth: 1.2))
                .frame(width: Self.width, height: Self.width)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        var items: [NSMenuItem] = []
        for profile in Profiles.shared.list {
            items.append(item(profile.name, checked: profile.id == browser.profileID) {
                if profile.id != browser.profileID { Browsers.open(profile: profile.id) }
            })
        }
        // A profile's own sign-ins need macOS 14 (separateStoresSupported).
        if WKWebsiteDataStore.separateStoresSupported {
            items.append(.separator())
            items.append(item("New Profile…") { askNew() })
        }
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
        // A profile's own sign-ins need a store of its own: macOS 14.
        guard WKWebsiteDataStore.separateStoresSupported else {
            let alert = NSAlert()
            alert.messageText = "Profiles need macOS 14 or later"
            alert.informativeText = "Each profile keeps its own sign-ins, which this version of macOS can't do. Spaces still work."
            alert.runModal()
            return
        }
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

/// Settings › Spaces & Pins: once there is more than one profile, each
/// with its spaces, arrows to move it, Open, Rename… and Delete…, under the
/// Profiles row. The order is the one profiles keep everywhere else.
struct ProfileList: View {
    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared

    var body: some View {
        if profiles.several {
            ForEach(Array(profiles.list.enumerated()), id: \.element.id) { index, profile in
                Rule()
                ProfilesSettings.Row(profile: profile, current: profile.id == browser.profileID,
                                     spaces: profiles.spaces(of: profile.id).map(\.name),
                                     index: index, count: profiles.list.count)
            }
        }
    }
}

private struct OrderButtons: View {
    let name: String
    let index: Int
    let count: Int
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("chevron.up", label: "Move \(name) up", enabled: index > 0, step: -1)
            button("chevron.down", label: "Move \(name) down", enabled: index + 1 < count, step: 1)
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, step: Int) -> some View {
        Button { move(step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Profiles in a card of its own.
struct ProfilesSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared

    var body: some View {
        Card {
            Line("Profiles", "Separate sets of spaces, each with its own sign-ins, history and bookmarks, in windows of their own. Extensions, passwords and settings are shared.") {
                if WKWebsiteDataStore.separateStoresSupported {
                    Pill("New Profile…") { ProfileMenu.askNew() }
                } else {
                    Text("Needs macOS 14")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            ProfileList(browser: browser)
        }
    }

    struct Row: View {
        let profile: Profile
        let current: Bool
        let spaces: [String]
        let index: Int
        let count: Int

        var body: some View {
            Line(profile.name + (current ? " — this window" : ""), spaces.joined(separator: ", ")) {
                HStack(spacing: 6) {
                    if count > 1 {
                        OrderButtons(name: profile.name, index: index, count: count) { step in
                            Profiles.shared.move(profile.id, by: step)
                        }
                    }
                    if !current { Pill("Open") { Browsers.open(profile: profile.id) } }
                    Pill("Rename…") {
                        Ask.name("Rename Profile", placeholder: profile.name, initial: profile.name, confirm: "Rename") {
                            Profiles.shared.rename(profile.id, to: $0)
                        }
                    }
                    if !profile.isPersonal {
                        Pill("Delete…", tint: .red) {
                            Ask.sure("Delete “\(profile.name)”?",
                                     detail: "Its windows close, its spaces go with their tabs and pins, and its cookies, sign-ins, history and bookmarks are erased from this Mac.",
                                     confirm: "Delete", returnCancels: true) {
                                Profiles.shared.delete(profile.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
