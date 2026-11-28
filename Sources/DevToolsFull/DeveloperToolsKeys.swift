import AppKit
import Combine
import SwiftUI

/// What a key does with the keyboard in DevTools, decided apart from the
/// event so the tests can check it.
enum DeveloperToolsKeyAction: Equatable {
    /// Opens the command menu with this typed: ">" for commands (⇧⌘P),
    /// nothing for files (⌘P, ⌘O).
    case commandMenu(String)
    case commandMenuMove(Int)
    case commandMenuRun
    case commandMenuClose
    /// ⌘[ and ⌘]: the panel before or after.
    case stepPanel(Int)
    /// Esc: the drawer.
    case toggleDrawer
    /// ⇧⌘D: back to the dock side used before.
    case toggleDockSide
    /// ⇧⌘M: the device toolbar.
    case toggleDeviceToolbar
    /// ⌘+, ⌘−, ⌘0: DevTools' own zoom (0 resets).
    case zoom(Int)
    /// F1: DevTools Settings.
    case settings
    /// F8, ⌘\ and the stepping keys, by debugger command.
    case debugger(String)
    /// ⌘F8.
    case toggleBreakpoints
    /// ⌘1–⌘9, with Settings › Preferences › "Enable ⌘ + 1-9 shortcut to
    /// switch panels" on: the strip's panel at that place (0-based).
    case selectPanel(Int)
    /// ⌃`: the Console's prompt, from any panel.
    case focusConsole
    /// ⌘K, ⌃L and ⌥L in the Console.
    case clearConsole
    /// ⌘F in the Console: its search bar.
    case findInConsole
    /// ⌘F in the Network panel: its Search pane.
    case findInNetwork
    /// ⌘F in the Performance panel: the find bar over the flame chart.
    case findInPerformance
    /// Esc with a request's details open in the Network panel.
    case closeDetails
    /// ⌘E in the Network panel.
    case recordNetwork
    /// ⌘E and ⇧⌘E in the Performance panel.
    case recordPerformance(reload: Bool)
    /// ⌘S (save) and ⌘O (load) in the Performance panel: a profile file.
    case performanceProfile(save: Bool)
    /// ⌃. and ⌃, while paused: the call frame below or above.
    case callFrame(Int)
    /// ⇧⌘Y in Sources.
    case toggleNavigator
    /// ⇧⌘H in Sources.
    case toggleDebuggerSidebar
    /// ⌥⌘S in Sources: every Local Overrides file edited.
    case saveAll
    /// ⌘Page Down and ⌘Page Up (fn⌘↓, fn⌘↑) in Sources: the next or the
    /// previous open file.
    case sourceTab(Int)
    /// ⌥⇧⌘} and ⌥⇧⌘{ with search results shown: all open, or all closed.
    case searchResults(expanded: Bool)
    /// ⌥⌘F outside Sources: Search across all files, in the drawer.
    case searchAllFiles
}

/// Where the keyboard is inside DevTools, as far as keys care.
enum DeveloperToolsKeyFocus: Equatable {
    /// A list, a tab, the panel itself: nothing that takes typing.
    case panel
    /// A one-line field being edited (a filter, a rename, an attribute).
    case field
    /// A multi-line editor that answers Esc itself (the Console prompt).
    case editor
    /// The Sources code view, whose own keys (DeveloperSourceKeys) come first.
    case code
}

struct DeveloperToolsKeyState: Equatable {
    var focus = DeveloperToolsKeyFocus.panel
    var commandMenuOpen = false
    var paused = false
    /// The element picker is on: Esc is its, to stop picking.
    var picking = false
    /// The main panel in front; nil while an extension's panel is.
    var panel: DeveloperPanel? = nil
    /// Settings › Preferences › Enable ⌘ + 1-9 shortcut to switch panels.
    var numberKeysSwitchPanels = false
    /// A request's details are open in the Network panel.
    var detailsOpen = false
    /// Search across all files has results on screen.
    var searchResultsShown = false
}

