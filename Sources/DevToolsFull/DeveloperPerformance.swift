import Foundation

/// As in Chrome DevTools: the kinds of work the Performance panel colours
/// and totals in its Summary.
enum DeveloperPerformanceCategory: String, CaseIterable, Identifiable {
    case loading = "Loading"
    case scripting = "Scripting"
    case rendering = "Rendering"
    case painting = "Painting"
    case system = "System"

    var id: String { rawValue }

    /// The category of a WebKit timeline record type.
    static func of(_ type: String) -> Self {
        switch type {
        case "ParseHTML", "ResourceSendRequest", "ResourceReceiveResponse", "ResourceReceivedData", "ResourceFinish",
             "ParseAuthorStyleSheet":
            .loading
        case "EventDispatch", "FunctionCall", "EvaluateScript", "JavaScriptFrame", "TimerInstall", "TimerRemove", "TimerFire",
             "RequestAnimationFrame", "CancelAnimationFrame", "FireAnimationFrame", "ObserverCallback", "ProbeSample",
             "ConsoleProfile", "TimeStamp", "Time", "TimeEnd", "XHRReadyStateChange", "XHRLoad", "GCEvent":
            .scripting
        case "ScheduleStyleRecalculation", "RecalculateStyles", "InvalidateLayout", "Layout", "RenderingFrame",
             "UpdateLayoutTree", "HitTest":
            .rendering
        case "Paint", "Composite", "Screenshot", "Rasterize", "DecodeImage":
            .painting
        default:
            .system
        }
    }
}

/// One record of a recording as the Performance panel shows it: times in
/// milliseconds from the start of the recording, its row in the flame
/// chart, and the records drawn beneath it.
struct DeveloperPerformanceEvent: Identifiable, Equatable {
    let id: Int
    let type: String
    let title: String
    /// What the record was about: a script and line, an event's target, a
    /// timestamp's message.
    let detail: String?
    let category: DeveloperPerformanceCategory
    let start: Double
    let end: Double
    /// The flame chart row: how many records it is nested in.
    let row: Int
    let parent: Int?
    var children: [Int] = []
    /// The record's time less the time of the records nested in it.
    var selfTime: Double = 0
    let data: [String: String]
    let stack: [String]
    /// Merged into its parent by a flame chart hide (DeveloperFlameHides).
    var isHidden = false
    /// Has children a flame chart hide merged into it, which Chrome marks.
    var hidesChildren = false
    /// `stack` with full addresses, which the Summary links through source maps.
    var frames: [ConsoleCallFrame] = []

    var duration: Double { end - start }

    /// What Bottom-up and Call tree group by, as Chrome groups by activity.
    var activity: String { detail.map { "\(title) — \($0)" } ?? title }

    /// Chrome's names for WebKit's record types.
    static func title(_ type: String, data: [String: String]) -> String {
        switch type {
        case "EventDispatch": data["type"].map { "Event: \($0)" } ?? "Event"
        case "FunctionCall": "Function call"
        case "EvaluateScript": "Evaluate script"
        case "JavaScriptFrame": data["name"] ?? "(anonymous)"
        case "TimerInstall": "Install timer"
        case "TimerRemove": "Remove timer"
        case "TimerFire": "Timer fired"
        case "RequestAnimationFrame": "Request animation frame"
        case "CancelAnimationFrame": "Cancel animation frame"
        case "FireAnimationFrame": "Animation frame fired"
        case "ObserverCallback": "Observer callback"
        case "ScheduleStyleRecalculation": "Schedule style recalculation"
        case "RecalculateStyles": "Recalculate style"
        case "InvalidateLayout": "Invalidate layout"
        case "Layout": "Layout"
        case "Paint": "Paint"
        case "Composite": "Composite layers"
        case "RenderingFrame": "Frame"
        case "TimeStamp": "Timestamp"
        case "Time": "console.time"
        case "TimeEnd": "console.timeEnd"
        case "ConsoleProfile": "Profile"
        case "ProbeSample": "Probe sample"
        case "Screenshot": "Screenshot"
        case "ParseHTML": "Parse HTML"
        default: spaced(type)
        }
    }

    static func detail(_ type: String, data: [String: String]) -> String? {
        func place(_ address: String?, line: String?) -> String? {
            guard let address, !address.isEmpty else { return nil }
            let file = URL(string: address)?.lastPathComponent ?? address
            let number = line.flatMap(Int.init).map { ":\($0)" } ?? ""
            return (file.isEmpty ? address : file) + number
        }
        switch type {
        case "FunctionCall": return place(data["scriptName"] ?? data["url"], line: data["scriptLine"] ?? data["lineNumber"])
        case "EvaluateScript", "JavaScriptFrame": return place(data["url"], line: data["lineNumber"])
        case "ObserverCallback": return data["type"]
        case "TimeStamp", "Time", "TimeEnd": return data["message"]
        case "ConsoleProfile": return data["title"]
        default: return nil
        }
    }

    /// "RecalculateStyles" as "Recalculate styles".
    static func spaced(_ type: String) -> String {
        var words = ""
        for (index, character) in type.enumerated() {
            if index > 0, character.isUppercase { words.append(" ") }
            words += index > 0 ? character.lowercased() : String(character)
        }
        return words.isEmpty ? "Event" : words
    }
}

