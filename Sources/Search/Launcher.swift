import AppKit
import Combine
import SwiftUI

// The address field from any app (Settings › Keyboard & Mouse › From any app;
// #783, idea 497). A key of your own raises it over whichever app is in
// front, as Spotlight's does. What is typed there is answered as ⌘L answers
// it — your bookmarks, where you have been, the pages already open — and
// Return opens it in Search's window in front, or goes to the tab that has
// it, and brings Search forward. Escape, a click outside, ⌘W or the key
// again puts it away and leaves you in the app you were in, which never
// stopped being in front: the panel takes the keys without making Search
// the active app.
//
// Only while Search isn't in front with a window: there the key is given
// back to the page, and ⌘L is the field (see standsAside).
//
// Its own field and list, not a window's. A window's field shows wherever
// its browser says it is editing, and on every blank tab, so one shared with
// it showed every key typed here in that window too. What answers what is
// typed is the window's own: Browser.placeOffers, and ⌘K's open pages.
//
// Nothing is asked of a search engine while typing: words typed over another
// app are not a page Search was asked to show.

/// The key the launcher is on, as Settings shows it, and the key on the
/// keyboard that Carbon registers (see HotKey).
struct LauncherKey: Codable, Equatable {
    var combo: KeyCombo
    var code: UInt16

    /// What Settings offers in one click: Spotlight's key, with ⇧.
    static let suggested = LauncherKey(combo: KeyCombo("space", shift: true), code: 49)
}

