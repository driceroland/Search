import AppKit
import Combine

// Settings › Shortcuts, customisable as in Chrome DevTools: each action
// DevTools' key routing answers (DeveloperToolsKeyRouting) can be given
// other keys, or follow a preset ("Match shortcuts from preset"). The keys
// a user gives an action are translated back to the action's own default
// key before routing, so every condition the routing has (paused, which
// panel, what is focused) still holds; a default key the user took from
// its action no longer runs it.

/// A key with its modifiers, as Settings › Shortcuts records it.
struct DeveloperShortcut: Codable, Hashable {
    /// A named key ("Esc", "F8", "PageDown") or the character typed with
    /// modifiers ignored, lowercased.
    var key: String
    /// NSEvent.ModifierFlags' raw value: ⌘ ⇧ ⌥ ⌃ only.
    var modifiers: UInt

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        self.key = key
        modifiers = flags.intersection(Self.relevant).rawValue
    }

    /// A key event's shortcut; `key` is the character typed with modifiers ignored.
    init(keyCode: UInt16, key: String, flags: NSEvent.ModifierFlags) {
        self.init(Self.namedKeys[keyCode] ?? key.lowercased(), flags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    /// Keys known by their key code rather than the character they type.
    static let namedKeys: [UInt16: String] = [
        53: "Esc", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 116: "PageUp", 121: "PageDown", 115: "Home", 119: "End",
        126: "Up", 125: "Down", 123: "Left", 124: "Right", 36: "Return", 76: "Enter", 48: "Tab",
        51: "Delete", 117: "ForwardDelete", 49: "Space",
    ]

    /// The key codes DevTools' routing reads for these characters.
    private static let characterKeyCodes: [String: UInt16] = [
        "`": 50, "[": 33, "]": 30, "{": 33, "}": 30, "/": 44, "?": 44,
    ]

    var isFunctionKey: Bool {
        key.count >= 2 && key.hasPrefix("F") && Int(key.dropFirst()) != nil
    }

    /// Whether the key may be recorded: a function key alone, anything else
    /// only with ⌘, ⌃ or ⌥, so typing in a field never runs a shortcut.
    var canBeRecorded: Bool {
        !key.isEmpty && (isFunctionKey || !flags.isDisjoint(with: [.command, .control, .option]))
    }

    /// What DevTools' routing is given for this shortcut.
    var routingInput: (keyCode: UInt16, key: String, flags: NSEvent.ModifierFlags) {
        if let code = Self.namedKeys.first(where: { $0.value == key })?.key { return (code, "", flags) }
        return (Self.characterKeyCodes[key] ?? UInt16.max, key, flags)
    }

    private static let keySymbols: [String: String] = [
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Return": "↩", "Enter": "⌤", "Tab": "⇥",
        "Delete": "⌫", "ForwardDelete": "⌦", "PageUp": "Page Up", "PageDown": "Page Down", "-": "−",
    ]

    /// As the Mac writes it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        if let symbol = Self.keySymbols[key] { return text + symbol }
        return text + (key.count == 1 ? key.uppercased() : key)
    }
}

private extension DeveloperShortcut {
    static func command(_ key: String) -> DeveloperShortcut { DeveloperShortcut(key, .command) }
    static func shiftCommand(_ key: String) -> DeveloperShortcut { DeveloperShortcut(key, [.command, .shift]) }
    static func optionCommand(_ key: String) -> DeveloperShortcut { DeveloperShortcut(key, [.command, .option]) }
    static func control(_ key: String) -> DeveloperShortcut { DeveloperShortcut(key, .control) }
    static func plain(_ key: String) -> DeveloperShortcut { DeveloperShortcut(key) }
}

