import AppKit

/// A mouse's wheel over the tabs, read as steps between spaces (SpaceSwipe).
///
/// A wheel with notches sends one event a notch, in lines, with no phase:
/// each one is a step, in the way it was turned, whatever its size. The Mac
/// speeds a quick spin up by making its notches bigger, not more of them,
/// so reading the size took one notch for three spaces. A wheel smoothed by
/// its driver (Logi Options+, on the MX Master's thumb wheel) sends each
/// notch as a run of small steps in points, still with no phase: those are
/// added up, and every `smooth` points of them is a step. A trackpad, or a
/// mouse that sends a gesture's phases as one does, isn't a wheel at all:
/// its strokes are read as strokes (SpaceSwipe.moved), unchanged.
///
/// Before, a spin brought one space and then waited for the wheel to rest
/// 0.3 s, every notch in between starting the wait again: turned steadily,
/// the wheel brought a space wherever it happened to pause, and a smoothed
/// one brought none.
struct WheelSteps {
    /// Points of a smoothed wheel that make one step: about one notch.
    static let smooth: CGFloat = 30
    /// A pause longer than this ends a turn of the wheel: what was added up
    /// toward the next step is dropped.
    static let turn: TimeInterval = 0.3
    /// The quickest notches step: 25 a second. A free-spinning wheel
    /// flicked sends notches faster than anyone turns one, and those between
    /// are let go by rather than run across every space there is.
    static let pace: TimeInterval = 0.04

    private var gathered: CGFloat = 0
    private var lastAt: TimeInterval = -.infinity
    private var steppedAt: TimeInterval = -.infinity

    /// An event a wheel sent, rather than a trackpad: line deltas, or point
    /// deltas with no gesture phase and no glide after one.
    static func isWheel(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        !precise || (phase.isEmpty && momentum.isEmpty)
    }

    /// One event of the wheel, `along` the spaces' axis as the wheel sends
    /// it: below zero toward the next space. Answers 1 for the next space,
    /// -1 for the one before, 0 for none yet.
    mutating func feed(_ along: CGFloat, notched: Bool, at now: TimeInterval) -> Int {
        guard along != 0 else { return 0 }
        let way: CGFloat = along < 0 ? 1 : -1
        // A new turn, or the wheel turned back: start counting afresh.
        if now - lastAt > Self.turn || gathered * way < 0 { gathered = 0 }
        lastAt = now
        gathered += notched ? way : way * abs(along) / Self.smooth
        guard abs(gathered) >= 1 - 1e-9 else { return 0 }
        // One step an event at most, and what's left over is kept for the
        // next, short of a whole one.
        gathered = way * min(abs(gathered) - 1, 0.99)
        if notched {
            guard now - steppedAt >= Self.pace else { return 0 }
            steppedAt = now
        }
        return Int(way)
    }
}
