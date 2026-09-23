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
// after half an hour as any tab does. ⌃1–⌃9 switch, as in Arc.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours`.
    var colour: Int
    /// Where this space's downloads go; nil for the folder in Settings.
    var downloads: String?

    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Space.firstID }
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

    private static var file: URL { Store.file("spaces.json") }

    /// Every space, the first one first — made on the spot if there is no
    /// list yet.
    static func read() -> [Space] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
        let first = saved.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0)
        return [first] + saved.filter { !$0.isFirst }
    }

    static func write(_ spaces: [Space]) {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]

    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.firstID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
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
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        }
        stores[id] = nil
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

    private func enter(_ id: UUID) {
        guard id != spaceID, spaces.contains(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if floater.showing { land() }
        writeSession(now: true)

        // The row on screen is parked as it is. Its sound stops: a space
        // you left is not one you are listening to.
        for tab in tabs where tab.built != nil { tab.web.pauseAllMediaPlayback() }
        parked[spaceID] = Parked(tabs: tabs, active: activeID)

        spaceID = id
        Spaces.current = id
        Store.settings.set(id.uuidString, forKey: "space.current")
        if let back = parked.removeValue(forKey: id) {
            showRow(back.tabs, active: back.active)
            if let active, !active.wake() { active.revive() }
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        editing = active?.isBlank ?? true
        typed = ""
        askFocus()
        announce(space.name)
    }

    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    /// The colour a new space gets unless told: the first no space has yet.
    var freeColour: Int {
        let used = Set(spaces.map(\.colour))
        return (0..<Spaces.colours.count).first { !used.contains($0) } ?? spaces.count % Spaces.colours.count
    }

    /// A new space, empty, and on screen.
    func addSpace(named name: String, colour: Int? = nil) {
        makingSpace = false
        let made = Space(id: UUID(), name: name, colour: colour ?? freeColour)
        spaces.append(made)
        Spaces.write(spaces)
        switchSpace(to: made.id)
    }

    /// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index), from != index else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        Spaces.write(spaces)
    }

    /// "New Space…": the card in the column when the column is there to
    /// hold it, a question otherwise.
    func askForSpace() {
        if prefs.sidebar, !folded || peeking {
            withAnimation(Motion.glide) { makingSpace = true }
        } else {
            Ask.name("New Space", placeholder: "Work", confirm: "Create") { self.addSpace(named: $0) }
        }
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[at].name = name
        Spaces.write(spaces)
    }

    func recolourSpace(_ id: UUID, to colour: Int) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].colour = colour
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
        spaces.remove(at: at)
        Spaces.write(spaces)
        Session.erase(space: id)
        Spaces.erase(id)
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        enter(Space.firstID)
        for (_, row) in parked { for tab in row.tabs { tab.close() } }
        parked = [:]
    }
}

// MARK: - the dot

/// The space on screen, as a dot of its colour: before the tabs in the row,
/// beside the bookmarks in the column. Its menu lists the spaces and does
/// the rest. Only there when spaces are on.
struct SpaceDot: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    static let width: CGFloat = 26

    var body: some View {
        // A plain button and a menu of AppKit's: SwiftUI's own Menu draws a
        // pop-up button of its own in place of the dot.
        Button { SpaceMenu.show(for: browser) } label: {
            Circle()
                .fill(Spaces.colours[browser.space.colour % Spaces.colours.count])
                .frame(width: 9, height: 9)
                .frame(width: SpaceDot.width, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — ⌃1–⌃9 to switch spaces")
        .animation(Motion.quick, value: hovering)
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
        actions = []
        let menu = NSMenu()
        for (index, space) in browser.spaces.enumerated() {
            menu.addItem(item(space.name, key: index < 9 ? "\(index + 1)" : "", checked: space.id == browser.spaceID) {
                browser.switchSpace(to: space.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("New Space…") { browser.askForSpace() })
        menu.addItem(.separator())
        let here = browser.space
        menu.addItem(item("Rename “\(here.name)”…") {
            Ask.name("Rename Space", placeholder: here.name, initial: here.name, confirm: "Rename") { browser.renameSpace(here.id, to: $0) }
        })
        let colours = NSMenu()
        for (i, name) in Spaces.colourNames.enumerated() {
            colours.addItem(item(name, checked: here.colour == i) { browser.recolourSpace(here.id, to: i) })
        }
        let colour = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colour.submenu = colours
        menu.addItem(colour)
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
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The few questions a space's menu asks, as sheets on the window.
@MainActor
enum Ask {
    static func name(_ title: String, placeholder: String, initial: String = "", confirm: String, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !name.isEmpty { then(name) }
        }
    }

    static func sure(_ title: String, detail: String, confirm: String, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        show(alert) { ok in if ok { then() } }
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
