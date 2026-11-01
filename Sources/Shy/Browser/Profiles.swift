import AppKit
import SwiftUI
import WebKit

// Profiles, as in Arc: a profile holds the sign-ins and site data, the
// history, the bookmarks and the passwords, and each space belongs to one.
// Going to a space is going to its profile, in the same window: the tabs
// there are signed in as the profile is, the address field offers its
// history, the bookmarks are its own, and a password saved or filled in is
// its own. Several spaces can share a profile — Work and Work Research,
// both signed in to the same mail.
//
// There is always one, "Personal": everything there was before profiles,
// left where it was — the same store, history.json, bookmarks.json and
// keychain items — so nobody's data moves, and every space is in it until
// it is given another. A space with sign-ins of its own from before keeps
// them, inside whichever profile it is in.
//
// Shared by every profile, for now: the settings, the extensions (one
// WKWebExtensionController for the app), downloads and the icons of sites.
// Never synced anywhere.

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String

    static let personalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
    var isPersonal: Bool { id == Profile.personalID }
    static let personal = Profile(id: personalID, name: "Personal")
}

/// What a profile remembers about sites — a zoom, a choice about dark
/// pages, videos that stay put, the blocker paused, pop-ups allowed, sites
/// kept awake — under keys of its own, so one profile's choices never
/// answer for another, nor show a site in one profile what it was allowed
/// in another. Personal's are the keys there always were; another's carry
/// its id. Whatever reads them is handed the profile (Tab.profile).
enum SiteMemory {
    /// A key for a whole list, such as "shield.paused".
    static func key(_ key: String, _ profile: UUID) -> String {
        profile == Profile.personalID ? key : "\(key)@\(profile.uuidString)"
    }

    /// A key for one site, such as "zoom." and a host.
    static func key(_ prefix: String, _ site: String, _ profile: UUID) -> String {
        profile == Profile.personalID ? prefix + site : "\(prefix)\(profile.uuidString)|\(site)"
    }

    /// Everything a profile remembered about sites, gone with it.
    static func forget(_ profile: UUID) {
        guard profile != Profile.personalID else { return }
        let id = profile.uuidString
        for key in Store.settings.dictionaryRepresentation().keys where key.hasSuffix("@\(id)") || key.contains(".\(id)|") {
            Store.settings.removeObject(forKey: key)
        }
    }
}

/// An entry of profiles.json, nil when it doesn't read as a profile.
private struct Lenient: Decodable {
    let profile: Profile?
    init(from decoder: Decoder) throws { profile = try? Profile(from: decoder) }
}