/// A node of Bottom-up or Call tree: an activity, the time spent in it
/// alone and in all, and what it called (Call tree) or what called it
/// (Bottom-up).
struct DeveloperPerformanceNode: Identifiable, Equatable {
    let id: String
    let activity: String
    let category: DeveloperPerformanceCategory
    var selfTime: Double
    var totalTime: Double
    var children: [DeveloperPerformanceNode]
    /// A row of Group by…, not an activity: its children are what's in the group.
    var isGroup = false
    /// A record of the activity, in `shown`, whose script place the row links.
    var event: Int? = nil

    /// For OutlineGroup, which wants nil at a leaf.
    var outline: [DeveloperPerformanceNode]? { children.isEmpty ? nil : children }
}

/// A recording laid out for the Performance panel: each record with its
/// flame chart row, parent and self time, and the totals the Summary,
/// Bottom-up, Call tree and Event log tabs show for a range of it.
struct DeveloperPerformanceProfile: Equatable {
    struct NetworkBar {
        let url: String
        let start: Double
        let end: Double
        /// WebKit's resource type: "Document", "Stylesheet", "Script"…
        var resourceType = "Other"
        /// When the response's headers came, in ms from the recording's start.
        var responseStart: Double?
        var status: Int?
        var mimeType: String?
        /// The response's Content-Encoding header.
        var encoding: String?
        /// Bytes over the network, when WebKit said.
        var transferSize: Double?
        /// Redirect hops before it, and how long they took.
        var redirects = 0
        var redirectTime = 0.0
        /// A hop that was redirected, not a request of its own.
        var isRedirect = false
        /// Its Cache-Control, Expires and Pragma headers.
        var cacheControl: String?
        var expires: String?
        var pragma: String?
        /// The protocol it went over ("http/1.1", "h2", "h3") and its
        /// priority ("low", "medium", "high"), as WebKit's metrics say.
        var networkProtocol: String?
        var priority: String?
        /// Who asked for it: WebKit's initiator type ("parser", "script",
        /// "other") and the document or script's URL.
        var initiatorType: String?
        var initiator: String?
        /// Where the response came from: "network", "memory-cache", "disk-cache"…
        var source: String?
        /// The body's size once decoded.
        var decodedSize: Double?
        /// The response's Content-Type header, as Character set reads it.
        var contentType: String?

        var duration: Double { end - start }

        /// The caching headers, lowercased, as Lighthouse's cache checks read them.
        var cacheHeaders: [String: String] {
            var headers: [String: String] = [:]
            if let cacheControl { headers["cache-control"] = cacheControl }
            if let expires { headers["expires"] = expires }
            if let pragma { headers["pragma"] = pragma }
            return headers
        }
    }

    struct HeapPoint {
        let time: Double
        let bytes: Double
    }

    /// The Timings track: a performance.mark (start and end the same), a
    /// performance.measure, or one of the page's milestones (FP, FCP,
    /// LCP, DCL, L), drawn as Chrome's markers.
    struct PageTiming: Equatable {
        let kind: String
        let name: String
        let start: Double
        let end: Double
        /// The Timings track row of a mark or measure.
        var row = 0
        /// A palette name (DeveloperPerformanceExtensions) for a measure
        /// an extended console.timeStamp put here.
        var color: String?

        var isMarker: Bool { DeveloperPerformanceProfile.markerKinds.contains(kind) }
    }

    /// The Interactions track: a user event the page handled, from its
    /// EventDispatch record.
    struct Interaction: Equatable {
        /// The EventDispatch record, in `events`.
        let event: Int
        let type: String
        /// From the input to the next paint after its handlers ran.
        let start: Double
        let end: Double
        /// When its handlers began and ended: the dispatch record.
        var processingStart: Double
        var processingEnd: Double
        var row = 0

        init(event: Int, type: String, start: Double, end: Double, processingStart: Double? = nil,
             processingEnd: Double? = nil, row: Int = 0) {
            self.event = event
            self.type = type
            self.start = start
            self.end = max(start, end)
            self.processingStart = min(max(processingStart ?? start, start), self.end)
            self.processingEnd = min(max(processingEnd ?? self.end, self.processingStart), self.end)
            self.row = row
        }

        var duration: Double { end - start }
        /// Chrome's three phases: waiting for the main thread, the event's
        /// handlers, and from them to the frame that showed their work.
        var inputDelay: Double { processingStart - start }
        var processingDuration: Double { processingEnd - processingStart }
        var presentationDelay: Double { end - processingEnd }
    }

    /// The Layout shifts track: a shift, its score, and up to five of the
    /// elements that moved, described ("div#hero.banner"); `index` finds
    /// them in the page again (DeveloperLiveMetricsModel.revealShiftNode).
    struct LayoutShift: Equatable {
        let time: Double
        let score: Double
        let index: Int?
        let nodes: [String]
    }