/// As in Chrome DevTools' shortcuts (ShortcutRegistry, mac keymap): which
/// keys DevTools takes for itself while the keyboard is in it.
enum DeveloperToolsKeyRouting {
    static let escape: UInt16 = 53
    static let up: UInt16 = 126
    static let down: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let f1: UInt16 = 122
    static let f8: UInt16 = 100
    static let f9: UInt16 = 101
    static let f10: UInt16 = 109
    static let f11: UInt16 = 103
    static let f12: UInt16 = 111
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let grave: UInt16 = 50
    static let leftBracket: UInt16 = 33
    static let rightBracket: UInt16 = 30

    /// `key` is the character typed with modifiers ignored, lowercased.
    static func action(keyCode: UInt16, key: String, flags: NSEvent.ModifierFlags,
                       state: DeveloperToolsKeyState) -> DeveloperToolsKeyAction? {
        let flags = flags.intersection([.command, .shift, .option, .control])
        if state.commandMenuOpen, flags.isEmpty || flags == .shift {
            switch keyCode {
            case escape: return .commandMenuClose
            case up: return .commandMenuMove(-1)
            case down: return .commandMenuMove(1)
            case returnKey, enter: return .commandMenuRun
            default: break
            }
        }
        switch (flags, keyCode) {
        case ([], escape):
            guard !state.picking, !state.commandMenuOpen else { return nil }
            // A field or the prompt has its own use for Esc (cancel an
            // edit, close completions); only the panel and the code view
            // pass it on to the drawer, as Chrome's do. In the Network
            // panel it first puts away the request's details.
            guard state.focus == .panel || state.focus == .code else { return nil }
            return state.panel == .network && state.detailsOpen ? .closeDetails : .toggleDrawer
        case ([], f1): return .settings
        case ([.control], grave): return .focusConsole
        case ([.command], pageDown) where state.panel == .sources: return .sourceTab(1)
        case ([.command], pageUp) where state.panel == .sources: return .sourceTab(-1)
        case ([.command, .option, .shift], rightBracket) where state.searchResultsShown:
            return .searchResults(expanded: true)
        case ([.command, .option, .shift], leftBracket) where state.searchResultsShown:
            return .searchResults(expanded: false)
        case ([], f8): return .debugger(state.paused ? "resume" : "pause")
        case ([.command], f8): return .toggleBreakpoints
        case ([], f10): return state.paused ? .debugger("stepOver") : nil
        case ([], f11): return state.paused ? .debugger("stepInto") : nil
        case ([.shift], f11): return state.paused ? .debugger("stepOut") : nil
        case ([], f9): return state.paused ? .debugger("stepNext") : nil
        default: break
        }
        switch (flags, key) {
        case ([.command], "\\"): return .debugger(state.paused ? "resume" : "pause")
        // Chrome's keys, moved where Search has its own (Shortcuts.swift):
        // ⌥⇧⌘P for ⇧⌘P (Float Video), ⌥⌘O for ⌘P/⌘O (Print, Open File),
        // ⌃⌘O/⌥⌘S for Performance's ⌘O/⌘S (Hide Sidebar), ⌃⌘[ ⌃⌘] for
        // ⌘[ ⌘] (Back, Forward), ⌃⇧⌘D for ⇧⌘D (Darken This Site), ⌃⇧⌘M
        // for ⇧⌘M (Stop Sound), ⌥⇧⌘H for ⇧⌘H (Hide Elements); ⌘K (Search
        // Tabs) no longer clears the Console, ⌃L does.
        case ([.command, .option, .shift], "p"): return .commandMenu(">")
        case ([.command, .control], "o") where state.panel == .performance: return .performanceProfile(save: false)
        case ([.command, .option], "s") where state.panel == .performance: return .performanceProfile(save: true)
        case ([.command, .option], "o"):
            // The code view's own box comes first (DeveloperSourceKeys).
            return .commandMenu("")
        // Go to symbol and Go to line from anywhere, as in Chrome: they show
        // Sources (the code view's own boxes come first there).
        case ([.command, .shift], "o"): return .commandMenu("@")
        // Sources' own ⌥⌘F (its Search pane) comes first there.
        case ([.command, .option], "f"): return .searchAllFiles
        case ([.control], "g") where state.panel == .sources: return .commandMenu(":")
        case ([.command, .control], "["): return .stepPanel(-1)
        case ([.command, .control], "]"): return .stepPanel(1)
        case ([.command, .control, .shift], "d"): return .toggleDockSide
        case ([.command, .control, .shift], "m"): return .toggleDeviceToolbar
        case ([.command], "="), ([.command], "+"), ([.command, .shift], "="), ([.command, .shift], "+"): return .zoom(1)
        case ([.command], "-"): return .zoom(-1)
        case ([.command], "0"): return .zoom(0)
        case ([.command], "'"): return state.paused ? .debugger("stepOver") : nil
        case ([.command], ";"): return state.paused ? .debugger("stepInto") : nil
        case ([.command, .shift], ";"), ([.command, .shift], ":"): return state.paused ? .debugger("stepOut") : nil
        case ([.control], "."): return state.paused ? .callFrame(1) : nil
        case ([.control], ","): return state.paused ? .callFrame(-1) : nil
        // "?" (⇧/ on most keyboards) with nothing taking typing: Settings.
        case ([], "?"), ([.shift], "?"), ([.shift], "/"):
            return state.focus == .panel && (key == "?" || keyCode == 44) ? .settings : nil
        default: break
        }
        if flags == .command, let digit = Int(key), (1...9).contains(digit), state.numberKeysSwitchPanels {
            return .selectPanel(digit - 1)
        }
        return panelAction(key: key, flags: flags, state: state)
    }

