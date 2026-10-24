import AppKit
import SwiftUI
import WebKit

// Profiles: whole separate browsers in one app, as in Chrome, Safari and
// Arc. A profile holds its own spaces (and so their tabs, pins and groups),
// its own cookies, sign-ins and site storage, its own history and its own
// bookmarks. A window belongs to one profile for its whole life, as in
// Chrome and Safari: its column shows that profile's spaces and nothing of
// any other's — not their dots, not ⌃1–⌃9, not ⌃Tab, not Move to Space,
// not the history the field offers.
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
    /// Its first space, which can't be deleted while the profile lives:
    /// what a window of the profile shows with spaces off.
    var home: UUID

    static let personalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
    var isPersonal: Bool { id == Profile.personalID }
    static let personal = Profile(id: personalID, name: "Personal", home: Space.firstID)
}

@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    /// Every profile, Personal first.
    @Published private(set) var list: [Profile]

    private init() { list = Profiles.read() }

    /// More than one: only then does anything about profiles show.
    var several: Bool { list.count > 1 }

    func profile(_ id: UUID) -> Profile { list.first { $0.id == id } ?? .personal }

    // MARK: - the file

    private nonisolated static var file: URL { Store.file("profiles.json") }

    nonisolated static func read() -> [Profile] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let personal = saved.first(where: \.isPersonal).map { Profile(id: Profile.personalID, name: $0.name, home: Space.firstID) } ?? .personal
        return [personal] + saved.filter { !$0.isPersonal }
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
        if id == Profile.personalID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
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

    /// A profile and all it holds, gone: its windows close, its spaces go
    /// with their tabs and pins, and its cookies, sign-ins, site data,
    /// history and bookmarks are erased from this Mac. Personal stays.
    func delete(_ id: UUID) {
        guard id != Profile.personalID, list.contains(where: { $0.id == id }) else { return }
        // Never left without a window: one of Personal's first, if no other
        // profile has one open.
        if Browsers.all.contains(where: { $0.profileID == id && $0.isOpen }),
           !Browsers.all.contains(where: { $0.profileID != id && $0.isOpen && $0.extensionPopup == nil }) {
            Browsers.open(profile: Profile.personalID)
        }
        for browser in Browsers.all where browser.profileID == id { Browsers.discard(browser) }
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
        // Never opened this run: their files go all the same.
        for name in ["history-\(id.uuidString).json", "bookmarks-\(id.uuidString).json"] {
            Disk.remove(Store.file(name))
        }
        Store.settings.removeObject(forKey: "space.current.\(id.uuidString)")
        list.removeAll { $0.id == id }
        write()
    }

    /// The spaces a profile holds, for Settings.
    func spaces(of id: UUID) -> [Space] { Spaces.read(profile: id) }
}

extension Browsers {
    /// A window of this profile: the one already open in front, or a new
    /// one at the space it was last in, its tabs read back from the
    /// profile's own files when no window of it is open.
    @discardableResult
    static func open(profile id: UUID) -> Browser {
        if let open = all.last(where: { $0.profileID == id && $0.isOpen && $0.extensionPopup == nil }) {
            show(open)
            return open
        }
        let space = Store.settings.string(forKey: "space.current.\(id.uuidString)").flatMap(UUID.init)
            .flatMap { last in Spaces.read(profile: id).first { $0.id == last }?.id }
            ?? Profiles.shared.profile(id).home
        let browser = Browser(record: WindowRecord(space: space))
        open(browser, frame: nil)
        return browser
    }
}

// MARK: - the switcher

/// The profile this window is in, as a letter in a circle: beside the
/// space's icon, only once there is more than one profile. A click opens
/// the list; choosing another brings its window, as in Chrome.
struct ProfileBadge: View {
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
                .frame(width: 26, height: 26)
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
        Ask.name("New Profile", detail: "A separate set of spaces with its own sign-ins, history and bookmarks, in a window of its own.",
                 placeholder: "Work", confirm: "Create") { name in
            let made = Profiles.shared.add(named: name)
            Browsers.open(profile: made.id)
        }
    }
}

// MARK: - Settings

/// Settings › Tabs › Profiles: New Profile…, and once there is more than
/// one, each with its spaces, Rename… and Delete….
struct ProfilesSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var profiles = Profiles.shared

    var body: some View {
        Card {
            Line("Profiles", "Separate sets of spaces, each with its own sign-ins, history and bookmarks, in windows of their own. Extensions, passwords and settings are shared.") {
                Pill("New Profile…") { ProfileMenu.askNew() }
            }
            if profiles.several {
                ForEach(profiles.list) { profile in
                    Rule()
                    Row(profile: profile, current: profile.id == browser.profileID, spaces: profiles.spaces(of: profile.id).map(\.name))
                }
            }
        }
    }

    private struct Row: View {
        let profile: Profile
        let current: Bool
        let spaces: [String]

        var body: some View {
            Line(profile.name + (current ? " — this window" : ""), spaces.joined(separator: ", ")) {
                HStack(spacing: 6) {
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
