import Foundation
import SwiftUI

// Chrome DevTools' Animations drawer tool (More tools › Animations), over
// WebKit's Animation domain: the page's CSS animations, transitions and
// Web Animations as they start, grouped by when they started, each drawn
// on a timeline. WebKit's protocol reports animations but can't pause,
// slow or seek them, so the drawer does that in the page itself, with
// the Web Animations API (document.getAnimations(), pause, playbackRate,
// currentTime), as a page's own script could. Dragging a bar changes the
// animation's delay and dragging its end changes its duration, as in
// Chrome, through the effect's updateTiming.
//
// Scroll-driven animations (a ScrollTimeline or ViewTimeline, which WebKit
// has had since Safari 26) are told apart by their page object's
// `timeline` and grouped by what they follow, with their scroll range in
// place of a time. View transitions (document.startViewTransition, in
// WebKit since Safari 18) aren't in WebKit's Animation domain as such: a
// hook in the page (DeveloperAnimations-page.js) notes each call and reads
// its ::view-transition pseudo-elements' animations, listed together as
// one "View transition" group. Both are feature-detected in the page.

/// An animation's timing, as WebKit's Animation.Effect describes it. Times
/// are in milliseconds; an endless iteration count is infinity.
struct DeveloperAnimationEffect: Equatable {
    struct Keyframe: Equatable {
        var offset: Double
        var easing: String?
        var style: String?
    }

    var startDelay: Double = 0
    var endDelay: Double = 0
    var iterationCount: Double = 1
    var iterationStart: Double = 0
    var iterationDuration: Double = 0
    var timingFunction: String?
    var playbackDirection: String?
    var fillMode: String?
    var keyframes: [Keyframe] = []

    init(startDelay: Double = 0, endDelay: Double = 0, iterationCount: Double = 1, iterationStart: Double = 0,
         iterationDuration: Double = 0, timingFunction: String? = nil, playbackDirection: String? = nil,
         fillMode: String? = nil, keyframes: [Keyframe] = []) {
        self.startDelay = startDelay
        self.endDelay = endDelay
        self.iterationCount = iterationCount
        self.iterationStart = iterationStart
        self.iterationDuration = iterationDuration
        self.timingFunction = timingFunction
        self.playbackDirection = playbackDirection
        self.fillMode = fillMode
        self.keyframes = keyframes
    }

    /// From the protocol's object. WebKit sends -1 for an endless count
    /// (the frontend script turns Infinity into -1 on its way here too).
    init(raw: [String: Any]) {
        let number = DeveloperAnimationTimeline.number
        startDelay = max(0, number(raw["startDelay"]) ?? 0)
        endDelay = number(raw["endDelay"]) ?? 0
        // -1, or null where WebKit once wrote Infinity into JSON: endless,
        // as Web Inspector's own WI.Animation reads both.
        if raw["iterationCount"] is NSNull {
            iterationCount = .infinity
        } else if let count = number(raw["iterationCount"]) {
            iterationCount = count < 0 || !count.isFinite ? .infinity : count
        }
        iterationStart = max(0, number(raw["iterationStart"]) ?? 0)
        iterationDuration = max(0, number(raw["iterationDuration"]) ?? 0)
        timingFunction = raw["timingFunction"] as? String
        playbackDirection = raw["playbackDirection"] as? String
        fillMode = raw["fillMode"] as? String
        keyframes = (raw["keyframes"] as? [[String: Any]] ?? []).compactMap { frame in
            guard let offset = number(frame["offset"]) else { return nil }
            return Keyframe(offset: offset, easing: frame["easing"] as? String, style: frame["style"] as? String)
        }
    }

    var infinite: Bool { !iterationCount.isFinite }
}

/// One animation the page started, as the drawer keeps it.
struct DeveloperAnimation: Identifiable, Equatable {
    enum Kind: Equatable { case cssAnimation, cssTransition, script }

    let id: String
    var name: String?
    var kind: Kind
    var effect: DeveloperAnimationEffect
    /// When the drawer heard of it, in milliseconds since 1970; what
    /// animations are grouped by.
    let arrival: Double
    /// The element it animates, for Reveal in Elements.
    var node: Int?
    var pseudo: String?
    /// `div#hero.card`, as Chrome labels a row.
    var label: String?
    /// Gone from the page: still shown, but can't be replayed.
    var destroyed = false
    /// The scroll or view timeline it follows, for a scroll-driven one.
    var scrollTimeline: ScrollTimeline?
    /// The view transition (its number in the page) whose pseudo-element
    /// it animates, as the page hook read it.
    var viewTransition: Int?

    /// A ScrollTimeline or ViewTimeline, as the page object describes it.
    struct ScrollTimeline: Equatable {
        enum Kind: String { case scroll, view }
        var kind: Kind
        /// block, inline, x or y.
        var axis: String
        /// The scroller (a scroll timeline) or the subject (a view timeline).
        var source: String
        /// The animation's rangeStart and rangeEnd, as CSS writes them.
        var rangeStart: String?
        var rangeEnd: String?

