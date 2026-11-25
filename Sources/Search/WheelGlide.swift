import AppKit

// A mouse wheel's notches, glided. WebKit on the Mac moves a page the whole
// notch at once — 40 points a line, in one frame — where Chrome eases it over
// a few frames. A trackpad or a mouse that scrolls in points is smooth
// already and is left alone.
//
// On unless turned off in Settings › Keyboard & Mouse. Each notch is taken
// from the page and given back as small steps in points, one per frame,
// eased out over about a sixth of a second; a notch during the glide adds to
// what is left, and one the other way starts afresh. The page sees those
// steps as its wheel events, in pixels rather than one per notch in lines.
// With ⌘, ⌃ or ⌥ held — zooming, as maps and some pages do — the notch goes
// to the page as it came.

@MainActor
final class WheelGlide: NSObject {
    /// Settings › Keyboard & Mouse › Smooth scrolling with a mouse wheel.
    static var on = false

    /// What WebKit moves for one line of a notch (Scrollbar::pixelsPerLineStep).
    static let line: CGFloat = 40
    /// How quickly the glide closes in: what's left shrinks by e every τ.
    static let tau: CFTimeInterval = 0.045

    private weak var view: PageView?
    /// The notch the steps are made from: its window, place and flags.
    private var template: CGEvent?
    /// Where the glide is going, from where it began, and how much of it
    /// has gone to the page — in whole points, what WebKit takes.
    private var target = CGVector.zero
    private var done = CGVector.zero
    private var moved = CGVector.zero
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    /// For the bench: steps sent since the last notch.
    private(set) var steps = 0

    init(_ view: PageView) {
        self.view = view
    }

    /// Takes a mouse wheel's notch, or says no and leaves it to the page.
    func take(_ event: NSEvent) -> Bool {
        guard Self.on, !event.hasPreciseScrollingDeltas, event.phase == [], event.momentumPhase == [],
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view, let cg = event.cgEvent?.copy()
        else { return false }
        let add = CGVector(dx: event.scrollingDeltaX * Self.line, dy: event.scrollingDeltaY * Self.line)
        guard add.dx != 0 || add.dy != 0 else { return false }
        // A made step must read as a step in points, from the same window
        // and place as the notch; a WebKit or a Mac that reads them some
        // other way gets its notches as they came.
        template = cg
        guard let check = make(0, 3), check.hasPreciseScrollingDeltas, check.scrollingDeltaY == 3,
              check.window === event.window, check.locationInWindow == event.locationInWindow
        else {
            template = nil
            return false
        }
        // The other way: what was left of the glide is dropped.
        let left = CGVector(dx: target.dx - moved.dx, dy: target.dy - moved.dy)
        if left.dx * add.dx < 0 || left.dy * add.dy < 0 {
            target = moved
        }
        target.dx += add.dx
        target.dy += add.dy
        steps = 0
        if link == nil, timer == nil {
            last = CACurrentMediaTime()
            // In step with the screen; a window on none, as a hidden probe's,
            // is stepped by a timer instead.
            if view.window?.occlusionState.contains(.visible) == true {
                let link = view.displayLink(target: self, selector: #selector(frame))
                link.add(to: .main, forMode: .common)
                self.link = link
            } else {
                let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frame() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            frame()
        }
        return true
    }

    /// Stops a glide, as when the page goes.
    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        target = .zero
        done = .zero
        moved = .zero
    }

    @objc private func frame() {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240, now - last)
        last = now
        let k = 1 - exp(-dt / Self.tau)
        moved.dx += (target.dx - moved.dx) * k
        moved.dy += (target.dy - moved.dy) * k
        let close = abs(target.dx - moved.dx) < 0.5 && abs(target.dy - moved.dy) < 0.5
        if close { moved = target }
        let step = CGVector(dx: moved.dx.rounded() - done.dx, dy: moved.dy.rounded() - done.dy)
        if step.dx != 0 || step.dy != 0, let event = make(step.dx, step.dy), let view {
            done.dx += step.dx
            done.dy += step.dy
            steps += 1
            view.glide(event)
        }
        if close || view == nil {
            stop()
        }
    }

    /// The notch made a step of dx, dy points, as a mouse that scrolls in
    /// points sends it. The point deltas go last: setting the line or fixed
    /// deltas after them clears what NSEvent reads.
    private func make(_ dx: CGFloat, _ dy: CGFloat) -> NSEvent? {
        guard let cg = template?.copy() else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy.sign == .minus ? -1 : dy == 0 ? 0 : 1))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx.sign == .minus ? -1 : dx == 0 ? 0 : 1))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy) / 10)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx) / 10)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        return NSEvent(cgEvent: cg)
    }
}
