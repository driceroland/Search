import SwiftUI

// A small window for a link from another app, and for a tab you already
// have (Open in Small Window): the page, and a thin line over it with the
// site, Open in Search and nothing else — to read and close, or to keep.
// Arc calls it Little Arc; the idea came to Search as #227.
//
// On for a new install, in Settings › General; an install from before it
// was the default keeps it off, and a link from Mail opens in the browser's
// window, as it always did, until it is turned on (see
// Preferences.settleLittleLinks).
//
// The page is a tab of its own, as a peek is (see Peek.swift), only in a
// window of its own: Open in Search moves it into the browser's row, where
// the space on screen is, loaded as it is and nothing loaded twice.
//
// It comes alone. The browser's window stays where it was — closed, in the
// Dock, behind another app — until Open in Search asks for it (see
// Links.little).

@MainActor
final class LittleWindow: NSObject, NSWindowDelegate {
    /// Open ones, each until it is closed or kept.
    private static var open: [LittleWindow] = []

    let tab: Tab
    /// Taken out of the row, rather than opened for a link. A quit puts it back.
    private(set) var lifted = false
    /// The space it was lifted from: a quit writes it back there, not into
    /// whatever space is on screen then.
    private(set) var liftedSpace: UUID?
    /// The browser it was opened for: the planet for ⌃Tab when no window is in front.
    private weak var browser: Browser?
    /// The space chosen for its page (see Links.open), whose sign-ins it
    /// loaded with; nil for the space of the window it was opened for.
    let chosenSpace: UUID?
    private let window: NSWindow
    private var kept = false
    /// Placed a step down from another one, not where anybody put it: the
    /// place is not worth keeping until it is moved or resized. Closed in
    /// any order, a stack of them walked the kept place across the screen.
    private var cascaded = false
    /// What it says for a moment at its foot: "Address copied".
    private let note = LittleNote()
    /// No smaller than this, by hand or from a kept place.
    private static let smallest = NSSize(width: 420, height: 320)

    /// A link from another app, in a small window in front of it.
    /// `front: false` makes it without showing it — for the bench, which
    /// must never put a window on screen.
    static func show(_ url: URL, for browser: Browser, front: Bool = true, space: UUID? = nil) {
        let tab = Tab(configuration: Web.configuration(space: space ?? browser.spaceID))
        browser.prepare(tab)
        tab.go(to: url)
        show(tab, for: browser, front: front, space: space)
    }

    /// A page already made for it: a new window a small window's page asked
    /// for (see Browser's createWebViewWith), which WebKit loads itself, or
    /// a tab lifted out of the row (`lifted`).
    static func show(_ tab: Tab, for browser: Browser, front: Bool = true, lifted: Bool = false, space: UUID? = nil) {
        // Not in the row until kept: extensions are told of it here, as of a
        // peek (see Extensions.openedAside). A tab lifted from the row is
        // told once the row has let it go (Extensions.follow), not twice.
        if #available(macOS 15.4, *), !lifted { Extensions.shared.openedAside(tab) }
        let little = LittleWindow(tab: tab, browser: browser, space: space)
        little.lifted = lifted
        little.liftedSpace = lifted ? browser.spaceID : nil
        // A tab from the row has its own history: back from its first page
        // goes nowhere, as in the row, rather than closing the window.
        if lifted { tab.leave = nil }
        // A step down and in from the newest one on screen, so that five
        // links from Mail are five windows you can see are there, not one
        // on top of four.
        if let last = open.last(where: { $0.window.isVisible }) {
            little.window.cascadeTopLeft(from: last.window.cascadeTopLeft(from: .zero))
            little.cascaded = true
        }
        open.append(little)
        watchKeys()
        watch()
        // Never a test run's in front: a probe started hidden stays off every screen.
        guard front, !Store.testing else { return }
        little.window.makeKeyAndOrderFront(nil)
        // Asked again if the app in front didn't hand the front over: the
        // address field from any app is a panel that never made Search the
        // app in front, so a plain activate() left the window behind (#1494).
        Links.comeForward()
    }

    /// The small windows open now, newest last — for the bench.
    static var all: [LittleWindow] { open }