    /// The keys one panel gives a meaning of its own.
    private static func panelAction(key: String, flags: NSEvent.ModifierFlags,
                                    state: DeveloperToolsKeyState) -> DeveloperToolsKeyAction? {
        switch state.panel {
        case .console:
            switch (flags, key) {
            // In a one-line field (the filter) these are typing.
            case ([.control], "l"), ([.option], "l"), ([.option], "¬"):
                return state.focus == .field ? nil : .clearConsole
            case ([.command], "f"): return .findInConsole
            default: return nil
            }
        case .network:
            switch (flags, key) {
            case ([.command], "e"): return .recordNetwork
            case ([.command], "f"): return .findInNetwork
            default: return nil
            }
        case .performance:
            switch (flags, key) {
            case ([.command], "e"): return .recordPerformance(reload: false)
            case ([.command, .shift], "e"): return .recordPerformance(reload: true)
            case ([.command], "f"): return .findInPerformance
            default: return nil
            }
        case .sources:
            switch (flags, key) {
            case ([.command, .shift], "y"): return .toggleNavigator
            case ([.command, .option, .shift], "h"): return .toggleDebuggerSidebar
            case ([.command, .option], "s"), ([.command, .option], "ß"): return .saveAll
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Browser keys that mean something else in Chrome DevTools — Find,
    /// Print, Save Page, Open File, Use Selection for Find — kept from the
    /// browser while the keyboard is in DevTools, even in a panel that has
    /// no use for them, so ⌘F never searches the page behind DevTools.
    static func keepsFromBrowser(key: String, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection([.command, .shift, .option, .control])
        switch (flags, key) {
        case ([.command], "f"), ([.command], "g"), ([.command, .shift], "g"), ([.command], "e"),
             ([.command, .shift], "o"), ([.command], "/"), ([.command], "u"):
            return true
        default:
            return false
        }
    }
}

/// The keys DevTools answers while the keyboard is in it — ⇧⌘P, ⌘P, ⌘[,
/// ⌘], Esc, ⇧⌘D, ⇧⌘M, ⌘+ and the rest — taken before the window's
/// shortcuts and the menus, which would otherwise print the page, go back
/// or zoom the page instead. As DeveloperSourceKeys does for the code view,
/// a key monitor finds DevTools by walking up from the first responder to
/// the view that hosts it (DeveloperToolsHostView).
enum DeveloperToolsKeys {
    nonisolated(unsafe) private static var monitor: Any?

    /// One monitor for all of DevTools' keys, so their order is this
    /// file's to say: AppKit asks local monitors newest first, so separate
    /// monitors would hear a key in the reverse of the order they were
    /// made, and the browser window's own monitor — made after these, as
    /// each window opens — would hear it before any of them. The window's
    /// monitor therefore asks `takeFirst` before its own shortcuts
    /// (ContentView.watchKeys); this monitor covers windows without one.
    /// Only while a session is open: closed, no monitor and no cost.
    @MainActor static func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    @MainActor static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { takeFirst(event) } ? nil : event
        }
    }

    /// Whether DevTools took the event: the code view's keys first
    /// (DeveloperSourceKeys: its ⌘P box, Esc for its find bar), then the
    /// Elements panel's (DeveloperElementsKeys), then DevTools' own.
    @MainActor static func takeFirst(_ event: NSEvent) -> Bool {
        // A sheet up (DeveloperSheets) has the keyboard: Esc closes it,
        // unless a shortcut is being recorded, and DevTools' own keys wait.
        if DeveloperSheets.shared.front != nil {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == DeveloperToolsKeyRouting.escape, flags.isEmpty, !DeveloperShortcutRecorder.recording {
                DeveloperSheets.shared.closeFront()
                return true
            }
            return false
        }
        if event.type == .keyDown, DeveloperSourceKeys.take(event) { return true }
        if event.type == .keyDown || event.type == .leftMouseDown, DeveloperElementsKeys.take(event) { return true }
        return take(event)
    }

    @MainActor static func take(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            // With DevTools closed there is no host to focus: no hit test
            // on every click in the browser.
            if DeveloperTools.shared.session != nil { focus(on: event) }
            return false
        }
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // F12 opens and closes DevTools from anywhere in the window, as in Chrome.
        if event.keyCode == DeveloperToolsKeyRouting.f12, flags.isEmpty {
            return toggleWithF12(event)
        }
        // The keyboard on DevTools' own window itself (nothing in it
        // focused) is still in DevTools.
        guard let host = host(of: event.window?.firstResponder)
            ?? (event.window?.firstResponder === event.window ? DeveloperToolsWindow.shared.host(in: event.window) : nil),
            let context = host.context else { return false }
        let session = context.session
        let shell = DeveloperToolsShell.shared
        let panel: DeveloperPanel? = session.extensionPanels.selection == nil ? session.panel : nil
        let search = DeveloperSourcesSearchModel.of(session)
        let state = DeveloperToolsKeyState(
            focus: focus(of: event.window?.firstResponder),
            commandMenuOpen: shell.commandMenu != nil,
            paused: session.debugger.pause != nil,
            picking: session.picking,
            panel: panel,
            numberKeysSwitchPanels: shell.numberKeysSwitchPanels,
            detailsOpen: panel == .network && DeveloperPanelKeys.network?.detailsOpen() == true,
            searchResultsShown: !search.results.isEmpty
                && (DeveloperSourceTabs.of(session).searchShown
                    || (shell.drawerOpen && shell.drawerSelection == .tool(.search))))
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // With the user's keys from Settings › Shortcuts (DeveloperShortcutBindings).
        if let action = DeveloperToolsKeyRouting.action(keyCode: event.keyCode, key: key, flags: flags, state: state,
                                                        shortcuts: DeveloperShortcutStore.shared.bindings) {
            if event.isARepeat, !action.repeats { return true }
            context.perform(action)
            return true
        }
        // A ⌘ or ⌃ key DevTools' routing has no use for: the panel's own
        // keyboard shortcuts (SwiftUI's, the Console prompt's ⌘K) get it
        // before the browser's, which would print or find on the page.
        // Not the editing keys, which are the menus' and the text's.
        if !flags.isDisjoint(with: [.command, .control]), !Self.editingKey(key, flags: flags),
           host.performKeyEquivalent(with: event) {
            return true
        }
        return DeveloperToolsKeyRouting.keepsFromBrowser(key: key, flags: flags)
    }

