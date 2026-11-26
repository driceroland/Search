import AppKit
import WebKit

// Pages out of sight load a few at a time.
//
// A page loading runs its scripts on a processor of its own, and twenty tabs
// reloaded at once, or a run of links opened behind the one you read, had
// twenty pages each wanting a whole processor: more than a Mac has. The
// window's own thread then waited its turn with them, ready but not running
// — a step of 35 ms of work took 280 ms to come round, and a swipe between
// spaces stopped for up to 700 ms (Bench "passes", Tests/tabs_loading.py).
// Six at once on twelve processors left it nothing to wait for.
//
// So a page out of sight starts loading only while fewer than `at` others
// out of sight are; the rest wait, in the order they were asked for. A page
// in sight never waits, and one that comes into sight while waiting starts
// at once (PageView.viewDidMoveToWindow). A page's turn ends as it stops
// loading, or two seconds on if it never started, or twenty seconds on
// whatever it is doing: a page that never says it is done doesn't hold up
// the rest for good.

@MainActor
final class LoadTurns {
    static let shared = LoadTurns()

    /// How many pages out of sight load at once: half the Mac's processors,
    /// from two to eight; or `load.turns`, for the bench and the measurements.
    static var at: Int {
        let set = Store.settings.integer(forKey: "load.turns")
        return set > 0 ? set : min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// A load: true when it asked for a page, false when it found it was
    /// no longer wanted (another load came after it, its view went).
    typealias Load = () -> Bool

    private final class Turn {
        weak var view: PageView?
        var watch: NSKeyValueObservation?
        var started = false
        var ends: [DispatchWorkItem] = []
        init(_ view: PageView) { self.view = view }
    }

    private struct Waiting {
        weak var view: PageView?
        let load: Load
    }

    private var turns: [ObjectIdentifier: Turn] = [:]
    private var waiting: [Waiting] = []

    /// How many pages out of sight are loading in their turn, and waiting
    /// for one, for the bench.
    var loadingCount: Int { turns.count }
    var waitingCount: Int { waiting.count }

    /// In a window that shows: not out of every window, nor in the room off
    /// every screen where a script's or an agent's tabs are laid out
    /// (PageRoom).
    static func inSight(_ view: PageView) -> Bool {
        guard let window = view.window else { return false }
        return window !== PageRoom.shared.window
    }

    /// `load` for `view`: now, if the view is in sight or a turn is free;
    /// otherwise once one is. A load asked for again replaces the one
    /// waiting.
    func start(_ view: PageView, _ load: @escaping Load) {
        waiting.removeAll { $0.view == nil || $0.view === view }
        finish(ObjectIdentifier(view), next: false)
        if Self.inSight(view) {
            _ = load()
        } else if turns.count < Self.at {
            run(view, load)
        } else {
            waiting.append(Waiting(view: view, load: load))
        }
        next()
    }

    /// The view came into sight: what it waits for, now, and the turn it
    /// held given to another.
    func shown(_ view: PageView) {
        finish(ObjectIdentifier(view))
        guard let index = waiting.firstIndex(where: { $0.view === view }) else { return }
        let load = waiting.remove(at: index).load
        _ = load()
    }

    private func run(_ view: PageView, _ load: Load) {
        let id = ObjectIdentifier(view)
        let turn = Turn(view)
        turns[id] = turn
        let key = ObjectIdentifier(turn)
        turn.watch = view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, let turn = self.turns[id], ObjectIdentifier(turn) == key else { return }
                if view.isLoading { turn.started = true } else if turn.started { self.finish(id) }
            }
        }
        for (after, unless) in [(2.0, true), (20.0, false)] {
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let turn = self.turns[id], ObjectIdentifier(turn) == key, !(unless && turn.started) else { return }
                    self.finish(id)
                }
            }
            turn.ends.append(end)
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: end)
        }
        // Asked again while still loading, it may never stop loading in
        // between to say it started.
        if !load() { finish(id) } else if view.isLoading { turn.started = true }
    }

    private func finish(_ id: ObjectIdentifier, next more: Bool = true) {
        guard let turn = turns.removeValue(forKey: id) else { return }
        turn.watch?.invalidate()
        turn.ends.forEach { $0.cancel() }
        if more { next() }
    }

    private func next() {
        // Views gone since they took their turn give it back.
        for (id, turn) in turns where turn.view == nil { finish(id, next: false) }
        while turns.count < Self.at, !waiting.isEmpty {
            let first = waiting.removeFirst()
            guard let view = first.view else { continue }
            if Self.inSight(view) {
                _ = first.load()
            } else {
                run(view, first.load)
            }
        }
    }
}
