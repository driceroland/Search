import AppKit
import SwiftUI
import WebKit

// Containers, as in Firefox's Multi-Account Containers and Zen: tabs that
// sit in the same row, in the same space, beside every other tab, but each
// container signed in as someone else — its own cookies, sign-ins and site
// storage. Two Outlook tabs side by side, one signed in to work and one to
// university, both still signed in tomorrow.
//
// A container's store is WebKit's store under the container's own id, made
// once and set up as a space's own is. A tab in one uses it whatever space
// the tab is in, and keeps it moved to another space or window; the tab's
// container is nothing but that store (Tab.container), so the two can never
// disagree. Pins carry theirs (PinDef.container), the session each tab's
// (Session.Entry.container). Links, pop-ups, a peek and Split View opened
// from a container tab are in the same container, as a private tab's are
// private. Private tabs and the bench's never are.
//
// History, bookmarks and passwords stay the profile's, as with spaces.
//
// Off unless turned on in Settings › Spaces & Pins. Until then nothing of
// it shows; on, the tab menu has its Container submenu, which makes the
// first one. Turned off again, the tabs already in a container stay in it,
// mark and all, and nothing is erased: only the menus go.

struct Container: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours`.
    var colour: Int

    var tint: Color { Spaces.colours[Containers.colourIndex(colour)] }
}

@MainActor
final class Containers: ObservableObject {
    static let shared = Containers()

    /// Every container, in the order they were made.
    @Published private(set) var list: [Container]

    private init() { list = Containers.read() }

    /// One there is, by its id.
    func container(_ id: UUID?) -> Container? {
        guard let id else { return nil }
        return list.first { $0.id == id }
    }

    /// An id that still names a container, or nil: a container saved with a
    /// tab or a pin and deleted since reads as none.
    func known(_ id: UUID?) -> UUID? { container(id)?.id }

    /// A colour's index, in range whatever a file says.
    nonisolated static func colourIndex(_ colour: Int) -> Int {
        let count = Spaces.colours.count
        return ((colour % count) + count) % count
    }

    // MARK: - the file

    private nonisolated static var file: URL { Store.file("containers.json") }

    /// What containers.json holds. A file that isn't there, or won't read,
    /// is no containers.
    nonisolated static func read() -> [Container] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Container].self, from: $0) } ?? []
    }

    private func write() {
        // No containers is no file, as it was before there were any.
        guard !list.isEmpty else {
            try? FileManager.default.removeItem(at: Containers.file)
            return
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: Containers.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Containers.file, options: .atomic)
    }

    // MARK: - the stores

    /// Each container's store, made once: WebKit shares processes between
    /// views that ask for the same store object, and a tab's container is
    /// told by which of these objects it holds.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// The store a container's tabs use, set up as a space's own is; nil for
    /// no container, or one that no longer exists.
    static func store(_ id: UUID?) -> WKWebsiteDataStore? {
        guard let id = shared.known(id) else { return nil }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
        BrowserProxy.shared.attach(made)
        stores[id] = made
        return made
    }

    /// The container a store is, or nil for any other store.
    static func id(of store: WKWebsiteDataStore) -> UUID? {
        guard let id = store.identifier, stores[id] === store else { return nil }
        return id
    }

    /// The container stores made so far, for Spaces.everyStore.
    static var madeStores: [WKWebsiteDataStore] { Array(stores.values) }

    /// Every container's store, made now if it wasn't: for clearing what
    /// sites left, which must reach a container no tab has opened this run.
    static var everyStore: [WKWebsiteDataStore] { shared.list.compactMap { store($0.id) } }

    // MARK: - making, renaming, deleting

    /// A new container, in the first colour no container wears yet.
    @discardableResult
    func add(named name: String) -> Container {
        let used = Set(list.map { Containers.colourIndex($0.colour) })
        // Slate last: it is the colour of nothing in particular.
        let colour = (Array(1..<Spaces.colours.count) + [0]).first { !used.contains($0) }
            ?? (list.count % (Spaces.colours.count - 1)) + 1
        let made = Container(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), colour: colour)
        list.append(made)
        write()
        return made
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].name = name
        write()
        Containers.redraw()
    }

    func setColour(_ id: UUID, to colour: Int) {
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].colour = Containers.colourIndex(colour)
        write()
        Containers.redraw()
    }

    /// A container gone: its open tabs, in every window and space, back in
    /// their space's store, reloaded there; its cookies, sign-ins and site
    /// data erased from this Mac, as a deleted space's are. A tab or pin
    /// saved with it reads as in no container from now on.
    func delete(_ id: UUID) {
        guard list.contains(where: { $0.id == id }) else { return }
        for browser in Browsers.all { browser.leave(container: id) }
        list.removeAll { $0.id == id }
        write()
        Spaces.eraseStore(Containers.stores.removeValue(forKey: id), id: id)
    }

    /// How many tabs are open in it, in every window, for Settings.
    func openTabs(in id: UUID) -> Int {
        Browsers.all.reduce(0) { count, browser in
            count + (browser.tabs + browser.parkedTabs).filter { $0.container == id }.count
        }
    }

    /// Its tabs wear its name and colour: drawn again when either changes.
    private static func redraw() {
        for browser in Browsers.all {
            for tab in browser.tabs where tab.container != nil { tab.objectWillChange.send() }
        }
    }
}

extension Web {
    /// The store a tab uses: its container's, whatever space it is in, or
    /// else its space's.
    @MainActor static func store(space: UUID, container: UUID?) -> WKWebsiteDataStore {
        Containers.store(container) ?? Spaces.store(for: space)
    }
}

extension Tab {
    /// The container it is in: the one whose store it holds. Never a
    /// private tab's or the bench's, which never hold one.
    var container: UUID? { Containers.id(of: store) }
}

extension Browser {
    /// Whether a tab can be put in a container: not a private tab, the
    /// bench's, or an extension's own page.
    func containable(_ tab: Tab) -> Bool {
        !tab.shy && !tab.bench && tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
    }

    /// The tab menu's Container: the tab's page opened again with that
    /// container's cookies, or its space's for none, as Move to Space does
    /// — asking first only when the page holds unsaved form entries.
    func contain(_ tab: Tab, in container: UUID?) {
        let container = Containers.shared.known(container)
        guard containable(tab), tab.container != container, space(holding: tab) != nil else { return }
        let complete: () -> Void = { [weak self, weak tab] in
            guard let self, let tab, let space = self.space(holding: tab) else { return }
            self.rebuild(tab, in: space, container: container)
            // A pin's container is part of the pin, in every window.
            if tab.pin != nil { self.writeSession(now: true) } else { self.writeSessionSoon() }
        }
        guard tab.built != nil, !tab.isBlank else { return complete() }
        tab.unsaved { unsaved in
            guard unsaved else { return complete() }
            let name = Containers.shared.container(container)?.name
            Ask.sure(
                "Change Container?",
                detail: "This page has unsaved form entries. It will reopen "
                    + (name.map { "in “\($0)” with that container’s sign-ins" } ?? "with this space’s sign-ins")
                    + ", so the entries may be lost.",
                confirm: "Reopen",
                then: complete
            )
        }
    }

    /// The space a tab of this window is in: the one on screen, or the
    /// parked row that holds it.
    func space(holding tab: Tab) -> UUID? {
        if tabs.contains(where: { $0 === tab }) { return spaceID }
        return parked.first { $0.value.tabs.contains { $0 === tab } }?.key
    }

    /// The tab's view made again with another store, its page kept: woken
    /// at once where it is on screen, left to wake when gone to otherwise.
    func rebuild(_ tab: Tab, in space: UUID, container: UUID?) {
        if let web = tab.built { cancelDisplay(for: web) }
        if floating == tab.id { land(covering: false) }
        tab.objectWillChange.send()
        tab.rehome(in: space, container: container)
        if space == spaceID, visibleTabIDs.contains(tab.id) { _ = tab.wake() }
        tab.objectWillChange.send()
        objectWillChange.send()
    }

    /// A container deleted: every tab of this window in it, on screen or
    /// parked, back in its space's store.
    func leave(container id: UUID) {
        for tab in tabs where tab.container == id { rebuild(tab, in: spaceID, container: nil) }
        for (space, row) in parked {
            for tab in row.tabs where tab.container == id { rebuild(tab, in: space, container: nil) }
        }
        writeSession(now: true)
        for (space, row) in parked { writeSession(now: true, space: space, row: row) }
    }
}

// MARK: - the menus

/// The tab menu's Container submenu: No Container, each container with the
/// tab's checked, then New Container…. With Containers on, there even
/// before the first one is made, with only New Container… in it.
struct ContainerMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var containers = Containers.shared

    var body: some View {
        Menu("Container") {
            if !containers.list.isEmpty {
                Toggle("No Container", isOn: Binding(get: { tab.container == nil },
                                                     set: { if $0 { browser.contain(tab, in: nil) } }))
                ForEach(containers.list) { container in
                    Toggle(isOn: Binding(get: { tab.container == container.id },
                                         set: { if $0 { browser.contain(tab, in: container.id) } })) {
                        Label {
                            Text(container.name)
                        } icon: {
                            Image(nsImage: ContainerMenu.swatch(container.colour))
                        }
                    }
                }
                Divider()
            }
            Button("New Container…") {
                ContainerMenu.askNew { made in browser.contain(tab, in: made.id) }
            }
        }
    }

    /// Its name, then the container; `then` with it, once made.
    static func askNew(then: ((Container) -> Void)? = nil) {
        Ask.name("New Container",
                 detail: "Tabs in it have their own cookies and sign-ins, in whatever space they are. History, bookmarks and passwords are shared.",
                 placeholder: "Work", confirm: "Create") { name in
            let made = Containers.shared.add(named: name)
            then?(made)
        }
    }

    /// A dot of a container's colour for a menu, drawn in that colour: a
    /// menu draws a symbol in its own grey.
    static func swatch(_ colour: Int) -> NSImage {
        let tint = NSColor(Spaces.colours[Containers.colourIndex(colour)])
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - the mark

/// A container tab's mark: a short line in the container's colour, beside
/// a row's icon, under a square or along the foot of a tab across the top.
/// Over what is there, so nothing moves for it, and taking no click: the
/// tab's own tooltip says the container's name (see Tab.withContainer).
struct ContainerMark: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var containers = Containers.shared
    /// Upright, beside a row; lying, under a square or a tab.
    var upright = false
    var length: CGFloat = 10
    /// How far in from the edge it stands.
    var inset: CGFloat = 3

    var body: some View {
        if let container = containers.container(tab.container) {
            Capsule()
                .fill(container.tint)
                .frame(width: upright ? 2.5 : length, height: upright ? length : 2.5)
                .padding(inset)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("In container \(container.name)")
        }
    }
}

extension Tab {
    /// The container's name, for its tooltip and the site card.
    var containerName: String? { Containers.shared.container(container)?.name }

    /// A tooltip with the container's name after it, for a tab in one.
    func withContainer(_ tip: String) -> String {
        guard let name = containerName else { return tip }
        return tip.isEmpty ? "Container: \(name)" : "\(tip) — \(name)"
    }
}

// MARK: - Settings

/// Settings › Spaces & Pins, under Containers once it is on: New
/// Container…, then each one with its colour, Rename… and Delete….
struct ContainerList: View {
    @ObservedObject private var containers = Containers.shared

    var body: some View {
        Rule()
        Line("New container", "Or right-click a tab › Container") {
            Pill("New Container…") { ContainerMenu.askNew() }
        }
        ForEach(containers.list) { container in
            Rule()
            Line(container.name, detail(container)) {
                HStack(spacing: 10) {
                    Colours(container: container)
                    Pill("Rename…") {
                        Ask.name("Rename Container", placeholder: container.name, initial: container.name, confirm: "Rename") {
                            Containers.shared.rename(container.id, to: $0)
                        }
                    }
                    Pill("Delete…", tint: .red) {
                        Ask.sure("Delete “\(container.name)”?",
                                 detail: "Its tabs stay open, in no container, and its cookies, sign-ins and site data are erased from this Mac.",
                                 confirm: "Delete", returnCancels: true) {
                            Containers.shared.delete(container.id)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ container: Container) -> String {
        let open = containers.openTabs(in: container.id)
        return open == 0 ? "No tabs open" : open == 1 ? "1 tab open" : "\(open) tabs open"
    }

    /// The colours, as dots: the container's ringed.
    private struct Colours: View {
        let container: Container

        var body: some View {
            HStack(spacing: 4) {
                ForEach(Spaces.colours.indices, id: \.self) { index in
                    let chosen = Containers.colourIndex(container.colour) == index
                    Button { Containers.shared.setColour(container.id, to: index) } label: {
                        Circle()
                            .fill(Spaces.colours[index])
                            .frame(width: 10, height: 10)
                            .padding(2)
                            .overlay(Circle().strokeBorder(chosen ? Palette.ink.opacity(0.55) : .clear, lineWidth: 1.2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(Spaces.colourNames[index])
                    .accessibilityLabel(Spaces.colourNames[index])
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }
}
