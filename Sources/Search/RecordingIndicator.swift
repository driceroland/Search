import AppKit
import SwiftUI
import WebKit

// "● Loom is recording your screen — Stop": a small pill of Search's own,
// floating at the foot of the screen for as long as an extension records
// anything — the screen, a window, the camera or the microphone — beside
// macOS's own sharing item and dots, and with its own Stop. It never takes
// the keys or the focus from what you are doing. What is recording is
// ExtensionCapture's to say (see ExtensionCapture.swift); this only shows it.
//
// An offscreen document that records (Tella, Vidyard…) has nowhere WebKit
// counts as seen, and WebKit won't start a capture from a page nobody sees.
// While it records, its page is lent to the pill — a 2×2 point view behind
// the pill's content — and given back after: the thing that lets it record
// is the thing that says it is recording.

/// One line of the pill: who is recording, and what.
struct RecordingLine: Identifiable, Equatable {
    let id: String
    /// The extension's name.
    let name: String
    /// "is recording your screen", "is using your camera and microphone"…
    let what: String
}

@MainActor
final class RecordingIndicator: ObservableObject {
    static let shared = RecordingIndicator()

    /// What the pill says, one line per extension recording.
    @Published private(set) var lines: [RecordingLine] = []
    /// What Stop does, for a line's extension.
    var onStop: ((String) -> Void)?
    /// Put away with Hide: the recording goes on, marked only by the red
    /// dot on its tab, which brings the pill back. A new recording, after
    /// all have stopped, shows it again.
    @Published private(set) var hidden = false

    private var panel: PillPanel?
    /// Offscreen pages lent to the pill while they record, with where each
    /// came from, to be given back.
    private var hosted: [(web: WKWebView, home: NSView?)] = []

    /// The lines as they are now, and the pages capturing: shown when
    /// there are any, or a page is lent to the pill; gone when there are
    /// none. A tab whose page is among them wears a mark in the row.
    func update(_ lines: [RecordingLine], pages: [WKWebView] = []) {
        if self.lines != lines { self.lines = lines }
        if lines.isEmpty, hidden { hidden = false }
        let capturing = Set(pages.map(ObjectIdentifier.init))
        for browser in Browsers.all {
            for tab in browser.tabs {
                let now = tab.built.map { capturing.contains(ObjectIdentifier($0)) } ?? false
                if tab.recording != now { tab.recording = now }
            }
        }
        settle()
    }

    /// A line's Stop.
    func stop(_ id: String) { onStop?(id) }

    /// Hide, from the pill; the tab's dot undoes it.
    func hide() { hidden = true; settle() }
    func show() { hidden = false; settle() }
    func toggle() { hidden ? show() : hide() }

    // MARK: - lending an offscreen page (phase 2)

    /// An offscreen document's page, lent to the pill so that WebKit counts
    /// it as seen while it records. Asked again for the same page, nothing
    /// more happens.
    func host(_ web: WKWebView) {
        guard !hosted.contains(where: { $0.web === web }) else { return }
        hosted.append((web, web.superview))
        let panel = ownPanel()
        web.removeFromSuperview()
        panel.lend(web)
        settle()
    }

    /// Given back to where it was, or to nowhere if it had no home.
    func release(_ web: WKWebView) {
        guard let index = hosted.firstIndex(where: { $0.web === web }) else { return }
        let home = hosted.remove(at: index).home
        web.removeFromSuperview()
        if let home { home.addSubview(web) }
        settle()
    }

    /// Whether a page is lent to the pill now, for the bench.
    func hosts(_ web: WKWebView) -> Bool { hosted.contains { $0.web === web } }

    // MARK: - on screen

    /// Up while anything records or a page is lent to it; down otherwise.
    /// A test run keeps it off every screen, whatever it would show: its
    /// model is what is tested there (see Bench, recording).
    private func settle() {
        hosted.removeAll { $0.web.superview == nil && $0.web.window == nil && !isLent($0.web) }
        let wanted = !lines.isEmpty || !hosted.isEmpty
        guard wanted else {
            ScreenInk.shared.stop()
            panel?.orderOut(nil)
            return
        }
        let panel = ownPanel()
        guard !Store.testing else { panel.fit(); return }
        // It rides on the window of the tab that records, near its top,
        // rather than over the page's own controls at the foot of the
        // screen; it moves and hides with that window.
        let home = Browsers.all.first { $0.tabs.contains(where: \.recording) }?.window
            ?? NSApp.keyWindow ?? NSApp.mainWindow
        panel.attach(to: home)
        panel.fit()
        // Hidden, it stays up but unseen and untouchable (a page lent to it
        // must still count as on screen to record); the menu bar holds Stop.
        panel.alphaValue = hidden ? 0 : 1
        panel.ignoresMouseEvents = hidden
        if !panel.isVisible { panel.orderFrontRegardless() }
        menuBar()
    }

    // MARK: - in the menu bar, while hidden

    private var item: NSStatusItem?