@MainActor
final class Launcher: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = Launcher()

    /// On screen — or, on a run the bench drives, up in the model alone.
    @Published private(set) var up = false
    @Published private(set) var typed = ""
    @Published private(set) var offers: [Suggestion] = []
    /// The rest of the best match, after the caret, as ⌘L's field draws it.
    @Published private(set) var ending: String?
    /// The row the arrow keys have walked to.
    @Published var picked: Int?
    /// Bumped when what was typed is no address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped each time the field should take the keys.
    @Published private(set) var focusRequest = 0
    /// Why macOS wouldn't give Search the key chosen, for Settings to say.
    @Published private(set) var refusal: String?

    /// What was typed when the field was put away without going anywhere,
    /// for the next time, as ⌘T keeps its words.
    private var draft = ""
    /// The window whose profile answers what is typed, and that Return goes
    /// to: the one in front when the key was pressed.
    private weak var target: Browser?
    private var panel: LauncherPanel?
    private var keys: Any?
    private var clicks: Any?
    private var watching: [NSObjectProtocol] = []
    private var bag = Set<AnyCancellable>()
    private var started = false

    /// A test run a script drives: the key is never asked of macOS and the
    /// panel never shown — the bench works the model (Bench.swift, "launcher").
    static var benchDriven: Bool { Store.testing && Shared.prefs.bench }

    static func owns(_ window: NSWindow?) -> Bool {
        guard let window, let panel = shared.panel else { return false }
        return window === panel
    }

    // MARK: - the key

    /// With a window of Search's in front, the key is the page's: the field
    /// over it is ⌘L's. Everywhere else — another app in front, Search
    /// minimised or with no window — it is the launcher's.
    nonisolated static func standsAside(active: Bool, windowShowing: Bool) -> Bool {
        active && windowShowing
    }

    /// A browser window on screen, not in the Dock.
    static var windowShowing: Bool {
        Browsers.all.contains { browser in
            guard browser.isOpen, !browser.isPopup, let window = browser.window else { return false }
            return window.isVisible && !window.isMiniaturized
        }
    }

    /// Whether the key should be Search's now. Up, it stays: pressed again,
    /// it puts the field away.
    var wants: Bool {
        let prefs = Shared.prefs
        guard prefs.launcher, prefs.launcherKey != nil, !ShortcutStore.shared.recording else { return false }
        return up || !Self.standsAside(active: NSApp.isActive, windowShowing: Self.windowShowing)
    }

    /// Once, at launch: the key follows the switch, the key chosen, and
    /// Search coming in front of other apps or going behind them.
    func start() {
        guard !started else { return }
        started = true
        HotKey.pressed = { [weak self] in self?.toggle() }
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.noticed(note) }
            }
            watching.append(observer)
        }
        // Published as they are about to change: read once they have.
        let prefs = Shared.prefs
        prefs.$launcher.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        prefs.$launcherKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }.store(in: &bag)
        ShortcutStore.shared.$recording.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        refresh()
    }

    private func noticed(_ note: Notification) {
        // Search brought forward some other way — its Dock icon, a link —
        // with the field up over the app it left: the field goes too.
        if note.name == NSApplication.didBecomeActiveNotification, up { dismiss() }
        // After a window closing has closed.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The key asked of macOS, or given back, as things are now.
    func refresh() {
        let prefs = Shared.prefs
        if !prefs.launcher || prefs.launcherKey == nil {
            if up { dismiss(keeping: false) }
            refusal = nil
        }
        guard wants, !Self.benchDriven, let key = prefs.launcherKey else {
            HotKey.clear()
            return
        }
        say(HotKey.set(code: key.code, modifiers: HotKey.modifiers(of: key.combo)), for: key)
    }

    /// A key just chosen, asked of macOS at once, so Settings can say
    /// straight away if it is another app's — though Settings is in front,
    /// where the key would otherwise wait until Search goes behind.
    private func check() {
        let prefs = Shared.prefs
        guard prefs.launcher, let key = prefs.launcherKey, !Self.benchDriven else { return refresh() }
        say(HotKey.set(code: key.code, modifiers: HotKey.modifiers(of: key.combo)), for: key)
        if !wants { HotKey.clear() }
    }

    /// Asked again each time, as one of macOS's keys can be switched on
    /// after this one was chosen — or this one taken by the button.
    private func say(_ status: OSStatus, for key: LauncherKey) {
        if HotKey.usedByMacOS(code: key.code, modifiers: HotKey.modifiers(of: key.combo)) {
            refusal = "\(key.combo.display) is used by macOS"
        } else {
            refusal = status == noErr ? nil : "macOS won’t give Search \(key.combo.display)"
        }
    }

    // MARK: - up and away

    func toggle() { up ? dismiss() : show() }

    func show() {
        guard Shared.prefs.launcher, !up else { return }
        target = Browsers.front.flatMap { $0.isPopup ? nil : $0 } ?? Browsers.primary ?? SceneSlot.shared.browser
        up = true
        typed = draft
        draft = ""
        guess()
        focusRequest += 1
        watchKeys()
        guard !Self.benchDriven else { return }
        present()
    }

    /// Put away. What was typed waits for the next time, unless it went
    /// somewhere.
    func dismiss(keeping: Bool = true) {
        guard up else { return }
        draft = keeping ? typed : ""
        up = false
        typed = ""
        offers = []
        ending = nil
        picked = nil
        panel?.orderOut(nil)
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if up { dismiss() }
    }

    /// On the screen with the pointer, a little above the middle, as
    /// Spotlight's: keys to it, while the app in front stays in front.
    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let area = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.18 - size.height))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        // A click anywhere else: in another app's window, the panel never
        // sees it, but this does.
        clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.fieldWidth + LauncherView.margin * 2, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Over every ordinary window, the floating video's included, on
        // whichever desktop is on screen and over an app in full screen.
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The field and its list draw their own.
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LauncherView(launcher: self))
        return panel
    }

    /// Its keys, before the menus: those act on a window of Search's behind
    /// another app. Escape and ⌘W put it away; the keys every text field
    /// has are done here; anything else with ⌘ or ⌃ is nobody's.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.up, Launcher.owns(event.window) else { return event }
            return self.take(event) ? nil : event
        }
    }

    private func take(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        let key = event.shortcutCharacters
        if flags == .command, key == "w" {
            dismiss()
            return true
        }
        let edit: Selector?
        switch (key, flags) {
        case ("a", .command): edit = #selector(NSResponder.selectAll(_:))
        case ("c", .command): edit = #selector(NSText.copy(_:))
        case ("v", .command): edit = #selector(NSText.paste(_:))
        case ("x", .command): edit = #selector(NSText.cut(_:))
        case ("z", .command): edit = Selector(("undo:"))
        case ("z", [.command, .shift]): edit = Selector(("redo:"))
        default: edit = nil
        }
        if let edit {
            NSApp.sendAction(edit, to: nil, from: nil)
            return true
        }
        // ⌘ or ⌥ with an arrow or ⌫ moves or deletes in the words, and ⌃
        // with a letter is the text system's own (⌃A, ⌃E, ⌃K).
        if [123, 124, 125, 126, 51, 117].contains(event.keyCode) { return false }
        if flags == .control, key.count == 1, key.first?.isLetter == true { return false }
        return true
    }

    // MARK: - what is typed

    func type(_ text: String) {
        typed = text
        guess()
    }

    /// Typed plus whatever the field is finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) { return offers[picked].key }
        return typed + (ending ?? "")
    }

    func stopCompleting() { ending = nil }

    /// The arrow keys walk the list, and walking off either end lets go.
    func walk(_ step: Int) {
        guard !offers.isEmpty else { return }
        switch picked {
        case nil: picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    /// What ⌘L's field would offer for the same words, in the window the
    /// key was pressed over, with the pages already open first.
    private func guess() {
        picked = nil
        guard let target, !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            return
        }
        let places = target.placeOffers(for: typed)
        let open = openTabs(matching: typed, for: target)
        // A page offered as open isn't offered again as a place to load.
        let shown = Set(open.map(\.url))
        var rest = places.offers.filter { $0.tab != nil || !shown.contains($0.url) }
        // A command typed whole stays on top, over the open pages: there it
        // is what Return does, as in ⌘L's field. Under a tab about settings,
        // "settings" searched the web for the word.
        let command = rest.first?.kind.isCommand == true ? [rest.removeFirst()] : []
        offers = command + open + rest
        ending = places.ending
    }

    /// Pages open in the windows of the profile the field was raised for,
    /// each window's space on screen as ⌘K lists them, the window in front
    /// first. Never a private tab, nor one a script opened. Three at most.
    private func openTabs(matching typed: String, for target: Browser) -> [Suggestion] {
        var found: [Suggestion] = []
        for browser in windows(for: target) {
            for offer in browser.openPages(matching: typed, front: true) {
                guard let id = offer.tab, let tab = browser.tabs.first(where: { $0.id == id }),
                      !tab.shy, !tab.bench else { continue }
                found.append(offer)
                if found.count == 3 { return found }
            }
        }
        return found
    }

    /// The tab that already has `url`, among the same tabs as the rows
    /// (openTabs) but not only the three listed: Return goes there rather
    /// than opening the page a second time.
    private func openTab(for url: URL, in target: Browser) -> (owner: Browser, id: Tab.ID)? {
        for browser in windows(for: target) {
            if let tab = browser.tabs.first(where: { !$0.shy && !$0.bench && Browser.samePage(url, $0.address) }) {
                return (browser, tab.id)
            }
        }
        return nil
    }

    /// The windows of the profile the field was raised for, the one in
    /// front first.
    private func windows(for target: Browser) -> [Browser] {
        ([target] + Browsers.all.reversed().filter { $0 !== target })
            .filter { $0.isOpen && !$0.isPopup && $0.profileID == target.profileID }
    }

    // MARK: - going there

    /// A row clicked, as Return on it.
    func take(_ offer: Suggestion) {
        guard let index = offers.firstIndex(of: offer) else { return }
        picked = index
        submit()
    }

    /// Return: the tab that has it, a command from the list, or what was
    /// typed opened in a new tab of the window in front — one brought back
    /// if none is open — and Search in front of the app the field was
    /// raised over. The same order as Browser.submit.
    func submit() {
        guard up, let target = target ?? Browsers.front else { return }
        let chosen = picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }

        if let chosen, let id = chosen.tab,
           let owner = Browsers.all.first(where: { browser in browser.tabs.contains { $0.id == id } }) {
            dismiss(keeping: false)
            go(to: id, in: owner)
            comeForward()
            return
        }

        // A command is only ever on top, and there it is what Return does.
        if case .command(let command) = (chosen ?? offers.first)?.kind {
            dismiss(keeping: false)
            let browser = Browsers.ensureWindow()
            command.run(on: browser)
            Self.bringUp(browser)
            comeForward()
            return
        }

        let url: URL?
        if let chosen {
            url = chosen.url
        } else if let ending {
            url = Address.url(from: typed + ending)
        } else {
            url = target.destination(for: typed)
        }
        guard let url else {
            refusals += 1
            return
        }
        dismiss(keeping: false)
        // search://settings and the rest: the page's own tab, one of each.
        if let page = InternalPage(url: url) {
            let browser = Browsers.ensureWindow()
            browser.show(page)
            Self.bringUp(browser)
        } else if Shared.prefs.launcherLittle {
            // In a small window over the app you're in, as a link from
            // another app can open (Settings › From any app).
            Links.openLittle(url, for: target)
            return
        } else if let open = openTab(for: url, in: target) {
            // Already open — typed out, finished by the grey ending, or a row
            // lower than the open pages reach: that tab, not a second one.
            go(to: open.id, in: open.owner)
        } else {
            Links.land(url)
        }
        comeForward()
    }

    /// A tab already open, in its window, on screen.
    private func go(to id: Tab.ID, in owner: Browser) {
        Browsers.bringBack()
        owner.bringForward(id)
        Self.bringUp(owner)
    }

    private func comeForward() { Links.comeForward(lookedAt: true) }

    /// The window what was asked for went to, on screen: out of the Dock
    /// first, since bringing a window to the front doesn't take it out
    /// (#95). With its only window there, Settings, Search's own pages and
    /// the commands opened in it and left nothing to see.
    static func bringUp(_ browser: Browser) {
        if let window = browser.window, window.isMiniaturized { window.deminiaturize(nil) }
        Browsers.show(browser)
    }
}