    /// Closed as its button closes it — for the bench.
    func close() { window.performClose(nil) }

    /// Its window, for the bench to press keys on, and what its foot says.
    var windowNumber: Int { window.windowNumber }
    var said: String? { note.text }

    /// The small window a key was pressed in, if it was one.
    static func owning(_ window: NSWindow?) -> LittleWindow? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    /// The small window a tab is the page of, if it is one's.
    static func holding(_ id: Tab.ID) -> LittleWindow? {
        open.first { $0.tab.id == id }
    }

    /// Tabs lifted out of this window's row. A quit writes them back into
    /// it (see Browser.writeSession); a link from another app is not one
    /// of them, and goes when its window does.
    static func parked(beside browser: Browser, space: UUID) -> [Tab] {
        open.filter { $0.browser === browser && $0.space(in: browser) == space }.map(\.tab)
    }

    /// The space a lifted tab is written into: the one it came from, or the
    /// one on screen once that space has been deleted.
    private func space(in browser: Browser) -> UUID? {
        guard lifted, let liftedSpace else { return nil }
        return browser.spaces.contains { $0.id == liftedSpace } ? liftedSpace : browser.spaceID
    }

    /// The browser window a tab was lifted from is closing, with another of
    /// its profile still open: that one keeps the tab now, so a quit still
    /// writes it down, and ⇧⌘T after closing it still finds a row.
    static func rehome(from leaving: Browser, to heir: Browser) {
        for little in open where little.browser === leaving {
            little.browser = heir
            if let space = little.liftedSpace, !heir.spaces.contains(where: { $0.id == space }) {
                little.liftedSpace = heir.spaceID
            }
        }
    }

    /// The small windows' tabs as the Mac stacks their windows, the one in
    /// front first; any never shown after them, newest first. The browser's
    /// switcher shows them in this order, beside its tabs.
    static var stacked: [Tab.ID] {
        // The Mac lists windows it has never shown too, oldest first: only
        // the ones on screen have a place in the stack.
        let stack = NSApp.orderedWindows.filter(\.isVisible)
        let depth = { (little: LittleWindow) in stack.firstIndex { $0 === little.window } ?? stack.count }
        return open.reversed().enumerated()
            .sorted { (depth($0.element), $0.offset) < (depth($1.element), $1.offset) }
            .map(\.element.tab.id)
    }

    /// ⌃Tab in a small window: the browser's switcher as it looks from
    /// here, the tabs as the planet and the small windows as its moons,
    /// walked from this moon. One for all of them, so the moons' order is
    /// the same whichever one it starts in; it shows over the one it started
    /// in, its home.
    static let switcher = TabSwitcher()

    /// The browser whose tabs are the planet for this gesture: the window
    /// in front, as Open in Search takes.
    private(set) static weak var planet: Browser?

    /// The last one brought forward on a test run, which never puts one
    /// on a screen — for the bench.
    private(set) static var fronted: Tab.ID?

    /// In front, with the keys, as a click on it would leave it.
    func front() {
        guard !Store.testing else { return LittleWindow.fronted = tab.id }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        Links.comeForward()
    }

    /// The card the switcher is on, or the one clicked: a small window
    /// forward, or a tab in its browser window.
    static func commit(picking id: Tab.ID? = nil) {
        guard let target = switcher.finish(picking: id) else { return }
        if let little = holding(target) { little.front() } else { planet?.bringForward(target) }
    }

    /// Letting go of ⌃, and a click while the switcher is up, in whichever
    /// small window it is up in. The browser windows' own monitors hear
    /// these too, and leave them: a small window isn't theirs.
    private static var watching: [Any] = []

