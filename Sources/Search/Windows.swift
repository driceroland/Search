import AppKit
import Combine
import SwiftUI

// Several windows, each with its tabs (Drice: "un search dans une window et
// un nouveau search dans une autre window").
//
// Each window has a Browser of its own: its tabs, its
// field and panels. What every window shares lives in `Shared` — settings,
// History, bookmarks, downloads — and the pins are the same everywhere.
//
// The first window is SwiftUI's scene, as it always was; any other is an
// AppKit window around the same ContentView. With one window, and nobody
// pressing ⌘N, nothing is different from before.
//
// The session: session.json belongs to the oldest window still open — so
// 1.0.3 reads a real window's tabs — and every other window is a line in
// windows.json, frame included.

/// A window's saved state: where it was, and its row of tabs. The oldest
/// window's row is in the session file instead, and its line here only
/// holds the frame.
struct WindowRecord: Codable {
    var id = UUID()
    var frame: String?
    var row: Session.Shape?
    /// Its column, or the strip across the top, folded away with ⌘S (see
    /// Fold.swift). Nil, as in any line written before it was kept: shown.
    var folded: Bool?

    init() {}

    private enum CodingKeys: String, CodingKey { case id, frame, row, rows, folded }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        frame = try? values.decode(String.self, forKey: .frame)
        // A line written before there was one row: the first of its rows,
        // the one that was there before any other.
        row = (try? values.decode(Session.Shape.self, forKey: .row))
            ?? (try? values.decode([String: Session.Shape].self, forKey: .rows))?[Session.legacyFirstRow]
        folded = try? values.decode(Bool.self, forKey: .folded)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(frame, forKey: .frame)
        try values.encodeIfPresent(row, forKey: .row)
        try values.encodeIfPresent(folded, forKey: .folded)
    }

    var rect: NSRect? { frame.map(NSRectFromString).flatMap { $0.width > 100 && $0.height > 100 ? $0 : nil } }
}

/// The browser whose window is in front, for the menus and everything else
/// that acts on "the" window. It passes on that browser's changes, so a menu
/// item's state follows the window you are in.
@MainActor
final class Front: ObservableObject {
    static let shared = Front()
    @Published private(set) var browser: Browser?
    private var relay: AnyCancellable?

