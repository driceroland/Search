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

    private var panel: PillPanel?
    /// Offscreen pages lent to the pill while they record, with where each
    /// came from, to be given back.
    private var hosted: [(web: WKWebView, home: NSView?)] = []

    /// The lines as they are now, and the pages capturing: shown when
    /// there are any, or a page is lent to the pill; gone when there are
    /// none. A tab whose page is among them wears a mark in the row.
    func update(_ lines: [RecordingLine], pages: [WKWebView] = []) {
        if self.lines != lines { self.lines = lines }
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
            panel?.orderOut(nil)
            return
        }
        let panel = ownPanel()
        panel.fit()
        guard !Store.testing else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

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
        isMovableByWindowBackground = true
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

    /// Its size for what it says, at the foot of the screen, centred.
    func fit() {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 24, width: size.width, height: size.height)
        content.frame = NSRect(origin: .zero, size: size)
        if isVisible { setFrame(NSRect(origin: self.frame.origin, size: size), display: true) } else { setFrame(frame, display: false) }
    }
}

/// What the pill draws: a line per extension recording, each with Stop.
struct PillView: View {
    @ObservedObject var indicator: RecordingIndicator

    var body: some View {
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
                    Button { indicator.stop(line.id) } label: {
                        Text(L("Stop"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 11)
                            .frame(height: 22)
                            .background(Palette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Stop \(line.name)"))
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        // A capsule for one line; the same corners round a taller card.
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Recording"))
    }
}
