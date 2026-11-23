import Foundation

/// Performance's Animations track, as Chrome DevTools draws one: a bar
/// for each CSS animation and transition the page ran while recording,
/// named by its @keyframes or the property it transitions.
///
/// WebKit gives this through the Timeline "Animation" instrument, which
/// turns on Animation tracking: Animation.trackingUpdate, at the
/// timeline's own time, each time a CSS animation or transition moves to
/// a new state (ready, delayed, active, canceled, done), with its
/// trackingAnimationId, animationName or transitionProperty and its
/// element. It says nothing of durations, keyframes or iterations, and
/// nothing of animations a script made; Web Inspector's own Media &
/// Animations timeline draws the same states. A bar runs from the first
/// state to done or canceled (or the recording's end), its delay drawn
/// lighter. Without the instrument (an older WebKit), the bars come from
/// what the Animations drawer heard while the recording ran, timed from
/// their effects.
enum DeveloperPerformanceAnimationTrack {
    typealias Timing = DeveloperToolsSession.Timing

    /// The record type the bars are kept as.
    static let type = "AnimationBar"
    /// The most bars a recording keeps.
    static let limit = 2_000
    static let install = DevToolsResources.script("DeveloperPerformanceAnimations-install.js")

    private struct Open {
        let start: Double
        var activeStart: Double?
        var name: String?
        var kind: String
        var node: Int?
    }

    static func kind(animationName: String?, transitionProperty: String?) -> String? {
        if let name = animationName, !name.isEmpty { return "CSS animation" }
        if let property = transitionProperty, !property.isEmpty { return "CSS transition" }
        return nil
    }

    /// The bars of a recording's Animation.trackingUpdate events (each as
    /// the frontend hook keeps it: timestamp, trackingAnimationId,
    /// animationState, animationName, transitionProperty, nodeId) within
    /// `bounds`, in timeline seconds.
    static func timings(_ updates: [[String: Any]], bounds: ClosedRange<Double>) -> [Timing] {
        let ordered = updates.enumerated().compactMap { entry -> (offset: Int, time: Double, raw: [String: Any])? in
            guard let time = (entry.element["timestamp"] as? NSNumber)?.doubleValue, time.isFinite else { return nil }
            return (entry.offset, time, entry.element)
        }
        .sorted { $0.time != $1.time ? $0.time < $1.time : $0.offset < $1.offset }
        var open: [String: Open] = [:]
        var order: [String] = []
        var result: [Timing] = []
        func close(_ id: String, _ bar: Open, at end: Double, state: String) {
            // Wholly outside the recording: not part of it.
            guard end >= bounds.lowerBound, bar.start <= bounds.upperBound else { return }
            let start = min(max(bar.start, bounds.lowerBound), bounds.upperBound)
            let finish = min(max(end, start), bounds.upperBound)
            var data = ["kind": bar.kind, "name": bar.name ?? bar.kind, "state": state, "id": String(id.prefix(200))]
            if let active = bar.activeStart {
                data["activeOffset"] = String(max(0, min(finish, active) - start) * 1_000)
            }
            if let node = bar.node { data["node"] = String(node) }
            result.append(Timing(type: Self.type, start: start, end: finish, data: data))
        }
        for (_, time, raw) in ordered {
            guard let id = raw["trackingAnimationId"] as? String, !id.isEmpty,
                  let state = raw["animationState"] as? String else { continue }
            let name = (raw["animationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (raw["transitionProperty"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let kind = Self.kind(animationName: raw["animationName"] as? String,
                                 transitionProperty: raw["transitionProperty"] as? String)
            let node = (raw["nodeId"] as? NSNumber)?.intValue
            switch state {
            case "ready", "delayed", "active":
                if var bar = open[id] {
                    if state == "active", bar.activeStart == nil { bar.activeStart = time }
                    if bar.name == nil { bar.name = name }
                    if let kind, bar.kind == "Animation" { bar.kind = kind }
                    open[id] = bar
                } else {
                    open[id] = Open(start: time, activeStart: state == "active" ? time : nil, name: name,
                                    kind: kind ?? "Animation", node: node)
                    order.append(id)
                }
            case "canceled", "done":
                if let bar = open.removeValue(forKey: id) {
                    close(id, bar, at: time, state: state)
                } else if time >= bounds.lowerBound {
                    // Running before the recording began.
                    close(id, Open(start: bounds.lowerBound, activeStart: bounds.lowerBound, name: name,
                                   kind: kind ?? "Animation", node: node), at: time, state: state)
                }
            default:
                continue
            }
        }
        // Still running when the recording stopped.
        for id in order {
            guard let bar = open.removeValue(forKey: id) else { continue }
            close(id, bar, at: bounds.upperBound, state: "active")
        }
        return Array(result.filter { $0.end >= bounds.lowerBound && $0.start <= bounds.upperBound }
            .sorted { $0.start < $1.start }.prefix(limit))
    }

    /// The bars the Animations drawer's animations make, for a WebKit
    /// without the instrument: each heard of at `arrival` (milliseconds
    /// since 1970), the recording having stopped at `stopped` on the same
    /// clock and at `bounds.upperBound` on the timeline's.
    static func timings(fromDrawer animations: [DeveloperAnimation], stopped: Double,
                        bounds: ClosedRange<Double>) -> [Timing] {
        var result: [Timing] = []
        for animation in animations {
            let start = bounds.upperBound - (stopped - animation.arrival) / 1_000
            guard start >= bounds.lowerBound, start <= bounds.upperBound else { continue }
            let active = start + animation.effect.startDelay / 1_000
            let length = animation.effect.infinite ? Double.infinity
                : DeveloperAnimationTimeline.activeDuration(animation.effect) / 1_000
            let end = min(bounds.upperBound, active + length)
            let kind: String
            switch animation.kind {
            case .cssAnimation: kind = "CSS animation"
            case .cssTransition: kind = "CSS transition"
            case .script: kind = "Animation"
            }
            var data = ["kind": kind, "name": animation.title, "state": end < bounds.upperBound ? "done" : "active",
                        "id": String(animation.id.prefix(200))]
            data["activeOffset"] = String(max(0, min(end, active) - start) * 1_000)
            if let node = animation.node { data["node"] = String(node) }
            result.append(Timing(type: Self.type, start: start, end: max(start, end), data: data))
        }
        return Array(result.sorted { $0.start < $1.start }.prefix(limit))
    }

    // MARK: Recording

    /// Before Timeline.start: the frontend hook in place and emptied.
    @MainActor
    static func begin(_ session: DeveloperToolsSession) async {
        _ = try? await session.evaluateInFrontend(install + "\nperchPerformanceAnimations.reset();\nreturn true;")
    }

    /// After the recording's events are in: Animation tracking stopped,
    /// and its bars, or the drawer's when WebKit sent none.
    @MainActor
    static func finish(_ session: DeveloperToolsSession) async -> [Timing] {
        let stopped = DeveloperAnimations.now()
        _ = try? await session.command("Animation.stopTracking")
        guard let bounds = session.timeline.last(where: { $0.type == "RecordingBounds" }) else { return [] }
        let range = bounds.start...max(bounds.start, bounds.end)
        let raw = try? await session.evaluateInFrontend(
            "return globalThis.perchPerformanceAnimations?.drain() ?? null;") as? [String: Any]
        let updates = raw?["updates"] as? [[String: Any]] ?? []
        let bars = timings(updates, bounds: range)
        if !bars.isEmpty { return bars }
        return timings(fromDrawer: DeveloperAnimations.model(for: session).animations, stopped: stopped, bounds: range)
    }
}