    /// The Animations track: a CSS animation or transition, from its first
    /// state to done or canceled, the part before it was active its delay.
    struct AnimationBar: Equatable {
        /// Its @keyframes name or transitioned property.
        let name: String
        /// "CSS animation", "CSS transition" or "Animation".
        let kind: String
        let start: Double
        let end: Double
        /// When it became active, in ms; its start when WebKit didn't say.
        let activeStart: Double
        /// How it ended: "done", "canceled", or "active" if still running.
        let state: String
        var node: Int?
        var row = 0

        init(name: String, kind: String, start: Double, end: Double, activeStart: Double? = nil,
             state: String = "done", node: Int? = nil, row: Int = 0) {
            self.name = name
            self.kind = kind
            self.start = start
            self.end = max(start, end)
            self.activeStart = min(max(activeStart ?? start, start), self.end)
            self.state = state
            self.node = node
            self.row = row
        }

        init(_ data: [String: String], start: Double, end: Double) {
            let kind = data["kind"] ?? "Animation"
            let offset = data["activeOffset"].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
            self.init(name: data["name"] ?? kind, kind: kind, start: start, end: end,
                      activeStart: offset.map { start + $0 }, state: data["state"] ?? "done",
                      node: data["node"].flatMap { Int($0) })
        }

        var duration: Double { end - start }
        var delay: Double { activeStart - start }
    }

    /// Shifts grouped as Chrome's clusters (and CLS's session windows) are:
    /// each less than a second after the last, five seconds at most.
    struct ShiftCluster: Equatable {
        let start: Double
        let end: Double
        let score: Double
        /// The cluster's shifts, in `layoutShifts`.
        let shifts: Range<Int>
    }

    static func clusters(_ shifts: [LayoutShift]) -> [ShiftCluster] {
        var result: [ShiftCluster] = []
        var first = 0
        for index in shifts.indices {
            let shift = shifts[index]
            if index > first, shift.time - shifts[index - 1].time < 1_000, shift.time - shifts[first].time < 5_000 { continue }
            if index > first { result.append(makeCluster(shifts, first..<index)) }
            first = index
        }
        if first < shifts.count { result.append(makeCluster(shifts, first..<shifts.count)) }
        return result
    }

    private static func makeCluster(_ shifts: [LayoutShift], _ range: Range<Int>) -> ShiftCluster {
        ShiftCluster(start: shifts[range.lowerBound].time, end: shifts[range.upperBound - 1].time,
                     score: shifts[range].reduce(0) { $0 + $1.score }, shifts: range)
    }

    /// The cluster a shift is in.
    func cluster(of shift: Int) -> ShiftCluster? {
        shiftClusters.first { $0.shifts.contains(shift) }
    }

    /// Chrome's milestones, in the order its Timings track lists them.
    static let markerKinds: [String] = ["FP", "FCP", "DCL", "LCP", "L"]
    /// As Chrome DevTools: a main-thread task over 50 ms is a long task.
    static let longTask = 50.0
    /// As Chrome DevTools: an interaction over 200 ms is a long interaction.
    static let longInteraction = 200.0
    /// The events Chrome's Interactions track shows: those that start an
    /// interaction, not moves and hovers.
    static let interactionTypes: Set<String> = [
        "click", "dblclick", "auxclick", "contextmenu", "mousedown", "mouseup",
        "pointerdown", "pointerup", "pointercancel", "keydown", "keyup", "keypress",
        "touchstart", "touchend", "touchcancel",
    ]

    private(set) var events: [DeveloperPerformanceEvent] = []
    private(set) var network: [NetworkBar] = []
    private(set) var heap: [HeapPoint] = []
    /// The CPU track's readings, in time order (DeveloperPerformanceCPU).
    private(set) var cpu: [DeveloperPerformanceCPU.Sample] = []
    /// The Animations track's bars, from a profile that has them (one
    /// opened from a file).
    private(set) var animations: [AnimationBar] = []
    private(set) var animationRows = 0
    /// How long the recording ran, in milliseconds.
    private(set) var duration: Double = 0
    /// How many flame chart rows it needs.
    private(set) var rows = 0
    /// The Screenshot instrument's frames, in ms from the recording's
    /// start, kept out of the flame chart.
    private(set) var screenshots: [DeveloperPerformanceScreenshot] = []
    /// The Timings track's marks and measures, and its markers.
    private(set) var pageTimings: [PageTiming] = []
    private(set) var markers: [PageTiming] = []
    private(set) var timingRows = 0
    /// Chrome's extensibility API (DeveloperPerformanceExtensions): the
    /// custom tracks, after the built-in ones, a group's together, and the
    /// markers the page's marks put down the timeline, in time order.
    private(set) var customTracks: [DeveloperPerformanceExtensions.Track] = []
    private(set) var extensionMarkers: [DeveloperPerformanceExtensions.Marker] = []
    private(set) var interactions: [Interaction] = []
    private(set) var interactionRows = 0
    /// The Frames track: the RenderingFrame records, in `events`.
    private(set) var frames: [Int] = []
    /// Main-thread top-level tasks over 50 ms, in `events`.
    private(set) var longTasks: [Int] = []
    private(set) var layoutShifts: [LayoutShift] = []
    private(set) var shiftClusters: [ShiftCluster] = []
    /// What the page said about itself as the recording stopped (its
    /// address, LCP image, DOM size), for Insights.
    private(set) var pageInfo: [String: String] = [:]
    /// What the flame chart's context menu has hidden: view state, kept
    /// with the recording and gone with it.
    private(set) var hides = DeveloperFlameHides()
    /// `events` with `hides` applied, same ids: what the Main track, Call
    /// tree and Bottom-up show. A hidden record is marked `isHidden`.
    private(set) var shown: [DeveloperPerformanceEvent] = []
    /// How many flame chart rows `shown` needs.
    private(set) var shownRows = 0
    /// Compared in place of the events, which can number thousands.
    private let revision = UUID()

