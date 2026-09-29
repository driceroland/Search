import SwiftUI

// A small window for a link from another app: the page, and a thin line over
// it with the site, Open in Search and nothing else — to read and close, or
// to keep. Arc calls it Little Arc; the idea came to Search as #227.
//
// Off unless asked for, in Settings › General: a link from Mail opens in the
// browser's window, as it always has, for anyone who hasn't chosen this.
//
// The page is a tab of its own, as a peek is (see Peek.swift), only in a
// window of its own: Open in Search moves it into the browser's row, where
// the space on screen is, loaded as it is and nothing loaded twice.

@MainActor
final class LittleWindow: NSObject, NSWindowDelegate {
    /// Open ones, each until it is closed or kept.
    private static var open: [LittleWindow] = []

    let tab: Tab
    private weak var browser: Browser?
    private let window: NSWindow
    private var kept = false

    /// A link from another app, in a small window in front of it.
    /// `front: false` makes it without showing it — for the bench, which
    /// must never put a window on screen.
    static func show(_ url: URL, for browser: Browser, front: Bool = true) {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        tab.go(to: url)
        let little = LittleWindow(tab: tab, browser: browser)
        // A step down and in from the newest one on screen, so that five
        // links from Mail are five windows you can see are there, not one
        // on top of four.
        if let last = open.last(where: { $0.window.isVisible }) {
            little.window.cascadeTopLeft(from: last.window.cascadeTopLeft(from: .zero))
        } else {
            little.window.center()
        }
        open.append(little)
        watch()
        // Never a test run's in front: a probe started hidden stays off every screen.
        guard front, !Store.testing else { return }
        little.window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The small windows open now, newest last — for the bench.
    static var all: [LittleWindow] { open }

    /// Closed as its button closes it — for the bench.
    func close() { window.performClose(nil) }

    /// Its window's number, for the bench to press keys in it.
    var windowNumber: Int { window.windowNumber }

    /// The small window a key was pressed in, if it was one.
    static func owning(_ window: NSWindow?) -> LittleWindow? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    /// The small window a tab is the page of, if it is one's.
    static func holding(_ id: Tab.ID) -> LittleWindow? {
        open.first { $0.tab.id == id }
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
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
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
                if !event.modifierFlags.contains(.control) { commit() }
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

    private init(tab: Tab, browser: Browser) {
        self.tab = tab
        self.browser = browser
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.delegate = self
        let id = tab.id
        window.contentView = NSHostingView(rootView: LittleView(tab: tab, keep: { [weak self] in self?.keep() })
            .overlay {
                TabSwitcherOverlay(
                    switcher: LittleWindow.switcher,
                    tab: { id in LittleWindow.holding(id)?.tab ?? LittleWindow.planet?.tabs.first { $0.id == id } },
                    current: id, host: id,
                    pick: { LittleWindow.commit(picking: $0) }
                )
            })
    }

    /// Its keys, before the browser's: ⌃Tab goes to the other small
    /// windows, ⌘O keeps it, Escape and ⌘W close it. Everything else is the
    /// page's.
    func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let switcher = LittleWindow.switcher
        if event.keyCode == 48, flags.contains(.control), flags.isDisjoint(with: [.command, .option]) {
            // A Tab held down doesn't race through them.
            guard !event.isARepeat else { return true }
            if !switcher.active {
                let browser = Browsers.front ?? self.browser
                LittleWindow.planet = browser
                switcher.partners = browser?.switcherPartners ?? [:]
            }
            switcher.step(fromMoon: tab.id, moons: LittleWindow.stacked,
                          planet: LittleWindow.planet?.switcherPlanet ?? [], backwards: flags.contains(.shift))
            return true
        }
        // While the switcher is up, ⌃ and the arrows move through it; any
        // other key puts it away. Escape does nothing else: it would close
        // this window too, on the way out of the switcher.
        if switcher.active {
            if flags.contains(.control), flags.isDisjoint(with: [.command, .option]) {
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
            // ⌃W, ⌃R, ⌃M, ⌃O on the card picked, a moon or a tab.
            if let action = TabSwitcher.Action(event), let id = switcher.selectedID {
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
        if event.keyCode == 53 && flags.isEmpty || key == "w" && flags == .command {
            window.performClose(nil)
            return true
        }
        if key == "o" && flags == .command {
            keep()
            return true
        }
        return false
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

    /// Into the browser's row, after the tab on screen (never among the
    /// pins), and in front; the small window goes.
    func keep() {
        // Into the window in front, whichever that is now.
        guard let browser = Browsers.front ?? browser else { return }
        kept = true
        // As a tab moved from another window is: this window's delegate,
        // and this window's space, with its sign-ins.
        browser.receive(tab)
        window.close()
        (browser.window ?? NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) && $0 !== window })?
            .makeKeyAndOrderFront(nil)
    }

    /// Stepping away puts the switcher away, and makes this the one ⌃Tab
    /// comes back to first.
    func windowDidResignKey(_ notification: Notification) {
        let switcher = LittleWindow.switcher
        if switcher.home == tab.id { switcher.cancel() }
        guard !kept else { return }
        switcher.left(tab, alive: Set(LittleWindow.open.map(\.tab.id)))
    }

    func windowWillClose(_ notification: Notification) {
        if LittleWindow.switcher.home == tab.id { LittleWindow.switcher.cancel() }
        if !kept { tab.close() }
        LittleWindow.open.removeAll { $0 === self }
    }
}

/// The page, and the line over it: the site, and Open in Search when there
/// is somewhere to keep it (an extension's popup window has no such button).
struct LittleView: View {
    @ObservedObject var tab: Tab
    let keep: (() -> Void)?

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
            WebStage(page: tab.built ?? tab.web)
        }
        .background(Palette.ground)
        .ignoresSafeArea()
    }

    /// The page on screen — not one still on its way, which a page can
    /// start and never finish — named as the site, or as what it is when
    /// it isn't a website, and marked when it came over plain http.
    private var site: String {
        guard let url = tab.pageAddress else { return "" }
        switch url.scheme?.lowercased() {
        case "https": return SiteCard.site(url)
        case "http": return "Not secure — " + SiteCard.site(url)
        case "chrome-extension", "webkit-extension": return "Extension page"
        default: return url.absoluteString == "about:blank" ? "" : "Not a website"
        }
    }
}

/// An extension's popup window (windows.create with type "popup"): the
/// browser's tab on screen as the small window shows a page, the site over
/// it. Its tabs, checks and passwords are the browser's, as in any window.
struct ExtensionPopupView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            LittleView(tab: tab, keep: nil).id(tab.id)
        } else {
            Palette.ground
        }
    }
}