/// Takes the keys without bringing Search in front of the app it is over.
/// Borderless windows refuse to become key by default.
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - the field

/// The field and its list, as they are over a page, standing over another
/// app instead.
private struct LauncherView: View {
    /// Room around the field for its shadow, which the panel doesn't draw.
    static let margin: CGFloat = 32

    @ObservedObject var launcher: Launcher
    @State private var shake: CGFloat = 0
    @State private var refused = false

    var body: some View {
        VStack(spacing: 8) {
            field
            if !launcher.offers.isEmpty { list }
        }
        .frame(width: Metrics.fieldWidth)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A click beside the field, in the panel, puts it away as a click
        // anywhere else does.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { launcher.dismiss() })
        .animation(Motion.quick, value: launcher.offers.isEmpty)
    }

    private var field: some View {
        LauncherField(launcher: launcher)
            .frame(height: 22)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(refused ? Color.red.opacity(0.35) : Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            // Deeper than over a page: it stands over another app's window.
            .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
            .modifier(Shake(travel: shake))
            .onChange(of: launcher.refusals) { _, _ in
                shake = 0
                refused = true
                withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
            }
            .onChange(of: launcher.typed) { _, _ in
                withAnimation(Motion.quick) { refused = false }
            }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(launcher.offers.enumerated()), id: \.element.id) { index, offer in
                Omnibox.Row(offer: offer, picked: launcher.picked == index)
                    .contentShape(Rectangle())
                    .onTapGesture { launcher.take(offer) }
            }
        }
        .padding(6)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 20, y: 6)
        .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
    }
}