    private static func watch() {
        guard watching.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown], handler: { event in
            guard switcher.active, let little = owning(event.window), switcher.home == little.tab.id
            else { return event }
            if event.type == .flagsChanged {
                if !ShortcutStore.shared.recentHeld(event.modifierFlags) { commit() }
                return event
            }
            // As in a browser window (Browser.clickTabSwitcher): ⌃ is held,
            // and a ⌃-click is a right-click to AppKit, so the switcher
            // takes the click before any view does.
            guard let height = little.window.contentView?.bounds.height else { return event }
            let at = event.locationInWindow
            return switcher.click(at: CGPoint(x: at.x, y: height - at.y)) { commit(picking: $0) } ? nil : event
        }) {
            watching.append(monitor)
        }
        watching.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { switcher.cancel() } })
    }

    private init(tab: Tab, browser: Browser, space: UUID?) {
        self.tab = tab
        self.browser = browser
        self.chosenSpace = space
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = Self.smallest
        if let frame = Self.remembered {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.delegate = self
        let id = tab.id
        window.contentView = NSHostingView(rootView: LittleView(tab: tab, note: note, keep: { [weak self] in self?.keep() })
            .overlay {
                TabSwitcherOverlay(
                    switcher: LittleWindow.switcher,
                    tab: { id in LittleWindow.holding(id)?.tab ?? LittleWindow.planet?.tabs.first { $0.id == id } },
                    current: id, host: id,
                    pick: { LittleWindow.commit(picking: $0) }
                )
            })
        // Back from the page it opened on is back to before it opened: a
        // swipe closes it (see PageView.leave).
        tab.leave = { [weak self] in self?.close() }
        // A zoom said at this window's foot, not the browser's behind it,
        // where Browser.prepare pointed it; kept, the tab is prepared again
        // and says it there.
        tab.onZoom = { [weak note] _, value in note?.say("\(Int((value * 100).rounded()))%") }
    }

    /// Its own key monitor, the only one that handles a small window's keys.
    /// A browser window's (ContentView.watchKeys) leaves them alone: a link
    /// that launched the app has no browser window at all, and a key the
    /// page should have first was gone before it got there.
    private static var keys: Any?

    private static func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) }
    }

    /// A key press on the app, before its window has it: nil when a small
    /// window took it.
    static func handle(_ event: NSEvent) -> NSEvent? {
        guard let little = owning(event.window) else { return event }
        if little.pageFirst(event) { return event }
        if little.take(event) { return nil }
        little.leaveCaretKey(event)
        return event
    }

    /// ⌘[ and ⌘] while the page has the keyboard go to the page first, as
    /// in the browser's window (ContentView.pageFirst): an editor outdents
    /// and indents with them. WebKit sends one the page leaves unused back
    /// through the app, and then it is this window's Back or Forward.
    /// Several, as PageView.handed keeps: pressed twice before WebKit
    /// answered, the first came back as a stranger and went to the menu,
    /// which ran Back in the browser's window.
    private static var passed: [NSEvent] = []

    private func pageFirst(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers, key == "[" || key == "]",
              let page = tab.built, window.firstResponder === page else { return false }
        if let index = LittleWindow.passed.firstIndex(where: { PageView.same($0, event) }) {
            LittleWindow.passed.remove(at: index)
            return false
        }
        // One the page used never comes back: none older than two seconds.
        LittleWindow.passed.removeAll { event.timestamp - $0.timestamp > 2 }
        LittleWindow.passed.append(event)
        return true
    }

    /// An arrow bound to a command, while the caret is in a field here, is
    /// the field's. The menu would run the command on the window behind,
    /// so its arrow items stand aside for this one press.
    private func leaveCaretKey(_ event: NSEvent) {
        guard let combo = KeyCombo(event: event), combo.movesCaret,
              tab.typing || tab.built?.inputContext != nil else { return }
        let stolen = ContentView.silenceCaretEquivalents()
        if !stolen.isEmpty { DispatchQueue.main.async { ContentView.restoreCaretEquivalents(stolen) } }
    }

    /// Its keys, before the browser's: ⌃Tab goes to the other small
    /// windows, ⌘O keeps it, Escape and ⌘W close it, and the page's own
    /// commands — copying its address, reloading it, zooming it, back and
    /// forward, previous and next among the small windows — act on this
    /// page, on whatever keys Settings › Shortcuts gives them. Left to the
    /// menus, they acted on the browser's tab, in a window behind this one
    /// or none, and said so there if anywhere. Everything else is the page's.
    func take(_ event: NSEvent) -> Bool {
        if let combo = KeyCombo(event: event) {
            let keys = ShortcutStore.shared
            if combo == keys.key(for: "tabs.copyAddress") { copy(markdown: false); return true }
            if combo == keys.key(for: "tabs.copyMarkdown") { copy(markdown: true); return true }
            if combo == keys.key(for: "view.reload") { tab.reload(fromOrigin: false); return true }
            if combo == keys.key(for: "view.reloadOrigin") { tab.reload(fromOrigin: true); return true }
            // By the same factor as the browser's window, and remembered
            // for the site the same way (see Tab.magnify).
            if combo == keys.key(for: "view.zoomIn") { tab.magnify(by: 1.1); return true }
            if combo == keys.key(for: "view.zoomOut") { tab.magnify(by: 1 / 1.1); return true }
            if combo == keys.key(for: "view.actualSize") { tab.resetZoom(); return true }
            // An arrow the text system uses moves the caret in this page.
            if combo.movesCaret, tab.typing || tab.built?.inputContext != nil { return false }
            if combo == keys.key(for: "tabs.back") { tab.back(); return true }
            if combo == keys.key(for: "tabs.forward") { tab.forward(); return true }
            // Previous and next tab walk the small windows, not the row
            // in the window behind this one.
            if combo == keys.key(for: "tabs.next") { step(1); return true }
            if combo == keys.key(for: "tabs.previous") { step(-1); return true }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.shortcutCharacters
        let switcher = LittleWindow.switcher
        // ⌃Tab, or the key Settings › Shortcuts gave the switcher.
        if let backwards = ShortcutStore.shared.recentSwitch(event) {
            // A Tab held down doesn't race through them.
            guard !event.isARepeat else { return true }
            if !switcher.active {
                let browser = Browsers.front ?? self.browser
                LittleWindow.planet = browser
                switcher.partners = browser?.switcherPartners ?? [:]
            }
            switcher.step(fromMoon: tab.id, moons: LittleWindow.stacked,
                          planet: LittleWindow.planet?.switcherPlanet ?? [], backwards: backwards)
            return true
        }
        // While the switcher is up, ⌃ and the arrows move through it; any
        // other key puts it away. Escape does nothing else: it would close
        // this window too, on the way out of the switcher.
        if switcher.active {
            if ShortcutStore.shared.recentOnly(flags) {
                let direction: TabSwitcher.Direction? = switch event.keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                case 126: .up
                default: nil
                }
                if let direction {
                    switcher.move(direction)
                    return true
                }
            }
            // ⌃W, ⌃R, ⌃M, ⌃O on the card picked, a moon or a tab, when
            // Settings › Tabs has them on.
            if Shared.prefs.switcherKeys, let action = TabSwitcher.Action(event), let id = switcher.selectedID {
                guard !event.isARepeat else { return true }
                if let little = LittleWindow.holding(id) {
                    little.act(action, in: switcher)
                } else {
                    LittleWindow.planet?.act(action, onCard: id, in: switcher)
                }
                return true
            }
            switcher.cancel()
            if event.keyCode == 53 { return true }
        }
        // Escape is a link's way out. A lifted tab is one of yours, and a
        // page's own Escape closing it lost it: ⌘W or the window's button.
        if event.keyCode == 53 && flags.isEmpty && !lifted || key == "w" && flags == .command {
            window.performClose(nil)
            return true
        }
        if key == "o" && flags == .command {
            keep()
            return true
        }
        return false
    }

    /// Previous and next tab, while this window has the keys: the other
    /// small windows. One window has nowhere to go, and the row behind
    /// stays where it is either way.
    private func step(_ direction: Int) {
        // In the order they were opened: by their stacking, the one just
        // left is always next, and with three the third is never reached.
        let ids = LittleWindow.open.map(\.tab.id)
        guard ids.count > 1, let here = ids.firstIndex(of: tab.id) else { return }
        let index = ((here + direction) % ids.count + ids.count) % ids.count
        LittleWindow.holding(ids[index])?.front()
    }

    /// A letter pressed on this window's card in a switcher (see
    /// TabSwitcher.Action): closed, reloaded, muted, or kept in the row.
    func act(_ action: TabSwitcher.Action, in switcher: TabSwitcher) {
        switch action {
        case .close:
            switcher.remove(tab.id)
            close()
        case .reload:
            tab.reload()
        case .mute:
            tab.toggleMute()
            switcher.redraw()
        case .keep:
            // Going to it in the row: nothing left to switch between here.
            switcher.cancel()
            keep()
        }
    }

    /// Its page's address on the pasteboard, plain or as a Markdown link,
    /// said at the foot of the window as the browser's window says it.
    private func copy(markdown: Bool) {
        guard let url = tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown ? Browser.markdownLink(Browser.ownTitle(of: tab), url) : url.absoluteString, forType: .string)
        note.say(markdown ? "Link copied" : "Address copied")
    }

    /// Into the browser's row, after the tab on screen (never among the
    /// pins), and in front; the small window goes. The one time a link in
    /// a small window brings the browser's window: the window in front, or
    /// one brought back for it, or the one showing the space chosen for it.
    /// With no window for that space, it isn't kept (see askAgain).
    func keep() {
        guard let browser = destination() else { return askAgain() }
        kept = true
        // In the row, back from the first page goes nowhere, as any tab's.
        tab.leave = nil
        // As a tab moved from another window is: this window's delegate,
        // and this window's space, with its sign-ins.
        browser.receive(tab)
        window.close()
        guard let front = browser.window else { return }
        // Put away in the Dock, it stayed there (#95).
        if front.isMiniaturized { front.deminiaturize(nil) }
        front.makeKeyAndOrderFront(nil)
    }

    /// A page opened in a space chosen for it goes to a window showing that
    /// space, not the one on screen, so it keeps those sign-ins. Nil once
    /// that space is gone, and while spaces are off.
    private func destination() -> Browser? {
        guard let chosenSpace else { return Browsers.ensureWindow() }
        return Browsers.window(showing: chosenSpace)
    }

    /// Its space gone, the page goes nowhere else: the panel asks again
    /// which space it opens in, and the small window goes. With spaces off
    /// the space is still there, and the small window stays as it is.
    private func askAgain() {
        guard let chosenSpace, Spaces.known[chosenSpace] == nil, let url = tab.address else { return }
        LinkChooserPanel.shared.ask(url, sender: nil)
        window.close()
    }

    /// Stepping away puts the switcher away, and makes this the one ⌃Tab
    /// comes back to first.
    func windowDidResignKey(_ notification: Notification) {
        let switcher = LittleWindow.switcher
        if switcher.home == tab.id { switcher.cancel() }
        guard !kept else { return }
        switcher.left(tab, alive: Set(LittleWindow.open.map(\.tab.id)))
    }

    /// The last place used, given back only while a screen still shows most
    /// of it, as the floating video's is: a screen removed since the last
    /// visit must not strand the next link off screen.
    private static var remembered: NSRect? {
        guard let text = Store.settings.string(forKey: "little.frame") else { return nil }
        let frame = NSRectFromString(text)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= smallest.width, frame.height >= smallest.height else { return nil }
        return NSScreen.screens.contains {
            let seen = $0.visibleFrame.intersection(frame)
            return !seen.isNull && seen.width * seen.height > 0.6 * frame.width * frame.height
        } ? frame : nil
    }

    /// Not in full screen: the screen's whole size, given back to a window
    /// that is not in full screen, covered the menu bar.
    private func rememberFrame() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        Store.settings.set(NSStringFromRect(window.frame), forKey: "little.frame")
    }

    func windowDidMove(_ notification: Notification) {
        guard window.isVisible else { return }
        cascaded = false
        rememberFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        cascaded = false
        rememberFrame()
    }

    func windowWillClose(_ notification: Notification) {
        if !cascaded { rememberFrame() }
        // Quitting writes a lifted page back into the row (see
        // Browser.writeSession). Taking it off the list here would forget it.
        if Browsers.quitting { return }
        if LittleWindow.switcher.home == tab.id { LittleWindow.switcher.cancel() }
        tab.leave = nil
        let owner = browser
        let from = owner.flatMap { self.space(in: $0) }
        // Out of the list before the session is written, so a closed one
        // isn't put back into the row.
        LittleWindow.open.removeAll { $0 === self }
        // Closed, a lifted tab is a tab closed: ⇧⌘T brings it back.
        if lifted, !kept { owner?.rememberLifted(tab) }
        if !kept { tab.close() }
        // Kept, it is in the row on screen, maybe another space's: the one
        // it came from still forgets it, or a relaunch would bring it twice.
        if let from { owner?.dropLifted(tab, from: from) }
    }
}