/// The DevTools actions Settings › Shortcuts lets the user give other keys.
enum DeveloperShortcutAction: String, CaseIterable, Codable, Identifiable {
    case commandMenu, openFile, goToSymbol, settings, toggleDrawer, previousPanel, nextPanel
    case toggleDockSide, toggleDeviceToolbar, searchAllFiles, zoomIn, zoomOut, resetZoom, focusConsole
    case pauseResume, stepOver, stepInto, stepOut, step, nextCallFrame, previousCallFrame, toggleBreakpoints
    case goToLine, saveAll, nextTab, previousTab, toggleNavigator, toggleDebuggerSidebar
    case expandSearchResults, collapseSearchResults
    case clearConsole, searchConsole
    case recordNetwork, searchNetwork
    case recordPerformance, recordReload, saveProfile, loadProfile, searchPerformance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandMenu: "Show command menu"
        case .openFile: "Open file"
        case .goToSymbol: "Go to symbol"
        case .settings: "Show Settings"
        case .toggleDrawer: "Toggle drawer"
        case .previousPanel: "Previous panel"
        case .nextPanel: "Next panel"
        case .toggleDockSide: "Toggle dock side"
        case .toggleDeviceToolbar: "Toggle device toolbar"
        case .searchAllFiles: "Search in all files"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .resetZoom: "Reset zoom level"
        case .focusConsole: "Focus Console"
        case .pauseResume: "Pause or resume script execution"
        case .stepOver: "Step over next function call"
        case .stepInto: "Step into next function call"
        case .stepOut: "Step out of current function"
        case .step: "Step"
        case .nextCallFrame: "Select next call frame"
        case .previousCallFrame: "Select previous call frame"
        case .toggleBreakpoints: "Activate or deactivate breakpoints"
        case .goToLine: "Go to line"
        case .saveAll: "Save all"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .toggleNavigator: "Toggle navigator"
        case .toggleDebuggerSidebar: "Toggle debugger sidebar"
        case .expandSearchResults: "Expand all search results"
        case .collapseSearchResults: "Collapse all search results"
        case .clearConsole: "Clear console"
        case .searchConsole: "Search messages"
        case .recordNetwork: "Start or stop recording network log"
        case .searchNetwork: "Search network log"
        case .recordPerformance: "Start or stop recording performance"
        case .recordReload: "Start profiling and reload page"
        case .saveProfile: "Save profile"
        case .loadProfile: "Load profile"
        case .searchPerformance: "Search the timeline"
        }
    }

    /// The panel the action belongs to; nil for every panel.
    var panel: DeveloperPanel? {
        switch self {
        case .goToLine, .saveAll, .nextTab, .previousTab, .toggleNavigator, .toggleDebuggerSidebar: .sources
        case .clearConsole, .searchConsole: .console
        case .recordNetwork, .searchNetwork: .network
        case .recordPerformance, .recordReload, .saveProfile, .loadProfile, .searchPerformance: .performance
        default: nil
        }
    }

    func applies(in panel: DeveloperPanel?) -> Bool { self.panel == nil || self.panel == panel }

    /// Whether the two can be pressed in the same panel.
    func overlaps(_ other: DeveloperShortcutAction) -> Bool {
        panel == nil || other.panel == nil || panel == other.panel
    }

    /// DevTools' own keys for it, as DeveloperToolsKeyRouting has them; the
    /// first is what a user's key is translated to.
    var defaults: [DeveloperShortcut] {
        switch self {
        case .commandMenu: [DeveloperShortcut("p", [.command, .option, .shift])]
        case .openFile: [.optionCommand("o")]
        case .goToSymbol: [.shiftCommand("o")]
        case .settings: [.plain("F1"), .plain("?")]
        case .toggleDrawer: [.plain("Esc")]
        case .previousPanel: [DeveloperShortcut("[", [.command, .control])]
        case .nextPanel: [DeveloperShortcut("]", [.command, .control])]
        case .toggleDockSide: [DeveloperShortcut("d", [.command, .control, .shift])]
        case .toggleDeviceToolbar: [DeveloperShortcut("m", [.command, .control, .shift])]
        case .searchAllFiles: [.optionCommand("f"), .shiftCommand("f")]
        case .zoomIn: [.command("+")]
        case .zoomOut: [.command("-")]
        case .resetZoom: [.command("0")]
        case .focusConsole: [.control("`")]
        case .pauseResume: [.plain("F8"), .command("\\")]
        case .stepOver: [.plain("F10"), .command("'")]
        case .stepInto: [.plain("F11"), .command(";")]
        case .stepOut: [DeveloperShortcut("F11", .shift), .shiftCommand(";")]
        case .step: [.plain("F9")]
        case .nextCallFrame: [.control(".")]
        case .previousCallFrame: [.control(",")]
        case .toggleBreakpoints: [.command("F8")]
        case .goToLine: [.control("g")]
        case .saveAll: [.optionCommand("s")]
        case .nextTab: [.command("PageDown")]
        case .previousTab: [.command("PageUp")]
        case .toggleNavigator: [.shiftCommand("y")]
        case .toggleDebuggerSidebar: [DeveloperShortcut("h", [.command, .option, .shift])]
        case .expandSearchResults: [DeveloperShortcut("}", [.command, .option, .shift])]
        case .collapseSearchResults: [DeveloperShortcut("{", [.command, .option, .shift])]
        case .clearConsole: [.control("l"), DeveloperShortcut("l", .option)]
        case .searchConsole: [.command("f")]
        case .recordNetwork: [.command("e")]
        case .searchNetwork: [.command("f")]
        case .recordPerformance: [.command("e")]
        case .recordReload: [.shiftCommand("e")]
        case .saveProfile: [.optionCommand("s")]
        case .loadProfile: [DeveloperShortcut("o", [.command, .control])]
        case .searchPerformance: [.command("f")]
        }
    }

    /// The action DevTools' routing answered with, if it is one of these.
    init?(_ action: DeveloperToolsKeyAction) {
        switch action {
        case .commandMenu(let prefix):
            switch prefix {
            case ">": self = .commandMenu
            case "": self = .openFile
            case "@": self = .goToSymbol
            case ":": self = .goToLine
            default: return nil
            }
        case .stepPanel(let offset): self = offset < 0 ? .previousPanel : .nextPanel
        case .toggleDrawer: self = .toggleDrawer
        case .toggleDockSide: self = .toggleDockSide
        case .toggleDeviceToolbar: self = .toggleDeviceToolbar
        case .zoom(let step): self = step > 0 ? .zoomIn : step < 0 ? .zoomOut : .resetZoom
        case .settings: self = .settings
        case .debugger(let command):
            switch command {
            case "pause", "resume": self = .pauseResume
            case "stepOver": self = .stepOver
            case "stepInto": self = .stepInto
            case "stepOut": self = .stepOut
            case "stepNext": self = .step
            default: return nil
            }
        case .toggleBreakpoints: self = .toggleBreakpoints
        case .focusConsole: self = .focusConsole
        case .clearConsole: self = .clearConsole
        case .findInConsole: self = .searchConsole
        case .findInNetwork: self = .searchNetwork
        case .findInPerformance: self = .searchPerformance
        case .recordNetwork: self = .recordNetwork
        case .recordPerformance(let reload): self = reload ? .recordReload : .recordPerformance
        case .performanceProfile(let save): self = save ? .saveProfile : .loadProfile
        case .callFrame(let offset): self = offset > 0 ? .nextCallFrame : .previousCallFrame
        case .toggleNavigator: self = .toggleNavigator
        case .toggleDebuggerSidebar: self = .toggleDebuggerSidebar
        case .saveAll: self = .saveAll
        case .sourceTab(let offset): self = offset > 0 ? .nextTab : .previousTab
        case .searchResults(let expanded): self = expanded ? .expandSearchResults : .collapseSearchResults
        case .searchAllFiles: self = .searchAllFiles
        case .commandMenuMove, .commandMenuRun, .commandMenuClose, .selectPanel, .closeDetails: return nil
        }
    }
}

