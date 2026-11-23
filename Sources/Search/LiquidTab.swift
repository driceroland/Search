import AppKit
import SwiftUI

// The tab you are on under a pane of Liquid Glass (Settings › Appearance ›
// Tabs › Liquid Glass tab), from macOS 26. Off unless turned on; off, the
// live tab wears its grey and glides from row to row as it always has.
//
// On, the live tab's grey is left out, its reading fill kept, and the
// ground still says where it is (LiveMatch, LiveLensKey). A pane of glass
// is laid under the rows in its place, so the tab's icon and title stand
// on the glass, sharp. A second pane, over the rows, is there only while
// the glass moves and as much as it moves: it bends the titles and icons
// it passes on its way, the way Liquid Glass bends what is under it, and
// is gone by the time the glass has landed rather than lying over the
// tab's own title. Both are held to the room the rows scroll in, so a tab
// scrolled out of sight takes its glass with it, never over the pins or
// the foot.
//
// Only the tabs of the column with titles and of the row across the top:
// a pinned square, the column as icons only and two pages split keep the
// grey they have.
//
// Both panes are moved by one spring of their own (LensMotion) rather than
// by an animation: what they have is a speed, and the speed shows. The
// glass stretches a little along the way it goes, overshoots a little, and
// settles. Standing still, it stays on its tab as the rows scroll; caught
// mid-glide by a scroll, it carries on to where its tab now is. To another
// space it doesn't travel: it is there, as the grey is (LivePill.id). With
// Reduce Motion on it doesn't move at all. The clock runs only while it
// moves, from the screen the window is on.

extension EnvironmentValues {
    /// Whether the live tab is a pane of Liquid Glass (see LiquidTab.swift).
    var liquidTabs: Bool {
        get { self[LiquidTabsKey.self] }
        set { self[LiquidTabsKey.self] = newValue }
    }
}

private struct LiquidTabsKey: EnvironmentKey {
    static let defaultValue = false
}

enum LiquidTab {
    /// Liquid Glass is the Mac's from macOS 26; before that the setting
    /// isn't offered.
    static var available: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// Where a live tab's ground is, said by the ground itself.
struct LiveLensMark {
    let tab: AnyHashable
    let anchor: Anchor<CGRect>
}

/// Every live ground in a row of tabs, the one on screen among them; the
/// lens keeps to the window's (LiveLens.active).
struct LiveLensKey: PreferenceKey {
    static let defaultValue: [LiveLensMark] = []
    static func reduce(value: inout [LiveLensMark], nextValue: () -> [LiveLensMark]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// The live tab's glass, under the rows and over them while it moves,
    /// held to this view's bounds: the room the rows scroll in.
    func liveLens(_ browser: Browser, motion: LensMotion) -> some View {
        backgroundPreferenceValue(LiveLensKey.self) { marks in
            if !marks.isEmpty {
                LiveLens(marks: marks, active: browser.activeID, motion: motion)
            }
        }
        .overlayPreferenceValue(LiveLensKey.self) { marks in
            if !marks.isEmpty {
                LiveLens(marks: marks, active: browser.activeID, motion: motion, over: true)
            }
        }
    }
}

/// A pane, laid under the rows or over them.
private struct LiveLens: View {
    let marks: [LiveLensMark]
    /// The window's live tab.
    let active: AnyHashable?
    /// The row's spring, which both panes follow.
    @ObservedObject var motion: LensMotion
    /// Over the rows: there only while the glass moves. The pane under them
    /// is the one that aims the spring.
    var over = false

    private struct Aim: Equatable {
        let rect: CGRect
        let tab: AnyHashable
    }

