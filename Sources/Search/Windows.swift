import AppKit
import Combine
import SwiftUI

// Several windows, each with its tabs (Drice: "un search dans une window et
// un nouveau search dans une autre window").
//
// Each window has a Browser of its own: its tabs, the space it shows, its
// field and panels. What every window shares lives in `Shared` — settings,
// History, bookmarks, downloads — and the spaces and pins are the same
// everywhere: each window shows one space at a time, of its own choosing.
//
// The first window is SwiftUI's scene, as it always was; any other is an
// AppKit window around the same ContentView. With one window, and nobody
// pressing ⌘N, nothing is different from before.
//
// The session: session.json and the other spaces' files belong to the
// oldest window still open — so 1.0.3 reads a real window's tabs — and every
// other window is a line in windows.json, frame and space included.

/// A window's saved state: where it was, which space it showed, and its
/// row of tabs in every space it has one in. The oldest window's rows are
/// in the session files instead, and its line here only holds the frame.
struct WindowRecord: Codable {
    var id = UUID()
    var frame: String?
    var space: UUID = Space.firstID
    /// Rows by space, keyed by the space's identifier.
    var rows: [String: Session.Shape] = [:]

    init(space: UUID = Space.firstID) { self.space = space }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        frame = try? values.decode(String.self, forKey: .frame)
        space = (try? values.decode(UUID.self, forKey: .space)) ?? Space.firstID
        rows = (try? values.decode([String: Session.Shape].self, forKey: .rows)) ?? [:]
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
        let fresh = Browser(record: WindowRecord(space: Browsers.front?.spaceID ?? Space.firstID))
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
    /// Windows closed while others were open, newest last, for ⇧⌘T.
    private(set) static var closed: [(record: WindowRecord, at: Date)] = []

    /// SwiftUI's window's id, which is also the name its frame is kept
    /// under (#204); a test run's own.
    static let sceneID = Store.world.map { "search (\($0))" } ?? "search"

    static var primary: Browser? { all.first }
    static var front: Browser? { Front.shared.browser ?? all.last }
    /// The browser to act on when a menu or a link needs one.
    static var acting: Browser { front ?? SceneSlot.shared.browser }

    static func register(_ browser: Browser, focusIfEmpty: Bool = true) {
        guard !all.contains(where: { $0 === browser }) else { return }
        all.append(browser)
        if Front.shared.browser == nil && focusIfEmpty { Front.shared.set(browser) }
        // Extensions see every window (windows.getAll, a tab's windowId).
        if #available(macOS 15.4, *) { Extensions.shared.attach(browser) }
    }

    static func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// A window of ours came to the front.
    static func becameKey(_ browser: Browser) {
        register(browser)
        browser.shut = false
        Front.shared.set(browser)
        Spaces.current = browser.spaceID
        if #available(macOS 15.4, *) { Extensions.shared.focused(browser) }
    }

    // MARK: - opening

    /// ⌘N. A window that is closed but kept — the last one, closed with the
    /// app running — comes back first, as a window always did; otherwise a
    /// new one, with one empty tab, in the space of the window in front.
    static func newWindow() {
        if let kept = all.first(where: { !$0.isOpen }) {
            show(kept)
            return
        }
        let browser = Browser(record: WindowRecord(space: front?.spaceID ?? Space.firstID))
        open(browser, frame: nil)
    }

