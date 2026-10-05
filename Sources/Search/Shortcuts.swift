import AppKit
import SwiftUI
import WebKit

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
        51: "delete", 117: "delete", 49: "space", 48: "tab", 53: "escape",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "delete": "⌫", "space": "Space",
        "tab": "⇥", "escape": "⎋",
    ]

    /// As a menu shows it: ⌃⌥⇧⌘ then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (key == "space" ? L("Space") : (KeyCombo.symbols[key] ?? key.uppercased()))
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
    /// keeps for itself: ⌘1–⌘9 for tabs, ⌃1–⌃9 for spaces, Tab and Escape
    /// with anything. Not ours to give, and so never taken from the Mac.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        let system: Set<KeyCombo> = [
            KeyCombo("q"), KeyCombo("q", option: true), KeyCombo("q", control: true),
            KeyCombo("q", shift: true), KeyCombo("q", shift: true, option: true),
            KeyCombo("h"), KeyCombo("h", option: true), KeyCombo("m"), KeyCombo("m", option: true),
            KeyCombo("c"), KeyCombo("v"), KeyCombo("x"), KeyCombo("a"), KeyCombo("z"), KeyCombo("z", shift: true),
            KeyCombo("`"), KeyCombo("`", shift: true), KeyCombo("f", control: true),
            KeyCombo("space"), KeyCombo("space", command: false, control: true),
            KeyCombo("space", option: true), KeyCombo("space", command: false, option: true, control: true),
        ]
        if system.contains(combo) || combo.key == "tab" || combo.key == "escape" { return true }
        let digit = combo.key.count == 1 && ("1"..."9").contains(combo.key)
        return digit && !combo.option && !combo.shift && (combo.command != combo.control)
    }

    /// Keys an extension never has, wherever Search's own commands are:
    /// closing, and opening a tab or a window, as Chrome keeps them. Yours
    /// to move among Search's commands, not to give to an extension.
    static func isBrowserOnly(_ combo: KeyCombo) -> Bool {
        [KeyCombo("w"), KeyCombo("w", shift: true), KeyCombo("w", option: true),
         KeyCombo("t"), KeyCombo("t", shift: true), KeyCombo("n"), KeyCombo("n", shift: true)].contains(combo)
    }
}

/// A menu command, and the key it has unless you give it another.
struct Command: Identifiable {
    enum Section: String, CaseIterable {
        case app = "Search", file = "File", edit = "Edit", view = "View", tabs = "Tabs", bookmarks = "Bookmarks", history = "History"
        var title: String { Localization.text(rawValue) }
    }

    let id: String
    private let titleKey: LocalizedPhrase
    var title: String { L(titleKey) }
    let section: Section
    let defaultKey: KeyCombo?
    let run: @MainActor (Browser) -> Void

