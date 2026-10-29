import AppKit
import SwiftUI

// Downloads by its button (Settings › Downloads › Open Downloads): the
// side panel's card, as wide as the panel is and a quarter of the window's
// height, floating beside the button instead of taking room from the page.
// Its own small window, as the site card's is (SiteCard.swift): it never
// takes the keys, so the page keeps them, and a click on the card is only a
// click. It grows in from the button's corner and shrinks back into it,
// fading; at once with Reduce Motion. It goes with a click anywhere else,
// Escape, the button again, or Search going to the back.
@MainActor
enum DownloadsFloat {
    private static var panel: Panel?
    private static var presence: Presence?
    /// One on its way out, still fading: taken away at once if another
    /// comes in meanwhile.
    private static var leaving: Panel?
    private static weak var owner: Browser?
    private static weak var anchor: NSView?
    private static var edge: Edge = .bottom
    private static var watches: [Any] = []
    private static var monitor: Any?

    /// Beside `button`, in `browser`'s window. `edge`: the side of the button
    /// it stands on — under a button in the row, beside one in the column.
    static func show(_ browser: Browser, from button: NSView, edge: Edge) {
        guard let window = button.window else { return }
        if let shown = owner, shown !== browser { shown.downloadsHanging = false }
        hide()
        owner = browser
        anchor = button
        self.edge = edge

        let card = DownloadsPanel(browser: browser, loot: browser.loot, compact: true,
                                  close: { browser.downloadsHanging = false })
            // As tall as the card, as the side panel's list is.
            .environment(\.asTab, true)
            .background(Palette.ground)
            .modifier(CardEdge(on: true))
        let presence = Presence()
        let host = FirstClick(rootView: AnyView(Arrival(presence: presence, edge: edge) { card }))
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card's own shadow, drawn inside the window's margin, grows
        // and fades with it; the window's would be worked out once, at the
        // card's smallest.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.appearance = window.appearance
        self.panel = panel
        self.presence = presence
        place()
        window.addChildWindow(panel, ordered: .above)
        // In, from the next frame: the first one draws it as it starts.
        DispatchQueue.main.async {
            guard self.presence === presence else { return }
            withAnimation(Motion.settle) { presence.shown = true }
        }

        let center = NotificationCenter.default
        watches = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { place() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { owner?.downloadsHanging = false }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { owner?.downloadsHanging = false }
            },
        ]
        // A click anywhere but the card and its own button, or Escape. The
        // button is left to itself: it closes the card by toggling, and
        // closing here first would only have it open again.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            guard let panel = DownloadsFloat.panel else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                owner?.downloadsHanging = false
                return nil
            }
            if event.window === panel { return event }
            if let anchor, event.window === anchor.window,
               anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) { return event }
            owner?.downloadsHanging = false
            return event
        }
    }

    /// Away: shrinking back into the button as it fades, or at once —
    /// another card coming in, a window closing, Reduce Motion.
    static func hide(animated: Bool = false) {
        watches.forEach(NotificationCenter.default.removeObserver)
        watches = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let leaving { take(leaving) }
        leaving = nil
        if let panel {
            if animated, let presence, let out = Motion.quick {
                // Clicks go through it while it fades: it is already gone.
                panel.ignoresMouseEvents = true
                leaving = panel
                withAnimation(out) { presence.shown = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    guard leaving === panel else { return }
                    take(panel)
                    leaving = nil
                }
            } else {
                take(panel)
            }
        }
        panel = nil
        presence = nil
        owner = nil
    }

    private static func take(_ panel: Panel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Only the one shown for `browser`: another window's card stays.
    static func hide(for browser: Browser, animated: Bool = false) {
        guard owner === browser else { return }
        hide(animated: animated)
    }

    /// The card's corner nearest the button, which it grows from.
    static func corner(_ edge: Edge) -> UnitPoint {
        switch edge {
        case .bottom: return .topTrailing
        case .trailing: return .bottomLeading
        case .leading, .top: return .bottomTrailing
        }
    }

    /// Room around the card, inside its window, for its shadow and for it
    /// to grow into — on every side but the one toward the button, so the
    /// window, margin and all, never lies over the button and takes the
    /// click meant for it.
    static let margin: CGFloat = 24

    static func insets(_ edge: Edge) -> EdgeInsets {
        EdgeInsets(top: edge == .bottom ? 0 : margin, leading: edge == .trailing ? 0 : margin,
                   bottom: edge == .top ? 0 : margin, trailing: edge == .leading ? 0 : margin)
    }

    /// Beside the button, as wide as the side panel and a quarter of the
    /// window's height: under a button in the row, its right edge with the
    /// button's; beside one at the column's foot, level with its bottom, on
    /// the side away from the column's edge. Kept inside the window and its
    /// screen, and never over the button: short of room on the button's
    /// side, it is smaller rather than pushed back onto it.
    private static func place() {
        guard let panel, let anchor, let window = anchor.window, let owner else { return }
        let gap = Metrics.cardGap
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var room = window.convertToScreen(window.contentLayoutRect).insetBy(dx: gap, dy: gap)
        if let screen = window.screen?.visibleFrame { room = room.intersection(screen) }
        let spot = layout(edge: edge, button: button, room: room, width: owner.prefs.sidePanelWidth,
                          windowHeight: window.contentLayoutRect.height)
        panel.setFrame(spot.window, display: true)
    }

    /// Where the card goes, and its window with the margin around it, in
    /// screen points. Apart from the window so the rule — never over the
    /// button — can be checked for every edge and every squeeze.
    static func layout(edge: Edge, button: NSRect, room: NSRect, width asked: CGFloat,
                       windowHeight: CGFloat) -> (card: NSRect, window: NSRect) {
        let gap = Metrics.cardGap
        let least: CGFloat = 120
        var width = min(asked, max(240, room.width))
        // Enough for its title, two downloads and its foot in a short window.
        var height = min(max(170, windowHeight / 4), room.height)
        var card = NSRect.zero
        switch edge {
        case .bottom:
            height = max(least, min(height, button.minY - gap - room.minY))
            card = NSRect(x: button.maxX - width, y: button.minY - gap - height, width: width, height: height)
            card.origin.x = max(min(card.minX, room.maxX - width), room.minX)
        case .top:
            height = max(least, min(height, room.maxY - button.maxY - gap))
            card = NSRect(x: button.maxX - width, y: button.maxY + gap, width: width, height: height)
            card.origin.x = max(min(card.minX, room.maxX - width), room.minX)
        case .trailing:
            width = max(least, min(width, room.maxX - button.maxX - gap))
            card = NSRect(x: button.maxX + gap, y: button.minY, width: width, height: height)
            card.origin.y = max(min(card.minY, room.maxY - height), room.minY)
        case .leading:
            width = max(least, min(width, button.minX - gap - room.minX))
            card = NSRect(x: button.minX - gap - width, y: button.minY, width: width, height: height)
            card.origin.y = max(min(card.minY, room.maxY - height), room.minY)
        }
        let edges = insets(edge)
        let window = NSRect(x: card.minX - edges.leading, y: card.minY - edges.bottom,
                            width: card.width + edges.leading + edges.trailing,
                            height: card.height + edges.top + edges.bottom)
        return (card, window)
    }

    /// Whether the card is in, for it to grow and fade by.
    @MainActor
    private final class Presence: ObservableObject {
        @Published var shown = false
    }

    /// The card, grown from its corner by the button and faded in, inside
    /// the window's margin.
    private struct Arrival<Card: View>: View {
        @ObservedObject var presence: Presence
        let edge: Edge
        @ViewBuilder let card: () -> Card

        var body: some View {
            card()
                .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
                .scaleEffect(presence.shown ? 1 : 0.9, anchor: DownloadsFloat.corner(edge))
                .opacity(presence.shown ? 1 : 0)
                .padding(DownloadsFloat.insets(edge))
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window never becomes key.
    private final class FirstClick: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// The button's own view, for the card to stand beside.
struct ButtonSpot: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