    /// A red record mark beside the clock while the pill is hidden: its
    /// menu says what records, with Stop for each, and Show.
    private func menuBar() {
        guard hidden, !lines.isEmpty, !Store.testing else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            image?.isTemplate = false
            button.image = image
            button.toolTip = lines.map { "\($0.name) \($0.what)" }.joined(separator: "\n")
        }
        let menu = NSMenu()
        for line in lines {
            let title = NSMenuItem(title: "\(line.name) \(line.what)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(MenuAction("Stop", { [weak self] in self?.stop(line.id) }).item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Draw on Screen", { ScreenInk.shared.start() }).item)
        if ScreenInk.shared.active {
            menu.addItem(MenuAction("Stop Drawing", { ScreenInk.shared.stop() }).item)
        }
        menu.addItem(MenuAction("Show Pill", { [weak self] in self?.show() }).item)
        item.menu = menu
    }

    /// The menu bar menu again, for Stop Drawing coming and going.
    func refreshMenu() { menuBar() }

    private func isLent(_ web: WKWebView) -> Bool { panel?.holds(web) == true }

    private func ownPanel() -> PillPanel {
        if let panel { return panel }
        let made = PillPanel(indicator: self)
        panel = made
        return made
    }

    /// The pill as it is drawn, as a picture, for the bench: the view alone,
    /// laid out off every screen.
    func picture(dark: Bool) -> NSBitmapImageRep? {
        let view = NSHostingView(rootView: PillView(indicator: self))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 10), height: max(size.height, 10)))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// The panel: borderless, never key or main, over every space and full
/// screen app, at the foot of the screen Search is on.
private final class PillPanel: NSPanel {
    private let content: NSHostingView<PillView>
    /// Where lent pages go: behind the pill's own content, 2×2 points.
    private let lending = NSView(frame: NSRect(x: 2, y: 2, width: 2, height: 2))

    init(indicator: RecordingIndicator) {
        content = NSHostingView(rootView: PillView(indicator: indicator))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let root = NSView(frame: .zero)
        root.addSubview(lending)
        root.addSubview(content)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func lend(_ web: WKWebView) {
        web.frame = lending.bounds
        lending.addSubview(web)
    }

    func holds(_ web: WKWebView) -> Bool { web.superview === lending }

    /// The window it rides on, and whether it has been placed there yet:
    /// once placed (or dragged), it stays where it is.
    private weak var home: NSWindow?
    private var placed = false

    func attach(to window: NSWindow?) {
        guard window !== home else { return }
        home?.removeChildWindow(self)
        home = window
        placed = false
        if let window {
            level = window.level
            collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            window.addChildWindow(self, ordered: .above)
        } else {
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
    }

    /// Its size for what it says; first placed at the top of its window,
    /// centred, just under the toolbar (or at the foot of the screen with
    /// no window). After that it keeps where it is, wherever it was dragged.
    func fit() {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        if placed {
            // Growing or shrinking, it keeps its top centre where it was.
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
            setFrame(NSRect(origin: origin, size: size), display: isVisible)
            return
        }
        let origin: NSPoint
        if let home {
            let area = home.frame
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - 64 - size.height)
        } else {
            let area = (NSScreen.main?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
        }
        setFrame(NSRect(origin: origin, size: size), display: false)
        placed = true
    }
}

/// What the pill draws: a line per extension recording, each with Stop.
struct PillView: View {
    @ObservedObject var indicator: RecordingIndicator

    var body: some View {
        full
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(indicator.lines) { line in
                HStack(spacing: 8) {
                    // The pill's one colour: a recording is known at a
                    // glance by its red dot, as in Chrome and Loom.
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 7, height: 7)
                    (Text(line.name).font(.system(size: 12.5, weight: .semibold))
                        + Text(" \(line.what)").font(.system(size: 12.5)))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 12)
                    // Mark up the screen while sharing it.
                    Button { ScreenInk.shared.toggle() } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 26, height: 22)
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Draw on screen")
                    .accessibilityLabel("Draw on screen")
                    // Out of the way: the tab's red dot brings it back.
                    Button { indicator.hide() } label: {
                        Text("Hide")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Hide; Stop stays in the menu bar")
                    .accessibilityLabel("Hide")
                    Button { indicator.stop(line.id) } label: {
                        Text("Stop")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 11)
                            .frame(height: 22)
                            .background(Palette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop \(line.name)")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        // Anywhere off the buttons drags it.
        .background(PillDragArea())
        // A capsule for one line; the same corners round a taller card.
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording")
    }
}

/// Behind the pill's words: a press there drags the pill, wherever it goes.
private struct PillDragArea: NSViewRepresentable {
    final class Grip: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A menu item that runs a closure: the item keeps its target alive.
private final class MenuAction: NSObject {
    let run: () -> Void
    let item: NSMenuItem
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        super.init()
        item.target = self
        item.representedObject = self
    }
    @objc func fire() { run() }
}