    init(_ id: String, _ title: LocalizedPhrase, _ section: Section, _ key: KeyCombo?, _ run: @escaping @MainActor (Browser) -> Void) {
        self.id = id
        self.titleKey = title
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

        Command("file.newWindow", "New Window", .file, KeyCombo("n")) { _ in Browsers.newWindow() },
        Command("file.newTab", "New Tab", .file, KeyCombo("t")) { $0.newTab() },
        Command("file.newPrivateTab", "New Private Tab", .file, KeyCombo("n", shift: true)) { $0.newShyTab() },
        Command("file.reopen", "Reopen Closed Tab", .file, KeyCombo("t", shift: true)) { $0.reopen() },
        Command("file.openAddress", "Open Address…", .file, KeyCombo("l")) { $0.edit() },
        Command("file.closeTab", "Close Tab", .file, KeyCombo("w")) { $0.closeFront() },
        Command("file.import", "Bring Things Over…", .file, nil) { $0.bringingIn = "" },
        Command("file.share", "Share…", .file, nil) { $0.share() },
        Command("file.print", "Print…", .file, KeyCombo("p")) { $0.printPage() },

        Command("edit.find", "Find on Page…", .edit, KeyCombo("f")) { $0.openFind() },
        Command("edit.findNext", "Find Next", .edit, KeyCombo("g")) { $0.look(forward: true) },
        Command("edit.findPrevious", "Find Previous", .edit, KeyCombo("g", shift: true)) { $0.look(forward: false) },

        Command("view.sidebar", "Show Tabs in Sidebar", .view, KeyCombo("s", shift: true)) { $0.toggleSidebar() },
        Command("view.fold", "Hide Sidebar or Tab Bar", .view, KeyCombo("s")) { $0.toggleFold() },
        Command("view.reload", "Reload Page", .view, KeyCombo("r")) { $0.reload() },
        Command("view.reloadOrigin", "Reload Page From Origin", .view, KeyCombo("r", option: true)) { $0.reload(fromOrigin: true) },
        Command("view.reader", "Reading Mode", .view, KeyCombo("r", shift: true)) { $0.toggleReader() },
        Command("view.float", "Float Video", .view, KeyCombo("p", shift: true)) { $0.toggleFloat() },
        Command("view.summarize", "Summarize Page", .view, nil) { $0.summarizePage() },
        Command("view.ask", "Ask About This Page…", .view, nil) { $0.askAboutPage() },
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
        // ⌥⌘N, Chrome's on the Mac: ⌃⌘S is the Mac's own Show Sidebar, and
        // sits beside ⌘S, which folds the tabs away.
        Command("tabs.split", "Split Current Page", .tabs, KeyCombo("n", option: true)) { browser in
            guard browser.prefs.splitView else { return }
            browser.startSplit()
        },
        Command("tabs.focusLeftPane", "Focus Left Page", .tabs, KeyCombo("left", control: true)) { browser in
            guard browser.prefs.splitView else { return }
            browser.focusPane(onLeft: true)
        },
        Command("tabs.focusRightPane", "Focus Right Page", .tabs, KeyCombo("right", control: true)) { browser in
            guard browser.prefs.splitView else { return }
            browser.focusPane(onLeft: false)
        },
        Command("tabs.focusOtherPane", "Focus Other Page", .tabs, nil) { browser in
            guard browser.prefs.splitView else { return }
            browser.focusOtherPane()
        },
        Command("tabs.swapSplit", "Swap Pages", .tabs, nil) { browser in
            guard browser.prefs.splitView else { return }
            browser.swapSplit()
        },
        Command("tabs.separateSplit", "Separate Split Tabs", .tabs, nil) { browser in
            guard browser.prefs.splitView, let tab = browser.active else { return }
            browser.detachSplit(tab)
        },
        Command("tabs.rename", "Rename Tab", .tabs, nil) { browser in
            if let tab = browser.active { browser.beginTabRename(tab) }
        },
        Command("tabs.duplicate", "Duplicate Tab", .tabs, KeyCombo("d")) { $0.duplicate() },
        Command("tabs.copyAddress", "Copy Address", .tabs, KeyCombo("c", shift: true)) { $0.copyAddress() },
        Command("tabs.copyMarkdown", "Copy as Markdown Link", .tabs, nil) { $0.copyMarkdownLink() },
        Command("tabs.pasteAndGo", "Paste and Go", .tabs, KeyCombo("v", shift: true)) { $0.pasteAndGo() },
        Command("tabs.closeOthers", "Close Other Tabs", .tabs, nil) { browser in
            if let tab = browser.active { browser.closeOthers(but: tab) }
        },
        Command("tabs.mute", "Stop Sound in Tab", .tabs, KeyCombo("m", shift: true)) { $0.pauseMedia() },

        Command("bookmarks.add", "Add This Page", .bookmarks, KeyCombo("b", shift: true)) { $0.bookmarkCurrent() },
        Command("bookmarks.show", "Show Bookmarks…", .bookmarks, nil) { $0.bookmarking = true },
        Command("bookmarks.bar", "Show Bookmarks Bar", .bookmarks, nil) { browser in
            withAnimation(Motion.glide) { browser.prefs.bookmarksBar.toggle() }
        },

        Command("history.show", "Show History…", .history, KeyCombo("y")) { $0.recalling.toggle() },
        Command("history.downloads", "Downloads…", .history, KeyCombo("j", shift: true)) { $0.hoarding.toggle() },
        Command("history.clearData", "Clear Browsing Data…", .history, KeyCombo("delete", shift: true)) { $0.recallMode = .clearing },
        Command("history.clear", "Clear History", .history, nil) { $0.clearHistory() },
    ]
}