        /// The group it's listed in: animations following the same timeline.
        var key: String { kind.rawValue + "|" + axis + "|" + source }

        /// What a scroll-driven animation's row says in place of a time:
        /// its timeline and the part of the scroll it runs over.
        var range: String {
            let start = rangeStart.flatMap { $0.isEmpty || $0 == "normal" ? nil : $0 }
            let end = rangeEnd.flatMap { $0.isEmpty || $0 == "normal" ? nil : $0 }
            let span = start == nil && end == nil
                ? (kind == .view ? "cover 0% – cover 100%" : "0% – 100%")
                : (start ?? (kind == .view ? "cover 0%" : "0%")) + " – " + (end ?? (kind == .view ? "cover 100%" : "100%"))
            return (kind == .view ? "view(" : "scroll(") + axis + ") of " + source + ": " + span
        }
    }

    /// An animation of a view transition's pseudo-elements, by the hook or
    /// by WebKit's own report of it.
    var isViewTransitionPseudo: Bool {
        viewTransition != nil || (pseudo?.hasPrefix("view-transition") ?? false)
            || (label?.contains("::view-transition") ?? false)
    }

    init(id: String, name: String? = nil, kind: Kind = .script, effect: DeveloperAnimationEffect = .init(),
         arrival: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.effect = effect
        self.arrival = arrival
    }

    init?(raw: [String: Any], arrival: Double) {
        guard let id = raw["animationId"] as? String, !id.isEmpty else { return nil }
        let animationName = (raw["cssAnimationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let property = (raw["cssTransitionProperty"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, name: animationName ?? property ?? (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  kind: animationName != nil ? .cssAnimation : property != nil ? .cssTransition : .script,
                  effect: (raw["effect"] as? [String: Any]).map(DeveloperAnimationEffect.init(raw:)) ?? .init(),
                  arrival: arrival)
    }

    /// The row's name: the @keyframes name, the transitioned property, or
    /// the script's own name for it.
    var title: String { name ?? (kind == .cssTransition ? "transition" : "(anonymous)") }
}

/// Animations started together (within about a frame), as Chrome's
/// Animations tool groups them in its list.
struct DeveloperAnimationGroup: Identifiable, Equatable {
    /// Started together; following the same scroll or view timeline; or
    /// the animations of one view transition.
    enum Kind: Equatable { case time, scrollDriven, viewTransition }

    /// Its first animation's id, so it keeps its identity as more join.
    let id: String
    /// When its first animation started, in milliseconds since 1970.
    let start: Double
    var animations: [DeveloperAnimation]
    var kind = Kind.time

    init(id: String, start: Double, animations: [DeveloperAnimation], kind: Kind = .time) {
        self.id = id
        self.start = start
        self.animations = animations
        self.kind = kind
    }

    /// The label Chrome gives a group that isn't timed: "Scroll-driven",
    /// "View transition".
    var title: String? {
        switch kind {
        case .time: nil
        case .scrollDriven: "Scroll-driven"
        case .viewTransition: "View transition"
        }
    }

    /// Whether it plays in time, so Replay, the scrubber and the speeds apply.
    var playable: Bool { kind == .time }