    var body: some View {
        GeometryReader { geo in
            if let mark = marks.first(where: { $0.tab == active }) ?? marks.first,
               !over || motion.moving > 0 {
                let aim = Aim(rect: geo[mark.anchor], tab: mark.tab)
                LiquidPane(cornerRadius: 9, motion: over ? nil : motion)
                    .frame(width: max(0, motion.frame.width), height: max(0, motion.frame.height))
                    .scaleEffect(x: motion.stretch.width, y: motion.stretch.height)
                    .position(x: motion.frame.midX, y: motion.frame.midY)
                    .opacity(motion.frame == .zero ? 0 : (over ? motion.moving : 1))
                    .onAppear { if !over { motion.aim(aim.rect, tab: aim.tab) } }
                    .onChange(of: aim) { _, now in if !over { motion.aim(now.rect, tab: now.tab) } }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// The glass's spring: its middle and its size, each pulled toward where the
/// live tab is, with a speed of its own. One for each row of tabs.
@MainActor
final class LensMotion: NSObject, ObservableObject {
    @Published private(set) var frame: CGRect = .zero
    /// Along the way it goes and across it: a little longer and a little
    /// narrower the faster it goes.
    @Published private(set) var stretch = CGSize(width: 1, height: 1)
    /// How much it is moving, nought to one: how much of the pane over the
    /// rows shows.
    @Published private(set) var moving = 0.0
    /// The pane's own view, for a clock from the screen it is on.
    weak var view: NSView?

    private var tab: AnyHashable?
    /// midX, midY, width, height: where it is, where it is going, how fast.
    private var at = [Double](repeating: 0, count: 4)
    private var to = [Double](repeating: 0, count: 4)
    private var speed = [Double](repeating: 0, count: 4)
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    /// How hard it is pulled, and how much of its speed it loses: three
    /// quarters of what would stop it without overshooting, so it overshoots
    /// a touch and settles at once. Less, and the wobble was the thing to
    /// watch rather than the tab.
    private static let pull = 320.0
    private static let damping = 27.0

    func aim(_ rect: CGRect, tab: AnyHashable) {
        let target = [Double(rect.midX), Double(rect.midY), Double(rect.width), Double(rect.height)]
        let glides = self.tab != nil && !Motion.reduced
            && (link != nil || self.tab != tab)
        self.tab = tab
        to = target
        // The first time, the same tab carried by a scroll or a resize while
        // the glass stands still, or anything at all under
        // Reduce Motion: it is simply there.
        guard glides else {
            link?.invalidate()
            link = nil
            at = target
            speed = [0, 0, 0, 0]
            show()
            return
        }
        if link == nil { start() }
    }

    private func start() {
        guard let view else {
            at = to
            show()
            return
        }
        last = 0
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 120 : min(1.0 / 30, now - last)
        last = now
        var resting = true
        for i in 0..<4 {
            let pulled = Self.pull * (to[i] - at[i]) - Self.damping * speed[i]
            speed[i] += pulled * dt
            at[i] += speed[i] * dt
            if abs(to[i] - at[i]) > 0.25 || abs(speed[i]) > 4 { resting = false }
        }
        if resting {
            at = to
            speed = [0, 0, 0, 0]
            link.invalidate()
            self.link = nil
        }
        show()
    }

    private func show() {
        frame = CGRect(x: at[0] - at[2] / 2, y: at[1] - at[3] / 2, width: at[2], height: at[3])
        let fast = (speed[0] * speed[0] + speed[1] * speed[1]).squareRoot()
        let s = min(0.12, fast / 10000)
        moving = min(1, fast / 600)
        stretch = abs(speed[1]) >= abs(speed[0])
            ? CGSize(width: 1 - s * 0.6, height: 1 + s)
            : CGSize(width: 1 + s, height: 1 - s * 0.6)
    }
}

/// One pane of Liquid Glass, clear so the title over it still reads. Only
/// ever asked for where there is Liquid Glass (ContentView's liquidTabs).
private struct LiquidPane: View {
    let cornerRadius: CGFloat
    /// The spring the pane under the rows lends its view to, for its clock.
    let motion: LensMotion?

    var body: some View {
        if #available(macOS 26, *) {
            LiquidPaneView(cornerRadius: cornerRadius, motion: motion)
        }
    }
}

@available(macOS 26, *)
private struct LiquidPaneView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let motion: LensMotion?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .clear
        view.cornerRadius = cornerRadius
        motion?.view = view
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
        motion?.view = view
    }
}
