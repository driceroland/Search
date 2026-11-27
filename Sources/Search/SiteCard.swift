import AppKit
import Combine
import SecurityInterface
import SwiftUI

// The site card: what a click on the tab you are on shows under its address,
// in the column and in the bar across the top alike — whether the connection
// is private, and the few things that belong to the page (copy its address,
// print it, its zoom, whether the blocker works there, whether it may play
// sound by itself, whether its videos float out). Right-click › Site
// Information… opens the same. It goes as soon as you type, when the
// address is left, or when one of its lines is used.
// From #56, whose bar it came with; the bar itself stayed out, since Search
// has the column or the strip, never a second row over the page.

/// The card's own small window, under the tab's address. It never takes the
/// keys: the address stays in the tab being edited, the caret where it was,
/// and a click on the card is only a click.
@MainActor
enum SiteCardPanel {
    private static var panel: Panel?
    private static var resign: Any?

    static var isShown: Bool { panel != nil }
    /// The tab the card that is up is about.
    private(set) static weak var shownTab: Tab?

    // MARK: - a pin's square

    /// A pin drawn as a square has no address to open, so the card hangs
    /// from the square itself (idea 1081): where each square is in its
    /// window, from the top left, as the square last measured itself.
    /// Kept as a place rather than as a view of the square's own: SwiftUI
    /// let go of those views as it drew the squares again — for a pin
    /// brought back at launch, the one you are on, or one put down — and
    /// Site Information… did nothing on them (idea 1118).
    private static var squares: [Tab.ID: (frame: CGRect, owner: UUID)] = [:]
    /// What the card hangs from under a square: a view of no size to speak
    /// of, never hit, moved onto the square each time.
    private static var mark: NSView?

    /// The square's place in `window`, made into a view the card can hang
    /// from; nil when the square isn't drawn there.
    static func square(for id: Tab.ID, in window: NSWindow?) -> NSView? {
        guard let window, let content = window.contentView, let frame = squares[id]?.frame,
              frame.width > 0, frame.height > 0 else { return nil }
        let rect = content.isFlipped ? frame
            : CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        guard content.bounds.intersects(rect) else { return nil }
        let view = mark ?? Spot()
        mark = view
        if view.superview !== content { view.removeFromSuperview(); content.addSubview(view) }
        view.frame = rect
        return view
    }

    /// Whether `id` has a square drawn somewhere to hang the card from.
    static func hasSquare(_ id: Tab.ID) -> Bool { squares[id] != nil }

