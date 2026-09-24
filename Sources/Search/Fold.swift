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

/// Over the window while the column or the strip is folded: the column or
/// the strip itself while it is out, brought out by the pointer at the
/// window's left edge, or its top edge.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// The column going back in, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?
    /// The column coming out, once the pointer has settled on the edge.
    @State private var arriving: DispatchWorkItem?
    /// The pointer is over the column.
    @State private var inside = false
    @State private var pointer = Pointer()

    /// How near the edge the pointer has to be.
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
            if folding, !prefs.sidebar, browser.peeking {
                TabBar(browser: browser)
                    .shadow(color: .black.opacity(0.14), radius: 20, y: 4)
                    .transition(.move(edge: .top))
            }
            ZStack(alignment: .leading) {
                Color.clear.frame(width: 0)
                if folding, prefs.sidebar, browser.peeking {
                    SideBar(browser: browser, prefs: prefs)
                        .shadow(color: .black.opacity(0.14), radius: 20, x: 4)
                        .transition(.move(edge: .leading))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            hideLights()
            watch()
        }
        .onDisappear { pointer.stop() }
        // A column folded for good is folded before there is a window to
        // hide the lights of; they go once there is one.
        .background(WindowSetup { window in
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff
            pointer.window = window
            watch()
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        .onChange(of: folding) { _, _ in watch() }
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

    /// The pointer is watched only while there is something folded for it
    /// to bring out; the rest of the time no move of it costs anything.
    private func watch() {
        if folding {
            pointer.start { follow() }
        } else {
            pointer.stop()
        }
    }

    /// Opens or closes the column from the pointer's actual position, on
    /// every move. Hover events weren't enough: a view that appears under a
    /// still pointer never gets "entered", so it never gets "exited" either,
    /// and after a few quick opens and closes the column stayed open, or the
    /// edge stopped opening it.
    private func follow() {
        guard folding, let window = pointer.window, window.isVisible else { return pass() }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        // Distance from the left edge for the column, from the top for the strip.
        let distance = prefs.sidebar ? point.x : size.height - point.y
        if browser.peeking {
            pass()
            // Only this window counts, not another app's window over it. One
            // of this app's own windows, such as a popover opened from the
            // column, counts as the column.
            let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            let onWindow = top == window.windowNumber
            let onOwnPanel = !onWindow && NSApp.windows.contains { $0.windowNumber == top }
            let reach = prefs.sidebar ? prefs.sideWidth : Metrics.strip
            let over = onOwnPanel || (onWindow && inWindow && distance < reach)
            if over != inside { inside = over }
            peek(over)
        } else if inWindow, distance < Fold.edge {
            // Which window is under the pointer is asked only here, at the
            // edge: another app's window over it doesn't bring the column out.
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return pass() }
            if arriving == nil { arrive() }
        } else {
            pass()
        }
    }

    /// The pointer on the edge: out at once, or after the dwell when the
    /// column is folded for good, and always for the strip, whose edge is
    /// the way to the menu bar.
    private func arrive() {
        guard !prefs.sidebar || prefs.sideHides else { return peek(true) }
        pass()
        let coming = DispatchWorkItem {
            arriving = nil
            peek(true)
        }
        arriving = coming
        DispatchQueue.main.asyncAfter(deadline: .now() + Fold.dwell, execute: coming)
    }

    /// The pointer crossed the edge without stopping.
    private func pass() {
        guard let arriving else { return }
        arriving.cancel()
        self.arriving = nil
    }

    /// Out at once; in only once the pointer has stayed away for the grace,
    /// counted from when it left rather than from its latest move.
    private func peek(_ out: Bool) {
        if out {
            if let leaving {
                leaving.cancel()
                self.leaving = nil
            }
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            guard leaving == nil else { return }
            let going = DispatchWorkItem {
                leaving = nil
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

/// The pointer's moves, wherever it goes, while something is folded: over
/// this app's windows, and over everything else while another app is in
/// front, since the edge is still the edge with Search behind.
@MainActor
private final class Pointer {
    weak var window: NSWindow?
    private var local: Any?
    private var global: Any?
    /// The window's own say on mouse-moved events, given back when the
    /// watch ends.
    private var accepted = false

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard local == nil, let window else { return }
        // The pointer's moves reach the monitor wherever it is over the
        // window, not only over what tracks it — for as long as the watch
        // lasts, and no longer.
        accepted = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { moved() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { moved() }
        }
    }

    func stop() {
        guard local != nil || global != nil else { return }
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        window?.acceptsMouseMovedEvents = accepted
    }
}
