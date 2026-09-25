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
        let tab = Tab()
        browser.prepare(tab)
        tab.go(to: url)
        let little = LittleWindow(tab: tab, browser: browser)
        open.append(little)
        little.window.center()
        guard front else { return }
        little.window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The small windows open now, newest last — for the bench.
    static var all: [LittleWindow] { open }

    /// Closed as its button closes it — for the bench.
    func close() { window.performClose(nil) }

    /// The small window a key was pressed in, if it was one.
    static func owning(_ window: NSWindow?) -> LittleWindow? {
        guard let window else { return nil }
        return open.first { $0.window === window }
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
        window.contentView = NSHostingView(rootView: LittleView(tab: tab, keep: { [weak self] in self?.keep() }))
    }

    /// Its keys, before the browser's: ⌘O keeps it, Escape and ⌘W close it.
    /// Everything else is the page's.
    func take(_ event: NSEvent) -> Bool {
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

    /// Into the browser's row, after the tab on screen (never among the
    /// pins), and in front; the small window goes.
    func keep() {
        guard let browser else { return }
        kept = true
        browser.insert(tab, at: browser.placeForNew())
        browser.select(tab)
        window.close()
        (Links.window ?? NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) && $0 !== window })?
            .makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !kept { tab.close() }
        LittleWindow.open.removeAll { $0 === self }
    }
}

/// The page, and the line over it.
private struct LittleView: View {
    @ObservedObject var tab: Tab
    let keep: () -> Void

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
                Pill("Open in Search", action: keep)
                    .help("Open in Search   ⌘O")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            WebStage(page: tab.built ?? tab.web)
        }
        .background(Palette.ground)
        .ignoresSafeArea()
    }

    private var site: String {
        guard let url = tab.address else { return "" }
        return SiteCard.site(url)
    }
}