    static func == (a: Self, b: Self) -> Bool { a.revision == b.revision && a.hides == b.hides }

    var bounds: ClosedRange<Double> { 0...max(duration, 1) }
    var isEmpty: Bool {
        events.isEmpty && screenshots.isEmpty && network.isEmpty && heap.isEmpty && pageTimings.isEmpty && markers.isEmpty
            && layoutShifts.isEmpty && cpu.isEmpty && animations.isEmpty && customTracks.isEmpty && extensionMarkers.isEmpty
    }

    /// The last screenshot taken at or before `time`, as Chrome shows on hover.
    func screenshot(at time: Double) -> DeveloperPerformanceScreenshot? {
        screenshots.last { $0.time <= time } ?? (screenshots.first.flatMap { $0.time - time < 1 ? $0 : nil })
    }

    init() {}

    init(_ timings: [DeveloperToolsSession.Timing]) {
        guard let origin = timings.map(\.start).min() else { return }
        // Lay records out by time, as Chrome does: a record starting
        // inside another goes on the row beneath it. Longer records come
        // first when two start together, so the container is the parent.
        let order = timings.indices.sorted { a, b in
            let x = timings[a], y = timings[b]
            if x.start != y.start { return x.start < y.start }
            if x.end != y.end { return x.end > y.end }
            return x.depth < y.depth
        }
        let slack = 0.000_5
        var open: [Int] = []
        var customEntries: [(track: String, group: String?, entry: DeveloperPerformanceExtensions.Entry)] = []
        var built: [DeveloperPerformanceEvent] = []
        built.reserveCapacity(order.count)
        for index in order {
            let timing = timings[index]
            let start = (timing.start - origin) * 1_000
            let end = (timing.end - origin) * 1_000
            duration = max(duration, end)
            switch timing.type {
            case "RecordingBounds": continue
            case "NetworkRequest":
                if let url = timing.data["url"] { network.append(Self.networkBar(url, start: start, end: end, data: timing.data)) }
                continue
            case "PageInfo":
                pageInfo.merge(timing.data) { $1 }
                continue
            case "JSHeapSample":
                if let bytes = timing.data["bytes"].flatMap(Double.init), bytes.isFinite, bytes >= 0 {
                    heap.append(HeapPoint(time: start, bytes: bytes))
                }
                continue
            case DeveloperPerformanceCPU.type:
                if let sample = DeveloperPerformanceCPU.sample(timing.data, at: start) { cpu.append(sample) }
                continue
            case DeveloperPerformanceAnimationTrack.type:
                animations.append(AnimationBar(timing.data, start: start, end: end))
                continue
            case DeveloperPerformanceExtensions.type:
                if let item = DeveloperPerformanceExtensions.entry(timing.data, start: start, end: end) {
                    customEntries.append(item)
                } else if let marker = DeveloperPerformanceExtensions.marker(timing.data, at: start) {
                    extensionMarkers.append(marker)
                }
                continue
            default: break
            }
            if timing.type == "PageTiming" {
                let kind = timing.data["kind"] ?? "mark"
                let item = PageTiming(kind: kind, name: timing.data["name"] ?? kind, start: start, end: max(start, end),
                                      color: timing.data["color"].map { DeveloperPerformanceExtensions.colorName($0) })
                if item.isMarker { markers.append(item) } else { pageTimings.append(item) }
                continue
            }
            if timing.type == "LayoutShift" {
                if let score = timing.data["score"].flatMap({ Double($0) }), score.isFinite, score >= 0 {
                    let nodes = timing.data["nodes"].map { $0.split(separator: "\n").map(String.init) } ?? []
                    layoutShifts.append(LayoutShift(time: start, score: score, index: timing.data["index"].flatMap { Int($0) },
                                                    nodes: nodes))
                }
                continue
            }
            if timing.type == "Screenshot" {
                if let image = timing.data["imageData"] {
                    screenshots.append(DeveloperPerformanceScreenshot(time: start, imageData: image))
                }
                continue
            }
            while let last = open.last, built[last].end <= start + slack { open.removeLast() }
            let id = built.count
            let parent = open.last
            built.append(DeveloperPerformanceEvent(
                id: id, type: timing.type, title: DeveloperPerformanceEvent.title(timing.type, data: timing.data),
                detail: DeveloperPerformanceEvent.detail(timing.type, data: timing.data),
                category: .of(timing.type), start: start, end: end, row: open.count, parent: parent,
                data: timing.data, stack: timing.stack, frames: timing.frames))
            if let parent { built[parent].children.append(id) }
            open.append(id)
        }
        for index in built.indices {
            let event = built[index]
            let nested = event.children.reduce(0) { total, child in
                total + max(0, min(built[child].end, event.end) - max(built[child].start, event.start))
            }
            built[index].selfTime = max(0, event.duration - nested)
        }
        events = built
        rows = (built.map(\.row).max() ?? -1) + 1
        shown = built
        shownRows = rows
        var laidOut = pageTimings
        let used = Self.stack(&laidOut, start: \.start, end: \.end, row: \.row, most: 4)
        pageTimings = laidOut
        timingRows = used
        markers.sort { $0.start < $1.start }
        customTracks = DeveloperPerformanceExtensions.tracks(customEntries)
        extensionMarkers.sort { $0.time < $1.time }
        cpu = DeveloperPerformanceCPU.budgeted(cpu)
        var stackedAnimations = animations
        animationRows = Self.stack(&stackedAnimations, start: \.start, end: \.end, row: \.row, most: 8)
        animations = stackedAnimations
        shiftClusters = Self.clusters(layoutShifts)
        // LCP is the last candidate, as Chrome marks it.
        if let last = markers.lastIndex(where: { $0.kind == "LCP" }) {
            markers = markers.enumerated().filter { $0.element.kind != "LCP" || $0.offset == last }.map(\.element)
        }
        frames = built.filter { $0.type == "RenderingFrame" }.map(\.id)
        longTasks = built.filter { $0.parent == nil && $0.duration > Self.longTask }.map(\.id)
        var found: [Interaction] = []
        for event in built where event.type == "EventDispatch" {
            guard let type = event.data["type"], Self.interactionTypes.contains(type) else { continue }
            // The outermost dispatch only: one an event handler sent from
            // inside another is part of that interaction.
            var parent = event.parent
            var nested = false
            while let index = parent {
                if built[index].type == "EventDispatch", let outer = built[index].data["type"],
                   Self.interactionTypes.contains(outer) {
                    nested = true
                    break
                }
                parent = built[index].parent
            }
            if !nested {
                let phases = Self.phases(of: event, in: built)
                found.append(Interaction(event: event.id, type: type, start: phases.input, end: phases.presented,
                                         processingStart: event.start, processingEnd: event.end))
            }
        }
        let interactionRowsUsed = Self.stack(&found, start: \.start, end: \.end, row: \.row, most: 3)
        interactionRows = interactionRowsUsed
        interactions = found
    }

