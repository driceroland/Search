import SwiftUI
import WebKit

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
    /// The three buttons as they look with the app behind another, drawn
    /// by hand as the browser's window draws them (see RestingLights).
    private let resting = RestingLights()
    private var watching: [Any] = []

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
        // The lights centred on the line, as far in from the side as down
        // from the top, as the button is at the other end (see Lights.swift).
        let centre = LittleView.line / 2
        Lights.keep(window, centreX: { centre }, centreY: centre, height: LittleView.line) { [weak self] in
            self?.rest()
        }
        // macOS's own, with the app behind another, come out nearly white
        // on a light page: the small window's line is the page, so it is
        // light as often as the page is.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rest() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.rest() }
    }

    /// The resting circles in the title bar, exactly over the buttons, and
    /// showing only while the app is behind another.
    private func rest() {
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        if resting.superview !== titlebar {
            resting.frame = titlebar.bounds
            resting.autoresizingMask = [.width, .height]
            titlebar.addSubview(resting, positioned: .above, relativeTo: nil)
        }
        resting.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        resting.isHidden = NSApp.isActive
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
    /// and the page's own commands — copying its address, reloading it —
    /// act on this page, on whatever keys Settings › Shortcuts gives them.
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
        // The browser's window has no line over its page to leave room for.
        if #available(macOS 26, *) { tab.built?.obscuredContentInsets = NSEdgeInsetsZero }
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
        Lights.forget(window)
        for observer in watching { NotificationCenter.default.removeObserver(observer) }
        watching = []
        if !kept { tab.close() }
        LittleWindow.open.removeAll { $0 === self }
    }
}

/// The page, and the line over it: the site, and Open in Search when there
/// is somewhere to keep it (an extension's popup window has no such button).
///
/// The line wears the page's own colour, found as Safari finds it (see
/// PageTint), so the window reads as the page and not as a frame around it. On macOS 26 the page runs to the top edge, under the line,
/// which is glass: what scrolls up goes on showing through it, blurred, as
/// under Safari's bar.
struct LittleView: View {
    @ObservedObject var tab: Tab
    /// Its window's line at the foot; an extension's popup has none.
    var note: LittleNote? = nil
    let keep: (() -> Void)?
    @StateObject private var tint = PageTint()

    /// The line's height: Open in Search with the same room above, below
    /// and beside it, and the window's own buttons moved down to sit
    /// centred on it (see LittleWindow.init).
    static let line: CGFloat = KeepButton.height + 2 * LittleView.inset
    /// The room around Open in Search, the same on its three open sides.
    static let inset: CGFloat = 6

    var body: some View {
        stage
            .background(tint.ground)
            .overlay(alignment: .bottom) { if let note { LittleToast(note: note) } }
            .ignoresSafeArea()
            .onAppear { settle(page) }
            .onChange(of: ObjectIdentifier(page)) { _, _ in settle(page) }
    }

    @ViewBuilder
    private var stage: some View {
        if #available(macOS 26, *) {
            ZStack(alignment: .top) {
                WebStage(page: page)
                bar.background(alignment: .top) { band }
            }
        } else {
            VStack(spacing: 0) {
                bar.background(tint.ground)
                WebStage(page: page)
            }
        }
    }

    private var page: PageView { tab.built ?? tab.web }

    /// The site in the middle, the button at the end, and the rest of the
    /// line a title bar: it drags the window and zooms it on a double-click.
    private var bar: some View {
        HStack(spacing: 10) {
            // Room for the window's own buttons, which sit on this line.
            Spacer().frame(width: 64)
            Spacer(minLength: 0)
            Text(site)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let keep {
                KeepButton(action: keep)
                    .help("Open in Search   ⌘O")
            } else {
                Spacer().frame(width: 64)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, LittleView.inset)
        .frame(height: LittleView.line)
        // Under the button, not on it: a real view takes the click first.
        .background { DragStrip(trailing: keep == nil ? 0 : 124) }
        .environment(\.colorScheme, tint.scheme ?? colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Behind the line: the page, blurred, under a thin wash of its own
    /// colour, as macOS 26's soft scroll edge is — no rule, and no colour
    /// the page doesn't have: it eases out over the first points below the
    /// line, so what scrolls up goes soft before it goes under.
    @available(macOS 26, *)
    private var band: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(tint.ground.opacity(0.5))
        }
        .frame(height: LittleView.line + LittleView.fade)
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.55),
                .init(color: .black.opacity(0.6), location: 0.75),
                .init(color: .black.opacity(0.2), location: 0.9),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .environment(\.colorScheme, tint.scheme ?? colorScheme)
        .allowsHitTesting(false)
    }

    /// How far below the line the soft edge reaches.
    static let fade: CGFloat = 18

    /// Watches the page's colour, and on macOS 26 tells it the line covers
    /// its top: it lays out below the line and keeps fixed headers there,
    /// while what scrolls goes on up underneath.
    private func settle(_ page: PageView) {
        tint.watch(page)
        if #available(macOS 26, *) {
            page.obscuredContentInsets = NSEdgeInsets(top: LittleView.line, left: 0, bottom: 0, right: 0)
        }
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