    /// On a pin's square (or a tile of the column of icons): says where it
    /// is, for its card. The map of every space's rows draws the squares
    /// too, and leaves this out.
    struct Square: ViewModifier {
        let id: Tab.ID
        /// Off for a square only drawn, as another space's are.
        var on = true
        @State private var me = UUID()
        @State private var frame = CGRect.zero
        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { now in
                    frame = now
                    if on { squares[id] = (now, me) }
                }
                .onChange(of: on) { _, on in
                    if on { squares[id] = (frame, me) } else if squares[id]?.owner == me { squares[id] = nil }
                }
                // Another tab come into this square (Browser.rowKey).
                .onChange(of: id) { was, now in
                    if on, let seen = squares[was], seen.owner == me {
                        squares[was] = nil
                        squares[now] = seen
                    }
                }
                .onDisappear { if squares[id]?.owner == me { squares[id] = nil } }
        }
    }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The card under a pin's square, from its menu's Site Information…;
    /// a click anywhere but the card puts it away, as the address bar's
    /// button's does.
    static func show(for tab: Tab, in browser: Browser) {
        // After the edit any other tab had is let go of (follow hides the
        // card as an edit ends), so this card isn't put away with it; and
        // where the square is once picking it has settled.
        DispatchQueue.main.async {
            guard let square = square(for: tab.id, in: browser.window) else { return }
            toggle(for: tab, in: browser, under: square, button: square)
        }
    }

    /// Where the card is and the field with the caret it should hang from,
    /// on the screen, for the bench: [x, y, width, height] each.
    static func geometry(_ browser: Browser) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let rect = { (r: NSRect) in [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        if let panel { out["card"] = rect(panel.frame) }
        if let window = browser.window ?? Links.window { out["window"] = rect(window.frame) }
        if let window = browser.window ?? Links.window,
           let field = (window.firstResponder as? NSTextView)?.delegate as? NSTextField ?? anchor, field.window != nil {
            out["field"] = rect(window.convertToScreen(field.convert(field.bounds, to: nil)))
        }
        return out
    }

    // MARK: - when

    /// The field the address is being edited in. SwiftUI can make it and
    /// throw it away several times as the edit begins, so the card follows
    /// the browser's edit rather than any one field, and stands under the one
    /// with the caret.
    private static weak var anchor: NSView?
    private static var watching: [ObjectIdentifier: AnyCancellable] = [:]
    /// The address as the edit began with it.
    private static var original: String?

    static func follow(_ browser: Browser, anchor field: NSView) {
        anchor = field
        let key = ObjectIdentifier(browser)
        guard watching[key] == nil else { return }
        watching[key] = browser.$editingTab.combineLatest(browser.$tabDraft)
            .receive(on: DispatchQueue.main)
            .sink { [weak browser] editing, draft in
                MainActor.assumeIsolated {
                    guard let browser else { return }
                    guard let id = editing, !browser.renamingTab,
                          let tab = browser.tabs.first(where: { $0.id == id }), tab.isWeb
                    else { original = nil; hide(); return }
                    if original == nil {
                        // The edit began: the card comes up under the field once it
                        // is in its window.
                        original = draft
                        if browser.tabEditCard { place(tab, browser, tries: 0) }
                    } else if draft != original {
                        // Typing somewhere else: the card was about the page you are on.
                        hide()
                    }
                }
            }
    }

    /// Shown once the field it hangs from is on the window and has stopped
    /// moving: the same place at two looks a moment apart. A double-click
    /// on a tab you aren't on picks it with the first click and opens its
    /// address with the second, while the row is still settling around the
    /// tab now in front, and the field may not be where it ends up yet: the
    /// card came up near the middle of the screen (#1310).
    private static func place(_ tab: Tab, _ browser: Browser, tries: Int, last: NSRect? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard original != nil, browser.editingTab == tab.id, browser.tabDraft == original else { return }
            guard let field = field(in: browser), let spot = spot(of: field) else {
                if tries < 15 { place(tab, browser, tries: tries + 1) }
                return
            }
            if spot != last, tries < 15 { return place(tab, browser, tries: tries + 1, last: spot) }
            show(for: tab, in: browser, under: field)
            keepUnder(browser)
        }
    }

    /// The field with the caret in it, the one on screen; failing that, the
    /// latest one made.
    private static func field(in browser: Browser) -> NSView? {
        let focused = ((browser.window ?? Links.window)?.firstResponder as? NSTextView)?.delegate as? NSTextField
        return focused ?? anchor
    }

    /// Where `field` is on the screen, when it is somewhere the card can hang
    /// from: in a window, shown, with a size, and inside the window's content.
    private static func spot(of field: NSView) -> NSRect? {
        guard let window = field.window, !field.isHiddenOrHasHiddenAncestor, !field.bounds.isEmpty,
              let content = window.contentView else { return nil }
        let inWindow = field.convert(field.bounds, to: nil)
        guard content.frame.intersects(inWindow), !field.visibleRect.isEmpty else { return nil }
        return window.convertToScreen(inWindow)
    }

    /// While the card is up, it goes where the field goes: the row moving on
    /// as a tab opens, closes or settles beside it.
    private static var follower: Timer?
    private static func keepUnder(_ browser: Browser) {
        follower?.invalidate()
        follower = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak browser] _ in
            MainActor.assumeIsolated {
                guard let browser, let panel, let field = field(in: browser), let spot = spot(of: field) else { return }
                let (origin, _) = placement(panel.frame.size, under: spot, on: field.window?.screen)
                if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            }
        }
    }

    /// Under the address, lined up with the tab's own edge — or over it,
    /// for a tab too near the bottom of the screen to have the room. Only
    /// ever beside the field: pushed up onto it, the card covered the
    /// address being edited, and what was typed there with it. True when
    /// it is over the field.
    private static func placement(_ size: NSSize, under spot: NSRect, on screen: NSScreen?) -> (NSPoint, Bool) {
        var origin = NSPoint(x: spot.minX - 12, y: spot.minY - 12 - size.height)
        var above = false
        if let screen = screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            if origin.y < screen.minY + 8 {
                above = true
                origin.y = min(spot.maxY + 12, screen.maxY - size.height - 8)
            }
        }
        return (origin, above)
    }

    /// From a button of its own, the address bar's (AddressLine.swift): the
    /// card under `line`, or put away if it is up. There is no edit to end
    /// it there, so a click anywhere but the card, or the button again,
    /// puts it away.
    static func toggle(for tab: Tab, in browser: Browser, under line: NSView, button: NSView) {
        guard !isShown else { return hide() }
        show(for: tab, in: browser, under: line)
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak button] event in
            MainActor.assumeIsolated {
                // The button's own click toggles it; the card's is the card's.
                let onButton = button.map { $0.window === event.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if event.window !== panel, !onButton { hide() }
            }
            return event
        }
    }
    private static var clicks: Any?

    /// Under `field`, the tab's address, in `browser`'s window.
    private static func show(for tab: Tab, in browser: Browser, under field: NSView) {
        guard let window = field.window else { return }
        hide()
        shownTab = tab
        let card = SiteCard(browser: browser, tab: tab) {
            SiteCardPanel.hide()
            browser.cancelTabEdit()
        }
        let host = FirstClick(rootView: AnyView(card.fixedSize()))
        let size = host.fittingSize
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = MenuMetrics.corner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = MenuMetrics.edge.cgColor
        // The material behind the window ignores the layer's corners: a pale
        // square showed past each rounded one, before macOS 26 and on it too.
        // A mask rounds the material, and the window's shadow with it.
        glass.maskImage = Self.rounded(MenuMetrics.corner)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        let (origin, above) = placement(size, under: window.convertToScreen(field.convert(field.bounds, to: nil)), on: window.screen)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        // Its size follows the card, keeping the edge nearest the address
        // where it is.
        host.onResize = { [weak panel] fitted in
            guard let panel, fitted.width > 0, fitted.height > 0,
                  panel.frame.size != fitted else { return }
            var frame = panel.frame
            if !above { frame.origin.y += frame.height - fitted.height }
            frame.size = fitted
            panel.setFrame(frame, display: true)
        }
        self.panel = panel
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SiteCardPanel.hide() }
        }
    }

    /// A rounded rectangle that stretches to any size, its corners kept.
    private static func rounded(_ corner: CGFloat) -> NSImage {
        let side = corner * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }

    static func hide() {
        shownTab = nil
        follower?.invalidate()
        follower = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click even though its window never becomes key, and
    /// says when what it shows changes size.
    private final class FirstClick: NSHostingView<AnyView> {
        var onResize: ((NSSize) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func layout() {
            super.layout()
            // SwiftUI can lay out a different card without invalidating the
            // host's intrinsic size. Measure after layout and resize outside it.
            let fitted = fittingSize
            let size = NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
            guard size != frame.size else { return }
            DispatchQueue.main.async { [weak self] in self?.onResize?(size) }
        }
    }
}

/// The site the tab is on: how private the connection is, and the few things
/// that belong to this page rather than to the browser. The connection's line
/// goes a step further in, to what it means and the certificate behind it.
struct SiteCard: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let close: () -> Void

    /// One step in: the connection, said in full.
    @State private var deeper: Bool
    @State private var showingPermissions = false
    @ObservedObject private var notifications = SiteNotifications.shared
    /// Whether this Mac trusts the site's certificate. Unknown until it has
    /// been asked, off the main thread: asking can go to the network.
    @State private var certified: Bool?

    init(browser: Browser, tab: Tab, deeper: Bool = false, close: @escaping () -> Void) {
        self.browser = browser
        self.prefs = browser.prefs
        self.tab = tab
        self.close = close
        _deeper = State(initialValue: deeper)
    }

    var body: some View {
        Group {
            if showingPermissions {
                permissions
            } else if deeper, let safety {
                security(safety)
            } else {
                front
            }
        }
        .padding(.vertical, MenuMetrics.pad)
        .frame(minWidth: 180)
        .fixedSize()
        .transition(.opacity)
        .animation(Motion.quick, value: deeper)
        .onAppear(perform: certify)
    }

    /// The host as a person says it, without the www. A page with no host —
    /// a file, about:blank — is named by what it is.
    static func site(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }

    // MARK: - the card, drawn as the system draws a menu

    private var front: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.pageAddress {
                Header(title: SiteCard.site(url))
            }
            if let safety {
                Row(safety.title, submenu: true) { deeper = true }
            }
            Row("Copy Address", keys: ShortcutStore.shared.key(for: "tabs.copyAddress")?.display ?? "") { after { browser.copyAddress() } }
            Separator()
            Row("Print…", keys: ShortcutStore.shared.key(for: "file.print")?.display ?? "") { after { browser.printPage() } }
            zoom
            blocker
            if let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Row("Site Permissions", submenu: true) { showingPermissions = true }
            }
            sound
            grounded
            darken
            if DevMode.host(of: tab.pageAddress) != nil {
                Developer(tab: tab)
            }
            if prefs.keepsSitesAwake, tab.awakeHost != nil {
                HStack(spacing: 0) {
                    Text("Keep This Site Awake").font(MenuMetrics.font)
                    Spacer(minLength: 24)
                    Switch(on: Binding(get: { browser.keepsAwake(tab) }, set: { browser.keepAwake($0, for: tab) }))
                        .accessibilityRepresentation {
                            Toggle("Keep This Site Awake", isOn: Binding(get: { browser.keepsAwake(tab) }, set: { browser.keepAwake($0, for: tab) }))
                        }
                        .focusable()
                        .onKeyPress(.space) { browser.keepAwake(!browser.keepsAwake(tab), for: tab); return .handled }
                }
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .frame(height: MenuMetrics.row)
                .help(tab.shy ? "Only in this private tab, until it closes. Uses more memory." : "Prevents sleep and automatic closure, even when memory is low. You can still close the tab.")
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        if let url = tab.pageAddress, let scheme = url.scheme, let host = url.host() {
            let origin = Browser.origin(scheme, host, url.port ?? 0)
            VStack(alignment: .leading, spacing: 0) {
                Header(title: origin)
                if tab.shy {
                    Text("Permissions aren't saved in a private tab.")
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, MenuMetrics.text).padding(.vertical, 8)
                } else {
                    ForEach([CaptureChoices.Kind.camera, .microphone, .location, .notifications]) { kind in
                        HStack {
                            Text(kind.title).font(MenuMetrics.font)
                            Spacer(minLength: 24)
                            Menu {
                                Button("Ask") { browser.setSitePermission(nil, kind: kind, origin: origin) }
                                Button("Allow") { browser.setSitePermission(true, kind: kind, origin: origin) }
                                    .disabled(kind == .notifications && !prefs.siteNotifications)
                                Button("Refuse") { browser.setSitePermission(false, kind: kind, origin: origin) }
                            } label: {
                                Text(CaptureChoices.choice(kind, origin: origin).title)
                                    .font(MenuMetrics.font)
                            }
                            .accessibilityLabel("\(kind.title): \(CaptureChoices.choice(kind, origin: origin).title)")
                            .menuStyle(.borderlessButton).fixedSize()
                        }.padding(.horizontal, MenuMetrics.text).frame(height: MenuMetrics.row)
                    }
                    if !prefs.siteNotifications {
                        Text("Notifications are off in Settings › Privacy.")
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 230, alignment: .leading)
                            .padding(.horizontal, MenuMetrics.text).padding(.vertical, 6)
                    }
                    if [CaptureChoices.Kind.camera, .microphone, .location, .notifications].contains(where: { CaptureChoices.choice($0, origin: origin) == .different }) {
                        Text("Saved two ways for this site. Pick one to keep.")
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 230, alignment: .leading)
                            .padding(.horizontal, MenuMetrics.text).padding(.vertical, 6)
                    }
                }
                Separator()
                Row("Back") { showingPermissions = false }
            }
        }
    }

    /// Whether the site's videos float out on their own (see Grounded).
    /// Only on a streaming site, or one playing a video now (they float
    /// from any site since idea 1248), with one of Settings › General's
    /// Float the video switches on, and not in a private tab.
    @ViewBuilder private var grounded: some View {
        if !tab.shy, browser.prefs.floatsOnLeave || browser.prefs.floatsAway,
           let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased()),
           Players.knows(url) || tab.playingVideo || tab.noisy, let host = url.host() {
            Ground(host: host)
        }
    }

    /// Whether Search darkens the site (see Dusk.swift), a switch like the
    /// sound's. Only while dark pages are on and doing something: not
    /// paused, and the frame dark. It takes effect on the page at once.
    @ViewBuilder private var darken: some View {
        if browser.canDusk(tab) {
            Darken(on: Binding(get: { tab.dusked }, set: { browser.dusk($0, tab) }))
        }
    }

    /// Whether the blocker works on this site (see Shield.pause), a switch
    /// like the sound's. Only with the blocker on and nothing wrong with it,
    /// and not in a private tab, which remembers nothing. The page reloads,
    /// as the blocker is decided for a page as it starts (#861).
    @ViewBuilder private var blocker: some View {
        if let host = Self.blockerHost(tab, browser) {
            Blocker(host: host) { tab.reload() }
        }
    }

    /// The site the blocker line is about, when the card has that line.
    static func blockerHost(_ tab: Tab, _ browser: Browser) -> String? {
        guard !tab.shy, browser.prefs.shielded, Shield.shared.trouble == nil,
              let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return browser.curtain.host(of: url)
    }

    /// Whether the site may play sound by itself (see Autoplay), a switch at
    /// the end of its line. Not in a private tab, which remembers nothing,
    /// nor with Settings › Videos wait for a click on, which lets no site.
    @ViewBuilder private var sound: some View {
        if !tab.shy, !Store.settings.bool(forKey: Preferences.waitsKey),
           let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased()),
           let host = url.host() {
            Sound(host: host)
        }
    }

    /// The page's size, remembered for the site (see Tab.rememberZoom), as a
    /// menu puts a control on one of its lines: the name, and the steps at
    /// its end. The number puts it back to the size every site starts at.
    private var zoom: some View {
        HStack(spacing: 0) {
            Text("Zoom")
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
            Spacer(minLength: 24)
            Step(symbol: "minus", help: "Zoom Out", shortcut: "view.zoomOut") { browser.zoom(by: 1 / 1.1) }
            Button { browser.resetZoom() } label: {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(MenuMetrics.font)
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutHelp("Actual Size", "view.actualSize")
            Step(symbol: "plus", help: "Zoom In", shortcut: "view.zoomIn") { browser.zoom(by: 1.1) }
        }
        .padding(.leading, MenuMetrics.text)
        .padding(.trailing, MenuMetrics.inset + 4)
        .frame(height: MenuMetrics.row)
    }

    /// The line itself. WebKit takes it as a page loads, so a page already
    /// open stays as it came, and the line says so once flipped.
    private struct Sound: View {
        let host: String
        private let was: Bool
        @State private var on: Bool

        init(host: String) {
            self.host = host
            was = Autoplay.allowed(host)
            _on = State(initialValue: was)
        }

        var body: some View {
            HStack(spacing: 0) {
                Text("Play Sound by Itself")
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                Spacer(minLength: 24)
                if on != was {
                    Text("from the next page")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                        .padding(.trailing, 8)
                }
                Switch(on: $on)
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.trailing)
            .frame(height: MenuMetrics.row)
            .onChange(of: on) { _, value in Autoplay.set(value, for: host) }
        }
    }

    /// Its line: on is the blocker at work here.
    private struct Blocker: View {
        let host: String
        let reload: () -> Void
        @State private var on: Bool

        init(host: String, reload: @escaping () -> Void) {
            self.host = host
            self.reload = reload
            _on = State(initialValue: !Shield.shared.isPaused(on: host))
        }

        var body: some View {
            HStack(spacing: 0) {
                Text("Block Ads and Trackers")
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                Spacer(minLength: 24)
                Switch(on: $on)
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.trailing)
            .frame(height: MenuMetrics.row)
            .help("Turn off here if the site breaks; the page reloads")
            .onChange(of: on) { _, value in
                Shield.shared.pause(host, !value)
                reload()
            }
        }
    }

    /// Its line. Asked each time a video would float, so it holds at once,
    /// for the page already open too.
    private struct Ground: View {
        let host: String
        @State private var on: Bool

        init(host: String) {
            self.host = host
            _on = State(initialValue: Grounded.holds(host))
        }

        var body: some View {
            HStack(spacing: 0) {
                Text("Don't Float Videos Here")
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                Spacer(minLength: 24)
                Switch(on: $on)
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.trailing)
            .frame(height: MenuMetrics.row)
            .onChange(of: on) { _, value in Grounded.set(value, for: host) }
        }
    }

    private struct Darken: View {
        @Binding var on: Bool

        var body: some View {
            HStack(spacing: 0) {
                Text("Darken This Site")
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                Spacer(minLength: 24)
                // The key as it is now: Settings › Shortcuts can move it.
                if let keys = ShortcutStore.shared.key(for: "view.dusk")?.display {
                    Text(keys)
                        .font(MenuMetrics.font)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                        .padding(.trailing, 8)
                }
                Switch(on: $on)
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.trailing)
            .frame(height: MenuMetrics.row)
        }
    }

    /// Developer Mode for the site (DevMode.swift): its bar over the page,
    /// at once.
    private struct Developer: View {
        @ObservedObject var tab: Tab
        @ObservedObject private var mode = DevMode.shared

        var body: some View {
            HStack(spacing: 0) {
                Text("Developer Mode")
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                Spacer(minLength: 24)
                if let keys = ShortcutStore.shared.key(for: "view.developerMode")?.display {
                    Text(keys)
                        .font(MenuMetrics.font)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                        .padding(.trailing, 8)
                }
                Switch(on: Binding(get: { mode.isOn(tab) }, set: { mode.set($0, for: tab.pageAddress, shy: tab.shy) }))
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.trailing)
            .frame(height: MenuMetrics.row)
            .help("The page's whole address and quick tools: Web Inspector, reload ignoring cache, cache off")
        }
    }

    // MARK: - one step in

    private func security(_ safety: Safety) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.pageAddress {
                Header(title: SiteCard.site(url))
            }
            Text(safety.title)
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.leading, MenuMetrics.text)
                .frame(height: MenuMetrics.row, alignment: .leading)
            Text(safety.detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .padding(.bottom, 6)
            Separator()
            if let trust = safety.trust {
                Row(certified == false ? "Show Certificate (Not Valid)…" : "Show Certificate…") {
                    after { SiteCard.show(trust) }
                }
            }
            Row("Back") { deeper = false }
        }
    }

    // MARK: - the connection

    /// What there is to say about the connection, from a page's own address
    /// and what WebKit knows of how it came.
    private struct Safety {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        /// The certificate the page came with, for an https page.
        let trust: SecTrust?
    }

    /// Asked when the card opens: a page that pulls in something over plain
    /// http after that is not worth a card that changes under you.
    private var safety: Safety? {
        switch tab.pageAddress?.scheme {
        case "https":
            let trust = tab.built?.serverTrust
            // Only a certificate this Mac refused and you let through anyway
            // (see Dialogs.trust) gets this far untrusted.
            if certified == false {
                return Safety(
                    symbol: "lock.open", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            if tab.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Parts of this page are not secure",
                    detail: "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            return Safety(
                symbol: "lock", title: "Connection is secure",
                detail: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
                tint: Palette.safe, trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
                tint: Palette.unsafe, trust: nil
            )
        default:
            return nil
        }
    }

    /// Asks whether this Mac trusts the certificate, the way it would for
    /// any app. Off the main thread: the answer can need a revocation check.
    private func certify() {
        guard certified == nil, let trust = tab.built?.serverTrust else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async { certified = ok }
        }
    }

    /// The system's own certificate sheet, over the window.
    private static func show(_ trust: SecTrust) {
        guard let window = Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }

    /// The card goes first, then the thing is done: a print panel or a sheet
    /// coming up under a popover still on its way out lands behind it.
    private func after(_ act: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: act)
    }

    /// One line, as a menu item draws it: its title in the menu's font where
    /// a menu puts its text, a key equivalent at the end, the accent colour
    /// behind it and white letters under the pointer. A line that opens more
    /// ends in the submenu's chevron.
    private struct Row: View {
        let title: String
        var keys = ""
        var submenu = false
        let act: () -> Void

        @State private var hovering = false

        init(_ title: String, keys: String = "", submenu: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.keys = keys
            self.submenu = submenu
            self.act = act
        }

        var body: some View {
            HStack(spacing: 0) {
                Text(title)
                    .font(MenuMetrics.font)
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: keys.isEmpty ? 24 : 26)
                if !keys.isEmpty {
                    Text(keys)
                        .font(MenuMetrics.font)
                        .foregroundStyle(hovering ? Color.white : Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                }
                if submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Color.white : Color(nsColor: .secondaryLabelColor))
                }
            }
            .padding(.leading, MenuMetrics.text - MenuMetrics.inset)
            .padding(.trailing, MenuMetrics.trailing - MenuMetrics.inset)
            .frame(height: MenuMetrics.row)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.highlight, style: .continuous)
                    .fill(hovering ? MenuMetrics.selection : .clear)
            )
            .padding(.horizontal, MenuMetrics.inset)
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }

    /// The site's name over the lines, as a menu's section header is drawn.
    private struct Header: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .frame(height: MenuMetrics.row, alignment: .leading)
        }
    }

    /// A menu's separator: a hairline in its own band.
    private struct Separator: View {
        var body: some View {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.horizontal, MenuMetrics.rule)
                .frame(height: MenuMetrics.separator)
        }
    }

    /// A step of the zoom: the symbol alone, on the accent colour under the
    /// pointer as a menu's line would be.
    private struct Step: View {
        let symbol: String
        let help: String
        var shortcut: String? = nil
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .labelColor))
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hovering ? MenuMetrics.selection : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .shortcutHelp(help, shortcut)
        }
    }
}