/// Settings › Shortcuts › Match shortcuts from preset.
enum DeveloperShortcutPreset: String, CaseIterable, Codable, Identifiable {
    case devTools
    case visualStudioCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devTools: "DevTools (default)"
        case .visualStudioCode: "Visual Studio Code"
        }
    }

    /// Visual Studio Code's keys where they differ from DevTools'.
    private static let visualStudioCodeKeys: [DeveloperShortcutAction: [DeveloperShortcut]] = [
        .commandMenu: [.shiftCommand("p"), .plain("F1")],
        .settings: [.command(",")],
        .searchAllFiles: [.shiftCommand("f")],
        .pauseResume: [.plain("F5"), .command("\\")],
        .stepOver: [.plain("F10"), .command("'")],
        .stepInto: [.plain("F11"), .command(";")],
        .stepOut: [DeveloperShortcut("F11", .shift), .shiftCommand(";")],
    ]

    func shortcuts(for action: DeveloperShortcutAction) -> [DeveloperShortcut] {
        switch self {
        case .devTools: action.defaults
        case .visualStudioCode: Self.visualStudioCodeKeys[action] ?? action.defaults
        }
    }
}

/// The user's shortcuts: a preset, and the actions given keys of their own.
struct DeveloperShortcutBindings: Codable, Equatable {
    var preset = DeveloperShortcutPreset.devTools
    /// The user's own keys, by action (its raw value).
    var overrides: [String: [DeveloperShortcut]] = [:]