@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    /// Every profile, Personal first.
    @Published private(set) var list: [Profile]

    private init() { list = Profiles.read() }

    /// More than one: only then does anything about profiles show beyond
    /// Settings.
    var several: Bool { list.count > 1 }

    func profile(_ id: UUID) -> Profile { list.first { $0.id == id } ?? .personal }

    // MARK: - the file

    private nonisolated static var file: URL { Store.file("profiles.json") }

    nonisolated static func read() -> [Profile] {
        // One by one: an entry that doesn't read loses itself, not every
        // profile — whose spaces would be left in none, their data beyond
        // the reach of Delete.
        let data = try? Data(contentsOf: file)
        let decoded = data.flatMap { try? JSONDecoder().decode([Lenient].self, from: $0) }
        // A file that doesn't read at all is set aside (see Spaces.read).
        if data != nil, decoded == nil { Store.quarantine(file) }
        let saved = decoded?.compactMap(\.profile) ?? []
        let personal = saved.first(where: \.isPersonal) ?? .personal
        return [personal] + saved.filter { !$0.isPersonal }
    }

    private func write() {
        let snapshot = list
        // Only Personal, named as it always was, is no file at all.
        if snapshot == [.personal] {
            try? FileManager.default.removeItem(at: Profiles.file)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Profiles.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Profiles.file, options: .atomic)
    }

    // MARK: - what each holds

    /// Each profile's store, made once: WebKit shares processes between
    /// views that ask for the same store object.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// The cookies and sign-ins its spaces share. Personal's is the store
    /// there always was; another's is WebKit's store under the profile's
    /// own identifier.
    static func store(_ id: UUID) -> WKWebsiteDataStore {
        if id == Profile.personalID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: Store.webKitID(id))
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
        stores[id] = made
        return made
    }

    /// Whose store this is: a profile's, or a space's own (in that space's
    /// profile). Nil for one of neither, a private tab's.
    static func owner(of store: WKWebsiteDataStore) -> UUID? {
        if store === Store.websites { return Profile.personalID }
        if let id = stores.first(where: { $0.value === store })?.key { return id }
        return Spaces.space(owning: store).map(Spaces.profile(of:))
    }

    /// The profile stores made so far, Personal's aside.
    static var madeStores: [WKWebsiteDataStore] { Array(stores.values) }

    private static var histories: [UUID: History] = [:]
    private static var bookmarkLists: [UUID: Bookmarks] = [:]

    /// Its history: Personal's in history.json, as always; another's in a
    /// file of its own.
    static func history(_ id: UUID) -> History {
        if let made = histories[id] { return made }
        let made = History(file: id == Profile.personalID ? "history.json" : "history-\(id.uuidString).json", profile: id)
        histories[id] = made
        return made
    }

    private static var curtains: [UUID: Curtain] = [:]

    /// What it hides on each site (see Curtain.swift): Personal's in
    /// hidden.json, as always; another's in a file of its own.
    static func curtain(_ id: UUID) -> Curtain {
        if let made = curtains[id] { return made }
        let made = Curtain(file: id == Profile.personalID ? "hidden.json" : "hidden-\(id.uuidString).json")
        curtains[id] = made
        return made
    }

    static func bookmarks(_ id: UUID) -> Bookmarks {
        if let made = bookmarkLists[id] { return made }
        let made = Bookmarks(file: id == Profile.personalID ? "bookmarks.json" : "bookmarks-\(id.uuidString).json", profile: id)
        bookmarkLists[id] = made
        return made
    }

    // MARK: - making, renaming, deleting

    @discardableResult
    func add(named name: String) -> Profile {
        let made = Profile(id: UUID(), name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
        list.append(made)
        write()
        return made
    }

    /// The one named so, made if there is none: for an import bringing a
    /// browser's profiles in.
    func named(_ name: String) -> Profile {
        if name == Profile.personal.name || name.isEmpty { return list[0] }
        return list.first { $0.name == name } ?? add(named: name)
    }

    func rename(_ id: UUID, to name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].name = name
        write()
    }

    /// A profile and all it holds, gone: its spaces close with their tabs,
    /// and its cookies, sign-ins, site data, history, bookmarks and
    /// passwords are erased from this Mac. Personal stays, and so does the
    /// first space, which can't be deleted: it comes back to Personal,
    /// signed out. `browser`: the window whose spaces go.
    func delete(_ id: UUID, from browser: Browser) {
        guard id != Profile.personalID, list.contains(where: { $0.id == id }) else { return }
        for space in browser.spaces where space.profile == id && !space.isFirst {
            browser.deleteSpace(space.id)
        }
        // Pages signed in as it that no space's row holds — a peek, a small
        // window — close while their store still says whose they are; its
        // closed tabs are forgotten in every window.
        for window in Browsers.all {
            if window.peekTab?.profile == id { window.closePeek() }
            window.forgetGhosts(of: id)
        }
        for little in LittleWindow.all where little.tab.profile == id { little.close() }
        // The first space, if it was in it: to Personal, and its own
        // sign-ins, if it had any, go with the rest.
        let all = Spaces.read()
        Spaces.write(all.map { space in
            var space = space
            guard space.profile == id else { return space }
            space.profile = nil
            if space.sharesSignIns != true {
                Spaces.erase(space.id)
                space.sharesSignIns = true
            }
            return space
        })
        // A side panel signed in as it goes first: its page holds the store.
        for window in Browsers.all {
            if case .site(_, let profile) = window.sidePanel, profile == id { window.closeSidePanel() }
        }
        list.removeAll { $0.id == id }
        write()
        if let store = Profiles.stores.removeValue(forKey: id) {
            Browsers.acting.forgetDownloads(of: store)
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        // The store itself, by the same sweep as a deleted space's.
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([Store.webKitID(id).uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        Spaces.sweep()
        // As for a space's (Spaces.erase): a page still holding the store
        // keeps it a moment longer.
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Spaces.sweep() }
        }
        Profiles.histories.removeValue(forKey: id)?.retire()
        Profiles.bookmarkLists.removeValue(forKey: id)?.retire()
        // Never opened this run: their files go all the same.
        Profiles.curtains.removeValue(forKey: id)?.retire()
        SiteSearch.forget(in: id)
        Favicons.drop(id)
        for name in ["history-\(id.uuidString).json", "bookmarks-\(id.uuidString).json", "hidden-\(id.uuidString).json"] {
            Disk.remove(Store.file(name))
        }
        // And any copy of them once set aside as unreadable.
        Store.forgetUnreadable { $0.contains(id.uuidString) }
        Vault.forgetAll(in: id)
        // What it remembered about sites, its camera, microphone, screen,
        // location and notification answers among them.
        SiteMemory.forget(id)
    }
}