    func set(_ browser: Browser?) {
        guard browser !== self.browser else { return }
        self.browser = browser
        relay = browser?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// The browser in SwiftUI's own window. Closed while other windows stay
/// open, that window's tabs go (⇧⌘T brings them back) and the scene, opened
/// again, comes with a fresh browser rather than the old one.
@MainActor
final class SceneSlot: ObservableObject {
    static let shared = SceneSlot()
    @Published private(set) var browser: Browser

    private init() {
        let browser = Browser()
        browser.inScene = true
        self.browser = browser
        Browsers.register(browser)
    }

    /// Its browser gone with its window: the next time the scene shows, a
    /// fresh one, counted once its window is really there.
    func refresh() {
        let fresh = Browser(record: WindowRecord())
        fresh.inScene = true
        browser = fresh
    }
}

@MainActor
enum Browsers {
    /// Every window's browser, oldest first. The first is the one whose tabs
    /// the session files hold.
    private(set) static var all: [Browser] = []
    /// The window around each browser that isn't the scene's: kept, since
    /// AppKit only lends it.
    private static var frames: [ObjectIdentifier: NSWindow] = [:]
    /// The primary window around SceneSlot.shared.
    private static var primaryWindow: NSWindow?
    /// Windows closed while others were open, newest last, for ⇧⌘T.
    private(set) static var closed: [(record: WindowRecord, at: Date)] = []

    /// SwiftUI's window's id, which is also the name its frame is kept
    /// under (#204); a test run's own.
    static let sceneID = Store.world.map { "search (\($0))" } ?? "search"

    static var primary: Browser? { all.first }
    static var front: Browser? { Front.shared.browser ?? all.last }
    /// The browser to act on when a menu or a link needs one.
    static var acting: Browser { front ?? SceneSlot.shared.browser }
    /// As `acting`, but never a popup's: with one in front, the first
    /// window's. The one a link from another app goes to when nothing asks
    /// for another.
    static var frontBrowser: Browser {
        front.flatMap { !$0.isPopup ? $0 : nil } ?? primary ?? SceneSlot.shared.browser
    }

    static func register(_ browser: Browser) {
        guard !all.contains(where: { $0 === browser }) else { return }
        all.append(browser)
        if Front.shared.browser == nil { Front.shared.set(browser) }
        // Extensions see every window (windows.getAll, a tab's windowId).
        if #available(macOS 15.4, *) { Extensions.shared.attach(browser) }
    }

    static func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// A window of ours came to the front.
    static func becameKey(_ browser: Browser) {
        // One kept away for a small window, brought forward by something
        // other than bringBack: off screen again (see putAway).
        if keptAway, isAway(browser.window) { return putAway() }
        register(browser)
        browser.shut = false
        Front.shared.set(browser)
        if #available(macOS 15.4, *) { Extensions.shared.focused(browser) }
    }

    // MARK: - opening

    /// The primary window around SceneSlot.shared, created once and reused.
    /// Restores its saved frame under `Browsers.sceneID` before showing so it
    /// never jumps from the default size (#202).
    static func openPrimary(show: Bool = true) {
        let browser = SceneSlot.shared.browser
        let window: NSWindow
        if let existing = primaryWindow {
            window = existing
        } else {
            let host = NSHostingView(rootView: SceneRoot(slot: SceneSlot.shared).frame(minWidth: 640, minHeight: 420))
            host.sizingOptions = [.minSize]
            let made = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            made.title = "Search"
            made.isReleasedWhenClosed = false
            made.tabbingMode = .disallowed
            made.titlebarAppearsTransparent = true
            made.titleVisibility = .hidden
            made.minSize = NSSize(width: 640, height: 420)
            made.contentView = host
            if !made.setFrameUsingName(sceneID) { made.center() }
            made.setFrameAutosaveName(sceneID)
            primaryWindow = made
            window = made
        }
        browser.window = window
        browser.shut = false
        register(browser)
        Links.hand(to: browser)
        BookmarkMenu.shared.start(for: browser)
        watchFrames()
        Bench.keepOff(window)
        if keptAway {
            window.orderOut(nil)
            if !isAway(window) { away.append(window) }
            return
        }
        if show && !(Store.testing && NSApp.isHidden) {
            window.makeKeyAndOrderFront(nil)
            becameKey(browser)
            comeForward()
        } else {
            window.layoutIfNeeded()
            restoreOnce()
        }
    }

    /// ⌘N. A window that is closed but kept — the last one, closed with the
    /// app running — comes back first, as a window always did; otherwise a
    /// new one, with one empty tab.
    static func newWindow() {
        if bringBack() { return }
        if let kept = all.first(where: { !$0.isOpen }) {
            show(kept)
            return
        }
        // Folded or not as the window it came from, as in Safari and Arc.
        var fresh = WindowRecord()
        if front?.isPopup == false, front?.folded == true { fresh.folded = true }
        let browser = Browser(record: fresh)
        open(browser, frame: nil)
    }

    /// Brings a browser's window on screen, the scene's included.
    static func show(_ browser: Browser) {
        browser.shut = false
        if let window = browser.window {
            Bench.keepOff(window)
            // A hidden probe stays hidden: ordered front, its window shows
            // the app again (an extension's windows.update focused, which
            // Claude's panel asks for whenever its window isn't key).
            if !(Store.testing && NSApp.isHidden) { window.makeKeyAndOrderFront(nil) }
        } else if browser.inScene {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
        comeForward()
    }

    /// Some window on screen for a link or a menu to act in: the one in
    /// front, or one brought back.
    @discardableResult
    static func ensureWindow() -> Browser {
        bringBack()
        if let front, front.isOpen, !front.isPopup { return front }
        if let open = all.last(where: { $0.isOpen && !$0.isPopup }) { return open }
        let kept = all.first { $0.shut && !$0.isPopup } ?? all.first ?? SceneSlot.shared.browser
        show(kept)
        return kept
    }

    /// A window around `browser`, made here rather than by SwiftUI.
    static func open(_ browser: Browser, frame: NSRect?) {
        let popup = browser.isPopup
        let host: NSView
        if popup {
            let view = NSHostingView(rootView: PopupWindowView(browser: browser).frame(minWidth: 200, minHeight: 150))
            view.sizingOptions = [.minSize]
            host = view
        } else {
            let view = NSHostingView(rootView: ContentView(browser: browser).frame(minWidth: 640, minHeight: 420))
            view.sizingOptions = [.minSize]
            host = view
        }
        // A new window from one in full screen: in full screen of its own,
        // in a Space of its own, as Safari and Chrome do — sized as a window
        // for when it leaves full screen, not as the screen.
        let fullScreen = !popup && frame == nil && front?.window?.styleMask.contains(.fullScreen) == true
        let size = popup ? NSSize(width: 480, height: 600)
            : fullScreen ? NSSize(width: 1180, height: 780)
            : front?.window?.frame.size ?? NSSize(width: 1180, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // A popup has no ContentView.dress() to tie the browser to its window;
        // tied here, before extensions hear of it (#408, lulkebit).
        browser.window = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = host
        if popup {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 200, height: 150)
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else if popup || fullScreen {
            window.center()
        } else if let beside = front?.window {
            // Down and to the right of the window in front, as new windows go.
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: beside.frame.minX, y: beside.frame.maxY)))
        } else {
            window.center()
        }
        frames[ObjectIdentifier(browser)] = window
        // Extensions hear of the window only now, with its real frame there
        // to report: told first, a popup's windows.update and getCurrent met
        // a window with no frame and no NSWindow behind it (#408, lulkebit).
        register(browser)
        Bench.keepOff(window)
        // A window brought back from last time while a link's small window
        // keeps them away: off screen with the rest (see keepAway).
        if keptAway, !popup {
            away.append(window)
            return
        }
        window.makeKeyAndOrderFront(nil)
        // The window just opened is the one in front from now on. Its own
        // didBecomeKey goes by before its view knows its window (WindowSetup
        // waits a turn), so the menus, Bookmarks among them, went on acting
        // on the window behind until you clicked away and back (#1146).
        becameKey(browser)
        // Never in a test run: full screen would put a probe's window on a screen.
        if fullScreen, !Store.testing { window.toggleFullScreen(nil) }
        comeForward()
    }

    /// A website controls the requested size, never the bounds of the display.
    static func popupFrame(width: Double?, height: Double?, on screen: NSRect) -> NSRect {
        let width = min(max(width.flatMap { $0.isFinite ? $0 : nil } ?? 480, 200), screen.width)
        let height = min(max(height.flatMap { $0.isFinite ? $0 : nil } ?? 600, 150), screen.height)
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    // MARK: - kept away

    /// A launch made for a link's small window keeps every browser window
    /// off screen until one is wanted: Open in Search, another link, the
    /// Dock icon or ⌘N (see Links.little). Put away, never closed: a window closed while another is
    /// open is retired (see closing), its tabs out of the session and
    /// windows.json, and a launch with several windows came back with one.
    private(set) static var keptAway = false
    private static var away: [NSWindow] = []

    static func keepAway() {
        keptAway = true
        // Each time the app is shown again after ⌘H, it brings back every
        // window it had when it was hidden: the browser's came up beside
        // the small window or the panel. They go again.
        guard unhiding == nil else { return }
        unhiding = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { putAway() } }
    }
    private static var unhiding: Any?

    /// Whether a window is one kept off screen — for the bench.
    static func isAway(_ window: NSWindow?) -> Bool { away.contains { $0 === window } }

    /// Every browser window there is now goes off screen, kept as it is.
    /// Asked as the app finishes launching and as each window is dressed,
    /// so SwiftUI's window, which it opens at every launch and asks nobody
    /// about, goes before it is drawn; and whenever one of them is back on
    /// screen while they are kept away — the app shown again after ⌘H, or
    /// SwiftUI bringing its window forward after all — since only
    /// bringBack is meant to bring them. One in the Dock stays there.
    static func putAway() {
        guard keptAway else { return }
        for window in NSApp.windows where isBrowserWindow(window) && !window.isMiniaturized
            && (!isAway(window) || window.isVisible) {
            window.orderOut(nil)
            if !isAway(window) { away.append(window) }
        }
    }

    /// A browser's window, or SwiftUI's own before ContentView has tied it to
    /// its browser: known then by the name its frame is kept under.
    private static func isBrowserWindow(_ window: NSWindow) -> Bool {
        guard window.contentView != nil, !(window is NSPanel), LittleWindow.owning(window) == nil else { return false }
        if let browser = browser(for: window) { return !browser.isPopup }
        return window.frameAutosaveName == sceneID
    }

    /// The windows kept away, back on screen all together, with any of last
    /// time's not brought back yet, the one in front key. True if there were
    /// any to bring.
    @discardableResult
    static func bringBack() -> Bool {
        guard keptAway else { return false }
        keptAway = false
        let windows = away
        away = []
        for window in windows {
            Bench.keepOff(window)
            window.orderFront(nil)
        }
        restoreOnce()
        (front?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
        comeForward()
        return true
    }

    /// Hidden again (⌘H), as the app was when a link came that opened
    /// nothing: the windows kept away go back behind every other app's
    /// first, never in front, or ⌘Tab would bring the app back with none.
    /// Never while it is hidden: a window ordered in shows it, a hidden
    /// probe's too.
    static func hideAgain() {
        keptAway = false
        for window in away { window.orderBack(nil) }
        away = []
        NSApp.hide(nil)
    }

    /// An extension unloaded, turned off or removed: the popup windows it
    /// opened go with it.
    static func closePopups(of id: String) {
        for browser in all where browser.extensionPopup == id { browser.window?.close() }
    }

    private static func comeForward() {
        // Never a test run's: a probe started hidden stays off every screen.
        guard !Store.testing else { return }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - closing

    /// A window is closing. The last one on screen stays, its browser kept,
    /// as the one window always was: opened again, it has its tabs, their
    /// pages asleep meanwhile but for what can't be (see sleepShut). One
    /// closed while others stay open goes, tabs and all, and ⇧⌘T can bring
    /// it back.
    /// The app is quitting: windows closing are not windows closed.
    static var quitting = false

    static func closing(_ window: NSWindow) {
        guard !quitting, let browser = browser(for: window) else { return }
        browser.cancelFileImport()
        browser.cancelDisplay()
        // A popup goes, and isn't one ⇧⌘T brings back.
        if browser.isPopup {
            retire(browser, remembered: false)
            return
        }
        let others = all.filter { $0 !== browser && $0.isOpen && !$0.isPopup }
        guard !others.isEmpty else {
            // The last one: kept, tabs and all, and written down now. Its
            // pages sleep, as Safari and Chrome close theirs: the tabs are
            // there when it comes back, the one in front woken.
            browser.shut = true
            browser.flushSession()
            save(now: true)
            browser.sleepShut()
            return
        }
        retire(browser)
    }

    private static func retire(_ browser: Browser, remembered: Bool = true) {
        let wasPrimary = browser === primary
        // The session file: to another window, or kept as it is for the
        // next one.
        let owned = browser.usesFiles && !browser.isPopup
        if owned { browser.leaveFiles() }
        if remembered {
            closed.append((record(of: browser, rows: true, keeping: true), Date()))
            if closed.count > 10 { closed.removeFirst(closed.count - 10) }
        }
        all.removeAll { $0 === browser }
        // Its tabs in small windows (Open in Small Window) stay open: another
        // window keeps them, and writes them down now.
        if let heir = all.first(where: { $0.isOpen && !$0.isPopup }) {
            LittleWindow.rehome(from: browser, to: heir)
            heir.writeSession(now: true)
        }
        if #available(macOS 15.4, *) { Extensions.shared.detach(browser) }
        browser.closeAll()
        ContentView.forget(browser)
        frames[ObjectIdentifier(browser)] = nil
        if Front.shared.browser === browser {
            Front.shared.set(all.last { $0.isOpen && !$0.isPopup } ?? all.last { !$0.isPopup })
        }
        if browser.inScene { SceneSlot.shared.refresh() }
        if owned, let heir = all.first(where: { !$0.isPopup }) { heir.takeFiles() }
        if wasPrimary, let next = primary { next.becomePrimary() }
        save(now: true)
    }

    /// A window closed, its tabs not kept for ⇧⌘T.
    static func discard(_ browser: Browser) {
        let window = browser.window
        retire(browser, remembered: false)
        window?.close()
    }

    /// ⇧⌘T, when the last thing closed was a window rather than a tab: the
    /// window comes back where it was, with its tabs, asleep until looked at.
    static func reopenWindow() -> Bool {
        guard let last = closed.popLast() else { return false }
        let browser = Browser(record: last.record)
        open(browser, frame: last.record.rect)
        save()
        return true
    }

    /// When the newest closed window was closed, to weigh against the newest
    /// closed tab.
    static var lastClosedAt: Date? { closed.last?.at }

    // MARK: - saving

    /// A window's state as a record: its frame, and — for any but the
    /// oldest, or when it is going away — its row.
    static func record(of browser: Browser, rows: Bool, keeping: Bool = false) -> WindowRecord {
        var record = browser.record
        if let window = browser.window { record.frame = NSStringFromRect(window.frame) }
        if rows { record.row = browser.currentRow(keeping: keeping) }
        record.folded = browser.folded ? true : nil
        return record
    }

    private static var file: URL { Store.file("windows.json") }

    /// The windows that are written down, oldest first: popups never come back.
    static var saved: [Browser] { all.filter { !$0.isPopup } }

    /// windows.json: the oldest window's frame first, then every
    /// other window whole.
    static func save(now: Bool = false) {
        guard let primary else { return }
        var records = [record(of: primary, rows: false)]
        records[0].row = nil
        for browser in saved.dropFirst() { records.append(record(of: browser, rows: true)) }
        // Last time's other windows, while they haven't been brought back:
        // as they were written, not dropped. They come back once the first
        // window is on screen, and a launch for a small window can end
        // before one ever is.
        if !restored { records = carried(records, over: read()) }
        // Frozen before it goes to the Disk queue.
        let snapshot = records
        Disk.write(file, now: now) { try? JSONEncoder().encode(snapshot) }
    }

    /// The windows open, then last time's that aren't among them: each
    /// window once, an open one as it is now. Appending the file whole wrote
    /// a window brought up before the others twice, and the file doubled up
    /// from save to save until they were brought back.
    static func carried(_ open: [WindowRecord], over stored: [WindowRecord]) -> [WindowRecord] {
        var seen = Set(open.map(\.id))
        return open + stored.dropFirst().filter { seen.insert($0.id).inserted }
    }

    /// Soon, not now: a window being dragged moves many times a second.
    static func saveSoon() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            saving = false
            save()
        }
    }
    private static var saving = false

    static func read() -> [WindowRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([WindowRecord].self, from: data)) ?? []
    }