    /// The keys that run the action now.
    func shortcuts(for action: DeveloperShortcutAction) -> [DeveloperShortcut] {
        overrides[action.rawValue] ?? preset.shortcuts(for: action)
    }

    /// Given keys of the user's own (Reset to default takes them back to the preset's).
    func isOverridden(_ action: DeveloperShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    /// Its keys aren't DevTools' own, so the routing needs them translated.
    func isCustomised(_ action: DeveloperShortcutAction) -> Bool { shortcuts(for: action) != action.defaults }

    mutating func set(_ shortcuts: [DeveloperShortcut], for action: DeveloperShortcutAction) {
        overrides[action.rawValue] = shortcuts == preset.shortcuts(for: action) ? nil : shortcuts
    }

    mutating func reset(_ action: DeveloperShortcutAction) { overrides[action.rawValue] = nil }

    /// Match shortcuts from preset: the preset's keys, the user's own dropped.
    mutating func apply(_ preset: DeveloperShortcutPreset) {
        self.preset = preset
        overrides = [:]
    }

    /// The customised action the key now runs in this panel; one of the
    /// panel's own before one of every panel's.
    func customAction(for pressed: DeveloperShortcut, panel: DeveloperPanel?) -> DeveloperShortcutAction? {
        let found = DeveloperShortcutAction.allCases.filter {
            $0.applies(in: panel) && isCustomised($0) && shortcuts(for: $0).contains(pressed)
        }
        return found.first { $0.panel != nil } ?? found.first
    }

    /// Other actions that a key would also run where this one runs.
    func conflicts(_ shortcut: DeveloperShortcut, for action: DeveloperShortcutAction) -> [DeveloperShortcutAction] {
        DeveloperShortcutAction.allCases.filter {
            $0 != action && $0.overlaps(action) && shortcuts(for: $0).contains(shortcut)
        }
    }

    /// The actions sharing a key with this one, for its warning.
    func conflicts(for action: DeveloperShortcutAction) -> [DeveloperShortcutAction] {
        var found: [DeveloperShortcutAction] = []
        for shortcut in shortcuts(for: action) {
            for other in conflicts(shortcut, for: action) where !found.contains(other) { found.append(other) }
        }
        return found
    }
}

/// The user's shortcuts, kept in UserDefaults as JSON.
@MainActor
final class DeveloperShortcutStore: ObservableObject {
    static let shared = DeveloperShortcutStore()
    static let key = "DeveloperToolsShortcutBindings"
    private let defaults: UserDefaults

