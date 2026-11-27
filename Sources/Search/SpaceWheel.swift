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
    /// A pen's pan has brought its space: the rest of it is let go by.
    private var spent = false

    /// How far an event goes `along` the spaces' axis, below zero toward the
    /// next space. In the bar across the top, up or down as sent. In the
    /// column, only an event more sideways than up or down. A pen's pan
    /// (PenPan) carries the page with it, the way macOS's own scroll
    /// direction says for it, as two fingers on a trackpad do: the spaces
    /// go with it, the page moving left bringing the next (SpaceSwipe.moved).
    /// A mouse's sideways wheel goes the other way round (#1646): turned
    /// toward the next space, it sends the sign a stroke toward the one
    /// before would.
    static func along(dx: CGFloat, dy: CGFloat, sidebar: Bool, pen: Bool) -> CGFloat {
        guard sidebar else { return dy }
        guard abs(dx) > abs(dy) else { return 0 }
        return pen ? dx : -dx
    }

    /// An event a wheel sent, rather than a trackpad: line deltas, or point
    /// deltas with no gesture phase and no glide after one.
    static func isWheel(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        !precise || (phase.isEmpty && momentum.isEmpty)
    }

    /// One event of the wheel, `along` the spaces' axis as the wheel sends
    /// it: below zero toward the next space. Answers 1 for the next space,
    /// -1 for the one before, 0 for none yet.
    ///
    /// A pen's pan (`pen`) is one gesture however long it is dragged, as a
    /// stroke is: once it has gone a line, or `smooth` points, it brings one
    /// space, and nothing more until it has rested. Read as a wheel's notches
    /// it ran across every space there is in one drag.
    mutating func feed(_ along: CGFloat, notched: Bool, pen: Bool = false, at now: TimeInterval) -> Int {
        guard along != 0 else { return 0 }
        let way: CGFloat = along < 0 ? 1 : -1
        let rested = now - lastAt > Self.turn
        if pen {
            if rested { spent = false; gathered = 0 }
            lastAt = now
            guard !spent else { return 0 }
            if gathered * way < 0 { gathered = 0 }
            gathered += way * abs(along) / (notched ? 1 : Self.smooth)
            guard abs(gathered) >= 1 - 1e-9 else { return 0 }
            spent = true
            gathered = 0
            return Int(way)
        }
        // A new turn, or the wheel turned back: start counting afresh.
        if rested || gathered * way < 0 { gathered = 0 }
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

/// A pen on a graphics tablet (Wacom) with a button set to Pan/Scroll: the
/// tablet's driver sends scroll events of its own while the button is held,
/// the page carried along with the pen. They come as a wheel's do, with no
/// gesture phase, line deltas or points; a scroll event can't say it came
/// from a tablet (macOS keeps no subtype on one). The pen is known from
/// around them: the tablet tells when it comes near and goes away
/// (tabletProximity), the pointer's events while it is near are the
/// tablet's (subtype tabletPoint), and the driver's own process posts them.
@MainActor
enum PenPan {
    /// A pen near the tablet, as last told.
    static var near = false

    /// Any event the app sees: a pen coming near or going, or the pointer
    /// moved by the pen or by something else.
    static func note(_ event: NSEvent) {
        switch event.type {
        case .tabletProximity:
            near = event.isEnteringProximity
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .otherMouseDown:
            near = isTablet(subtype: event.subtype)
        default:
            break
        }
    }

    static func isTablet(subtype: NSEvent.EventSubtype) -> Bool {
        subtype == .tabletPoint || subtype == .tabletProximity
    }

    /// A scroll event of the pen's pan.
    static func isPen(_ event: NSEvent) -> Bool {
        if near { return true }
        guard let cg = event.cgEvent else { return false }
        return fromTabletDriver(pid: pid_t(cg.getIntegerValueField(.eventSourceUnixProcessID)))
    }

    private static var known: (pid: pid_t, tablet: Bool)?

    /// The process that posted an event is a tablet's driver (Wacom's
    /// TabletDriver, WacomTabletDriver and the like).
    static func fromTabletDriver(pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        if let known, known.pid == pid { return known.tablet }
        var buffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let tablet = isTabletDriver(name)
        known = (pid, tablet)
        return tablet
    }

    static func isTabletDriver(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("wacom") || name.contains("tabletdriver")
    }
}