/// What you've changed, on top of the defaults: a new key, or none. One for
/// the app, whichever window the key is pressed in. Only Settings › Shortcuts
/// changes it: no page and no extension can.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    private struct Override: Codable, Equatable { var key: KeyCombo? }

    @Published private var changed: [String: Override]
    /// A key is being typed into Settings; the app's own keys stand aside.
    @Published var recording = false
    /// The key each extension command came with, as its extension loaded
    /// (see `adopt`), by its id here: "ext:" + extension + ":" + command.
    private var manifest: [String: Override] = [:]

    private init() {
        // Read with the same rules the Settings box keeps: a key that isn't
        // ours to give stays the Mac's, whatever the file says.
        let saved = Store.settings.data(forKey: "shortcuts")
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
        changed = saved.filter { id, override in
            override.key.map { !KeyCombo.isReserved($0) && !(id.hasPrefix("ext:") && KeyCombo.isBrowserOnly($0)) } ?? true
        }
    }

    func key(for id: String) -> KeyCombo? {
        if let override = changed[id] { return override.key }
        return defaultKey(for: id)
    }

    private func defaultKey(for id: String) -> KeyCombo? {
        guard id.hasPrefix("ext:") else { return Command.named(id)?.defaultKey }
        // What the manifest asked for, while no key of Search's is in the
        // way: checked each time, so moving or resetting one of Search's
        // commands frees or takes an extension's key at once.
        return manifest[id]?.key.flatMap { keepsFromExtensions($0) ? nil : $0 }
    }

    func isChanged(_ id: String) -> Bool { changed[id] != nil }
    var anyChanged: Bool { !changed.isEmpty }

    /// A command you gave `combo`, for the key monitor to run.
    func changedCommand(on combo: KeyCombo) -> Command? {
        Command.all.first { changed[$0.id] != nil && key(for: $0.id) == combo }
    }

    /// A key an extension may not have: one of the Mac's, or one of
    /// Search's commands has as things stand.
    func keepsFromExtensions(_ combo: KeyCombo) -> Bool {
        KeyCombo.isReserved(combo) || KeyCombo.isBrowserOnly(combo) || Command.all.contains { key(for: $0.id) == combo }
    }

    /// A key the menus had that no command has now: the page's again —
    /// unless you gave it to an extension's command.
    func isFreed(_ combo: KeyCombo) -> Bool {
        guard Command.all.contains(where: { $0.defaultKey == combo && changed[$0.id] != nil }),
              !Command.all.contains(where: { key(for: $0.id) == combo })
        else { return false }
        if #available(macOS 15.4, *), extensionCommands().contains(where: { key(for: $0.id) == combo }) { return false }
        return true
    }

    /// The command already on `combo`, other than `id`: one of Search's,
    /// or an extension's.
    func owner(of combo: KeyCombo, except id: String) -> (id: String, title: String)? {
        if let command = Command.all.first(where: { $0.id != id && key(for: $0.id) == combo }) {
            return (command.id, command.title)
        }
        if #available(macOS 15.4, *),
           let other = extensionCommands().first(where: { $0.id != id && key(for: $0.id) == combo }) {
            return (other.id, other.command.title)
        }
        return nil
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
        applyExtensions()
    }

    func resetAll() {
        changed = [:]
        save()
        applyExtensions()
    }

    /// Only a difference from the default is kept.
    private func set(_ combo: KeyCombo?, for id: String) {
        changed[id] = combo == defaultKey(for: id) ? nil : Override(key: combo)
        save()
        applyExtensions()
    }

    /// Every extension command's key as it now stands, handed to WebKit: a
    /// change to one of Search's can free or take an extension's.
    private func applyExtensions() {
        guard #available(macOS 15.4, *) else { return }
        for command in extensionCommands() { applied(command.id) }
    }

    /// An extension command's key, handed to WebKit, which matches it.
    private func applied(_ id: String) {
        guard id.hasPrefix("ext:"), #available(macOS 15.4, *),
              let command = extensionCommands().first(where: { $0.id == id })?.command else { return }
        let combo = key(for: id)
        command.activationKey = combo?.key
        command.modifierFlags = combo?.flags ?? []
    }

    private func save() {
        if changed.isEmpty {
            Store.settings.removeObject(forKey: "shortcuts")
        } else {
            Store.settings.set(try? JSONEncoder().encode(changed), forKey: "shortcuts")
        }
    }
}

// Extension commands, #189: the keys an extension's manifest asks for, set
// otherwise here as WebKit means them to be — it matches the key it is
// given, and the app keeps it. Only single keys, as a manifest has them.

@available(macOS 15.4, *)
extension ShortcutStore {
    struct ExtensionCommand {
        let id: String
        let extensionName: String
        let command: WKWebExtension.Command
    }

    /// The commands of every extension loaded, with a name to show.
    func extensionCommands() -> [ExtensionCommand] {
        let names = Dictionary(Extensions.shared.installed.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Extensions.shared.contexts.sorted { $0.key < $1.key }.flatMap { ext, context in
            context.commands.map {
                ExtensionCommand(id: "ext:\(ext):\($0.id)", extensionName: names[ext] ?? ext, command: $0)
            }
        }
    }

    /// An extension just loaded: the keys it came with noted, and yours
    /// put in their place. A key its manifest asks for that is the Mac's,
    /// or that one of Search's commands has, it doesn't get — as in Chrome,
    /// an extension never has a key the browser uses. Its command is left
    /// without one, for you to give it one in Settings if you like.
    func adopt(_ context: WKWebExtensionContext, id ext: String) {
        for command in context.commands {
            let id = "ext:\(ext):\(command.id)"
            // What WebKit holds is the manifest's on a fresh load, or an
            // update's; once applied here, it is ours, and not taken again.
            let current = KeyCombo(activation: command.activationKey, flags: command.modifierFlags)
            if manifest[id] == nil || current != key(for: id) { manifest[id] = Override(key: current) }
            applied(id)
        }
    }
}

extension KeyCombo {
    /// An extension command's key, as WebKit holds it.
    init?(activation key: String?, flags: NSEvent.ModifierFlags) {
        guard let key, !key.isEmpty else { return nil }
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }
}

extension View {
    /// The command's key as it stands, or none (see ShortcutStore).
    @MainActor
    func shortcut(_ id: String) -> some View {
        keyboardShortcut(ShortcutStore.shared.key(for: id)?.swiftUI)
    }
}

extension Command {
    /// Split View's commands: with it off, not listed, and their keys go on
    /// to the page.
    static let split: Set<String> = ["tabs.split", "tabs.focusLeftPane", "tabs.focusRightPane", "tabs.focusOtherPane",
                                     "tabs.swapSplit", "tabs.separateSplit"]
    /// The AI add-on's: with it off, not listed.
    static let ai: Set<String> = ["view.summarize", "view.ask"]
}