    /// ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z and ⇧⌘Z: Edit menu keys, left to the responder.
    private static func editingKey(_ key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags == .command || flags == [.command, .shift] else { return false }
        return ["a", "c", "v", "x", "z"].contains(key)
    }

    /// The DevTools host the responder is in, if any.
    @MainActor static func host(of responder: NSResponder?) -> DeveloperToolsHostView? {
        var view = responder as? NSView
        while let current = view {
            if let host = current as? DeveloperToolsHostView { return host }
            view = current.superview
        }
        return nil
    }

    @MainActor private static func focus(of responder: NSResponder?) -> DeveloperToolsKeyFocus {
        guard let text = responder as? NSTextView else { return .panel }
        if text is SourceTextView { return .code }
        if text.isFieldEditor { return .field }
        return text.isEditable ? .editor : .panel
    }

    /// A click in DevTools puts the keyboard there, as in Chrome, even on
    /// a part that takes no typing: the panel's keys are then DevTools'
    /// rather than the page's.
    @MainActor private static func focus(on event: NSEvent) {
        guard let window = event.window, let content = window.contentView else { return }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return }
        guard let clicked = host(of: hit), host(of: window.firstResponder) !== clicked else { return }
        if let panel = clicked.context?.session.extensionPanels.selection?.view, hit.isDescendant(of: panel) { return }
        window.makeFirstResponder(clicked)
    }

    /// F12 in DevTools closes it; on the page, FullPlugin.keyDown opens it.
    @MainActor private static func toggleWithF12(_ event: NSEvent) -> Bool {
        guard let host = host(of: event.window?.firstResponder) ?? DeveloperToolsWindow.shared.host(in: event.window),
              host.context != nil else { return false }
        DeveloperTools.shared.close()
        return true
    }
}