/// Settings › Profiles & Spaces: every profile with its spaces under it.
/// A space's right-click menu renames it, moves it to another profile
/// (after a yes) or deletes it; each profile's ⋯ makes a space in it,
/// renames or deletes it. The order of spaces is the drawer's to change.
struct ProfilesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var profiles = Profiles.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Each profile keeps its own sign-ins, history, bookmarks and passwords. Right-click a space to rename it, move it to another profile or delete it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Pill("New Profile…") {
                    Ask.name("New Profile", detail: "Signed out of everything, with no history, bookmarks or passwords.",
                             placeholder: "Work", confirm: "Create") { profiles.add(named: $0) }
                }
            }
            ForEach(profiles.list) { profile in
                card(profile)
            }
        }
    }

    private func card(_ profile: Profile) -> some View {
        let spaces = browser.spaces.filter { $0.profileID == profile.id }
        return Card {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Dots {
                    Button("New Space") { browser.askForSpace(in: profile.id) }
                    Button("Rename…") {
                        Ask.name("Rename Profile", placeholder: profile.name, initial: profile.name, confirm: "Rename") {
                            profiles.rename(profile.id, to: $0)
                        }
                    }
                    if !profile.isPersonal {
                        Divider()
                        Button("Delete…") { askDelete(profile, spaces: spaces) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            if spaces.isEmpty {
                Rule()
                Text("No spaces yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            ForEach(spaces) { space in
                Rule()
                row(space, in: profile)
            }
            ProfileData(profile: profile)
        }
    }

    /// A space: its icon and name; a right-click for what can be done to it.
    private func row(_ space: Space, in profile: Profile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: space.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            Text(space.name)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") {
                Ask.name("Rename Space", placeholder: space.name, initial: space.name, confirm: "Rename") {
                    browser.renameSpace(space.id, to: $0)
                }
            }
            Menu("Move to") {
                ForEach(profiles.list.filter { $0.id != profile.id }) { other in
                    Button(other.name) { browser.askToMove(space.id, to: other.id) }
                }
            }
            .disabled(profiles.list.count < 2)
            if !space.isFirst {
                Divider()
                Button("Delete…") {
                    Ask.sure("Delete “\(space.name)”?", detail: "Its tabs close, and what it alone keeps is erased from this Mac.", confirm: "Delete") {
                        browser.deleteSpace(space.id)
                    }
                }
            }
        }
    }

    /// The ⋯ button and its menu.
    private struct Dots<Items: View>: View {
        @ViewBuilder let items: () -> Items
        var body: some View {
            Menu(content: items) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func askDelete(_ profile: Profile, spaces: [Space]) {
        let going = spaces.filter { !$0.isFirst }
        let named = going.map { "“\($0.name)”" }.joined(separator: ", ")
        let erased = "cookies, sign-ins, history, bookmarks and passwords are erased from this Mac. This can't be undone."
        var detail = going.isEmpty ? "Its " + erased
            : (going.count == 1 ? "Its space \(named) closes" : "Its spaces \(named) close") + " with their tabs, and its " + erased
        if spaces.contains(where: \.isFirst) {
            detail += " Your first space stays, signed out, in \(profiles.list[0].name)."
        }
        Ask.sure("Delete “\(profile.name)” and its spaces?", detail: detail, confirm: "Delete", returnCancels: true) {
            profiles.delete(profile.id, from: browser)
        }
    }
}