    /// Start with a fresh window (see Session.startFresh): one window, the
    /// first, where it was; the others' tabs don't come back, and their
    /// pins are every window's anyway (Pins.swift).
    static func startFresh() {
        let records = read()
        guard records.count > 1 else { return }
        let first = [records[0]]
        Disk.write(file, now: true) { try? JSONEncoder().encode(first) }
    }

    /// At launch, once the first window is up.
    static func restoreOnce() {
        guard !restored else { return }
        restored = true
        restore()
    }
    private static var restored = false

    /// At launch: the other windows there were, each as it was left.
    static func restore() {
        let records = read()
        guard records.count > 1 else { return }
        for record in records.dropFirst() {
            open(Browser(record: record), frame: record.rect)
        }
        // The first window in front, as the app opens; not while they are
        // kept away.
        DispatchQueue.main.async {
            guard !keptAway, let primary else { return }
            primary.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Quitting: every window written, now.
    static func flush() {
        for browser in all { browser.flushSession() }
        save(now: true)
        // A visit or an icon from the last second or so, still waiting to be
        // written.
        History.shared.flush()
        Favicons.shared.flush()
    }

    /// The window has moved or changed size.
    static func watchFrames() {
        guard watching.isEmpty else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard browser(for: note.object as? NSWindow) != nil else { return }
                    saveSoon()
                }
            })
        }
        watching.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                closing(window)
            }
        })
    }
    nonisolated(unsafe) private static var watching: [Any] = []
}

extension Browser {
    /// How a menu names this window: the page in front, as the Window menu
    /// does.
    var windowName: String {
        active.map { $0.isBlank ? "New Tab" : $0.label } ?? "Window"
    }
}
