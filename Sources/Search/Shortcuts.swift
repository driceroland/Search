import AppKit
import SwiftUI

// Your own keys for the menu commands (Settings › Shortcuts). Only what you
// change is kept, on top of the keys the menus already have, so a browser
// nobody has customised behaves exactly as it always did — and a default
// that changes later still reaches everyone who never touched it.

/// A key and the modifiers held with it.
struct KeyCombo: Codable, Hashable {
    /// A lowercased character, or the name of a key that has none:
    /// left, right, up, down, return, delete, space, f1…f12.
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        // ⌘+ is ⇧⌘= on some keyboards and a key of its own on others; both
        // mean the same thing, so both are kept as "+" with nothing about ⇧.
        let plus = key == "=" || key == "+"
        self.key = plus ? "+" : key.lowercased()
        self.shift = plus ? false : shift
        self.command = command
        self.option = option
        self.control = control
    }

    /// The key an event pressed, read the way the keyboard's own layout
    /// names it with nothing held — so ⇧⌘] is "]" with shift, not "}" —
    /// and the top row by where it sits, as ⌘1–⌘9 are.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named = KeyCombo.names[event.keyCode] ?? ContentView.digits[event.keyCode].map(String.init)
        guard let key = named ?? event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return nil }
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    private static let names: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return",
        51: "delete", 117: "delete", 49: "space",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "delete": "⌫", "space": "Space",
    ]

    /// As a menu shows it: ⌃⌥⇧⌘ then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (KeyCombo.symbols[key] ?? key.uppercased())
    }

    private var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// A key alone, or with only ⇧, is typing — never a shortcut.
    var isUsable: Bool { command || option || control || isFunctionKey }

    var swiftUI: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "return": equivalent = .return
        case "delete": equivalent = .delete
        case "space": equivalent = .space
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                equivalent = KeyEquivalent(Character(scalar))
            } else if key.count == 1, let character = key.first {
                equivalent = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// macOS's own, the ones every text field relies on, and the ones Search
    /// keeps for itself (⌘1–⌘9 and ⌘0, ⌃1–⌃9 for spaces). Not ours to give.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        let system: Set<KeyCombo> = [
            KeyCombo("q"), KeyCombo("h"), KeyCombo("m"), KeyCombo("c"), KeyCombo("v"), KeyCombo("x"),
            KeyCombo("a"), KeyCombo("z"), KeyCombo("z", shift: true), KeyCombo("`"), KeyCombo("h", option: true),
        ]
        if system.contains(combo) { return true }
        let digit = combo.key.count == 1 && combo.key.first?.isNumber == true
        return digit && !combo.option && !combo.shift && (combo.command != combo.control)
    }
}

/// A menu command, and the key it has unless you give it another.
struct Command: Identifiable {
    enum Section: String, CaseIterable {
        case app = "Search", file = "File", edit = "Edit", view = "View", tabs = "Tabs", bookmarks = "Bookmarks", history = "History"
    }

    let id: String
    let title: String
    let section: Section
    let defaultKey: KeyCombo?
    let run: @MainActor (Browser) -> Void

    init(_ id: String, _ title: String, _ section: Section, _ key: KeyCombo?, _ run: @escaping @MainActor (Browser) -> Void) {
        self.id = id
        self.title = title
        self.section = section
        self.defaultKey = key
        self.run = run
    }