    static func networkBar(_ url: String, start: Double, end: Double, data: [String: String]) -> NetworkBar {
        func number(_ key: String) -> Double? {
            guard let value = data[key].flatMap({ Double($0) }), value.isFinite, value >= 0 else { return nil }
            return value
        }
        var bar = NetworkBar(url: url, start: start, end: max(start, end))
        bar.resourceType = data["resourceType"] ?? "Other"
        bar.responseStart = number("responseOffset").map { min(bar.end, start + $0) }
        bar.status = data["status"].flatMap { Int($0) }
        bar.mimeType = data["mimeType"]
        bar.encoding = data["encoding"]
        bar.transferSize = number("transferSize")
        bar.redirects = data["redirects"].flatMap { Int($0) } ?? 0
        bar.redirectTime = number("redirectOffset") ?? 0
        bar.isRedirect = data["redirect"] == "true"
        bar.cacheControl = data["cacheControl"]
        bar.expires = data["expires"]
        bar.pragma = data["pragma"]
        bar.networkProtocol = data["protocol"]
        bar.priority = data["priority"]
        bar.initiatorType = data["initiatorType"]
        bar.initiator = data["initiator"]
        bar.source = data["source"]
        bar.decodedSize = number("decodedSize")
        bar.contentType = data["contentType"]
        return bar
    }

    /// Where an interaction's dispatch record puts its phases, as Chrome
    /// splits an interaction: the input waited from the start of the task
    /// the dispatch ran in (WebKit doesn't say when the input came), and
    /// was presented when the first paint after its handlers ended (or the
    /// frame they ran in, without one), within a second of them.
    static func phases(of dispatch: DeveloperPerformanceEvent,
                       in events: [DeveloperPerformanceEvent]) -> (input: Double, presented: Double) {
        // The outermost task around the dispatch, a frame aside: a frame
        // holds more than the one task.
        var input = dispatch.start
        var enclosingFrame: Double?
        var parent = dispatch.parent
        while let index = parent, events.indices.contains(index) {
            let outer = events[index]
            if outer.type == "RenderingFrame" {
                if outer.end > dispatch.end { enclosingFrame = outer.end }
            } else {
                input = min(input, outer.start)
            }
            parent = outer.parent
        }
        let after = dispatch.end - 0.000_5
        var frame: Double?
        // Records are in the order they began.
        let first = events.firstIndex { $0.start >= after } ?? events.count
        for index in first..<events.count {
            let event = events[index]
            if event.start > dispatch.end + 1_000 { break }
            if event.type == "Paint" || event.type == "Composite" { return (input, max(dispatch.end, event.end)) }
            if frame == nil, event.type == "RenderingFrame" { frame = event.end }
        }
        return (input, max(dispatch.end, enclosingFrame ?? frame ?? dispatch.end))
    }

