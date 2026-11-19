import AppKit
import Combine
import SwiftUI

// Ask which space a link from another app opens in (#1175): a panel over that
// app, where the Launcher's field stands, the links waiting to be asked
// about, the keys, and the choice opened in that space; or, with nothing
// opened, Search left as the link found it (see finish). What it lists and
// remembers is LinkChooser's.
//
// The digits are read by where they are on the keyboard, not what they type,
// so a Hebrew layout picks the same rows.

@MainActor
final class LinkChooserPanel: ObservableObject {
    static let shared = LinkChooserPanel()

    /// Every space of every profile, as the Spaces menu lists them.
    @Published private(set) var rows: [LinkChooser.Row] = []
    /// The row Return opens.
    @Published private(set) var marked = 0
    /// Always open the site's links in the space chosen: a rule, as Send
    /// links to a space keeps them.
    @Published var always = false
    /// Only while Send links to a space is on, and for a link with a site.
    @Published private(set) var alwaysShown = false
    @Published private(set) var title = ""
    @Published private(set) var address = ""
    /// The site Always makes a rule for, as SpaceRoutes keeps one.
    @Published private(set) var site: String?
    /// The space chosen went while the link waited.
    @Published private(set) var gone = false
    /// How tall the panel can be on the screen it is on: past that, the
    /// rows scroll.
    @Published private(set) var room: CGFloat?

    private var queue = LinkChooser.Queue()
    /// How the first of the links waiting found Search, for when the last
    /// one goes.
    private var batch: Batch?
    private var panel: LauncherPanel?
    private var watching: [Any] = []

    private struct Batch {
        /// The app it came from.
        let pid: pid_t?
        /// It came while Search was hidden (⌘H).
        let hidden: Bool
        /// It brought Search in front.
        let forward: Bool
        /// One of the links opened from the panel.
        var opened = false
    }

    /// The link asked about now; nil while none waits.
    var link: URL? { queue.current?.url }
    /// The links that came after it.
    var queued: Int { queue.behind }

    func ask(_ url: URL, sender: String?, pid: pid_t? = nil) {
        let waiting = link != nil
        queue.add(url, sender: sender, pid: pid)
        guard waiting else { return start() }
        // Still on the one before: back on screen if ⌘H took it away.
        if panel?.isVisible != true { present() }
    }

    /// The link the app was launched with, on screen now the launch is
    /// over (see present).
    func launched() {
        if link != nil { present() }
    }

    /// A key pressed on the panel. Held down, only an arrow goes on, as it
    /// walks the Launcher's list: any other would open the next link
    /// waiting too.
    func key(_ event: NSEvent) {
        guard !event.isARepeat || [125, 126].contains(event.keyCode) else { return }
        // Only these: an arrow's event has .numericPad and .function on.
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌘W by what it types, as the Launcher reads it: on AZERTY the key
        // where W is types Z.
        if held == .command, event.shortcutCharacters == "w" { return cancel() }
        guard held.isEmpty else { return }
        let code = event.keyCode
        if let digit = LinkChooser.digit(keyCode: code) {
            if let row = LinkChooser.row(forDigit: digit, in: rows) { open(row) }
            return
        }
        switch code {
        case 36, 76: choose(row: marked)
        case 125: mark(by: 1)
        case 126: mark(by: -1)
        case 49: if alwaysShown { always.toggle() }
        case 53: cancel()
        default: break
        }
    }

    /// A row clicked, or the marked one on Return.
    func choose(row index: Int) {
        guard rows.indices.contains(index) else { return }
        open(rows[index])
    }

    /// The link goes unopened, and the next one is asked about: Esc, ⌘W,
    /// or a click beside the panel.
    func cancel() {
        guard link != nil else { return }
        next(handingBack: true)
    }

    // MARK: - asking

