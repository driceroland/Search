import AppKit
import SwiftUI

// A look into a folded pin folder (#1585): rest the pointer on its heading
// and a small list beside the column shows the folder's own pages, the one
// looked at last first (PinTree.peek). A click on one goes to it as its row
// would, and the folder stays folded, the page under its heading as the
// page in front always is. Its own small window, as the tab's offers are
// (TabOffers.swift): it never takes the keys from the page. It goes once
// the pointer has been off the heading and the list a moment, at a key or
// a click elsewhere, as the folder opens or changes, as the column folds
// away and as Search goes to the back. Settings › Spaces & Pins › Peek
// into folded folders; off unless turned on.

@MainActor
enum FolderPeek {
    /// How long the pointer rests on a heading before the list comes.
    static let delay: TimeInterval = 0.5
    /// How long the pointer may be off both, crossing from one to the other.
    static let grace: TimeInterval = 0.3

    private static var panel: Panel?
    private static weak var browser: Browser?
    private static var folder: UUID?
    private static var pages: [Tab.ID] = []
    /// The heading on screen, as the list opened.
    private static var heading: NSRect = .zero
    private static var awaySince: TimeInterval?
    private static var waiting: DispatchWorkItem?
    private static var watching: DispatchWorkItem?
    private static var monitor: Any?
    private static var resign: Any?

    static var isShown: Bool { panel != nil }

    /// The pointer onto a folder's heading (`on`) or off it. `view` stands
    /// behind the heading, measured only when the list opens.
    static func hover(_ on: Bool, folder id: UUID, view: NSView?, in browser: Browser) {
        waiting?.cancel()
        waiting = nil
        // Back on the heading from its list: the list stays as it is.
        if folder == id, self.browser === browser, panel != nil { return }
        guard on, refusal(id, in: browser) == nil else { return }
        let work = DispatchWorkItem { [weak browser, weak view] in
            MainActor.assumeIsolated {
                guard let browser, let view else { return }
                show(id, view: view, in: browser)
            }
        }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The heading gone from the column: its list with it.
    static func gone(_ id: UUID, from browser: Browser) {
        waiting?.cancel()
        waiting = nil
        if folder == id, self.browser === browser { hide() }
    }

    /// Why the list for `id` would not be shown now, nil when it would.
    /// `opening`: a button held down is a drag or a click on its way, but
    /// once the list is up, it is the click on one of its rows.
    static func refusal(_ id: UUID, in browser: Browser, opening: Bool = true) -> String? {
        if !browser.prefs.pinFolderPeek { return "off" }
        guard let folder = browser.pinFolders.first(where: { $0.id == id }), folder.collapsed, !folder.isLive
        else { return "not a folded folder" }
        if browser.editingPinFolder == id { return "being renamed" }
        if browser.folderPeek(id).isEmpty { return "no pages" }
        if browser.folded && !browser.peeking { return "column away" }
        if opening, NSEvent.pressedMouseButtons != 0 { return "a button is down" }
        guard let window = browser.window, window.isVisible, window.isKeyWindow, NSApp.isActive else {
            return "window not in front"
        }
        return nil
    }

    private static func show(_ id: UUID, view: NSView, in browser: Browser) {
        guard refusal(id, in: browser) == nil, let window = view.window, window === browser.window else { return }
        hide()
        let tabs = browser.folderPeek(id)
        let name = browser.pinFolders.first { $0.id == id }?.name ?? ""
        let host = Host(rootView: AnyView(FolderPeekList(browser: browser, name: name, pages: tabs)))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = Panel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.appearance = window.appearance

        // Beside the heading, on the page's side of it, its top in line with
        // the heading's, and close enough that the pointer crossing to it
        // never leaves the column: folded away, the column stays out over a
        // window of Search's own (Fold.follow). Kept on the screen.
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let onRight = browser.prefs.sidePosition == .right
        var origin = NSPoint(x: onRight ? rect.minX - 6 - size.width : rect.maxX + 6, y: rect.maxY - size.height + 6)
        if let visible = window.screen?.visibleFrame {
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height - 4))
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.browser = browser
        folder = id
        pages = tabs.map(\.id)
        heading = rect
        awaySince = nil

        // Away at a click or a key anywhere but the list, and as Search goes
        // to the back.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { if event.window !== self.panel { hide() } }
            return event
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                        queue: .main) { _ in MainActor.assumeIsolated { hide() } }
        watch()
    }

    /// Looked at again ten times a second while it is up: the pointer, the
    /// folder and its pages, the column. Nothing is watched while it isn't.
    private static func watch() {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let panel, let browser, let folder else { return hide() }
                guard refusal(folder, in: browser, opening: false) == nil, browser.folderPeek(folder).map(\.id) == pages
                else { return hide() }
                let pointer = NSEvent.mouseLocation
                let now = ProcessInfo.processInfo.systemUptime
                if heading.insetBy(dx: -4, dy: -2).contains(pointer) || panel.frame.insetBy(dx: -4, dy: -4).contains(pointer) {
                    awaySince = nil
                } else if let since = awaySince {
                    if now - since > grace { return hide() }
                } else {
                    awaySince = now
                }
                watch()
            }
        }
        watching = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// A row clicked: its page, as a click on the pin's own row goes to it.
    static func open(_ tab: Tab, in browser: Browser) {
        hide()
        guard browser.tabs.contains(where: { $0 === tab }) else { return }
        browser.clearTabSelection()
        browser.select(tab)
    }

    static func hide() {
        waiting?.cancel()
        waiting = nil
        watching?.cancel()
        watching = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        folder = nil
        pages = []
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Where a heading is: an AppKit view behind it, read only as its list
    /// opens, rather than its frame sent up on every frame of a scroll.
    final class Spot { weak var view: NSView? }

    struct Holder: NSViewRepresentable {
        let spot: Spot
        func makeNSView(context: Context) -> NSView {
            let view = Bare()
            spot.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { spot.view = view }
    }

    /// Only there to be measured: clicks go to the heading in front.
    private final class Bare: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window never becomes key.
    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// The list: the folder's name, then a row for each page, its icon and title.
private struct FolderPeekList: View {
    let browser: Browser
    let name: String
    let pages: [Tab]

    static let width: CGFloat = 240
    static let row: CGFloat = 26
    /// Rows shown before the list scrolls.
    static let most = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(pages) { tab in FolderPeekRow(browser: browser, tab: tab) }
                }
            }
            .scrollIndicators(pages.count > Self.most ? .automatic : .never)
            .frame(height: Self.row * CGFloat(min(pages.count, Self.most)))
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(1)
    }
}

private struct FolderPeekRow: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15, dim: tab.asleep)
            Text(tab.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 8)
        .frame(height: FolderPeekList.row)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { FolderPeek.open(tab, in: browser) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(.isButton)
    }
}