    @Published private(set) var bindings: DeveloperShortcutBindings

    init(defaults: UserDefaults = DevDefaults.store) {
        self.defaults = defaults
        bindings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(DeveloperShortcutBindings.self, from: $0) } ?? DeveloperShortcutBindings()
    }

    func set(_ shortcuts: [DeveloperShortcut], for action: DeveloperShortcutAction) {
        bindings.set(shortcuts, for: action)
        persist()
    }

    func reset(_ action: DeveloperShortcutAction) {
        bindings.reset(action)
        persist()
    }

    func apply(_ preset: DeveloperShortcutPreset) {
        bindings.apply(preset)
        persist()
    }

    private func persist() {
        if bindings == DeveloperShortcutBindings() {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Settings › Shortcuts' key capture: the next key pressed becomes the
/// action's shortcut; Esc stops without changing it.
@MainActor
final class DeveloperShortcutRecorder: ObservableObject {
    @Published private(set) var action: DeveloperShortcutAction? {
        didSet { Self.recording = action != nil }
    }
    /// A key is being recorded somewhere: Esc is the recorder's.
    private(set) static var recording = false
    private var monitor: Any?

    func toggle(_ action: DeveloperShortcutAction, store: DeveloperShortcutStore) {
        if self.action == action {
            stop()
            return
        }
        stop()
        self.action = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak store] event in
            let keyCode = event.keyCode
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let flags = event.modifierFlags.intersection(DeveloperShortcut.relevant)
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, let store else { return false }
                return self.record(keyCode: keyCode, key: key, flags: flags, store: store)
            }
            return taken ? nil : event
        }
    }

    /// The key pressed while recording; true when it was taken.
    private func record(keyCode: UInt16, key: String, flags: NSEvent.ModifierFlags, store: DeveloperShortcutStore) -> Bool {
        guard let action else { return false }
        if keyCode == 53, flags.isEmpty {
            stop()
            return true
        }
        let shortcut = DeveloperShortcut(keyCode: keyCode, key: key, flags: flags)
        guard shortcut.canBeRecorded else {
            NSSound.beep()
            return true
        }
        store.set([shortcut], for: action)
        stop()
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if action != nil { action = nil }
    }
}

extension DeveloperToolsKeyRouting {
    /// The action for a key with the user's shortcuts (Settings › Shortcuts)
    /// applied: a key the user gave an action runs it, as its own default
    /// key would; a default key the user took from its action runs nothing.
    static func action(keyCode: UInt16, key: String, flags: NSEvent.ModifierFlags, state: DeveloperToolsKeyState,
                       shortcuts: DeveloperShortcutBindings) -> DeveloperToolsKeyAction? {
        let flags = flags.intersection(DeveloperShortcut.relevant)
        let routed = action(keyCode: keyCode, key: key, flags: flags, state: state)
        // The open command menu's own keys come first.
        if let routed {
            switch routed {
            case .commandMenuMove, .commandMenuRun, .commandMenuClose: return routed
            default: break
            }
        }
        let pressed = DeveloperShortcut(keyCode: keyCode, key: key, flags: flags)
        if pressed.canBeRecorded, let custom = shortcuts.customAction(for: pressed, panel: state.panel),
           let original = custom.defaults.first {
            let input = original.routingInput
            return action(keyCode: input.keyCode, key: input.key, flags: input.flags, state: state)
        }
        guard let found = routed else { return nil }
        if let original = DeveloperShortcutAction(found), shortcuts.isCustomised(original),
           !shortcuts.shortcuts(for: original).contains(pressed) {
            return nil
        }
        return found
    }
}