/// A menu's measurements, as macOS lays out an NSMenu (measured from one:
/// NSMenu.size with the same items), so the card sits beside the tab's
/// right-click menu as one of its own.
enum MenuMetrics {
    static let font = Font(NSFont.menuFont(ofSize: 0))
    /// One item.
    static let row: CGFloat = 24
    /// A separator's band.
    static let separator: CGFloat = 11
    /// Above the first item and under the last.
    static let pad: CGFloat = 5
    /// Where the highlight starts, from the menu's edge.
    static let inset: CGFloat = 5
    /// Where an item's text starts, from the menu's edge: a context menu
    /// without a checkmark column, as the tab's right-click is.
    static let text: CGFloat = 17
    /// From the end of the text, or of its key equivalent, to the menu's edge.
    static let trailing: CGFloat = 17
    /// A separator's line, in from either edge.
    static let rule: CGFloat = 16
    static let highlight: CGFloat = 6
    static let corner: CGFloat = 12
    /// The line under the pointer: the accent colour as a menu shows it over
    /// its glass, lighter than the accent itself (111, 162, 249 for blue).
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accent.blended(withFraction: 0.15, of: .black) ?? accent
            : accent.blended(withFraction: 0.42, of: .white) ?? accent
    })
    /// The panel's hairline edge.
    static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.26)
    }
}

extension Browser {
    /// Whether a tab's menu offers Site Information…: a tab with a page,
    /// a pin's too (idea 1081), whose blocker and the rest were out of reach.
    static func offersSiteInformation(_ tab: Tab) -> Bool {
        !tab.isBlank && tab.address != nil
    }

    /// The tab's menu › Site Information…: the card a click on the tab you
    /// are on shows under its address. A pin drawn as a square has no
    /// address to open, and its own click goes back to its page: the card
    /// hangs from the square instead.
    func showSiteInformation(_ tab: Tab) {
        if activeID != tab.id { select(tab) }
        // The column of icons has no address in a tile either: the card
        // hangs from the tile, as from a square.
        if tab.pin != nil || prefs.iconColumn, SiteCardPanel.hasSquare(tab.id) {
            if editingTab != nil { cancelTabEdit() }
            SiteCardPanel.show(for: tab, in: self)
        } else {
            beginTabEdit(tab, card: true)
        }
    }
}