    static func named(_ id: String) -> Command? { byID[id] }
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The same commands, keys and order as the menus (see App.swift).
    static let all: [Command] = [
        Command("app.settings", "Settings…", .app, KeyCombo(",")) { $0.tuning.toggle() },
        Command("app.welcome", "Welcome…", .app, nil) { $0.welcoming = true },
        Command("app.passwords", "Passwords…", .app, KeyCombo("l", option: true)) { $0.managing = true },

        Command("file.newTab", "New Tab", .file, KeyCombo("t")) { $0.newTab() },
        Command("file.newPrivateTab", "New Private Tab", .file, KeyCombo("n", shift: true)) { $0.newShyTab() },
        Command("file.reopen", "Reopen Closed Tab", .file, KeyCombo("t", shift: true)) { $0.reopen() },
        Command("file.openAddress", "Open Address…", .file, KeyCombo("l")) { $0.edit() },
        Command("file.closeTab", "Close Tab", .file, KeyCombo("w")) { browser in
            if let tab = browser.active { browser.close(tab) }
        },
        Command("file.print", "Print…", .file, KeyCombo("p")) { $0.printPage() },

        Command("edit.find", "Find on Page…", .edit, KeyCombo("f")) { $0.openFind() },
        Command("edit.findNext", "Find Next", .edit, KeyCombo("g")) { $0.look(forward: true) },
        Command("edit.findPrevious", "Find Previous", .edit, KeyCombo("g", shift: true)) { $0.look(forward: false) },

        Command("view.sidebar", "Show Tabs in Sidebar", .view, KeyCombo("s", shift: true)) { $0.toggleSidebar() },
        Command("view.fold", "Hide Sidebar or Tab Bar", .view, KeyCombo("s")) { $0.toggleFold() },
        Command("view.reload", "Reload Page", .view, KeyCombo("r")) { $0.reload() },
        Command("view.reader", "Reading Mode", .view, KeyCombo("r", shift: true)) { $0.toggleReader() },
        Command("view.float", "Float Video", .view, KeyCombo("p", shift: true)) { $0.toggleFloat() },
        Command("view.hide", "Hide Elements…", .view, KeyCombo("h", shift: true)) { $0.toggleHiding() },
        Command("view.hidden", "Hidden on This Site…", .view, KeyCombo("u", shift: true)) { $0.reviewing.toggle() },
        Command("view.zoomIn", "Zoom In", .view, KeyCombo("+")) { $0.zoom(by: 1.1) },
        Command("view.zoomOut", "Zoom Out", .view, KeyCombo("-")) { $0.zoom(by: 1 / 1.1) },
        Command("view.actualSize", "Actual Size", .view, KeyCombo("0")) { $0.resetZoom() },
        Command("view.inspector", "Web Inspector", .view, KeyCombo("i", option: true)) { $0.toggleInspector() },
        Command("view.console", "JavaScript Console", .view, KeyCombo("j", option: true)) { $0.showConsole() },
        Command("view.inspect", "Inspect Element", .view, KeyCombo("c", option: true)) { $0.inspectElement() },

        Command("tabs.back", "Back", .tabs, KeyCombo("[")) { $0.back() },
        Command("tabs.forward", "Forward", .tabs, KeyCombo("]")) { $0.forward() },
        Command("tabs.next", "Next Tab", .tabs, KeyCombo("]", shift: true)) { $0.step(1) },
        Command("tabs.previous", "Previous Tab", .tabs, KeyCombo("[", shift: true)) { $0.step(-1) },
        Command("tabs.search", "Search Tabs…", .tabs, KeyCombo("k")) { browser in
            if browser.editing, !browser.offers.isEmpty { browser.stepSummon() } else { browser.summon() }
        },
        Command("tabs.rename", "Rename Tab", .tabs, nil) { browser in
            if let tab = browser.active { browser.beginTabRename(tab) }
        },
        Command("tabs.duplicate", "Duplicate Tab", .tabs, KeyCombo("d")) { $0.duplicate() },
        Command("tabs.copyAddress", "Copy Address", .tabs, KeyCombo("c", shift: true)) { $0.copyAddress() },
        Command("tabs.pasteAndGo", "Paste and Go", .tabs, KeyCombo("v", shift: true)) { $0.pasteAndGo() },
        Command("tabs.closeOthers", "Close Other Tabs", .tabs, nil) { browser in
            if let tab = browser.active { browser.closeOthers(but: tab) }
        },
        Command("tabs.mute", "Stop Sound in Tab", .tabs, KeyCombo("m", shift: true)) { $0.pauseMedia() },

        Command("bookmarks.add", "Add This Page", .bookmarks, KeyCombo("b", shift: true)) { $0.bookmarkCurrent() },
        Command("bookmarks.show", "Show Bookmarks…", .bookmarks, nil) { $0.bookmarking = true },

        Command("history.show", "Show History…", .history, KeyCombo("y")) { $0.recalling.toggle() },
        Command("history.downloads", "Downloads…", .history, KeyCombo("j", shift: true)) { $0.hoarding.toggle() },
        Command("history.clear", "Clear History", .history, nil) { $0.clearHistory() },
    ]
}

/// What you've changed, on top of the defaults: a new key, or none.
@MainActor
final class ShortcutStore: ObservableObject {
    private struct Override: Codable, Equatable { var key: KeyCombo? }

    @Published private var changed: [String: Override]
    /// A key is being typed into Settings; the app's own keys stand aside.
    @Published var recording = false

    init() {
        changed = Store.settings.data(forKey: "shortcuts")
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }

    func key(for id: String) -> KeyCombo? {
        if let override = changed[id] { return override.key }
        return Command.named(id)?.defaultKey
    }

    func isChanged(_ id: String) -> Bool { changed[id] != nil }
    var anyChanged: Bool { !changed.isEmpty }

    /// A command you gave `combo`, for the key monitor to run.
    func changedCommand(on combo: KeyCombo) -> Command? {
        Command.all.first { changed[$0.id] != nil && key(for: $0.id) == combo }
    }

    /// A key the menus had that no command has now: the page's again.
    func isFreed(_ combo: KeyCombo) -> Bool {
        Command.all.contains { $0.defaultKey == combo && changed[$0.id] != nil }
            && !Command.all.contains { key(for: $0.id) == combo }
    }

    /// The command already on `combo`, other than `id`.
    func owner(of combo: KeyCombo, except id: String) -> Command? {
        Command.all.first { $0.id != id && key(for: $0.id) == combo }
    }

    /// `combo` for `id`, taken from whichever command had it.
    func assign(_ combo: KeyCombo, to id: String) {
        if let other = owner(of: combo, except: id) { set(nil, for: other.id) }
        set(combo, for: id)
    }

    func clear(_ id: String) { set(nil, for: id) }

    func reset(_ id: String) {
        changed[id] = nil
        save()
    }

    func resetAll() {
        changed = [:]
        save()
    }

    /// Only a difference from the default is kept.
    private func set(_ combo: KeyCombo?, for id: String) {
        changed[id] = combo == Command.named(id)?.defaultKey ? nil : Override(key: combo)
        save()
    }

    private func save() {
        if changed.isEmpty {
            Store.settings.removeObject(forKey: "shortcuts")
        } else {
            Store.settings.set(try? JSONEncoder().encode(changed), forKey: "shortcuts")
        }
    }
}

extension View {
    /// The command's key as it stands, or none (see ShortcutStore).
    func shortcut(_ id: String, _ store: ShortcutStore) -> some View {
        keyboardShortcut(store.key(for: id)?.swiftUI)
    }
}
