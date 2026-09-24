import SwiftUI
import WebKit

/// Everything below the strip: the page, the line that says it is coming, and
/// the sentence that says it never did.
///
/// The tab is watched from here rather than from the window. A tab is a class,
/// so going from blank to loaded changes nothing about the value the window
/// hands down — SwiftUI sees the same reference, re-runs nothing, and the page
/// arrives in WebKit without ever being put on screen. Watching it here is
/// what turns that into a redraw.
struct Page: View {
    @ObservedObject var tab: Tab

    var body: some View {
        ZStack {
            // A tab put down with ⌘W has no view, and asking for one here
            // would build an empty one a frame before the stage moves on.
            //
            // Nor is a floating page asked for. Handing the same view over
            // before and after the float changes nothing SwiftUI can see, so
            // the stage was never told to take it back when it landed, and
            // the tab stayed empty. Nothing, then the page, is a change.
            WebStage(page: tab.isBlank || tab.asleep || tab.floating ? nil : tab.web)

            if let cover = tab.cover {
                // The page as it was left, while it is rebuilt underneath —
                // anchored where the page itself starts, and never in the
                // way of a click meant for the page.
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if tab.floating {
                // The tab is not empty, its page is simply elsewhere. Saying so
                // is kinder than a white rectangle.
                Text("This page is playing in the floating window.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.ground)
                    .transition(.opacity)
            }

            if let failure = tab.failure {
                Trouble(message: failure) { tab.reload() }
                    .transition(.opacity)
            }

            if let pull = tab.pull {
                Disc(pull: pull)
                    // A disc for each edge, never one that changes edges: a
                    // view whose alignment flips is a view that glides the
                    // whole way across the window to get there.
                    .id(pull.back)
                    // A short fade and a little growth, both ways. Anything
                    // longer is still arriving when a quick flick has already
                    // let go.
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(Motion.quick, value: tab.failure)
        .animation(Motion.quick, value: tab.floating)
        .animation(.easeOut(duration: 0.2), value: tab.cover == nil)
        .animation(.easeOut(duration: 0.16), value: tab.pull == nil)
    }
}

/// The disc a sideways swipe brings in from the edge.
///
/// White, with a hairline, like everything else that floats over a page. A
/// line of ink winds round it as the fingers go and closes at the point where
/// letting go would mean it. Turn back and it unwinds. Let go while it is
/// closed and the disc leaves with the page.
///
/// It follows the fingers directly, with no spring between: a spring reads
/// as lag on a quick flick, and a quick flick is how most people swipe.
private struct Disc: View {
    let pull: Pull

    var body: some View {
        // The fingers can travel as far as they like; the disc stops short.
        let reach = 150 * (1 - exp(-pull.travel / 110))
        let grown = min(1, pull.travel / 110)
        let scale: CGFloat = pull.going ? 1.08 : 0.86 + 0.14 * grown

        ZStack {
            Circle()
                .fill(Palette.ground)
            Circle()
                .strokeBorder(Palette.hairline, lineWidth: 1)
            // How far there is to go, wound round the edge, closed when it
            // is armed.
            Circle()
                .trim(from: 0, to: grown)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(0.75)
            Image(systemName: pull.back ? "arrow.left" : "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(0.4 + 0.6 * grown))
        }
        .frame(width: 52, height: 52)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .scaleEffect(scale)
        .opacity(pull.going ? 0 : 1)
        // Whole from the first point, a little way in from the edge, drawn
        // further in as the fingers go — and a step further on its way out
        // with the page.
        .offset(x: (pull.back ? 1 : -1) * (10 + reach * 0.2 + (pull.going ? 12 : 0)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pull.back ? .leading : .trailing)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: pull.going)
    }
}

/// The one place a page is allowed to be. Tabs hand their web view over when
/// they become the live one and get it back untouched when they don't — no
/// reload, no lost scroll position, no forgotten form.
struct WebStage: NSViewRepresentable {
    let page: NSView?

    func makeNSView(context: Context) -> StageView { StageView() }

    func updateNSView(_ view: StageView, context: Context) {
        view.show(page)
    }
}

final class StageView: NSView {
    /// What this stage has been told to show, and the only thing it keeps.
    ///
    /// It used to track that *and* what it was holding, and reconcile the two.
    /// One divergence between them — a page taken by the floating window, a tab
    /// closed at the wrong moment, an update that arrived out of order — and
    /// the stage would sit there holding nothing while believing it held
    /// something. That is the white page, and it came back every time from a
    /// different direction because the bookkeeping had many ways to slip.
    ///
    /// Now there is one fact and one rule: show `wanted`, and put that right on
    /// every layout. Nothing to fall out of step with.
    private weak var wanted: NSView?

    override func layout() {
        super.layout()
        settle()
    }

    func show(_ page: NSView?) {
        wanted = page
        settle()
    }

    private func settle() {
        // Anything here that isn't wanted, out. Only ever what is actually
        // ours: a page may be somewhere else on purpose.
        for view in subviews where view !== wanted {
            view.removeFromSuperview()
        }

        guard let wanted, window != nil else { return }
        if wanted.superview !== self {
            // A web view can have only one superview, so taking it back is how
            // it is taken back.
            wanted.removeFromSuperview()
            // Seen — unless it has yet to draw, and would be seen white.
            wanted.alphaValue = (wanted as? PageView)?.unpainted == true ? 0 : 1
            addSubview(wanted)
            // A web view coming back into a window sometimes keeps the last
            // picture it had — which, after a while out of one, is nothing.
            // Asking it to draw again is cheap and is what brings it back.
            wanted.needsLayout = true
            wanted.needsDisplay = true
            wanted.layer?.setNeedsDisplay()
        }
        wanted.frame = bounds
    }
}

/// What there is to say when the page never came. One line, and the only thing
/// worth offering — another go.
private struct Trouble: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
            Button("Try again", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// Hands back the NSWindow once there is one. SwiftUI has no opinion about
/// traffic lights or title bars, and both need settling by hand here.
struct WindowSetup: NSViewRepresentable {
    let ready: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(ready: ready) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let ready: (NSWindow) -> Void

        init(ready: @escaping (NSWindow) -> Void) {
            self.ready = ready
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Here only to learn the window, never to be clicked: set behind or
        /// over something that spans the whole window — Fold's layer does,
        /// since its band runs along the top — a view that answered would
        /// take every click meant for the page and the tabs.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // The window is still being put together at this point; anything
            // set now gets overwritten a moment later.
            DispatchQueue.main.async { self.ready(window) }
        }
    }
}

/// Drag to move, double-click to fill the screen. Lifted from the canvas app —
/// with the title bar hidden the interface swallows the clicks a title bar
/// would have handled, and they have to be put back.
struct DragStrip: NSViewRepresentable {
    /// How much of the leading edge belongs to the tabs. A representable is a
    /// real view sitting under everything SwiftUI draws on top of it, and a
    /// real view takes the click first — so the run the tabs occupy is refused
    /// here and falls through to them.
    var reserved: CGFloat = 0
    /// How much of the top belongs to whatever is drawn there, measured from
    /// the top edge. The column of tabs uses this the way the strip uses the
    /// leading run.
    var below: CGFloat = 0
    /// The run at the trailing end that belongs to a button.
    var trailing: CGFloat = 0

    func makeNSView(context: Context) -> NSView { Strip() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Strip)?.reserved = reserved
        (view as? Strip)?.below = below
        (view as? Strip)?.trailing = trailing
    }

    private final class Strip: NSView {
        var reserved: CGFloat = 0
        var below: CGFloat = 0
        var trailing: CGFloat = 0

        private var pressed: NSEvent?
        private var moved = false

        /// The strip moves the window and answers the double-click itself.
        /// Left to say yes, AppKit takes both on too in the title bar the
        /// strip sits in, and a double-click answered twice — by AppKit on
        /// the press, here on the release — ends where it started.
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            guard inside.x >= reserved, inside.x <= bounds.width - trailing else { return nil }
            // AppKit measures up from the bottom; the reservation is from the top.
            guard bounds.height - inside.y >= below else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = event
            moved = false
        }

        /// The window is not movable on its own (see dress in App.swift): a tab
        /// picked up in the strip would carry the window off with it. Here
        /// it is let go for the one drag, handed to the system's own window
        /// drag so it snaps and tiles as any window does.
        override func mouseDragged(with event: NSEvent) {
            guard let window, let pressed, !moved else { return }
            let dx = event.locationInWindow.x - pressed.locationInWindow.x
            let dy = event.locationInWindow.y - pressed.locationInWindow.y
            // A little slack, so a shaky click is still a click.
            if abs(dx) < 3 && abs(dy) < 3 { return }
            moved = true
            window.isMovable = true
            window.performDrag(with: pressed)
            window.isMovable = false
        }

        /// A double-click does what a title bar's does. It answered every
        /// click before — so a double-click filled the screen on the first
        /// click and put the window back on the second, and looked like
        /// nothing at all.
        override func mouseUp(with event: NSEvent) {
            guard let window, !moved, event.clickCount == 2 else { return }
            // System Settings › Desktop & Dock: what double-clicking a title
            // bar should do. Unset means the default, which fills the screen.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}


/// The three buttons as they look when the app is not the one you are using.
///
/// macOS does draw its own in that state, but in a light window they come out
/// nearly white on white — Apple's own choice, and the reason a pale window
/// looks like it has lost its controls while a dark one does not. So the
/// system's are put away and these are drawn in exactly their place, read from
/// the real buttons rather than guessed at.
///
/// It lives inside the title bar rather than in the window's content, because
/// the title bar draws above everything the app puts on screen.
final class RestingLights: NSView {
    /// Set again each time the title bar is laid out — every change of
    /// screen, key window or size — and redrawn only when they moved.
    var spots: [CGRect] = [] {
        didSet { if spots != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirty: NSRect) {
        Palette.NS.resting.setFill()
        for spot in spots { NSBezierPath(ovalIn: spot).fill() }
    }

    /// Never in the way of a click: the real buttons are underneath, and they
    /// come back the moment the app does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