    /// Where an animation of the group starts on its timeline.
    func offset(of animation: DeveloperAnimation) -> Double { max(0, animation.arrival - start) }
}

/// The drawer's arithmetic, apart from the page: grouping, timeline
/// geometry, durations and keyframe positions.
enum DeveloperAnimationTimeline {
    /// Chrome puts animations started within a frame of each other in one group.
    static let groupingWindow = 1000.0 / 60
    /// An endless animation is drawn for this many iterations.
    static let infiniteIterationsShown = 3.0
    /// Beyond this many iterations a bar is drawn at this many; the
    /// timeline would be all iterations otherwise.
    static let iterationsShownLimit = 100.0
    /// The shortest timeline, so a 0ms transition still has a bar.
    static let minimumDuration = 100.0

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            if string.lowercased() == "infinity" { return .infinity }
            return Double(string)
        default: return nil
        }
    }

    // MARK: Grouping

    /// Groups in the order they started: each animation joins the group
    /// its first animation started less than `window` before it. A
    /// scroll-driven animation joins the others following its timeline;
    /// a view transition's are a group of their own. With
    /// `hidingViewTransitionPseudos`, WebKit's own reports of a view
    /// transition's pseudo-element animations are left out, the page hook
    /// having listed them.
    static func groups(_ animations: [DeveloperAnimation], window: Double = groupingWindow,
                       hidingViewTransitionPseudos: Bool = false) -> [DeveloperAnimationGroup] {
        let ordered = animations.enumerated().sorted {
            $0.element.arrival != $1.element.arrival ? $0.element.arrival < $1.element.arrival : $0.offset < $1.offset
        }.map(\.element)
        var groups: [DeveloperAnimationGroup] = []
        var timed: Int?
        var scrollGroups: [String: Int] = [:]
        var transitionGroups: [Int: Int] = [:]
        for animation in ordered {
            if let transition = animation.viewTransition {
                if let at = transitionGroups[transition] {
                    groups[at].animations.append(animation)
                } else {
                    transitionGroups[transition] = groups.count
                    groups.append(DeveloperAnimationGroup(id: "view-transition:\(transition)", start: animation.arrival,
                                                          animations: [animation], kind: .viewTransition))
                }
                continue
            }
            if hidingViewTransitionPseudos, animation.isViewTransitionPseudo { continue }
            if let timeline = animation.scrollTimeline {
                if let at = scrollGroups[timeline.key] {
                    groups[at].animations.append(animation)
                } else {
                    scrollGroups[timeline.key] = groups.count
                    groups.append(DeveloperAnimationGroup(id: "scroll:" + animation.id, start: animation.arrival,
                                                          animations: [animation], kind: .scrollDriven))
                }
                continue
            }
            if let at = timed, animation.arrival - groups[at].start < window {
                groups[at].animations.append(animation)
            } else {
                timed = groups.count
                groups.append(DeveloperAnimationGroup(id: animation.id, start: animation.arrival, animations: [animation]))
            }
        }
        return groups
    }

    // MARK: Scroll-driven animations and view transitions

    /// The timeline an animation's page object described (describeFunction's
    /// `timeline`): a scroll or view timeline, or nil for the document's.
    static func scrollTimeline(_ raw: Any?) -> DeveloperAnimation.ScrollTimeline? {
        guard let raw = raw as? [String: Any], let type = raw["type"] as? String else { return nil }
        let kind: DeveloperAnimation.ScrollTimeline.Kind
        switch type {
        case "ViewTimeline", "view": kind = .view
        case "ScrollTimeline", "scroll": kind = .scroll
        default: return nil
        }
        let axis = (raw["axis"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "block"
        let source = (raw["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .view ? "(subject)" : "(scroller)")
        return DeveloperAnimation.ScrollTimeline(kind: kind, axis: axis, source: source,
                                                 rangeStart: raw["rangeStart"] as? String, rangeEnd: raw["rangeEnd"] as? String)
    }

    /// Ids of the animations made from the page hook's view transitions.
    static let viewTransitionPrefix = "view-transition:"

    /// A view transition the page hook noted: its pseudo-elements'
    /// animations, as the drawer lists them.
    static func viewTransitionAnimations(_ raw: [String: Any]) -> [DeveloperAnimation] {
        guard let serial = (raw["id"] as? NSNumber)?.intValue else { return [] }
        let time = number(raw["time"]) ?? 0
        let list = raw["animations"] as? [[String: Any]] ?? []
        return list.enumerated().map { index, item in
            let pseudo = (item["pseudo"] as? String) ?? "::view-transition"
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let iterations = number(item["iterations"]) ?? 1
            let effect = DeveloperAnimationEffect(
                startDelay: max(0, number(item["delay"]) ?? 0), endDelay: number(item["endDelay"]) ?? 0,
                iterationCount: iterations < 0 ? .infinity : iterations,
                iterationDuration: max(0, number(item["duration"]) ?? 0),
                timingFunction: (item["easing"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                playbackDirection: (item["direction"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                fillMode: (item["fill"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            var animation = DeveloperAnimation(id: viewTransitionPrefix + "\(serial):\(index)", name: name ?? pseudo,
                                               kind: .cssAnimation, effect: effect, arrival: time)
            animation.label = "html" + pseudo
            animation.pseudo = String(pseudo.drop { $0 == ":" })
            animation.viewTransition = serial
            return animation
        }
    }

    // MARK: Durations

    /// How many iterations a bar shows: an endless count drawn as a few.
    static func iterationsShown(_ effect: DeveloperAnimationEffect) -> Double {
        if effect.infinite { return infiniteIterationsShown }
        return min(max(0, effect.iterationCount), iterationsShownLimit)
    }

    /// The active part of an animation as drawn: duration × iterations.
    static func activeDuration(_ effect: DeveloperAnimationEffect) -> Double {
        effect.iterationDuration * iterationsShown(effect)
    }

    /// Where its bar starts and ends on its group's timeline.
    static func bar(_ animation: DeveloperAnimation, in group: DeveloperAnimationGroup) -> ClosedRange<Double> {
        let start = group.offset(of: animation) + animation.effect.startDelay
        return start...(start + activeDuration(animation.effect))
    }

    /// When an animation is done on its group's timeline: its delays and
    /// its iterations, endless ones counted as drawn.
    static func end(of animation: DeveloperAnimation, in group: DeveloperAnimationGroup) -> Double {
        bar(animation, in: group).upperBound + max(0, animation.effect.endDelay)
    }

    /// How long the group's timeline is: until its last animation ends.
    static func duration(of group: DeveloperAnimationGroup) -> Double {
        max(minimumDuration, group.animations.map { end(of: $0, in: group) }.max() ?? 0)
    }

    /// Whether the scrubber goes round again at the end, as it does for a
    /// group with an endless animation in it.
    static func loops(_ group: DeveloperAnimationGroup) -> Bool {
        group.animations.contains { $0.effect.infinite }
    }

    /// Where the scrubber is `elapsed` ms after the group started playing.
    static func position(elapsed: Double, duration: Double, loops: Bool) -> Double {
        guard duration > 0, elapsed > 0 else { return 0 }
        return loops ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
    }

    // MARK: Geometry

    static func x(_ time: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    /// The time under a point on the track, kept on the timeline.
    static func time(atX x: CGFloat, duration: Double, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(duration, max(0, Double(x / width) * duration))
    }

    /// The ruler's marks: a round step (1, 2 or 5 × 10ⁿ ms) at least
    /// `spacing` points apart.
    static func ticks(duration: Double, width: CGFloat, spacing: CGFloat = 70) -> [Double] {
        guard duration > 0, width > 0 else { return [0] }
        let least = duration * Double(spacing / width)
        var step = 1.0
        var scale = 1.0
        search: while true {
            for factor in [1.0, 2.0, 5.0] where factor * scale >= least {
                step = factor * scale
                break search
            }
            scale *= 10
        }
        return stride(from: 0, through: duration, by: step).map { $0 }
    }

    /// `0`, `250 ms`, `1.5 s`, as Chrome labels times.
    static func label(_ ms: Double) -> String {
        if ms == 0 { return "0" }
        if !ms.isFinite { return "∞" }
        if abs(ms) < 1000 { return "\(Int(ms.rounded())) ms" }
        let seconds = (ms / 10).rounded() / 100
        var text = String(format: "%.2f", seconds)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " s"
    }

    // MARK: Editing timing

    /// The part of a bar a drag took hold of: the bar itself moves the
    /// start (the delay); the end of its first iteration stretches it (the
    /// duration), as Chrome's handles do.
    enum Handle: Equatable { case body, end }

    /// How near the end of the first iteration a drag has to start, in
    /// points, to take hold of the duration rather than the delay.
    static let handleWidth: CGFloat = 6

    /// Which part of the bar is under `x`, if any.
    static func handle(atX x: CGFloat, _ animation: DeveloperAnimation, in group: DeveloperAnimationGroup,
                       duration: Double, width: CGFloat) -> Handle? {
        let span = Self.bar(animation, in: group)
        let start = Self.x(span.lowerBound, duration: duration, width: width)
        let firstEnd = Self.x(span.lowerBound + animation.effect.iterationDuration, duration: duration, width: width)
        let end = max(start + 2, Self.x(span.upperBound, duration: duration, width: width))
        if abs(x - firstEnd) <= handleWidth { return .end }
        if x >= start - 2, x <= end + 2 { return .body }
        return nil
    }

    /// The delay and duration after dragging a handle `delta` ms: never
    /// below zero, whole milliseconds, as Chrome sets them.
    static func retimed(_ effect: DeveloperAnimationEffect, _ handle: Handle, by delta: Double) -> (delay: Double, duration: Double) {
        switch handle {
        case .body: (max(0, (effect.startDelay + delta).rounded()), effect.iterationDuration)
        case .end: (effect.startDelay, max(0, (effect.iterationDuration + delta).rounded()))
        }
    }

    // MARK: Keyframes

    /// The keyframes' offsets in an iteration, 0…1, in order. A transition
    /// (no keyframes sent) goes from 0 to 1.
    static func keyframeOffsets(_ effect: DeveloperAnimationEffect) -> [Double] {
        let offsets = Set(effect.keyframes.map { min(1, max(0, $0.offset)) }).sorted()
        return offsets.isEmpty ? [0, 1] : offsets
    }

    /// Whether iteration `index` (from 0) plays backwards.
    static func reversed(_ index: Int, direction: String?) -> Bool {
        switch direction?.lowercased() {
        case "reverse": true
        case "alternate": index % 2 == 1
        case "alternate-reverse", "alternatereverse": index % 2 == 0
        default: false
        }
    }

    /// Where each keyframe falls on the bar, every iteration shown, a
    /// backward iteration's mirrored; `start` is where the bar starts.
    static func keyframeTimes(_ effect: DeveloperAnimationEffect, start: Double) -> [Double] {
        let shown = iterationsShown(effect)
        let duration = effect.iterationDuration
        let end = start + duration * shown
        let offsets = keyframeOffsets(effect)
        var times: [Double] = []
        var index = 0
        while Double(index) < shown, times.count < 2000 {
            let base = start + Double(index) * duration
            let backward = reversed(index, direction: effect.playbackDirection)
            for offset in offsets {
                let time = base + (backward ? 1 - offset : offset) * duration
                if time <= end + 0.0001 { times.append(time) }
            }
            index += 1
        }
        return Array(Set(times.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }

    /// Where one iteration ends and the next begins on the bar.
    static func iterationBoundaries(_ effect: DeveloperAnimationEffect, start: Double) -> [Double] {
        let shown = iterationsShown(effect)
        guard effect.iterationDuration > 0, shown > 1 else { return [] }
        return (1..<Int(shown.rounded(.up))).map { start + Double($0) * effect.iterationDuration }
    }

    // MARK: Presentation

    /// Which of `count` colours a row is drawn in: the same name, the same
    /// colour, as Chrome keeps one per name.
    static func colorIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return Int(hash % UInt32(count))
    }

    /// What hovering a bar tells: its timing, as Chrome's popover does.
    static func summary(_ animation: DeveloperAnimation) -> String {
        let effect = animation.effect
        let iterations = effect.infinite ? "infinite" : effect.iterationCount.formatted()
        var lines = [
            animation.title,
            "Duration: " + label(effect.iterationDuration),
            "Delay: " + label(effect.startDelay),
        ]
        if effect.endDelay != 0 { lines.append("End delay: " + label(effect.endDelay)) }
        lines.append("Iterations: " + iterations)
        lines.append("Easing: " + (effect.timingFunction ?? "linear"))
        if let direction = effect.playbackDirection, direction.lowercased() != "normal" {
            lines.append("Direction: " + direction)
        }
        if let fill = effect.fillMode, !["none", "auto"].contains(fill.lowercased()) { lines.append("Fill: " + fill) }
        return lines.joined(separator: "\n")
    }
}

/// The page's animations as the drawer heard them, and its playback
/// controls. One per DevTools session, kept while the drawer tab is closed
/// and reopened, as Chrome keeps what it recorded.
@MainActor
final class DeveloperAnimations: ObservableObject {
    @Published private(set) var animations: [DeveloperAnimation] = []
    @Published private(set) var groups: [DeveloperAnimationGroup] = []
    @Published var selection: String? { didSet { if selection != oldValue { origin = nil; scrubbed = nil } } }
    /// Pause all: the page's animations held, and new ones held as they start.
    @Published private(set) var paused = false
    /// Playback speed: 1, 0.25 or 0.1, for running and new animations alike.
    @Published private(set) var rate = 1.0
    @Published private(set) var problem: String?
    @Published private(set) var listening = false
    /// Where the selected group was scrubbed to, or paused at; nil while it plays.
    @Published private(set) var scrubbed: Double?
    /// When the selected group (re)started playing, if not when it started.
    @Published private(set) var origin: Double?
    /// What the page's WebKit has, as the page hook found: nil until it ran.
    @Published private(set) var viewTransitionsSupported: Bool?
    @Published private(set) var scrollTimelinesSupported: Bool?
    /// How many view transitions the page started while the drawer listened.
    @Published private(set) var viewTransitionCount = 0

    static let rates = [1.0, 0.25, 0.1]
    static let limit = 1000
    private static let objectGroup = "perch-animations"
    static let install = DevToolsResources.script("DeveloperAnimations-install.js")
    static let pageHook = DevToolsResources.script("DeveloperAnimations-page.js")

    private weak var session: DeveloperToolsSession?
    private var poll: Task<Void, Never>?
    private var enabledTarget: String??
    private var address: URL?
    /// Animations' page objects, resolved once.
    private var objects: [String: String] = [:]
    private var pendingScrub: Double?
    private var scrubbing: Task<Void, Never>?

    static func model(for session: DeveloperToolsSession) -> DeveloperAnimations {
        DeveloperSessionModels.model(for: session, make: DeveloperAnimations.init)
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    var selectedGroup: DeveloperAnimationGroup? { groups.first { $0.id == selection } }

    // MARK: Listening

    /// While the tool is shown, the frontend's events are collected every
    /// quarter second; while it's hidden the frontend keeps them.
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            // Ends with the model, not only on stop().
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    private func tick() async {
        guard let session, session.ready else { return }
        if session.address != address {
            if address != nil { reset() }
            address = session.address
        }
        do {
            let raw = try await session.evaluateInFrontend(
                Self.install + "\nreturn {fresh, ...perchAnimations.drain()};") as? [String: Any] ?? [:]
            let target = session.domTargetID
            if raw["fresh"] as? Bool == true || enabledTarget != .some(target) {
                if enabledTarget != nil, enabledTarget != .some(target) { reset() }
                try await enable(session, target: target)
            }
            apply(raw)
            await collectViewTransitions(session)
            if listening, problem != nil { problem = nil }
        } catch is CancellationError {
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Animation.enable, once per target. WebKit refuses a second enable
    /// (its own frontend may have asked first), so then the domain is
    /// turned off and on, which sends the page's running animations again.
    private func enable(_ session: DeveloperToolsSession, target: String?) async throws {
        do {
            _ = try await session.command("Animation.enable", targetID: target)
        } catch {
            _ = try? await session.command("Animation.disable", targetID: target)
            do {
                _ = try await session.command("Animation.enable", targetID: target)
            } catch {
                listening = false
                enabledTarget = .some(target)
                throw DeveloperAnimationsError("WebKit can’t report this page’s animations.")
            }
        }
        enabledTarget = .some(target)
        listening = true
    }

    private func apply(_ raw: [String: Any]) {
        guard let events = raw["events"] as? [[String: Any]], !events.isEmpty else { return }
        let frontendNow = DeveloperAnimationTimeline.number(raw["now"]) ?? 0
        let now = Self.now()
        var list = animations
        var index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var created: [DeveloperAnimation] = []
        var retarget: [String] = []
        var refetch: [String] = []
        for event in events {
            guard let method = event["method"] as? String, let params = event["params"] as? [String: Any] else { continue }
            let time = DeveloperAnimationTimeline.number(event["time"]) ?? frontendNow
            if method == "Animation.animationCreated" {
                guard let raw = params["animation"] as? [String: Any],
                      let animation = DeveloperAnimation(raw: raw, arrival: now - max(0, frontendNow - time)),
                      index[animation.id] == nil else { continue }
                index[animation.id] = list.count
                list.append(animation)
                created.append(animation)
                continue
            }
            guard let id = params["animationId"] as? String, let at = index[id] else { continue }
            switch method {
            case "Animation.nameChanged":
                if let name = params["name"] as? String, !name.isEmpty { list[at].name = name }
            case "Animation.effectChanged":
                // Current WebKit sends only the id (the timing is asked for
                // with Animation.requestEffect); older ones sent the effect.
                if let effect = params["effect"] as? [String: Any] { list[at].effect = DeveloperAnimationEffect(raw: effect) }
                else { refetch.append(id) }
            case "Animation.targetChanged":
                retarget.append(id)
            case "Animation.animationDestroyed":
                list[at].destroyed = true
                objects[id] = nil
            default: break
            }
        }
        if list.count > Self.limit {
            let dropped = list.prefix(list.count - Self.limit)
            for animation in dropped { objects[animation.id] = nil }
            list.removeFirst(list.count - Self.limit)
        }
        if list != animations {
            animations = list
            groups = regroup(list)
            if selectedGroup == nil { selection = groups.last?.id }
        }
        for animation in created {
            requestEffect(animation.id)
            describe(animation.id, holdIfNeeded: true)
        }
        for id in Set(retarget) { describe(id, holdIfNeeded: false) }
        for id in Set(refetch).subtracting(retarget) { requestEffect(id) }
    }

    private func regroup(_ list: [DeveloperAnimation]) -> [DeveloperAnimationGroup] {
        DeveloperAnimationTimeline.groups(list, hidingViewTransitionPseudos: viewTransitionsSupported == true)
    }

    /// The page hook: installed in the page as it is (again after a
    /// navigation), and the view transitions it noted since.
    private func collectViewTransitions(_ session: DeveloperToolsSession) async {
        guard let reply = try? await session.command("Runtime.evaluate", [
            "expression": Self.pageHook, "returnByValue": true, "doNotPauseOnExceptionsAndMuteConsole": true,
        ], targetID: session.runtimeTargetID),
            reply["wasThrown"] as? Bool != true,
            let value = (reply["result"] as? [String: Any])?["value"] as? [String: Any] else { return }
        let supported = value["viewTransitions"] as? Bool
        if supported != viewTransitionsSupported { viewTransitionsSupported = supported }
        let scroll = value["scrollTimelines"] as? Bool
        if scroll != scrollTimelinesSupported { scrollTimelinesSupported = scroll }
        let transitions = value["transitions"] as? [[String: Any]] ?? []
        guard !transitions.isEmpty else { return }
        viewTransitionCount += transitions.count
        var list = animations
        let known = Set(list.map(\.id))
        for transition in transitions {
            list += DeveloperAnimationTimeline.viewTransitionAnimations(transition).filter { !known.contains($0.id) }
        }
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        guard list != animations else { return }
        animations = list
        groups = regroup(list)
        // As Chrome does, the newest transition is shown.
        if let last = groups.last(where: { $0.kind == .viewTransition }) { selection = last.id }
    }

    /// The animation's timing, from Animation.requestEffect. Current WebKit
    /// leaves the effect out of animationCreated and effectChanged (its
    /// own frontend asks for it the same way); an older one that sent it
    /// and lacks the command keeps what came with the event.
    private func requestEffect(_ id: String) {
        guard let session else { return }
        let target = session.domTargetID
        Task { [weak self] in
            guard let reply = try? await session.command("Animation.requestEffect", ["animationId": id], targetID: target),
                  let raw = reply["effect"] as? [String: Any],
                  let self, let at = self.animations.firstIndex(where: { $0.id == id }) else { return }
            let effect = DeveloperAnimationEffect(raw: raw)
            guard effect != self.animations[at].effect else { return }
            self.animations[at].effect = effect
            self.groups = self.regroup(self.animations)
        }
    }

    /// The animation's element: its node id, for Reveal in Elements, and
    /// a label for its row. New animations are paused or slowed as all are.
    private func describe(_ id: String, holdIfNeeded: Bool) {
        guard let session else { return }
        let target = session.domTargetID
        let paused = self.paused
        let rate = self.rate
        Task { [weak self] in
            let reply = try? await session.command("Animation.requestEffectTarget", ["animationId": id], targetID: target)
            // Newer WebKit answers {effectTarget: {nodeId, pseudoId}} (a
            // DOM.Styleable), older {effectTarget: nodeId}, as Web
            // Inspector's own WI.Animation reads it.
            let bare = (reply?["effectTarget"] as? NSNumber)?.intValue
            let effectTarget = reply?["effectTarget"] as? [String: Any] ?? reply
            let node = bare ?? (effectTarget?["nodeId"] as? NSNumber)?.intValue
            let pseudo = effectTarget?["pseudoId"] as? String
            let value = try? await self?.call(id, Self.describeFunction, arguments: [holdIfNeeded && paused, holdIfNeeded ? rate : 1])
            guard let self, let at = self.animations.firstIndex(where: { $0.id == id }) else { return }
            var animation = self.animations[at]
            animation.node = node.flatMap { $0 > 0 ? $0 : nil }
            animation.pseudo = pseudo
            animation.scrollTimeline = DeveloperAnimationTimeline.scrollTimeline((value as? [String: Any])?["timeline"])
            if let label = (value as? [String: Any])?["label"] as? String, !label.isEmpty {
                animation.label = label
            } else if let node, let name = session.nodes[node]?.name {
                animation.label = name.lowercased() + (pseudo.map { "::" + $0 } ?? "")
            }
            guard animation != self.animations[at] else { return }
            self.animations[at] = animation
            self.groups = self.regroup(self.animations)
        }
    }

    /// Runs `function` on the animation's page object, resolved once and
    /// kept; returns its value.
    private func call(_ id: String, _ function: String, arguments: [Any] = []) async throws -> Any? {
        // The page hook's view transition animations have no object here.
        guard let session, !id.hasPrefix(DeveloperAnimationTimeline.viewTransitionPrefix) else { return nil }
        let target = session.domTargetID
        for attempt in 0..<2 {
            let objectID: String
            if let known = objects[id] {
                objectID = known
            } else {
                let resolved = try await session.command("Animation.resolveAnimation",
                                                         ["animationId": id, "objectGroup": Self.objectGroup], targetID: target)
                guard let object = (resolved["object"] ?? resolved["result"]) as? [String: Any],
                      let found = object["objectId"] as? String else { return nil }
                objectID = found
                objects[id] = found
            }
            do {
                let reply = try await session.command("Runtime.callFunctionOn", [
                    "objectId": objectID, "functionDeclaration": function,
                    "arguments": arguments.map { ["value": $0] }, "returnByValue": true,
                ], targetID: target)
                if reply["wasThrown"] as? Bool == true {
                    throw DeveloperAnimationsError(((reply["result"] as? [String: Any])?["description"] as? String) ?? "The animation refused.")
                }
                return (reply["result"] as? [String: Any])?["value"]
            } catch {
                // A stale object (the page dropped it): resolve once more.
                objects[id] = nil
                if attempt == 1 { throw error }
            }
        }
        return nil
    }

    // MARK: Controls

    func clear() {
        animations = []
        groups = []
        selection = nil
        releaseObjects()
    }

    /// The page moved on: what was heard belongs to the old one.
    private func reset() {
        clear()
        enabledTarget = nil
        listening = false
    }

    private func releaseObjects() {
        objects = [:]
        guard let session, session.ready else { return }
        let target = session.domTargetID
        Task { _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": Self.objectGroup], targetID: target) }
    }

    /// Where the selected group's scrubber is now.
    func position(at now: Double) -> Double {
        guard let group = selectedGroup else { return 0 }
        if let scrubbed { return scrubbed }
        let duration = DeveloperAnimationTimeline.duration(of: group)
        return DeveloperAnimationTimeline.position(elapsed: (now - (origin ?? group.start)) * rate, duration: duration,
                                                   loops: DeveloperAnimationTimeline.loops(group))
    }

    var playing: Bool { selectedGroup != nil && scrubbed == nil && !paused }

    func togglePause() { setPaused(!paused) }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        let now = Self.now()
        if paused {
            if scrubbed == nil, selectedGroup != nil { scrubbed = position(at: now) }
        } else if let scrubbed {
            origin = now - scrubbed / rate
            self.scrubbed = nil
        }
        self.paused = paused
        evaluate("""
            for (const animation of document.getAnimations()) {
                if (animation.timeline && animation.timeline !== document.timeline) continue;
                if (\(paused)) { if (animation.playState === "running") animation.pause(); }
                else if (animation.playState === "paused") animation.play();
            }
            """)
    }

    func setRate(_ rate: Double) {
        guard rate != self.rate, rate > 0 else { return }
        if scrubbed == nil, selectedGroup != nil {
            let now = Self.now()
            let at = position(at: now)
            origin = now - at / rate
        }
        self.rate = rate
        evaluate("""
            for (const animation of document.getAnimations()) {
                if (animation.timeline && animation.timeline !== document.timeline) continue;
                animation.playbackRate = \(rate);
            }
            """)
    }

    /// The animation's delay and duration changed, as dragging its bar does
    /// in Chrome: shown at once, and set in the page with the effect's
    /// updateTiming (WebKit's Animation domain can't change timing); what
    /// the page then reports is kept.
    func retime(_ id: String, delay: Double, duration: Double) {
        guard let at = animations.firstIndex(where: { $0.id == id }), !animations[at].destroyed,
              animations[at].scrollTimeline == nil, animations[at].viewTransition == nil else { return }
        let delay = max(0, delay.rounded())
        let duration = max(0, duration.rounded())
        var effect = animations[at].effect
        guard effect.startDelay != delay || effect.iterationDuration != duration else { return }
        effect.startDelay = delay
        effect.iterationDuration = duration
        animations[at].effect = effect
        groups = regroup(animations)
        Task { [weak self] in
            do {
                let value = try await self?.call(id, Self.retimeFunction, arguments: [delay, duration])
                guard let self, let timing = value as? [String: Any],
                      let index = self.animations.firstIndex(where: { $0.id == id }) else { return }
                var effect = self.animations[index].effect
                if let set = DeveloperAnimationTimeline.number(timing["delay"]) { effect.startDelay = max(0, set) }
                if let set = DeveloperAnimationTimeline.number(timing["duration"]) { effect.iterationDuration = max(0, set) }
                guard effect != self.animations[index].effect else { return }
                self.animations[index].effect = effect
                self.groups = self.regroup(self.animations)
            } catch {
                self?.problem = error.localizedDescription
                self?.requestEffect(id)
            }
        }
    }

    /// Replay: the group's animations from the start, together.
    func replay() {
        guard let group = selectedGroup, group.playable else { return }
        origin = Self.now()
        scrubbed = paused ? 0 : nil
        let held = self.paused
        let rate = self.rate
        Task { [weak self] in
            for animation in group.animations where !animation.destroyed {
                _ = try? await self?.call(animation.id, Self.replayFunction, arguments: [rate, held])
            }
        }
    }

    /// The group held at `time` on its timeline, as dragging the scrubber
    /// does in Chrome. Drags are coalesced: the latest time wins.
    func scrub(to time: Double) {
        guard selectedGroup?.playable == true else { return }
        scrubbed = time
        pendingScrub = time
        guard scrubbing == nil else { return }
        scrubbing = Task { [weak self] in
            while let self, let time = self.pendingScrub, let group = self.selectedGroup {
                self.pendingScrub = nil
                for animation in group.animations where !animation.destroyed {
                    _ = try? await self.call(animation.id, Self.seekFunction, arguments: [time - group.offset(of: animation)])
                }
            }
            self?.scrubbing = nil
        }
    }

    private func evaluate(_ body: String) {
        guard let session, session.ready else { return }
        let target = session.runtimeTargetID
        Task { [weak self] in
            do {
                _ = try await session.command("Runtime.evaluate", [
                    "expression": "(() => {\n" + body + "\n})()", "returnByValue": true,
                ], targetID: target)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    // Run on an animation's page object (this).

    private static let describeFunction = """
        function(hold, rate) {
            const name = (element) => {
                if (!element || !element.nodeType) return "";
                let text = (element.localName || element.nodeName || "").toLowerCase();
                if (element.id) text += "#" + element.id;
                const list = element.classList ? Array.from(element.classList).slice(0, 3) : [];
                if (list.length) text += "." + list.join(".");
                return text.slice(0, 120);
            };
            const range = (value) => {
                if (value === undefined || value === null) return undefined;
                if (typeof value === "string") return value.slice(0, 80);
                const parts = [];
                if (value.rangeName) parts.push(String(value.rangeName));
                if (value.offset !== undefined && value.offset !== null) parts.push(String(value.offset));
                return parts.join(" ").slice(0, 80);
            };
            const line = this.timeline;
            let timeline = null;
            // A ViewTimeline is a ScrollTimeline too: it's asked first.
            if (line && typeof ViewTimeline === "function" && line instanceof ViewTimeline) {
                timeline = {type: "ViewTimeline", axis: String(line.axis || "block"), source: name(line.subject)};
            } else if (line && typeof ScrollTimeline === "function" && line instanceof ScrollTimeline) {
                timeline = {type: "ScrollTimeline", axis: String(line.axis || "block"), source: name(line.source)};
            }
            if (timeline) {
                timeline.rangeStart = range(this.rangeStart);
                timeline.rangeEnd = range(this.rangeEnd);
            } else {
                if (rate && rate !== 1) this.playbackRate = rate;
                if (hold && this.playState !== "finished") this.pause();
            }
            const effect = this.effect;
            const target = effect && effect.target;
            if (!target) return {label: "", timeline};
            let label = name(target);
            if (effect.pseudoElement) label += effect.pseudoElement;
            return {label: label.slice(0, 120), timeline};
        }
        """

    private static let replayFunction = """
        function(rate, hold) {
            this.playbackRate = rate;
            this.currentTime = 0;
            if (hold) this.pause(); else this.play();
        }
        """

    private static let retimeFunction = """
        function(delay, duration) {
            const effect = this.effect;
            if (!effect || typeof effect.updateTiming !== "function") throw new Error("This animation's timing can't be changed.");
            effect.updateTiming({delay, duration});
            const timing = effect.getTiming();
            return {delay: timing.delay, duration: typeof timing.duration === "number" ? timing.duration : 0};
        }
        """

    private static let seekFunction = """
        function(time) {
            this.pause();
            this.currentTime = Math.max(0, time);
        }
        """
}

struct DeveloperAnimationsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
