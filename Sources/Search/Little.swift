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
//
// It comes alone. The browser's window stays where it was — closed, in the
// Dock, behind another app — until Open in Search asks for it (see
// Links.little).

@MainActor
final class LittleWindow: NSObject, NSWindowDelegate {
    /// Open ones, each until it is closed or kept.
    private static var open: [LittleWindow] = []

    let tab: Tab
    private let window: NSWindow
    private var kept = false
    /// What it says for a moment at its foot: "Address copied".
    private let note = LittleNote()

    /// A link from another app, in a small window in front of it.
    /// `front: false` makes it without showing it — for the bench, which
    /// must never put a window on screen.
    static func show(_ url: URL, for browser: Browser, front: Bool = true) {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        tab.go(to: url)
        let little = LittleWindow(tab: tab)
        open.append(little)
        watchKeys()
        little.window.center()
        // Never a test run's in front: a probe started hidden stays off every screen.
        guard front, !Store.testing else { return }
        little.window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
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

    private init(tab: Tab) {
        self.tab = tab
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
        window.contentView = NSHostingView(rootView: LittleView(tab: tab, note: note, keep: { [weak self] in self?.keep() }))
        // A zoom said at this window's foot, not the browser's behind it,
        // where Browser.prepare pointed it; kept, the tab is prepared again
        // and says it there.
        tab.onZoom = { [weak note] _, value in note?.say("\(Int((value * 100).rounded()))%") }
    }

    /// Its own key monitor. A browser window's (see ContentView.watchKeys)
    /// hands it these too, but a link that launched the app has no browser
    /// window to lend one any more, and ⌘W went on to close a tab in a
    /// window nobody could see.
    private static var keys: Any?

    private static func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            owning(event.window)?.take(event) == true ? nil : event
        }
    }

    /// Its keys, before the browser's: ⌘O keeps it, Escape and ⌘W close it,
    /// and the page's own commands — copying its address, reloading it,
    /// zooming it — act on this page, on whatever keys Settings › Shortcuts
    /// gives them.
    /// Left to the menus, they acted on the browser's tab, in a window
    /// behind this one or none, and said so there if anywhere. Everything
    /// else is the page's.
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
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
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

    /// Its page's address on the pasteboard, plain or as a Markdown link,
    /// said at the foot of the window as the browser's window says it.
    private func copy(markdown: Bool) {
        guard let url = tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown ? Browser.markdownLink(tab.label, url) : url.absoluteString, forType: .string)
        note.say(markdown ? "Link copied" : "Address copied")
    }

    /// Into the browser's row, after the tab on screen (never among the
    /// pins), and in front; the small window goes. The one time a link in
    /// a small window brings the browser's window: the window in front, or
    /// one brought back for it.
    func keep() {
        let browser = Browsers.ensureWindow()
        kept = true
        // As a tab moved from another window is: this window's delegate,
        // and this window's space, with its sign-ins.
        browser.receive(tab)
        window.close()
        guard let front = browser.window else { return }
        // Put away in the Dock, it stayed there (#95).
        if front.isMiniaturized { front.deminiaturize(nil) }
        front.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !kept { tab.close() }
        LittleWindow.open.removeAll { $0 === self }
    }
}

/// The page, and the line over it: the site, and Open in Search when there
/// is somewhere to keep it (an extension's popup window has no such button).
struct LittleView: View {
    @ObservedObject var tab: Tab
    /// Its window's line at the foot; an extension's popup has none.
    var note: LittleNote? = nil
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
            ZStack {
                WebStage(page: tab.built ?? tab.web)
                // A page that never came says so, with Try again, as in a tab.
                if let failure = tab.failure {
                    Trouble(message: failure) { tab.reload() }
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: tab.failure)
        }
        .background(Palette.ground)
        .overlay(alignment: .bottom) { if let note { LittleToast(note: note) } }
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