/// The page, and the line over it: the site, and Open in Search when there
/// is somewhere to keep it (an extension's popup window has no such button).
struct LittleView: View {
    @ObservedObject var tab: Tab
    /// Its window's line at the foot; an extension's popup has none.
    var note: LittleNote? = nil
    let keep: (() -> Void)?
    /// The browser whose window this is, for the accounts under a sign-in
    /// box and the code card, laid over the page (CardsOverPage); none for
    /// a window that has no such list.
    var cards: Browser? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Room for the window's own buttons, which sit on this line.
                Spacer().frame(width: 64)
                Spacer(minLength: 0)
                Text(site)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    // The end of a long name is the part that counts: the
                    // registrable domain, which a cut tail would lose.
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if let keep {
                    Pill("Open in Search", action: keep)
                        .help("Open in Search   ⌘O")
                } else {
                    Spacer().frame(width: 64)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            ZStack {
                WebStage(page: tab.built ?? tab.web)
                if let cards { CardsOverPage(browser: cards, tab: tab.id) }
                // A page that never came says so, with Try again, as in a tab.
                if let failure = tab.failure {
                    Trouble(message: failure) { tab.reload() }
                        .transition(.opacity)
                }
                Swiping(pulling: tab.pulling)
            }
            .animation(Motion.quick, value: tab.failure)
        }
        .background(Palette.ground)
        .overlay(alignment: .bottom) { if let note { LittleToast(note: note) } }
        .ignoresSafeArea()
    }

    /// The page on screen — not one still on its way, which a page can
    /// start and never finish — named as the site, or as what it is when
    /// it isn't a website, and marked when it came over plain http. Only
    /// what has arrived (`committed`): the address a pop-up was asked to
    /// open is not on screen until its page is. A page with nothing of its
    /// own yet, about:blank or blob:, is its opener's, and named as that.
    private var site: String {
        let arrived = tab.committed.flatMap { url -> URL? in
            ["about", "blob"].contains(url.scheme?.lowercased() ?? "") ? nil : url
        }
        guard let url = arrived ?? opened else { return "" }
        switch url.scheme?.lowercased() {
        case "https": return SiteCard.site(url)
        case "http": return "Not secure — " + SiteCard.site(url)
        case "chrome-extension", "webkit-extension": return "Extension page"
        default: return url.absoluteString == "about:blank" ? "" : "Not a website"
        }
    }

    /// What the tab that opened this one has on screen.
    private var opened: URL? {
        guard let id = tab.opener else { return nil }
        return Browsers.all.lazy.flatMap { $0.tabs }.first { $0.id == id }?.committed
    }
}

/// A line said for a moment, as the browser's window says it (see
/// ContentView.announcement): an address copied.
@MainActor
final class LittleNote: ObservableObject {
    @Published private(set) var text: String?
    private var hush: DispatchWorkItem?

    func say(_ text: String) {
        self.text = text
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.text = nil }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }
}

private struct LittleToast: View {
    @ObservedObject var note: LittleNote

    var body: some View {
        ZStack {
            if let text = note.text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Palette.ground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .animation(Motion.settle, value: note.text)
        .allowsHitTesting(false)
    }
}

/// A website's sized pop-up or an extension's popup window: the
/// browser's tab on screen as the small window shows a page, the site over
/// it. Its tabs, checks and passwords are the browser's, as in any window.
struct PopupWindowView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            LittleView(tab: tab, keep: nil, cards: browser).id(tab.id)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        if let ask = browser.asking {
                            if ask.screen { ScreenQuestion(browser: browser, ask: ask) }
                            else { CaptureQuestion(browser: browser, ask: ask) }
                        }
                        if let offer = browser.offering { PasswordOffer(browser: browser, offer: offer) }
                    }
                    .padding(12)
                }
        } else {
            Palette.ground
        }
    }
}
