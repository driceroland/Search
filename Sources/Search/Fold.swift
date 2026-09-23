import SwiftUI

// The column of tabs, folded away with ⌘S.
//
// The column is two hundred and some points the page never gets back, even
// while all you do is read. Folded, the page takes the whole window. The tabs
// are one push against the left edge away: the column slides out over the
// page, the same column with the same rows, and goes again once the pointer
// leaves it. A short grace before it goes, so a hand that overshoots on the
// way back in doesn't lose it.
//
// The traffic lights go with it. They live in the column's corner, and left
// alone over a page they sit on top of whatever the page put in its own
// corner — a logo, a menu button. They come back with the column when it
// slides out, which is also where the window is dragged from.
//
// Folding lasts the session. A browser opening with no tabs anywhere on
// screen, for a reason set days ago, reads as a broken one.
//
// Unless that is the reason: Settings can keep the column folded for good,
// Arc's way, and then the fold is where it rests, at launch and after every
// change of layout. ⌘S still brings it out to stay, and puts it away again.
// Folded like that, the edge is met far more often by a hand on its way
// somewhere else — the Dock, the window beside — than by one reaching for
// the tabs, so the column waits for the pointer to settle there a moment
// before it comes. Folded by hand with ⌘S, it comes at once, as it always did.
//
// While a tab's address is being typed into its row, the column stays out:
// the pointer drifting off it is no reason to take the field away.
//
// The strip across the top folds the same way: up out of the window, the
// page taking the full height, and back down over the page when the pointer
// rests against the top edge. There the edge is crossed on every trip to the
// menu bar just above, so the strip always waits for the pointer to settle.

extension Browser {
    /// ⌘S. The column, or the strip across the top, out of the way, or back.
    func toggleFold() {
        peeking = false
        withAnimation(Motion.glide) { folded.toggle() }
    }

    /// The folded column out over the page, or back in.
    func peek(_ out: Bool) {
        withAnimation(Motion.glide) { peeking = out }
    }
}

