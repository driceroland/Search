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
// Only in the column's mode: the strip across the top is already thin, and
// there ⌘S is left to the page, which often has a use for it.

extension Browser {
    /// ⌘S. The column out of the way, or back.
    func toggleFold() {
        guard prefs.sidebar else { return }
        peeking = false
        withAnimation(Motion.glide) { folded.toggle() }
    }

    /// The folded column out over the page, or back in.
    func peek(_ out: Bool) {
        withAnimation(Motion.glide) { peeking = out }
    }
}

/// Over the window's left edge while the column is folded: the strip of edge
/// that brings it out, and the column itself while it is out.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// The column going back in, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?

    /// How much of the edge answers the pointer. Thin enough that a page's
    /// own left edge — a scrollbar is on the other side — still takes clicks.
    private static let edge: CGFloat = 6
    /// The grace before the column goes back in.
    private static let grace: TimeInterval = 0.3
    /// The band along the top that is the title bar over the page.
    private static let top: CGFloat = 8

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
            ZStack(alignment: .leading) {
                Color.clear.frame(width: 0)
                if folding {
                    Color.clear
                        .frame(width: Fold.edge)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onHover { over in if over { peek(true) } }
                }
                if folding, browser.peeking {
                    SideBar(browser: browser, prefs: prefs)
                        .shadow(color: .black.opacity(0.14), radius: 20, x: 4)
                        .onHover { over in peek(over) }
                        .transition(.move(edge: .leading))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear { hideLights() }
        .onChange(of: lightsOff) { _, _ in hideLights() }
        // Back to the strip and then to the column again: the column comes
        // back whole, not folded from a time nobody remembers.
        .onChange(of: prefs.sidebar) { _, _ in
            browser.folded = false
            browser.peeking = false
        }
    }

    /// Folded, and not taken over by a page filling the screen.
    private var folding: Bool {
        prefs.sidebar && browser.folded && browser.active?.immersed != true
    }

    private var lightsOff: Bool {
        prefs.sidebar && browser.folded && !browser.peeking
    }

    /// Out at once; in only once the pointer has stayed away for the grace.
    private func peek(_ out: Bool) {
        leaving?.cancel()
        leaving = nil
        if out {
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            let going = DispatchWorkItem { browser.peek(false) }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Fold.grace, execute: going)
        }
    }

    /// The title bar's own view holds the three buttons and the resting
    /// circles drawn over them while the app is behind (see RestingLights),
    /// so hiding it hides both, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = Fold.titlebar else { return }
        Fold.slide(bar, off: lightsOff, by: prefs.sideWidth)
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
    /// wherever they are, when the pointer turns back halfway.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        let moving = layer.animation(forKey: "fold") != nil
        let from = moving
            ? (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
            : (bar.isHidden ? -width : 0)
        let to: CGFloat = off ? -width : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
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