    /// The link at the head of the queue, with the rows as they are now.
    private func start() {
        guard let current = queue.current else { return }
        if batch == nil {
            batch = Batch(pid: current.pid, hidden: Links.cameWhileHidden, forward: Links.broughtForward)
        }
        let prefs = Shared.prefs
        let pruned = LinkChooser.pruned(prefs.linkChoices, known: Set(Spaces.known.keys))
        if pruned != prefs.linkChoices { prefs.linkChoices = pruned }
        title = LinkChooser.title(sender: current.sender)
        address = Address.pretty(current.url)
        site = SpaceRoutes.site(of: current.url)
        alwaysShown = prefs.sendsLinksToSpaces && site != nil
        always = false
        gone = false
        listSpaces()
        present()
    }

    /// The rows, and the mark where this site went last, else on the space
    /// in front.
    private func listSpaces() {
        rows = Self.allRows
        marked = LinkChooser.preselected(site: site, rows: rows, memory: Shared.prefs.linkChoices,
                                         front: Browsers.frontBrowser.spaceID)
    }

    /// A row for every space of every profile, in the Spaces menu's order.
    static var allRows: [LinkChooser.Row] {
        LinkChooser.rows(profiles: Profiles.shared.list.map { ($0.id, $0.name) }, spaces: { Spaces.read(profile: $0) })
    }

    /// The arrows reach every row, those with no number too.
    private func mark(by step: Int) {
        guard !rows.isEmpty else { return }
        marked = min(max(marked + step, 0), rows.count - 1)
    }

    /// The next link, or, with none left, the panel goes.
    private func next(handingBack: Bool = false) {
        queue.finishCurrent()
        if queue.current == nil { finish(handingBack: handingBack) } else { start() }
    }

    /// None left. If none of them opened, Search is left as the first found
    /// it: Esc, ⌘W or a click beside the panel goes back to the app it came
    /// from, if it brought Search in front; and one that came while Search
    /// was hidden hides it again, unless something else of Search's is on
    /// screen.
    private func finish(handingBack: Bool) {
        let batch = self.batch
        self.batch = nil
        // Once made, the page room's window is "visible" far off screen, so
        // a window counts only where a screen shows it.
        let alone = !NSApp.windows.contains { window in
            window.isVisible && window !== panel && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        }
        putAway()
        guard let batch, !batch.opened else { return }
        if handingBack, batch.forward, NSApp.isActive { Self.handBack(to: batch.pid) }
        if batch.hidden, alone, Browsers.keptAway, !NSApp.isHidden { Browsers.hideAgain() }
    }

    /// The app the links came from in front again: while it runs, an app
    /// with windows, never Search itself. Unknown or gone, Search stays.
    private static func handBack(to pid: pid_t?) {
        guard let pid, pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, app.activationPolicy == .regular
        else { return }
        app.activate()
    }

    // MARK: - on screen

    /// Never on a run the bench drives: the bench works the controller. Nor
    /// before the app has finished launching: SwiftUI's window, which comes
    /// then and is put away, would take the keys from it.
    private func present() {
        guard !Launcher.benchDriven, Links.launched else { return }
        room = LauncherPanel.room
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A link sent without bringing the app forward finds it still hidden
        // (⌘H), and a hidden app shows none of its windows, this one neither.
        // Shown again without coming forward; the browser's windows that come
        // back with it go again (see Browsers.keepAway).
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.present()
        watch()
    }

    /// As tall as what it shows: the window follows the view.
    private func makePanel() -> LauncherPanel {
        let view = NSHostingView(rootView: LinkChooserView(chooser: self))
        return LauncherPanel(size: view.fittingSize, content: view)
    }

    private func putAway() {
        panel?.orderOut(nil)
        watching.forEach(NSEvent.removeMonitor)
        watching = []
    }