/// Over the window's left edge while the column is folded, or its top edge
/// while the strip is: the band of edge that brings it out, and the column or
/// the strip itself while it is out.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// The column going back in, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?
    /// The column coming out, once the pointer has settled on the edge.
    @State private var arriving: DispatchWorkItem?
    /// The pointer is over the column.
    @State private var inside = false

    /// How much of the edge answers the pointer. Thin enough that a page's
    /// own left edge — a scrollbar is on the other side — still takes clicks.
    private static let edge: CGFloat = 6
    /// The grace before the column goes back in.
    private static let grace: TimeInterval = 0.3
    /// The band along the top that is the title bar over the page.
    private static let top: CGFloat = 8
    /// How long the pointer rests on the edge before a column folded for
    /// good comes out. Long enough to cross the edge, short enough not to be
    /// waited for.
    private static let dwell: TimeInterval = 0.15

    var body: some View {
        ZStack(alignment: .topLeading) {
            // In the column's mode the page reaches the window's top edge —
            // beside the column, and everywhere once it is folded away — and
            // there was nowhere there to drag the window from, or to
            // double-click to fill the screen: only the column's own corner,
            // gone when folded. A band too thin to be in a page's way stands
            // in for the title bar along the whole top; the column lies over
            // it with its own.
            if prefs.sidebar, browser.active?.immersed != true {
                DragStrip()
                    .frame(height: Fold.top)
                    .frame(maxWidth: .infinity)
            }
            if folding, !prefs.sidebar {
                Color.clear
                    .frame(height: Fold.edge)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { over in if over { arrive() } else { pass() } }
                if browser.peeking {
                    TabBar(browser: browser)
                        .shadow(color: .black.opacity(0.14), radius: 20, y: 4)
                        .onHover { over in
                            inside = over
                            peek(over)
                        }
                        .transition(.move(edge: .top))
                }
            }
            ZStack(alignment: .leading) {
                Color.clear.frame(width: 0)
                if folding, prefs.sidebar {
                    Color.clear
                        .frame(width: Fold.edge)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onHover { over in if over { arrive() } else { pass() } }
                }
                if folding, prefs.sidebar, browser.peeking {
                    SideBar(browser: browser, prefs: prefs)
                        .shadow(color: .black.opacity(0.14), radius: 20, x: 4)
                        .onHover { over in
                            inside = over
                            peek(over)
                        }
                        .transition(.move(edge: .leading))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear { hideLights() }
        // A column folded for good is folded before there is a window to
        // hide the lights of; they go once there is one.
        .background(WindowSetup { window in
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        // Back to the strip and then to the column again: the column comes
        // back as it rests — whole, not folded from a time nobody remembers,
        // unless Settings says it rests folded.
        .onChange(of: prefs.sidebar) { _, _ in
            browser.folded = prefs.sidebar && prefs.sideHides
            browser.peeking = false
        }
        .onChange(of: prefs.sideHides) { _, hides in
            guard prefs.sidebar else { return }
            browser.peeking = false
            withAnimation(Motion.glide) { browser.folded = hides }
        }
        // The address typed into a row is done with, and the pointer went
        // elsewhere while it was: the column goes the way it would have.
        .onChange(of: browser.editingTab) { _, editing in
            if editing == nil, !inside, browser.peeking { peek(false) }
        }
    }

    /// Folded, and not taken over by a page filling the screen.
    private var folding: Bool {
        browser.folded && browser.active?.immersed != true
    }

    private var lightsOff: Bool {
        browser.folded && !browser.peeking
    }

    /// The pointer on the edge: out at once, or after the dwell when the
    /// column is folded for good, and always for the strip, whose edge is
    /// the way to the menu bar.
    private func arrive() {
        guard !prefs.sidebar || prefs.sideHides else { return peek(true) }
        pass()
        let coming = DispatchWorkItem { peek(true) }
        arriving = coming
        DispatchQueue.main.asyncAfter(deadline: .now() + Fold.dwell, execute: coming)
    }

    /// The pointer crossed the edge without stopping.
    private func pass() {
        arriving?.cancel()
        arriving = nil
    }

    /// Out at once; in only once the pointer has stayed away for the grace.
    private func peek(_ out: Bool) {
        leaving?.cancel()
        leaving = nil
        if out {
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            let going = DispatchWorkItem {
                guard browser.editingTab == nil else { return }
                browser.peek(false)
            }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Fold.grace, execute: going)
        }
    }

    /// The title bar's own view holds the three buttons and the resting
    /// circles drawn over them while the app is behind (see RestingLights),
    /// so hiding it hides both, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = Fold.titlebar else { return }
        if prefs.sidebar {
            Fold.slide(bar, off: lightsOff, by: prefs.sideWidth)
        } else {
            Fold.slide(bar, off: lightsOff, by: Metrics.strip, up: true)
        }
    }

    static var titlebar: NSView? {
        Links.window?.standardWindowButton(.closeButton)?.superview
    }

    /// Bumped by every slide, so one that was overtaken doesn't hide the
    /// lights on its way out.
    private static var slides = 0

    /// The lights ride with the column, as everything else in its corner
    /// does. Shown or hidden at once, they stood in their place while the
    /// column was still sliding in under them, and vanished before it had
    /// gone. So they come in from the left edge and go back off it, on the
    /// column's own spring (Motion.glide, in Core Animation's terms) — from
    /// wherever they are, when the pointer turns back halfway. `up`: off the
    /// top edge with the strip rather than off the left edge with the column.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, up: Bool = false) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        // Up is +y in a superview that isn't flipped, -y in one that is.
        let path = up ? "transform.translation.y" : "transform.translation.x"
        let gone: CGFloat = up ? ((bar.superview?.isFlipped ?? false) ? -width : width) : -width
        let other = up ? "transform.translation.x" : "transform.translation.y"
        let moving = layer.animation(forKey: "fold") != nil
        // A slide still running on the other axis — the layout was switched
        // halfway — is simply let go.
        if moving, (layer.animation(forKey: "fold") as? CABasicAnimation)?.keyPath == other {
            layer.removeAnimation(forKey: "fold")
        }
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let spring = CASpringAnimation(keyPath: path)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.34, 2)
        spring.damping = 4 * .pi * 0.82 / 0.34
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}