    /// Gives each item the first of `most` rows free at its start, as
    /// Chrome stacks a track's bars, and returns how many rows are used.
    static func stack<Item>(_ items: inout [Item], start: KeyPath<Item, Double>, end: KeyPath<Item, Double>,
                            row: WritableKeyPath<Item, Int>, most: Int) -> Int {
        guard most > 0 else { return 0 }
        var free = Array(repeating: -Double.infinity, count: most)
        var used = 0
        for index in items.indices {
            let from = items[index][keyPath: start]
            let lane = free.firstIndex { $0 <= from } ?? most - 1
            free[lane] = max(free[lane], items[index][keyPath: end])
            items[index][keyPath: row] = lane
            used = max(used, lane + 1)
        }
        return used
    }

    // MARK: Hiding entries

    /// Hide function: every entry of the record's function merges into its parent.
    mutating func hideFunction(_ id: Int) {
        guard events.indices.contains(id) else { return }
        hides.hideFunction(events[id].activity, in: events)
        applyHides()
    }

    /// Hide children: what the record holds collapses into it.
    mutating func hideChildren(_ id: Int) {
        guard events.indices.contains(id) else { return }
        hides.children.insert(id)
        applyHides()
    }

    /// Hide repeating children: the record's descendants of its own
    /// function merge into it.
    mutating func hideRepeatingChildren(_ id: Int) {
        guard events.indices.contains(id) else { return }
        hides.repeating.insert(id)
        applyHides()
    }

    /// Reset children: the hides under the record undone.
    mutating func resetChildren(_ id: Int) {
        hides.resetChildren(of: id, in: events)
        applyHides()
    }

    /// Reset trace: every hide undone.
    mutating func resetTrace() {
        hides = DeveloperFlameHides()
        applyHides()
    }

    /// Whether the record has descendants Hide children would collapse.
    func canHideChildren(_ id: Int) -> Bool {
        shown.indices.contains(id) && !shown[id].isHidden && !shown[id].children.isEmpty
    }

    /// Whether the record has a descendant of its own function shown.
    func canHideRepeatingChildren(_ id: Int) -> Bool {
        guard canHideChildren(id) else { return false }
        let activity = shown[id].activity
        var stack = shown[id].children
        while let next = stack.popLast() {
            if shown[next].activity == activity { return true }
            stack.append(contentsOf: shown[next].children)
        }
        return false
    }

    /// Whether Reset children has something to undo under the record.
    func canResetChildren(_ id: Int) -> Bool {
        guard events.indices.contains(id) else { return false }
        if hides.children.contains(id) || hides.repeating.contains(id) { return true }
        var stack = events[id].children
        while let next = stack.popLast() {
            if shown[next].isHidden || shown[next].hidesChildren { return true }
            stack.append(contentsOf: events[next].children)
        }
        return false
    }

    private mutating func applyHides() {
        shown = hides.apply(to: events)
        shownRows = (shown.lazy.filter { !$0.isHidden }.map(\.row).max() ?? -1) + 1
    }

    // MARK: Time within a range

    func overlap(_ event: DeveloperPerformanceEvent, _ range: ClosedRange<Double>) -> Double {
        max(0, min(event.end, range.upperBound) - max(event.start, range.lowerBound))
    }

    /// The record's self time that falls inside `range`.
    func selfTime(_ event: DeveloperPerformanceEvent, in range: ClosedRange<Double>) -> Double {
        let own = overlap(event, range)
        guard own > 0 else { return 0 }
        let lower = max(range.lowerBound, event.start)
        let clipped = lower...max(lower, min(range.upperBound, event.end))
        let nested = event.children.reduce(0) { $0 + overlap(events[$1], clipped) }
        return max(0, own - nested)
    }

    /// Summary: the self time of each category in `range`, and the idle rest.
    func summary(in range: ClosedRange<Double>) -> (categories: [DeveloperPerformanceCategory: Double], idle: Double) {
        var totals: [DeveloperPerformanceCategory: Double] = [:]
        for event in events where event.end >= range.lowerBound && event.start <= range.upperBound {
            let time = selfTime(event, in: range)
            if time > 0 { totals[event.category, default: 0] += time }
        }
        let busy = totals.values.reduce(0, +)
        return (totals, max(0, (range.upperBound - range.lowerBound) - busy))
    }

    /// Call tree: the top-level activities in `range`, each opening on the
    /// activities it called, busiest first, after the flame chart's hides.
    func callTree(in range: ClosedRange<Double>) -> [DeveloperPerformanceNode] {
        let roots = shown.filter { !$0.isHidden && $0.parent == nil && overlap($0, range) > 0 }.map(\.id)
        return tree(roots, path: "", in: range, depth: 0)
    }