    /// Its keys, before the menus, as the Launcher's: those act on a window
    /// of Search's behind another app. And a click anywhere but on it: in
    /// another app's window, which it never sees, or in one of Search's,
    /// which still gets the click.
    private func watch() {
        guard watching.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.key(event)
            return nil
        }
        let here = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self, event.window !== self.panel { self.clickedOutside() }
            return event
        }
        let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
        watching = [keys, here, elsewhere].compactMap { $0 }
    }

    /// Only while it is on screen: hidden with the app (⌘H), a click cancels
    /// nothing, and the link waits for the panel to be back. Never back to
    /// the app the link came from: the click chose where to go.
    private func clickedOutside() {
        guard panel?.isVisible == true, link != nil else { return }
        next(handingBack: false)
    }

    // MARK: - opening

    /// With Always on, a tab, as the rule will open the site's links from
    /// now on; otherwise where links from other apps open. Remembered only
    /// once it opened: a space that went must not be kept for the site.
    private func open(_ row: LinkChooser.Row) {
        guard let url = link else { return }
        guard Links.open(url, in: row.space, little: !makesRule && Shared.prefs.littleLinks) else { return lost() }
        remember(row.space)
        batch?.opened = true
        next()
    }

    /// Always on, while it is offered.
    private var makesRule: Bool { always && alwaysShown }

    /// Where the site went, for the mark next time; with Always, its rule.
    private func remember(_ space: UUID) {
        guard let site else { return }
        let prefs = Shared.prefs
        prefs.linkChoices = LinkChooser.remembered(prefs.linkChoices, site: site, space: space)
        if makesRule { SpaceRoutes.set(site, to: space) }
    }

    /// Never opened somewhere else instead: the panel says the space is
    /// gone, lists the spaces there are now, and keeps the link.
    private func lost() {
        gone = true
        listSpaces()
    }
}

// MARK: - the panel

/// The link, every space under its profile's name, the switch and the keys,
/// on the Launcher's white: its corners, edge and shadow, and its rows.
private struct LinkChooserView: View {
    @ObservedObject var chooser: LinkChooserPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            spaces
            foot
        }
        .padding(6)
        .frame(width: 360)
        .frame(maxHeight: chooser.room)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        // The card's shadow alone: without it the marked row and each dot
        // cast their own on the white.
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
        .padding(LauncherPanel.margin)
        // A click beside it, in the panel, is a click outside it.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { chooser.cancel() })
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chooser.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(chooser.address)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            if chooser.gone {
                Text("That space is gone. Choose another.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Under each profile's name, once there is more than one. Past the
    /// foot of the screen they scroll, with the marked one kept in sight.
    private var spaces: some View {
        let rows = chooser.rows
        let several = Profiles.shared.several
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.space) { index, row in
                        if several, index == 0 || rows[index - 1].profile != row.profile {
                            Caption(row.profile)
                                .padding(.leading, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 3)
                        }
                        SpaceRow(row: row, marked: index == chooser.marked)
                            .contentShape(Rectangle())
                            .onTapGesture { chooser.choose(row: index) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: chooser.marked, initial: true) { _, marked in
                if chooser.rows.indices.contains(marked) { scroller.scrollTo(chooser.rows[marked].space) }
            }
        }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chooser.alwaysShown, let site = chooser.site {
                HStack(spacing: 8) {
                    Switch(on: $chooser.always)
                    Text("Always open \(site) links here")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(chooser.alwaysShown ? "1–0 or Return opens · Space: Always · Esc cancels" : "1–0 or Return opens · Esc cancels")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .padding(.top, 6)
    }
}

/// A space as the Launcher draws a row, its icon on its colour's wash as
/// the space's dot wears it, and the digit that opens the link there.
private struct SpaceRow: View {
    let row: LinkChooser.Row
    /// Where Return opens it. The pointer gets its own, quieter mark.
    let marked: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.tint ?? Palette.muted)
                .frame(width: SpaceDot.width, height: SpaceDot.width)
                .background(row.tint?.opacity(0.14) ?? .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(row.name)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let digit = row.digit {
                Text(String(digit))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(marked ? Palette.wash : hovering ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