private extension DeveloperToolsKeyAction {
    /// Held down, only these go on repeating.
    var repeats: Bool {
        switch self {
        case .commandMenuMove, .stepPanel, .zoom, .debugger, .callFrame, .sourceTab: true
        default: false
        }
    }
}

/// What DevTools' keys and command menu act on: the session, the shell,
/// and the tab's device toolbar.
@MainActor
struct DeveloperToolsContext {
    let session: DeveloperToolsSession
    let tools: DeveloperTools
    let shell: DeveloperToolsShell

    /// The tab's device toolbar (Shared/DeviceToolbar.swift), as Lite has it.
    var viewportEnabled: Bool { session.web.flatMap { FullPlugin.current?.sharedSession($0, making: false) }?.device.on ?? false }
    func toggleViewport() { if let web = session.web { FullPlugin.current?.open("device", webView: web) } }

    /// The panels ⌘[ and ⌘] step through.
    var strip: [DeveloperToolsTab] {
        shell.panels.shown.map(DeveloperToolsTab.panel) + session.extensionPanels.items.map { .extensionPanel($0.id) }
    }

    var currentTab: DeveloperToolsTab {
        session.extensionPanels.selection.map { .extensionPanel($0.id) } ?? .panel(session.panel)
    }

    func select(_ tab: DeveloperToolsTab) {
        switch tab {
        case .panel(let panel): session.select(panel)
        case .extensionPanel(let id):
            if session.picking { session.togglePicker() }
            session.extensionPanels.select(id)
        }
    }