    /// Brings a browser's window on screen, the scene's included.
    static func show(_ browser: Browser) {
        browser.shut = false
        if let window = browser.window {
            Bench.keepOff(window)
            window.makeKeyAndOrderFront(nil)
        } else if browser.inScene {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
        comeForward()
    }

    /// Some window on screen for a link or a menu to act in: the one in
    /// front, or one brought back.
    @discardableResult
    static func ensureWindow() -> Browser {
        if let front, front.isOpen { return front }
        if let open = all.last(where: { $0.isOpen && $0.extensionPopup == nil }) { return open }
        let kept = all.first ?? SceneSlot.shared.browser
        show(kept)
        return kept
    }

    /// A window around `browser`, made here rather than by SwiftUI.
    /// `present` is false for model tests that must exercise a real frame unseen.
    static func open(_ browser: Browser, frame: NSRect?, shouldBeFocused: Bool = true, present: Bool = true) {
        let previouslyFocused = shouldBeFocused ? nil : Front.shared.browser
        let popup = browser.extensionPopup != nil
        let host: NSView
        if popup {
            let view = NSHostingView(rootView: ExtensionPopupView(browser: browser).frame(minWidth: 200, minHeight: 150))
            view.sizingOptions = [.minSize]
            host = view
        } else {
            let view = NSHostingView(rootView: ContentView(browser: browser).frame(minWidth: 640, minHeight: 420))
            view.sizingOptions = [.minSize]
            host = view
        }
        let size = popup ? NSSize(width: 480, height: 600) : front?.window?.frame.size ?? NSSize(width: 1180, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // A popup has no ContentView.dress() to bind this weak reference.
        browser.window = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if popup {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 200, height: 150)
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else if popup {
            window.center()
        } else if let beside = front?.window {
            // Down and to the right of the window in front, as new windows go.
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: beside.frame.minX, y: beside.frame.maxY)))
        } else {
            window.center()
        }
        // Extensions learn about a new window in register(). Keep the real
        // frame ready before WebKit can report it or the view appears.
        frames[ObjectIdentifier(browser)] = window
        register(browser, focusIfEmpty: shouldBeFocused)
        // WebKit's didOpenWindow moves a new window to the front of its own
        // order even when AppKit leaves it unfocused. Restore its focus model
        // to the actual front window (or nil) without changing Front.
        if !shouldBeFocused, #available(macOS 15.4, *) {
            Extensions.shared.focused(previouslyFocused)
        }
        window.contentView = host
        if present {
            Bench.keepOff(window)
            if shouldBeFocused {
                window.makeKeyAndOrderFront(nil)
                comeForward()
            } else {
                window.orderFront(nil)
            }
        }
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

    /// A window is closing. The last one on screen stays as it is, its
    /// browser kept, as the one window always was: opened again, it has its
    /// tabs. One closed while others stay open goes, tabs and all, and ⇧⌘T
    /// can bring it back.
    /// The app is quitting: windows closing are not windows closed.
    static var quitting = false

    static func closing(_ window: NSWindow) {
        guard !quitting, let browser = browser(for: window) else { return }
        // An extension's popup goes, and isn't one ⇧⌘T brings back.
        if browser.extensionPopup != nil {
            retire(browser, remembered: false)
            return
        }
        let others = all.filter { $0 !== browser && $0.isOpen && $0.extensionPopup == nil }
        guard !others.isEmpty else {
            // The last one: kept, tabs and all, and written down now.
            browser.shut = true
            browser.flushSession()
            save(now: true)
            return
        }
        retire(browser)
    }

    private static func retire(_ browser: Browser, remembered: Bool = true) {
        let wasPrimary = browser === primary
        if remembered {
            closed.append((record(of: browser, rows: true), Date()))
            if closed.count > 10 { closed.removeFirst(closed.count - 10) }
        }
        all.removeAll { $0 === browser }
        if #available(macOS 15.4, *) { Extensions.shared.detach(browser) }
        browser.closeAll()
        frames[ObjectIdentifier(browser)] = nil
        if Front.shared.browser === browser {
            Front.shared.set(all.last { $0.isOpen && $0.extensionPopup == nil } ?? all.last { $0.extensionPopup == nil })
        }
        if browser.inScene { SceneSlot.shared.refresh() }
        if wasPrimary, let next = primary { next.becomePrimary() }
        save(now: true)
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

    /// A window's state as a record: frame, space, and — for any but the
    /// oldest, or when it is going away — its rows.
    static func record(of browser: Browser, rows: Bool) -> WindowRecord {
        var record = browser.record
        record.space = browser.spaceID
        if let window = browser.window { record.frame = NSStringFromRect(window.frame) }
        if rows { record.rows = browser.allRows() }
        return record
    }

    private static var file: URL { Store.file("windows.json") }

    /// The windows that are written down, the oldest first: every one but an
    /// extension's popups, which never come back.
    static var saved: [Browser] { all.enumerated().filter { $0.offset == 0 || $0.element.extensionPopup == nil }.map(\.element) }

    /// windows.json: the oldest window's frame and space first, then every
    /// other window whole.
    static func save(now: Bool = false) {
        guard let primary else { return }
        var records = [record(of: primary, rows: false)]
        records[0].rows = [:]
        for browser in saved.dropFirst() { records.append(record(of: browser, rows: true)) }
        // Frozen before it goes to the Disk queue.
        let snapshot = records
        Disk.write(file, now: now) { try? JSONEncoder().encode(snapshot) }
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
        // The first window in front, as the app opens.
        DispatchQueue.main.async { primary?.window?.makeKeyAndOrderFront(nil) }
    }

    /// Quitting: every window written, now.
    static func flush() {
        for browser in all { browser.flushSession() }
        save(now: true)
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
        // Movable between presses, for macOS's Move & Resize and tiling;
        // not during one, so that a tab picked up in the strip — the title
        // bar — moves itself and not the window (see DragStrip, which moves
        // the window itself). The flag is set before the window sees the
        // press, which is when AppKit decides.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in
            MainActor.assumeIsolated {
                if let window = event.window, browser(for: window) != nil {
                    window.isMovable = event.type == .leftMouseUp
                }
            }
            return event
        }) { watching.append(monitor) }
        // Popups use ExtensionPopupView, so there is no ContentView to relay
        // their key-window change to the extension controller.
        watching.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let browser = browser(for: note.object as? NSWindow), browser.extensionPopup != nil else { return }
                becameKey(browser)
            }
        })
        // A press whose release something else kept — a menu popped up from
        // it tracks the mouse itself — leaves no window unmovable for long.
        watching.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for browser in all { browser.window?.isMovable = true } }
        })
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
    /// does, and the space when there are spaces.
    var windowName: String {
        let page = active.map { $0.isBlank ? "New Tab" : $0.label } ?? "Window"
        return prefs.usesSpaces ? "\(page) — \(space.name)" : page
    }
}