/// The words, in AppKit, for the same reason as the window's AddressField:
/// the rest of an address offered after the caret, selected, so typing on
/// replaces it and Return takes it.
private struct LauncherField: NSViewRepresentable {
    @ObservedObject var launcher: Launcher

    private static let font = NSFont.systemFont(ofSize: 15.5)

    func makeCoordinator() -> Coordinator { Coordinator(launcher: launcher) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(
            string: "Search or enter a web address",
            attributes: [.font: Self.font, .foregroundColor: NSColor(Palette.ink.opacity(0.3))]
        )
        field.setAccessibilityLabel("Address, opened in Search")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.launcher = launcher
        // Only when something other than typing changed it: the words kept
        // from last time, a walk through the list, a submit clearing it.
        let want = launcher.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: launcher.typed.count, in: field)
        }
        if coordinator.answered != launcher.focusRequest {
            coordinator.answered = launcher.focusRequest
            DispatchQueue.main.async { coordinator.focus(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var launcher: Launcher
        var answered = -1
        var synced = ""
        /// A backspace takes a letter off rather than having the same
        /// letter offered straight back as the rest of an address.
        private var deleting = false

        init(launcher: Launcher) {
            self.launcher = launcher
        }

        /// The keys, with the words kept from last time selected whole, so
        /// typing over them costs nothing. A field not in its panel yet is
        /// asked again a turn later.
        func focus(_ field: NSTextField, tries: Int = 0) {
            guard launcher.up else { return }
            guard let window = field.window else {
                if tries < 10 { DispatchQueue.main.async { self.focus(field, tries: tries + 1) } }
                return
            }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue
            launcher.type(text)
            guard !deleting, let ending = launcher.ending else {
                if deleting { launcher.stopCompleting() }
                deleting = false
                synced = launcher.completed
                return
            }
            deleting = false
            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// The part after the caret, selected, so the next key replaces it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                launcher.submit()
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
                launcher.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
                launcher.walk(-1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                launcher.dismiss()
                return true
            case #selector(NSResponder.deleteWordBackward(_:)):
                // ⌥⌫ over an offered ending lets go of it and takes the last
                // word typed, as in the window's field.
                deleting = true
                let selected = textView.selectedRange()
                guard launcher.ending != nil, selected.length > 0,
                      NSMaxRange(selected) == (textView.string as NSString).length
                else { return false }
                textView.delete(nil)
                deleting = true
                textView.deleteWordBackward(nil)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}

// MARK: - Settings

/// The launcher's key, chosen in Settings: click, then press it. Empty until
/// chosen, with Spotlight's key, ⇧, one click away; ⌫ takes it away.
struct LauncherKeyBox: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var launcher = Launcher.shared

    @State private var listening = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let refusal = launcher.refusal, !listening {
                Text(refusal)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .lineLimit(1)
            }
            if prefs.launcherKey == nil, !listening {
                Pill("Use \(LauncherKey.suggested.combo.display)") { prefs.launcherKey = .suggested }
            }
            Button(action: listen) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(listening || prefs.launcherKey != nil ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 64, minHeight: 24)
                    .background(listening || hovering ? Palette.hover : Palette.ground,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(listening ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click, then press the key. ⌫ takes it away")
            .onHover { hovering = $0 }
            .onDisappear(perform: stop)
        }
    }

    private var label: String {
        if let note { return note }
        if listening { return "Type a shortcut" }
        return prefs.launcherKey?.combo.display ?? "None"
    }

    private func listen() {
        guard !listening else { return stop() }
        listening = true
        note = nil
        // Search's own keys stand aside while one is typed here, and so
        // does the launcher's (see Launcher.wants).
        ShortcutStore.shared.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            take(event)
            return nil
        }
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            prefs.launcherKey = nil
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say("Add ⌘, ⌥ or ⌃") }
        guard !KeyCombo.isReserved(combo) else { return say("Can’t be used") }
        guard !HotKey.usedByMacOS(code: event.keyCode, modifiers: HotKey.modifiers(of: combo)) else {
            return say("Used by macOS")
        }
        prefs.launcherKey = LauncherKey(combo: combo, code: event.keyCode)
        stop()
    }

    /// Why that key won't do, for a moment, still listening.
    private func say(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if note == text { note = nil } }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        note = nil
        ShortcutStore.shared.recording = false
    }
}