/// Open in Search: a drop of glass on macOS 26, as the system's own buttons
/// are there; a quiet capsule before it. Either way it takes the line's
/// light or dark from the page, not from the app.
private struct KeepButton: View {
    static let height: CGFloat = 24
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Button(action: action) {
                label.background(.primary.opacity(hovering ? 0.14 : 0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    private var label: some View {
        Text("Open in Search")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: KeepButton.height)
            .contentShape(Capsule())
    }
}

/// The page's colour, as Safari finds it for its bar: the colour along
/// the page's top edge, when the top edge is one colour, and the colour the
/// page is on otherwise.
///
/// WebKit samples that edge itself (PageColorSampler, a handful of points
/// across the top, kept only if they agree), but hands the answer only to
/// Safari, through a private property. So it is done again here the same
/// way, from a snapshot of a thin strip at the top of the page, once a page
/// has drawn. A site's theme-color is not asked: GitHub names a near-black
/// one over a white page, and the line came out dark over it.
@MainActor
private final class PageTint: ObservableObject {
    @Published private(set) var colour: NSColor?
    private weak var page: WKWebView?
    private var watching: [NSKeyValueObservation] = []
    /// The top edge's colour when it has one, from the last snapshot.
    private var edge: NSColor?
    private var ticket = 0

    /// Where across the edge it is looked at, as fractions of the width.
    private static let spots: [CGFloat] = [0.03, 0.25, 0.5, 0.75, 0.97]
    /// How far apart, in sRGB, two spots may be and still be one colour.
    private static let tolerance: CGFloat = 0.06

    var ground: Color { colour.map(Color.init(nsColor:)) ?? Palette.ground }

    /// Dark or light to go on it: whichever of white and black text reads
    /// better on it, by the WCAG contrast ratio, the measure the system's
    /// own accessibility checks use. Nil until there is a page, and the
    /// app's own until then.
    var scheme: ColorScheme? {
        guard let rgb = colour?.usingColorSpace(.sRGB) else { return nil }
        // Relative luminance, from the gamma-encoded components.
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        let onWhite = 1.05 / (lum + 0.05), onBlack = (lum + 0.05) / 0.05
        return onWhite > onBlack ? .dark : .light
    }

    func watch(_ page: WKWebView) {
        guard page !== self.page else { return }
        self.page = page
        edge = nil
        // A page finishing, and a page changing its own background, are
        // when its top can have changed colour.
        watching = [
            page.observe(\.isLoading) { [weak self] _, _ in
                DispatchQueue.main.async { self?.lookSoon() }
            },
            page.observe(\.underPageBackgroundColor) { [weak self] _, _ in
                DispatchQueue.main.async { self?.lookSoon() }
            },
        ]
        lookSoon()
    }

    /// A moment after the page settles, so it has drawn what it loaded;
    /// only the last of several asks in a row looks.
    private func lookSoon() {
        settle()
        ticket += 1
        let ticket = ticket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, ticket == self.ticket else { return }
            self.look()
        }
    }

    private func look() {
        guard let page, page.bounds.width > 40, page.bounds.height > 40 else { return }
        var top: CGFloat = 0
        if #available(macOS 26, *) { top = page.obscuredContentInsets.top }
        let strip = WKSnapshotConfiguration()
        strip.rect = CGRect(x: 0, y: top, width: page.bounds.width, height: 4)
        strip.afterScreenUpdates = false
        page.takeSnapshot(with: strip) { [weak self, weak page] image, _ in
            guard let self, page === self.page else { return }
            self.edge = image.flatMap(PageTint.oneColour)
            self.settle()
        }
    }

    private func settle() {
        guard let page else { return }
        let now = edge ?? page.underPageBackgroundColor
        if now != colour { colour = now }
    }

    /// The strip's colour, if every spot across it is the same one.
    private static func oneColour(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        let row = bitmap.pixelsHigh / 2
        let seen = spots.compactMap { at -> NSColor? in
            let x = min(bitmap.pixelsWide - 1, Int(CGFloat(bitmap.pixelsWide) * at))
            return bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)
        }
        guard seen.count == spots.count else { return nil }
        let n = CGFloat(seen.count)
        let mean = (r: seen.map(\.redComponent).reduce(0, +) / n,
                    g: seen.map(\.greenComponent).reduce(0, +) / n,
                    b: seen.map(\.blueComponent).reduce(0, +) / n)
        for colour in seen {
            let dr = colour.redComponent - mean.r, dg = colour.greenComponent - mean.g, db = colour.blueComponent - mean.b
            if (dr * dr + dg * dg + db * db).squareRoot() > tolerance { return nil }
        }
        return NSColor(srgbRed: mean.r, green: mean.g, blue: mean.b, alpha: 1)
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