    func tree(_ ids: [Int], path: String, in range: ClosedRange<Double>, depth: Int) -> [DeveloperPerformanceNode] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for id in ids where overlap(shown[id], range) > 0 {
            let key = shown[id].activity
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(id)
        }
        return order.map { key -> DeveloperPerformanceNode in
            let members = groups[key, default: []]
            let children = depth < 48 ? tree(members.flatMap { shown[$0].children }, path: path + "/" + key,
                                             in: range, depth: depth + 1) : []
            return DeveloperPerformanceNode(
                id: path + "/" + key, activity: key, category: shown[members[0]].category,
                selfTime: members.reduce(0) { $0 + selfTime(shown[$1], in: range) },
                totalTime: members.reduce(0) { $0 + overlap(shown[$1], range) }, children: children, event: members[0])
        }
        .sorted { $0.totalTime != $1.totalTime ? $0.totalTime > $1.totalTime : $0.activity < $1.activity }
    }

    /// Bottom-up: every activity in `range` by the time spent in it alone,
    /// each opening on the activities that led to it.
    func bottomUp(in range: ClosedRange<Double>) -> [DeveloperPerformanceNode] {
        let leaves = shown.filter { !$0.isHidden && overlap($0, range) > 0 }.map(\.id)
        return callers(leaves.map { ($0, $0) }, path: "", in: range, depth: 0)
    }

    /// `pairs` are (record, the ancestor of it this level groups by).
    func callers(_ pairs: [(leaf: Int, at: Int)], path: String, in range: ClosedRange<Double>,
                         depth: Int) -> [DeveloperPerformanceNode] {
        var groups: [String: [(leaf: Int, at: Int)]] = [:]
        for pair in pairs { groups[shown[pair.at].activity, default: []].append(pair) }
        return groups.map { entry -> DeveloperPerformanceNode in
            let key = entry.key, members = entry.value
            let up = members.compactMap { pair in shown[pair.at].parent.map { (leaf: pair.leaf, at: $0) } }
            // A record inside another of the same activity is already in
            // that one's total, so only the outermost counts.
            let total = members.reduce(0.0) { sum, pair in
                depth == 0 && hasAncestor(shown[pair.leaf], activity: key) ? sum : sum + overlap(shown[pair.leaf], range)
            }
            return DeveloperPerformanceNode(
                id: path + "/" + key, activity: key, category: shown[members[0].at].category,
                selfTime: members.reduce(0) { $0 + selfTime(shown[$1.leaf], in: range) }, totalTime: total,
                children: depth < 48 && !up.isEmpty ? callers(up, path: path + "/" + key, in: range, depth: depth + 1) : [],
                event: members[0].at)
        }
        .sorted { $0.selfTime != $1.selfTime ? $0.selfTime > $1.selfTime : $0.activity < $1.activity }
    }

    func hasAncestor(_ event: DeveloperPerformanceEvent, activity: String) -> Bool {
        var parent = event.parent
        while let index = parent {
            if shown[index].activity == activity { return true }
            parent = shown[index].parent
        }
        return false
    }

    /// Event log: the records in `range` in the order they began, those
    /// matching `filter` and lasting at least `minimum` milliseconds.
    func log(in range: ClosedRange<Double>, filter: String = "", minimum: Double = 0,
             limit: Int = 5_000) -> [DeveloperPerformanceEvent] {
        var found: [DeveloperPerformanceEvent] = []
        for event in events where event.end >= range.lowerBound && event.start <= range.upperBound {
            guard event.duration >= minimum else { continue }
            if !filter.isEmpty, !event.activity.localizedCaseInsensitiveContains(filter) { continue }
            found.append(event)
            if found.count >= limit { break }
        }
        return found
    }

    /// The record on flame chart `row` at `time`, or within `tolerance`
    /// of it for one too narrow to aim at.
    func event(at time: Double, row: Int, tolerance: Double = 0) -> DeveloperPerformanceEvent? {
        var best: (event: DeveloperPerformanceEvent, distance: Double)?
        for event in shown where event.row == row && !event.isHidden {
            let distance = time < event.start ? event.start - time : time > event.end ? time - event.end : 0
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance || (distance == best!.distance && event.duration < best!.event.duration) {
                best = (event, distance)
            }
        }
        return best?.event
    }

    /// The overview strip's activity chart: for each of `buckets` slices of
    /// the recording, how busy each category kept the page, from 0 to 1.
    func activity(buckets: Int) -> [[DeveloperPerformanceCategory: Double]] {
        guard buckets > 0, duration > 0 else { return [] }
        var result = Array(repeating: [DeveloperPerformanceCategory: Double](), count: buckets)
        let width = duration / Double(buckets)
        for event in events where event.selfTime > 0 && event.duration > 0 {
            let first = max(0, min(buckets - 1, Int(event.start / width)))
            let last = max(first, min(buckets - 1, Int(event.end / width)))
            for bucket in first...last {
                let slice = Double(bucket) * width...Double(bucket + 1) * width
                let share = selfTime(event, in: slice) / width
                if share > 0 { result[bucket][event.category, default: 0] += share }
            }
        }
        return result.map { slice in slice.mapValues { min(1, $0) } }
    }
}

/// The part of a recording the flame chart shows, in milliseconds, and
/// the maths of moving it, as Chrome's flame chart zooms and pans.
struct DeveloperFlameWindow: Equatable {
    var lower: Double
    var upper: Double