    func perform(_ action: DeveloperToolsKeyAction) {
        switch action {
        case .commandMenu(let prefix):
            // Open file lists Sources' files, so it shows that panel, as
            // Chrome's ⌘P does; Go to symbol and Go to line likewise.
            if prefix.isEmpty || prefix == "@" || prefix == ":" { session.select(.sources) }
            shell.showCommandMenu(prefix)
        case .commandMenuMove(let offset):
            guard var menu = shell.commandMenu else { return }
            let count = DeveloperCommandMenu.items(for: menu.query, in: self).count
            menu.selection = count == 0 ? 0 : min(max(0, menu.selection + offset), count - 1)
            shell.commandMenu = menu
        case .commandMenuRun:
            guard let menu = shell.commandMenu else { return }
            DeveloperCommandMenu.run(menu, in: self)
        case .commandMenuClose: shell.commandMenu = nil
        case .stepPanel(let offset):
            if let tab = DeveloperTabStrip.step(strip, from: currentTab, by: offset) { select(tab) }
        case .toggleDrawer: shell.toggleDrawer()
        case .toggleDockSide: tools.toggleDockSide()
        case .toggleDeviceToolbar: toggleViewport()
        case .zoom(let step): shell.zoom(by: step)
        case .settings: shell.settingsShown = true
        case .debugger(let command): session.debugger.step(command)
        case .toggleBreakpoints: session.debugger.setBreakpointsActive(!session.debugger.breakpointsActive)
        case .selectPanel(let index):
            let tabs = strip
            if tabs.indices.contains(index) { select(tabs[index]) }
        case .focusConsole:
            // In the drawer when Console isn't the panel in front, as in Chrome.
            if currentTab != .panel(.console) {
                shell.showDrawer(.tool(.console))
            }
            session.consoleStore.promptFocus += 1
        case .clearConsole: session.clearConsole()
        case .findInConsole:
            session.consoleStore.findShown = true
            session.consoleStore.findFocus += 1
        case .findInNetwork: DeveloperPanelKeys.network?.find()
        case .findInPerformance: DeveloperPanelKeys.performance?.find()
        case .closeDetails: DeveloperPanelKeys.network?.closeDetails()
        case .recordNetwork: session.recordNetwork.toggle()
        case .recordPerformance(let reload):
            if reload {
                // Start profiling and reload page: only from a stop.
                if !session.recordingTimeline { session.toggleTimeline(reloading: true) }
            } else {
                session.toggleTimeline()
            }
        case .performanceProfile(let save):
            if let keys = DeveloperPanelKeys.performance {
                if save { keys.save() } else { keys.load() }
            } else if save {
                DeveloperPerformanceFiles.save(session)
            } else {
                DeveloperPerformanceFiles.load(into: session)
            }
        case .callFrame(let offset):
            let debugger = session.debugger
            guard let pause = debugger.pause else { return }
            let next = debugger.selectedFrame + offset
            if pause.frames.indices.contains(next) { debugger.selectFrame(next) }
        case .toggleNavigator: shell.sourcesNavigatorHidden.toggle()
        case .toggleDebuggerSidebar: shell.sourcesDebuggerHidden.toggle()
        case .saveAll: DeveloperSourceTabs.of(session).saveAll()
        case .sourceTab(let offset): DeveloperSourceTabs.of(session).selectTab(by: offset)
        case .searchResults(let expanded): DeveloperSourcesSearchModel.of(session).setAllExpanded(expanded)
        case .searchAllFiles: shell.showDrawer(.tool(.search))
        }
    }
}

/// What a panel lends DevTools' keys while it is on screen, for the keys
/// that act on its own view state (DeveloperToolsKeys).
@MainActor
enum DeveloperPanelKeys {
    struct Network {
        /// ⌘F: the Search pane, its field focused.
        var find: @MainActor () -> Void
        /// Whether a request's details are open, which Esc closes.
        var detailsOpen: @MainActor () -> Bool
        var closeDetails: @MainActor () -> Void
    }

    static var network: Network?

    struct Performance {
        /// ⌘S: Save profile.
        var save: @MainActor () -> Void
        /// ⌘O: Load profile.
        var load: @MainActor () -> Void
        /// ⌘F: find in the timeline.
        var find: @MainActor () -> Void
    }

    static var performance: Performance?
}

/// Hosts DevTools in a view of its own, so the key monitor can tell when
/// the keyboard is inside it, and so DevTools' zoom can scale everything
/// in it — AppKit views such as the code view and the Console prompt
/// included — by scaling this view's bounds, as page zoom does.
final class DeveloperToolsHostView: NSView {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var context: DeveloperToolsContext?
    private var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            fitBounds()
            needsDisplay = true
        }
    }
    private var zoom: AnyCancellable?
    private var theme: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hosting.sizingOptions = []
        hosting.autoresizingMask = []
        addSubview(hosting)
        // DevTools' zoom (⌘+, ⌘−, ⌘0), watched here rather than by the dock,
        // so typing in DevTools never lays the page out again.
        zoom = DeveloperToolsShell.shared.$scale.sink { [weak self] scale in self?.scale = scale }
        // Settings › Appearance › Theme: DevTools alone, the page left as it is.
        theme = DeveloperToolsThemeStore.shared.$theme.sink { [weak self] theme in self?.appearance = theme.appearance }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// With the keyboard on DevTools itself (after a click on a part that
    /// takes no typing), a key nothing wants is dropped, not beeped at.
    override func keyDown(with event: NSEvent) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitBounds()
    }

    override func layout() {
        fitBounds()
        super.layout()
    }

    private func fitBounds() {
        let scale = max(0.25, scale)
        let size = NSSize(width: frame.width / scale, height: frame.height / scale)
        if bounds.size != size { setBoundsSize(size) }
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
        let target = NSRect(origin: .zero, size: size)
        if hosting.frame != target { hosting.frame = target }
    }
}