    /// The narrowest window: 20 microseconds.
    static let least = 0.02

    init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    init(_ range: ClosedRange<Double>) {
        self.init(lower: range.lowerBound, upper: range.upperBound)
    }

    var span: Double { max(upper - lower, .leastNonzeroMagnitude) }
    var range: ClosedRange<Double> { lower...max(lower, upper) }

    func x(_ time: Double, width: Double) -> Double { (time - lower) / span * width }
    func time(atX x: Double, width: Double) -> Double { lower + x / max(width, 1) * span }

    /// Zoomed in by `factor` (above 1) or out (below 1), keeping `anchor`
    /// where it is on screen, never past `bounds` or narrower than `least`.
    func zoomed(by factor: Double, around anchor: Double, in bounds: ClosedRange<Double>) -> Self {
        guard factor > 0 else { return self }
        let whole = bounds.upperBound - bounds.lowerBound
        let next = min(whole, max(Self.least, span / factor))
        let ratio = min(1, max(0, (anchor - lower) / span))
        return Self(lower: anchor - ratio * next, upper: anchor - ratio * next + next).clamped(to: bounds)
    }

    /// Moved later by `delta` milliseconds (earlier when negative), kept
    /// inside `bounds`.
    func panned(by delta: Double, in bounds: ClosedRange<Double>) -> Self {
        Self(lower: lower + delta, upper: upper + delta).clamped(to: bounds)
    }

    /// Shifted, then cut, to lie inside `bounds`.
    func clamped(to bounds: ClosedRange<Double>) -> Self {
        let width = min(upper - lower, bounds.upperBound - bounds.lowerBound)
        var start = lower
        if start < bounds.lowerBound { start = bounds.lowerBound }
        if start + width > bounds.upperBound { start = bounds.upperBound - width }
        return Self(lower: start, upper: start + width)
    }
}

/// Dragging in the overview strip, as in Chrome DevTools: from outside the
/// window draws a new one, a window edge resizes it, and inside it slides.
enum DeveloperOverviewDrag {
    enum Grab: Equatable { case lower, upper, slide, choose }

    /// What a drag starting at `x` takes hold of, given where the window's
    /// edges are drawn.
    static func grab(atX x: Double, lowerX: Double, upperX: Double, grip: Double = 5) -> Grab {
        if abs(x - lowerX) <= grip { return .lower }
        if abs(x - upperX) <= grip { return .upper }
        if x > lowerX && x < upperX { return .slide }
        return .choose
    }

    /// The window as the drag leaves it: `from` is where the drag began
    /// and `to` where the pointer is, both as times in the recording.
    static func window(_ grab: Grab, original: DeveloperFlameWindow, from: Double, to: Double,
                       bounds: ClosedRange<Double>, least: Double = DeveloperFlameWindow.least) -> DeveloperFlameWindow {
        let to = min(bounds.upperBound, max(bounds.lowerBound, to))
        switch grab {
        case .choose:
            let start = min(bounds.upperBound, max(bounds.lowerBound, from))
            let lower = min(start, to), upper = max(start, to)
            guard upper - lower >= least else { return original }
            return DeveloperFlameWindow(lower: lower, upper: upper)
        case .lower:
            return DeveloperFlameWindow(lower: min(to, original.upper - least), upper: original.upper)
        case .upper:
            return DeveloperFlameWindow(lower: original.lower, upper: max(to, original.lower + least))
        case .slide:
            return original.panned(by: to - from, in: bounds)
        }
    }
}

/// The time ruler over the flame chart and overview: gridlines 1, 2 or 5
/// times a power of ten apart, at least `spacing` points apart.
enum DeveloperPerformanceRuler {
    static func step(span: Double, width: Double, spacing: Double = 80) -> Double {
        guard span > 0, width > 0 else { return 1 }
        let least = span * spacing / width
        let power = pow(10, floor(log10(least)))
        for multiple in [1.0, 2, 5, 10] where power * multiple >= least { return power * multiple }
        return power * 10
    }

    static func ticks(in window: DeveloperFlameWindow, width: Double, spacing: Double = 80) -> [Double] {
        let step = step(span: window.span, width: width, spacing: spacing)
        var tick = (window.lower / step).rounded(.up) * step
        var result: [Double] = []
        while tick <= window.upper, result.count < 500 {
            result.append(tick)
            tick += step
        }
        return result
    }

    /// "850 ms", "1.25 s", "120 µs", as Chrome labels times.
    static func label(_ milliseconds: Double) -> String {
        let value = abs(milliseconds)
        if value == 0 { return "0 ms" }
        if value < 1 { return "\(trimmed(milliseconds * 1_000, digits: 0)) µs" }
        if value < 1_000 { return "\(trimmed(milliseconds, digits: value < 10 ? 1 : 0)) ms" }
        return "\(trimmed(milliseconds / 1_000, digits: 2)) s"
    }

    private static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

/// The Animations track's records, as a saved profile names them.
enum DeveloperPerformanceAnimationTrack {
    static let type = "AnimationBar"
    static let limit = 2_000
}
