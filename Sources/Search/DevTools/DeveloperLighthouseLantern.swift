import Foundation

// Lantern, Lighthouse's simulated throttling, as pure arithmetic over what
// a Navigation run recorded. Chrome's Lighthouse loads the page unthrottled
// and then estimates how it would have loaded on Lighthouse's slow phone or
// desktop: it builds a graph of the load (each network request, depending
// on the request or script that started it, and each main-thread task,
// depending on the script it ran and starting the requests it made),
// replays the graph on a simulated network and CPU, and reads the metrics
// off the replay. Search does the same over the Network panel's requests and
// the run's trace (or, without one, the observer's long tasks).
//
// Sources (GoogleChrome/lighthouse core/lib/lantern, Lighthouse 10–12):
// - page-dependency-graph.js: linking requests by initiator, tasks to the
//   scripts they evaluate (a request ending up to 100 ms after the task
//   began still counts), timers to the task that installed them, requests
//   to the task that sent them, and pruning tasks under 10 ms.
// - simulator/simulator.js: one CPU task at a time, CPU durations times
//   the slowdown (layout times half of it), at most 10 requests at once,
//   throughput shared by the requests in flight, disk-cache estimates.
// - simulator/tcp-connection.js: handshakes, TLS False Start, slow start
//   from 10 segments of 1460 bytes, the window capped by throughput, H2's
//   free first byte on a warm connection.
// - simulator/connection-pool.js: one connection per request observed
//   opening one (at least six for HTTP/1), warm ones reused per origin.
// - simulator/dns-cache.js: two round trips to resolve a host, once.
// - metrics/*.js: each metric's optimistic and pessimistic graphs and the
//   coefficients that blend them (FCP and LCP ½ and ½, Speed Index -250 +
//   1.4 and 0.65 scaled to the RTT, TTI 0.45 and 0.55, TBT ½ and ½).
// - core/config/constants.js: mobile slow 4G (150 ms, 1.6 Mbps, 4× CPU)
//   and desktop dense 4G (40 ms, 10 Mbps, 1×).
//
// Where Search knows less than a Chrome trace: requests' priorities come from
// WebKit's metrics, so an image is low priority when WebKit says so and it
// isn't the LCP image; render blocking is the main document, stylesheets and
// the head's synchronous scripts; a request of any type sent by a script
// during a task depends on that task (Lighthouse links only XHRs this way);
// when no connection of the observed warmth is free, another free one is
// used rather than waiting; and without a trace, the observer's long tasks
// are linked to the script that finished closest before each began.

/// How a Navigation run's load metrics are throttled, as Lighthouse's
/// `throttlingMethod`.
enum DeveloperLighthouseThrottling: String, CaseIterable, Identifiable, Codable {
    case simulated = "Simulated throttling"
    case devtools = "DevTools throttling"
    case none = "No throttling"

    var id: Self { self }

    /// LHR's configSettings.throttlingMethod.
    var lhr: String {
        switch self {
        case .simulated: "simulate"
        case .devtools: "devtools"
        case .none: "provided"
        }
    }

    var summary: String {
        switch self {
        case .simulated: "Loads the page unthrottled, then estimates the metrics on Lighthouse's throttled network and CPU (Lantern), as Chrome does by default."
        case .devtools: "Slows the network while the page loads, through the Network panel's throttling. WebKit can't slow the CPU."
        case .none: "The metrics as measured on this Mac."
        }
    }
}

enum DeveloperLighthouseLantern {
    static let tcpSegmentSize = 1_460.0
    static let initialCongestionWindow = 10.0
    static let connectionsPerOrigin = 6
    static let dnsRTTMultiplier = 2.0
    static let defaultServerResponseTime = 30.0
    static let maximumCPUTaskDuration = 10_000.0
    /// Tasks shorter than this are pruned from the graph unless they matter.
    static let significantTaskDuration = 10.0
    static let blockingThreshold = 50.0

    /// Lighthouse's throttling settings for a form factor.
    struct Settings: Equatable {
        var rttMs: Double
        var throughputKbps: Double
        var cpuSlowdownMultiplier: Double
        var maximumConcurrentRequests = 10
        /// Of the CPU slowdown, for tasks that laid the page out.
        var layoutTaskMultiplier = 0.5

        static let mobileSlow4G = Settings(rttMs: 150, throughputKbps: 1.6 * 1_024, cpuSlowdownMultiplier: 4)
        static let desktopDense4G = Settings(rttMs: 40, throughputKbps: 10 * 1_024, cpuSlowdownMultiplier: 1)

        static func lighthouse(_ formFactor: DeveloperLighthouseFormFactor) -> Settings {
            formFactor == .mobile ? mobileSlow4G : desktopDense4G
        }

        /// Bits a second, as the simulator counts throughput.
        var throughput: Double { throughputKbps * 1_024 }

        var summary: String {
            let mbps = (throughputKbps / 1_024).formatted(.number.precision(.fractionLength(0...1)))
            return "\(rttMs.formatted()) ms RTT, \(mbps) Mbps, \(cpuSlowdownMultiplier.formatted())× CPU slowdown"
        }
    }

    /// A request as the graph knows it: times in milliseconds on the page's
    /// clock (from navigation start), as observed unthrottled.
    struct Request: Equatable {
        var url: String
        var resourceType = "Other"
        var start: Double
        var end: Double
        var transferSize = 0.0
        var resourceSize = 0.0
        /// Request sent to response begun, observed: a round trip and the server's time.
        var serverTime: Double?
        /// Opening the connection, when the request opened one.
        var connectMs: Double?
        var connectionReused = false
        var networkProtocol: String?
        var priority: String?
        var initiatorType: String?
        var initiatorURL: String?
        var renderBlocking = false
        var cached = false
        var isMainDocument = false
        /// An image Chrome would load at low priority (not the LCP image).
        var lowPriority = false

        private var address: URL? { URL(string: url) }
        var scheme: String { address?.scheme?.lowercased() ?? "" }
        var host: String { address?.host()?.lowercased() ?? "" }
        /// The security origin, scheme://host:port, connections are pooled by.
        var origin: String {
            let port = address?.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }
        var secure: Bool { ["https", "wss"].contains(scheme) }
        var h2: Bool {
            let name = (networkProtocol ?? "").lowercased()
            return name.hasPrefix("h2") || name.hasPrefix("h3") || name.hasPrefix("spdy")
        }
        var nonNetwork: Bool { !["http", "https", "ws", "wss"].contains(scheme) }
        /// Needs no connection: from the cache, or not over the network.
        var connectionless: Bool { cached || nonNetwork }
        var isImage: Bool { resourceType == "Image" }
        var isScript: Bool { resourceType == "Script" }
    }

    /// A main-thread task: its times and what it did that the graph and
    /// metrics look at.
    struct CPUTask: Equatable {
        var start: Double
        var end: Double
        /// Scripts it evaluated.
        var scriptURLs: [String] = []
        /// Scripts whose functions it called.
        var calledURLs: [String] = []
        var didLayout = false
        var didPaint = false
        var didParseHTML = false
        /// Timers and animation frames it set up ("timer:3", "frame:2"), and the one it ran.
        var installs: [String] = []
        var fires: String?

        var duration: Double { end - start }
    }

    // MARK: Tasks from a trace

    /// The timeline's record types that are main-thread work, as against
    /// the records Search draws from other domains (frames, network bars, heap).
    static let mainThreadTypes: Set<String> = [
        "EventDispatch", "FunctionCall", "EvaluateScript", "TimerInstall", "TimerRemove", "TimerFire",
        "RequestAnimationFrame", "CancelAnimationFrame", "FireAnimationFrame", "ObserverCallback", "ProbeSample",
        "ConsoleProfile", "TimeStamp", "Time", "TimeEnd", "XHRReadyStateChange", "XHRLoad",
        "ScheduleStyleRecalculation", "RecalculateStyles", "InvalidateLayout", "Layout", "RenderingFrame",
        "UpdateLayoutTree", "HitTest", "Paint", "Composite", "ParseHTML", "ParseAuthorStyleSheet",
    ]

    /// The top-level tasks of a WebKit timeline recording, with what the
    /// records nested in each did. Times stay in the timeline's clock
    /// (seconds), the Network panel's.
    static func tasks(fromTimeline timeline: [DeveloperToolsSession.Timing]) -> [CPUTask] {
        let records = timeline.filter { mainThreadTypes.contains($0.type) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.depth < $1.depth }
        var out: [CPUTask] = []
        for record in records {
            if record.depth == 0, record.end > record.start {
                out.append(CPUTask(start: record.start, end: record.end))
            }
            guard let last = out.indices.last, record.start >= out[last].start, record.start <= out[last].end else { continue }
            note(record, in: &out[last])
        }
        return out
    }

    private static func note(_ record: DeveloperToolsSession.Timing, in task: inout CPUTask) {
        switch record.type {
        case "EvaluateScript":
            if let url = record.data["url"], !url.isEmpty, !task.scriptURLs.contains(url) { task.scriptURLs.append(url) }
        case "FunctionCall":
            if let url = record.data["scriptName"] ?? record.data["url"], !url.isEmpty, !task.calledURLs.contains(url) {
                task.calledURLs.append(url)
            }
        case "Layout": task.didLayout = true
        case "Paint", "Composite": task.didPaint = true
        case "ParseHTML": task.didParseHTML = true
        case "TimerInstall": if let id = record.data["timerId"] { task.installs.append("timer:" + id) }
        case "TimerFire": if task.fires == nil, let id = record.data["timerId"] { task.fires = "timer:" + id }
        case "RequestAnimationFrame": if let id = record.data["id"] { task.installs.append("frame:" + id) }
        case "FireAnimationFrame": if task.fires == nil, let id = record.data["id"] { task.fires = "frame:" + id }
        default: break
        }
    }

    // MARK: The graph

    struct Node: Equatable {
        enum Kind: Equatable {
            case network(Int)
            case cpu(Int)
        }

        var kind: Kind
        /// Observed, unthrottled.
        var start: Double
        var end: Double
        var dependencies: Set<Int> = []
    }

    struct Graph: Equatable {
        var requests: [Request]
        var tasks: [CPUTask]
        var nodes: [Node]
        var root: Int

        func request(_ id: Int) -> Request? {
            if case .network(let index) = nodes[id].kind { return requests[index] }
            return nil
        }

        func task(_ id: Int) -> CPUTask? {
            if case .cpu(let index) = nodes[id].kind { return tasks[index] }
            return nil
        }

        var all: Set<Int> { Set(nodes.indices) }

        /// Each node's dependents.
        var dependents: [[Int]] {
            var out = Array(repeating: [Int](), count: nodes.count)
            for (id, node) in nodes.enumerated() {
                for dependency in node.dependencies { out[dependency].append(id) }
            }
            return out
        }

        /// The nodes `predicate` picks and everything they depend on, as
        /// Lantern's cloneWithRelationships keeps them.
        func closure(_ predicate: (Int) -> Bool) -> Set<Int> {
            var out = Set<Int>()
            var stack = nodes.indices.filter(predicate)
            while let id = stack.popLast() {
                guard out.insert(id).inserted else { continue }
                stack.append(contentsOf: nodes[id].dependencies)
            }
            return out
        }
    }

    /// A URL without its fragment, as requests are matched by.
    static func key(_ url: String) -> String {
        url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
    }

    /// page-dependency-graph.js: the load as a graph. The root is the main
    /// document. `inferScripts`, for tasks that don't say which script they
    /// ran (the observer's long tasks), links each to the script or document
    /// that finished closest to when it began.
    static func graph(requests: [Request], tasks: [CPUTask], inferScripts: Bool = false) -> Graph? {
        guard !requests.isEmpty else { return nil }
        let root = requests.firstIndex(where: \.isMainDocument)
            ?? requests.indices.min { requests[$0].start < requests[$1].start } ?? 0
        let tasks = tasks.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var nodes = requests.enumerated().map { Node(kind: .network($0.offset), start: $0.element.start, end: $0.element.end) }
        var byURL: [String: [Int]] = [:]
        for (index, request) in requests.enumerated() { byURL[key(request.url), default: []].append(index) }

        // Every edge runs from an earlier node to a later one, so the graph
        // has no cycles.
        func earlier(_ a: Int, _ b: Int) -> Bool {
            nodes[a].start < nodes[b].start || (nodes[a].start == nodes[b].start && a < b)
        }
        // Requests: on the request that started them, when that's unambiguous.
        for index in requests.indices where index != root {
            if let initiator = requests[index].initiatorURL, let candidates = byURL[key(initiator)], candidates.count == 1,
               candidates[0] != index, earlier(candidates[0], index) {
                nodes[index].dependencies.insert(candidates[0])
            } else {
                nodes[index].dependencies.insert(root)
            }
        }

        // Tasks.
        let base = nodes.count
        for (offset, task) in tasks.enumerated() {
            nodes.append(Node(kind: .cpu(offset), start: task.start, end: task.end))
        }
        func dependency(onURL url: String, _ task: CPUTask) -> Int? {
            guard let candidates = byURL[key(url)] else { return nil }
            var best: Int?
            var distance = Double.infinity
            for candidate in candidates {
                // A request that began after the task can't be what it ran.
                if task.start <= requests[candidate].start { return nil }
                let gap = task.start - requests[candidate].end
                if gap >= -100, gap < distance {
                    best = candidate
                    distance = gap
                }
            }
            return best
        }
        var timers: [String: Int] = [:]
        for (offset, task) in tasks.enumerated() {
            let id = base + offset
            if let fired = task.fires, let installer = timers[fired], installer != id {
                nodes[id].dependencies.insert(installer)
            }
            for installed in task.installs { timers[installed] = id }
            let urls = task.scriptURLs + task.calledURLs
            for url in urls {
                if let found = dependency(onURL: url, task) { nodes[id].dependencies.insert(found) }
            }
            if inferScripts, urls.isEmpty {
                var best: Int?
                var distance = Double.infinity
                for (index, request) in requests.enumerated() where (request.isScript || index == root) && request.start < task.start {
                    let gap = task.start - request.end
                    if gap >= -100, gap < distance {
                        best = index
                        distance = gap
                    }
                }
                if let best { nodes[id].dependencies.insert(best) }
            }
            // The requests the task sent.
            for (index, request) in requests.enumerated() where index != root
                && request.start > task.start && request.start <= task.end
                && (request.initiatorType == "script" || request.resourceType == "XHR" || request.resourceType == "Fetch") {
                nodes[index].dependencies.insert(id)
            }
            if nodes[id].dependencies.isEmpty { nodes[id].dependencies.insert(root) }
        }

        // Short tasks go unless they're the first layout, paint or parse,
        // or too connected to rewire cheaply; their edges pass through.
        var dependents = Array(repeating: Set<Int>(), count: nodes.count)
        for (id, node) in nodes.enumerated() {
            for dependency in node.dependencies { dependents[dependency].insert(id) }
        }
        var removed = Set<Int>()
        var foundLayout = false, foundPaint = false, foundParse = false
        for (offset, task) in tasks.enumerated() {
            let id = base + offset
            var first = false
            if !foundLayout, task.didLayout { first = true; foundLayout = true }
            if !foundPaint, task.didPaint { first = true; foundPaint = true }
            if !foundParse, task.didParseHTML { first = true; foundParse = true }
            if first || task.duration >= significantTaskDuration { continue }
            let up = nodes[id].dependencies
            let down = dependents[id]
            guard up.count == 1 || down.count <= 1 else { continue }
            for dependency in up {
                dependents[dependency].remove(id)
                dependents[dependency].formUnion(down)
            }
            for dependent in down {
                nodes[dependent].dependencies.remove(id)
                nodes[dependent].dependencies.formUnion(up)
            }
            nodes[id].dependencies = []
            dependents[id] = []
            removed.insert(id)
        }
        guard !removed.isEmpty else { return Graph(requests: requests, tasks: tasks, nodes: nodes, root: root) }
        var renumbered: [Int: Int] = [:]
        var kept: [Node] = []
        for (id, node) in nodes.enumerated() where !removed.contains(id) {
            renumbered[id] = kept.count
            kept.append(node)
        }
        for index in kept.indices {
            kept[index].dependencies = Set(kept[index].dependencies.compactMap { renumbered[$0] })
        }
        return Graph(requests: requests, tasks: tasks, nodes: kept, root: renumbered[root] ?? root)
    }

    // MARK: The network

    /// network-analyzer.js, as far as Search's timings go: each origin's
    /// round trip beyond the fastest origin's, and its server's response
    /// time (request sent to response begun, less a round trip).
    struct Analysis: Equatable {
        var additionalRTT: [String: Double] = [:]
        var serverResponseTime: [String: Double] = [:]
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func analysis(_ requests: [Request]) -> Analysis {
        var rtts: [String: [Double]] = [:]
        var times: [String: [Double]] = [:]
        for request in requests where !request.connectionless {
            // TCP's handshake is one round trip, TLS's another.
            if let connect = request.connectMs, connect > 0 {
                rtts[request.origin, default: []].append(connect / (request.secure ? 2 : 1))
            }
            if let time = request.serverTime { times[request.origin, default: []].append(time) }
        }
        let rttByOrigin = rtts.compactMapValues(median)
        let fastest = rttByOrigin.values.min() ?? 0
        var out = Analysis()
        for (origin, rtt) in rttByOrigin { out.additionalRTT[origin] = max(0, rtt - fastest) }
        for (origin, values) in times {
            let rtt = rttByOrigin[origin] ?? fastest
            if let time = median(values.map { $0 - rtt }) { out.serverResponseTime[origin] = max(0, time) }
        }
        return out
    }

    /// tcp-connection.js's state.
    struct Connection: Equatable {
        var rtt: Double
        /// Bits a second, this connection's share.
        var throughput: Double
        var serverLatency: Double
        var ssl: Bool
        var h2: Bool
        var warmed = false
        var congestionWindow = DeveloperLighthouseLantern.initialCongestionWindow
        var h2OverflowBytes = 0.0
    }

    struct Download: Equatable {
        var roundTrips: Double
        var timeElapsed: Double
        var bytesDownloaded: Double
        var extraBytesDownloaded: Double
        var congestionWindow: Double
    }

    /// tcp-connection.js maximumSaturatedConnections: the most segments a
    /// round trip that the throughput can carry.
    static func maximumSaturatedConnections(rtt: Double, throughput: Double) -> Double {
        guard rtt > 0 else { return .greatestFiniteMagnitude }
        let bytesPerSecond = 1_000 / rtt * tcpSegmentSize
        return (throughput / (bytesPerSecond * 8)).rounded(.down)
    }

    /// tcp-connection.js simulateDownloadUntil: how long the bytes take on
    /// the connection, from the handshake (for a cold one) through slow start.
    static func download(_ connection: Connection, bytes: Double, timeAlreadyElapsed: Double = 0,
                         maximumTimeToElapse: Double = .infinity, dnsResolutionTime: Double = 0) -> Download {
        var bytesToDownload = bytes
        if connection.warmed, connection.h2 { bytesToDownload -= connection.h2OverflowBytes }
        let twoWayLatency = connection.rtt
        let oneWayLatency = twoWayLatency / 2
        let maximumWindow = maximumSaturatedConnections(rtt: connection.rtt, throughput: connection.throughput)

        var handshakeAndRequest = oneWayLatency
        if !connection.warmed {
            // DNS, SYN, SYN ACK, ACK with the request, and TLS with False Start.
            handshakeAndRequest = dnsResolutionTime + oneWayLatency * 3 + (connection.ssl ? twoWayLatency : 0)
        }
        var roundTrips = twoWayLatency > 0 ? (handshakeAndRequest / twoWayLatency).rounded(.up) : 0
        var timeToFirstByte = handshakeAndRequest + connection.serverLatency + oneWayLatency
        if connection.warmed, connection.h2 { timeToFirstByte = 0 }

        let elapsedForFirstByte = max(timeToFirstByte - timeAlreadyElapsed, 0)
        let maximumDownloadTime = maximumTimeToElapse - elapsedForFirstByte
        var window = min(connection.congestionWindow, maximumWindow)
        var total = 0.0
        if elapsedForFirstByte > 0 {
            total = window * tcpSegmentSize
        } else {
            roundTrips = 0
        }
        var downloadTime = 0.0
        var remaining = bytesToDownload - total
        while remaining > 0, downloadTime <= maximumDownloadTime {
            roundTrips += 1
            downloadTime += twoWayLatency
            window = max(min(maximumWindow, window * 2), 1)
            let inWindow = window * tcpSegmentSize
            total += inWindow
            remaining -= inWindow
            // A connection without latency moves everything in one go.
            if twoWayLatency <= 0 { break }
        }
        return Download(roundTrips: roundTrips, timeElapsed: elapsedForFirstByte + downloadTime,
                        bytesDownloaded: max(min(total, bytesToDownload), 0),
                        extraBytesDownloaded: connection.h2 ? max(total - bytesToDownload, 0) : 0,
                        congestionWindow: window)
    }

    // MARK: The simulator

    struct Timing: Equatable {
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    struct Simulation: Equatable {
        /// When the last node finished.
        var timeInMs: Double
        var timings: [Int: Timing]
    }

    /// simulator.js: the graph's `included` nodes replayed on the throttled
    /// network and CPU.
    static func simulate(_ graph: Graph, nodes included: Set<Int>, settings: Settings,
                         analysis: Analysis = Analysis()) -> Simulation {
        struct Progress {
            var start: Double
            var timeElapsed = 0.0
            var overshoot = 0.0
            var bytesDownloaded = 0.0
            var estimate = 0.0
            var connection: Int?
            var dns = 0.0
        }

        // The connection pool, by origin.
        var connections: [Connection] = []
        var pools: [String: [Int]] = [:]
        var byOrigin: [String: [Request]] = [:]
        for id in included.sorted() {
            guard let request = graph.request(id), !request.connectionless else { continue }
            byOrigin[request.origin, default: []].append(request)
        }
        for (origin, list) in byOrigin.sorted(by: { $0.key < $1.key }) {
            let rtt = settings.rttMs + (analysis.additionalRTT[origin] ?? 0)
            let server = analysis.serverResponseTime[origin] ?? defaultServerResponseTime
            func make(_ request: Request) -> Connection {
                Connection(rtt: rtt, throughput: settings.throughput, serverLatency: server, ssl: request.secure, h2: request.h2)
            }
            var made: [Int] = []
            for request in list where !request.connectionReused {
                made.append(connections.count)
                connections.append(make(request))
            }
            if made.isEmpty, let first = list.first {
                made.append(connections.count)
                connections.append(make(first))
            }
            guard let template = made.first.map({ connections[$0] }) else { continue }
            let minimum = template.h2 ? 1 : connectionsPerOrigin
            while made.count < minimum {
                made.append(connections.count)
                connections.append(template)
            }
            pools[origin] = made
        }
        var inUse = Set<Int>()
        var resolved: [String: Double] = [:]

        let dependents = graph.dependents
        var waiting: [Int: Int] = [:]
        for id in included {
            waiting[id] = graph.nodes[id].dependencies.filter(included.contains).count
        }
        var ready = Set(included.filter { waiting[$0] == 0 })
        var progress: [Int: Progress] = [:]
        var timings: [Int: Timing] = [:]
        var total = 0.0

        func isCPU(_ id: Int) -> Bool {
            if case .cpu = graph.nodes[id].kind { return true }
            return false
        }
        func networkInProgress() -> Int { progress.keys.filter { !isCPU($0) }.count }
        func resolve(_ host: String, at time: Double) -> Double {
            var until = settings.rttMs * dnsRTTMultiplier
            if let at = resolved[host] { until = min(max(at - time, 0), until) }
            resolved[host] = min(resolved[host] ?? .infinity, time + until)
            return until
        }
        func acquire(_ request: Request) -> Int? {
            let free = (pools[request.origin] ?? []).filter { !inUse.contains($0) }
            let matching = free.filter { connections[$0].warmed == request.connectionReused }
            let choices = matching.isEmpty ? free : matching
            return choices.max { connections[$0].congestionWindow < connections[$1].congestionWindow }
        }
        func start(_ id: Int) {
            var state = Progress(start: total)
            switch graph.nodes[id].kind {
            case .cpu:
                guard !progress.keys.contains(where: isCPU) else { return }
            case .network(let index):
                let request = graph.requests[index]
                if !request.connectionless {
                    guard networkInProgress() < settings.maximumConcurrentRequests, let connection = acquire(request) else { return }
                    inUse.insert(connection)
                    state.connection = connection
                    state.dns = resolve(request.host, at: total)
                }
            }
            ready.remove(id)
            progress[id] = state
        }
        func remaining(_ id: Int, _ state: Progress) -> Double {
            switch graph.nodes[id].kind {
            case .cpu(let index):
                let task = graph.tasks[index]
                let multiplier = task.didLayout
                    ? settings.cpuSlowdownMultiplier * settings.layoutTaskMultiplier : settings.cpuSlowdownMultiplier
                return min((task.duration * multiplier).rounded(), maximumCPUTaskDuration) - state.timeElapsed
            case .network(let index):
                let request = graph.requests[index]
                if request.cached { return 8 + 20 * request.resourceSize / 1_048_576 - state.timeElapsed }
                guard let connection = state.connection else { return 0 }
                return download(connections[connection], bytes: request.transferSize - state.bytesDownloaded,
                                timeAlreadyElapsed: state.timeElapsed, dnsResolutionTime: state.dns).timeElapsed + state.overshoot
            }
        }
        func complete(_ id: Int, _ state: Progress) {
            progress[id] = nil
            timings[id] = Timing(start: state.start, end: total)
            for dependent in dependents[id] where included.contains(dependent) {
                let left = (waiting[dependent] ?? 1) - 1
                waiting[dependent] = left
                if left == 0 { ready.insert(dependent) }
            }
        }

        var iterations = 0
        while !ready.isEmpty || !progress.isEmpty {
            iterations += 1
            guard iterations < 200_000 else { break }
            let order = ready.sorted { (graph.nodes[$0].start, $0) < (graph.nodes[$1].start, $1) }
            for id in order { start(id) }
            // Nothing could start: no connection for a request's origin.
            guard !progress.isEmpty else { break }
            let inFlight = networkInProgress()
            if inFlight > 0 {
                for connection in inUse { connections[connection].throughput = settings.throughput / Double(inFlight) }
            }
            var period = Double.infinity
            for id in Array(progress.keys) {
                guard var state = progress[id] else { continue }
                state.estimate = remaining(id, state)
                progress[id] = state
                period = min(period, state.estimate)
            }
            period = max(0, period)
            total += period
            for id in progress.keys.sorted() {
                guard var state = progress[id] else { continue }
                let finished = state.estimate <= period + 1e-9
                switch graph.nodes[id].kind {
                case .cpu:
                    if finished { complete(id, state) } else { state.timeElapsed += period; progress[id] = state }
                case .network(let index):
                    let request = graph.requests[index]
                    guard let connection = state.connection else {
                        if finished { complete(id, state) } else { state.timeElapsed += period; progress[id] = state }
                        continue
                    }
                    let step = download(connections[connection], bytes: request.transferSize - state.bytesDownloaded,
                                        timeAlreadyElapsed: state.timeElapsed, maximumTimeToElapse: period - state.overshoot,
                                        dnsResolutionTime: state.dns)
                    connections[connection].congestionWindow = step.congestionWindow
                    connections[connection].h2OverflowBytes = step.extraBytesDownloaded
                    if finished {
                        connections[connection].warmed = true
                        inUse.remove(connection)
                        complete(id, state)
                    } else {
                        state.timeElapsed += step.timeElapsed
                        state.overshoot += step.timeElapsed - period
                        state.bytesDownloaded += step.bytesDownloaded
                        progress[id] = state
                    }
                }
            }
        }
        return Simulation(timeInMs: total, timings: timings)
    }

    // MARK: Metrics

    /// A metric's two simulations and the value blended from them.
    struct Estimate: Equatable {
        var optimistic: Double
        var pessimistic: Double
        var value: Double
    }

    struct Estimates: Equatable {
        var settings: Settings
        var fcp: Estimate
        var lcp: Estimate?
        var speedIndex: Estimate?
        var interactive: Estimate
        var totalBlockingTime: Estimate
        /// What the graph was built from.
        var requests: Int
        var tasks: Int
        var fromTrace: Bool

        var summary: String {
            let source = fromTrace ? "main-thread tasks from the run's trace" : "long tasks the page reported"
            return "Simulated with Lantern on \(settings.summary), over \(requests) requests and \(tasks) \(source)."
        }
    }

    /// What the unthrottled load measured, in the page's clock.
    struct Observed: Equatable {
        var fcp: Double
        var lcp: Double?
        var speedIndex: Double?
    }

    struct Coefficients: Equatable {
        var intercept: Double
        var optimistic: Double
        var pessimistic: Double

        func blend(_ optimistic: Double, _ pessimistic: Double) -> Double {
            // metric.js: a positive intercept is scaled down for loads under a second.
            let interceptMultiplier = intercept > 0 ? min(1, optimistic / 1_000) : 1
            return intercept * interceptMultiplier + self.optimistic * optimistic + self.pessimistic * pessimistic
        }
    }

    static let fcpCoefficients = Coefficients(intercept: 0, optimistic: 0.5, pessimistic: 0.5)
    static let lcpCoefficients = Coefficients(intercept: 0, optimistic: 0.5, pessimistic: 0.5)
    static let interactiveCoefficients = Coefficients(intercept: 0, optimistic: 0.45, pessimistic: 0.55)
    static let blockingCoefficients = Coefficients(intercept: 0, optimistic: 0.5, pessimistic: 0.5)
    static let speedIndexBaseCoefficients = Coefficients(intercept: -250, optimistic: 1.4, pessimistic: 0.65)

    /// speed-index.js getScaledCoefficients: Speed Index's were fitted on
    /// slow 4G; on a faster connection they move towards ½ and ½.
    static func speedIndexCoefficients(rtt: Double) -> Coefficients {
        let base = speedIndexBaseCoefficients
        let excess = Settings.mobileSlow4G.rttMs - 30
        let multiplier = max((rtt - 30) / excess, 0)
        return Coefficients(intercept: base.intercept * multiplier,
                            optimistic: 0.5 + (base.optimistic - 0.5) * multiplier,
                            pessimistic: 0.5 + (base.pessimistic - 0.5) * multiplier)
    }

    /// lantern-metric.js getFirstPaintBasedGraph: the requests that finished
    /// before the paint and `treat` calls render blocking (but not scripts
    /// that ran after it), the tasks that held the paint up, and what they
    /// depend on.
    static func firstPaintGraph(_ graph: Graph, cutoff: Double, treat: (Request) -> Bool,
                                additionalTasks: ((CPUTask) -> Bool)? = nil) -> Set<Int> {
        var earliestByScript: [String: Int] = [:]
        var before: [Int] = []
        for (id, node) in graph.nodes.enumerated() {
            guard let task = graph.task(id) else { continue }
            if node.start <= cutoff { before.append(id) }
            for url in task.scriptURLs {
                if let existing = earliestByScript[url], graph.nodes[existing].start <= node.start { continue }
                earliestByScript[url] = id
            }
        }
        before.sort { graph.nodes[$0].start < graph.nodes[$1].start }
        let beforeSet = Set(before)
        var blocking = Set<Int>()
        var notBlocking = Set<String>()
        for (id, node) in graph.nodes.enumerated() {
            guard let request = graph.request(id), request.isScript, node.end <= cutoff, treat(request) else { continue }
            // Which task ran it first: before the paint, it blocked it; after, it can't have.
            guard let ran = earliestByScript[request.url] else { continue }
            if beforeSet.contains(ran) { blocking.insert(ran) } else { notBlocking.insert(request.url) }
        }
        if let first = before.first(where: { graph.task($0)?.didLayout == true }) { blocking.insert(first) }
        if let first = before.first(where: { graph.task($0)?.didPaint == true }) { blocking.insert(first) }
        if let first = before.first(where: { graph.task($0)?.didParseHTML == true }) { blocking.insert(first) }
        if let additionalTasks {
            for id in before where graph.task(id).map(additionalTasks) == true { blocking.insert(id) }
        }
        return graph.closure { id in
            if let request = graph.request(id) {
                let node = graph.nodes[id]
                if (node.end > cutoff || node.start > cutoff), !request.isMainDocument { return false }
                if notBlocking.contains(request.url) { return false }
                return treat(request)
            }
            return blocking.contains(id)
        }
    }

    /// Chrome's hasRenderBlockingPriority, as far as Search knows it.
    static func rendersBlocking(_ request: Request) -> Bool { request.isMainDocument || request.renderBlocking }

    static func notLowPriorityImage(_ request: Request) -> Bool { !(request.isImage && request.lowPriority) }

    /// speed-index.js computeLayoutBasedSpeedIndex: when the layouts ended,
    /// each weighted by the log of how long it took.
    static func layoutBasedSpeedIndex(_ graph: Graph, _ simulation: Simulation, fcp: Double) -> Double {
        var weighted = 0.0
        var weights = 0.0
        for (id, timing) in simulation.timings {
            guard graph.task(id)?.didLayout == true else { continue }
            let weight = max(log2(max(timing.duration, Double.leastNonzeroMagnitude)), 0)
            weighted += weight * max(timing.end, fcp)
            weights += weight
        }
        return weights > 0 ? weighted / weights : fcp
    }

    /// interactive.js getLastLongTaskEndTime.
    static func lastLongTaskEnd(_ graph: Graph, _ simulation: Simulation, longerThan duration: Double = 50) -> Double {
        simulation.timings.filter { graph.task($0.key) != nil && $0.value.duration > duration }
            .map { $0.value.end }.reduce(0) { Swift.max($0, $1) }
    }

    /// total-blocking-time.js over the simulation, between FCP and TTI.
    static func blockingTime(_ graph: Graph, _ simulation: Simulation, from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        let tasks = simulation.timings.filter { graph.task($0.key) != nil && $0.value.duration >= blockingThreshold }
            .map { (start: $0.value.start, duration: $0.value.duration) }
        return DeveloperLighthouseMetrics.totalBlockingTime(tasks, after: start, until: end)
    }

    /// Every metric Lantern estimates, from the graph of the load.
    static func estimates(_ graph: Graph, observed: Observed, settings: Settings, analysis: Analysis = Analysis(),
                          fromTrace: Bool = false) -> Estimates {
        func run(_ nodes: Set<Int>) -> Simulation { simulate(graph, nodes: nodes, settings: settings, analysis: analysis) }
        let whole = run(graph.all)

        // First Contentful Paint: optimistically, without what scripts asked for.
        let fcpOptimistic = run(firstPaintGraph(graph, cutoff: observed.fcp,
                                                treat: { rendersBlocking($0) && $0.initiatorType != "script" })).timeInMs
        let fcpPessimistic = run(firstPaintGraph(graph, cutoff: observed.fcp, treat: rendersBlocking,
                                                 additionalTasks: { $0.didLayout })).timeInMs
        let fcp = Estimate(optimistic: fcpOptimistic, pessimistic: fcpPessimistic,
                           value: fcpCoefficients.blend(fcpOptimistic, fcpPessimistic))

        // Largest Contentful Paint: the last thing that wasn't a low-priority image.
        var lcp: Estimate?
        if let cutoff = observed.lcp {
            func end(_ simulation: Simulation) -> Double {
                simulation.timings.filter { graph.request($0.key).map(notLowPriorityImage) ?? true }
                    .map { $0.value.end }.reduce(0) { Swift.max($0, $1) }
            }
            let optimistic = end(run(firstPaintGraph(graph, cutoff: cutoff, treat: notLowPriorityImage)))
            let pessimistic = end(run(firstPaintGraph(graph, cutoff: cutoff, treat: { _ in true },
                                                      additionalTasks: { $0.didLayout })))
            lcp = Estimate(optimistic: optimistic, pessimistic: pessimistic,
                           value: max(lcpCoefficients.blend(optimistic, pessimistic), fcp.value))
        }

        // Time to Interactive: scripts and important requests, and every task
        // that might be long; no earlier than LCP.
        let interactiveGraph = graph.closure { id in
            if let task = graph.task(id) { return task.duration > 20 }
            guard let request = graph.request(id), !request.isImage else { return false }
            let important = ["Document", "Stylesheet", "Font", "XHR", "Fetch"].contains(request.resourceType)
                || request.renderBlocking || ["high", "veryhigh", "very-high"].contains((request.priority ?? "").lowercased())
            return request.isScript || important || request.isMainDocument
        }
        let interactiveOptimistic = max(lcp?.optimistic ?? fcp.optimistic,
                                        lastLongTaskEnd(graph, run(interactiveGraph)))
        let interactivePessimistic = max(lcp?.pessimistic ?? fcp.pessimistic, lastLongTaskEnd(graph, whole))
        let interactive = Estimate(optimistic: interactiveOptimistic, pessimistic: interactivePessimistic,
                                   value: interactiveCoefficients.blend(interactiveOptimistic, interactivePessimistic))

        // Total Blocking Time: the opposite FCP for each side, so the
        // optimistic window is the narrower one.
        let blockingOptimistic = blockingTime(graph, whole, from: fcp.pessimistic, to: interactive.optimistic)
        let blockingPessimistic = blockingTime(graph, whole, from: fcp.optimistic, to: interactive.pessimistic)
        let blocking = Estimate(optimistic: blockingOptimistic, pessimistic: blockingPessimistic,
                                value: blockingCoefficients.blend(blockingOptimistic, blockingPessimistic))

        // Speed Index: optimistically the observed one, pessimistically
        // from when the simulated layouts ended.
        let siPessimistic = layoutBasedSpeedIndex(graph, whole, fcp: fcp.pessimistic)
        let siOptimistic = observed.speedIndex ?? layoutBasedSpeedIndex(graph, whole, fcp: fcp.optimistic)
        let siValue = max(speedIndexCoefficients(rtt: settings.rttMs).blend(siOptimistic, siPessimistic), fcp.value)
        let speedIndex = Estimate(optimistic: siOptimistic, pessimistic: siPessimistic, value: siValue)

        return Estimates(settings: settings, fcp: fcp, lcp: lcp, speedIndex: speedIndex, interactive: interactive,
                         totalBlockingTime: blocking, requests: graph.requests.count, tasks: graph.tasks.count,
                         fromTrace: fromTrace)
    }

    // MARK: From a run

    /// The requests' clock (seconds) lined up with the page's (milliseconds
    /// since navigation start): the document's first byte on both.
    struct Clock: Equatable {
        var origin: Double
        func ms(_ seconds: Double) -> Double { (seconds - origin) * 1_000 }
    }

    /// The run's main document among its requests.
    static func mainDocument(_ input: DeveloperLighthouseInput) -> Int? {
        let address = key(input.page.url.isEmpty ? input.requestedURL : input.page.url)
        let documents = input.requests.indices.filter { input.requests[$0].type == "Document" && input.requests[$0].startedAt != nil }
        return documents.first { key(input.requests[$0].url) == address } ?? documents.first
    }

    static func clock(_ input: DeveloperLighthouseInput, document: DeveloperLighthouseRequest) -> Clock? {
        if let received = document.receivedAt, let responseStart = input.metrics?.responseStart, responseStart > 0 {
            return Clock(origin: received - responseStart / 1_000)
        }
        return document.startedAt.map { Clock(origin: $0) }
    }

    /// The run's requests as the graph's, on the page's clock.
    static func requests(_ input: DeveloperLighthouseInput, clock: Clock, document: Int) -> [Request] {
        var blockingScripts = Set<String>()
        var quietStyles = Set<String>()
        for resource in input.page.headResources where !resource.url.isEmpty {
            switch resource.kind {
            case .script:
                if !resource.async, !resource.deferred, !resource.module { blockingScripts.insert(key(resource.url)) }
            case .stylesheet:
                if !resource.mediaMatches || resource.disabled { quietStyles.insert(key(resource.url)) }
            }
        }
        for timing in input.page.timings {
            if timing.renderBlockingStatus == "blocking" { blockingScripts.insert(key(timing.url)) }
            if timing.renderBlockingStatus == "non-blocking" { quietStyles.insert(key(timing.url)) }
        }
        let lcpURL = input.metrics?.lcpURL.map(key)
        var out: [Request] = []
        for (index, raw) in input.requests.enumerated() {
            guard let started = raw.startedAt, !["WebSocket", "EventSource", "Beacon", "Ping"].contains(raw.type) else { continue }
            guard let ended = raw.endedAt ?? raw.durationMs.map({ started + $0 / 1_000 }) else { continue }
            let address = key(raw.url)
            var request = Request(url: raw.url, resourceType: raw.type, start: clock.ms(started), end: clock.ms(max(ended, started)))
            request.transferSize = raw.transferSize ?? raw.resourceSize ?? 0
            request.resourceSize = raw.resourceSize ?? request.transferSize
            if let sent = raw.sentAt, let received = raw.receivedAt, received >= sent {
                request.serverTime = (received - sent) * 1_000
            }
            request.connectMs = raw.connectMs
            request.connectionReused = raw.connectMs == nil
            request.networkProtocol = raw.networkProtocol
            request.priority = raw.priority
            request.initiatorType = raw.initiatorType
            request.initiatorURL = raw.initiatorURL
            request.cached = raw.cached
            request.isMainDocument = index == document
            switch raw.type {
            case "Stylesheet": request.renderBlocking = !quietStyles.contains(address)
            case "Script": request.renderBlocking = blockingScripts.contains(address)
            default: request.renderBlocking = false
            }
            let priority = (raw.priority ?? "").lowercased()
            request.lowPriority = raw.type == "Image" && ["low", "very-low", "verylow", "lowest"].contains(priority)
                && address != lcpURL
            out.append(request)
        }
        return out
    }

    /// The trace's main-thread tasks as the observed metrics count them,
    /// on the page's clock (ms from navigation): what Total Blocking Time is
    /// measured from when a trace was recorded, in place of the observer's
    /// timer gaps. Nil without a trace or a main document to place it by.
    static func pageTasks(_ input: DeveloperLighthouseInput) -> [(start: Double, duration: Double)]? {
        guard let trace = input.traceTasks, let document = mainDocument(input),
              let clock = clock(input, document: input.requests[document]) else { return nil }
        return trace.map { (start: clock.ms($0.start), duration: $0.duration * 1_000) }
            .filter { $0.start + $0.duration > 0 && $0.duration > 0 }
    }

    /// Lantern's estimates for a Navigation run: nil when the load can't be
    /// simulated (no First Contentful Paint, or no main document request).
    static func estimate(for input: DeveloperLighthouseInput) -> Estimates? {
        guard input.mode == .navigation, let metrics = input.metrics, let fcp = metrics.fcp,
              let document = Self.mainDocument(input), let clock = Self.clock(input, document: input.requests[document]) else { return nil }
        let requests = Self.requests(input, clock: clock, document: document)
        guard requests.contains(where: \.isMainDocument) else { return nil }
        let fromTrace = input.traceTasks != nil
        let tasks: [CPUTask]
        if let trace = input.traceTasks {
            tasks = trace.map { task in
                var shifted = task
                shifted.start = clock.ms(task.start)
                shifted.end = clock.ms(task.end)
                return shifted
            }
        } else {
            tasks = metrics.tasks.map { CPUTask(start: $0.start, end: $0.start + $0.duration) }
        }
        // Work from the page before the reload isn't the load's.
        let loadTasks = tasks.filter { $0.end > 0 && $0.duration > 0 }
        guard let graph = Self.graph(requests: requests, tasks: loadTasks, inferScripts: !fromTrace) else { return nil }
        let observed = Observed(fcp: fcp, lcp: metrics.lcpSupported ? metrics.lcp : nil, speedIndex: metrics.speedIndex)
        return estimates(graph, observed: observed, settings: .lighthouse(input.formFactor), analysis: analysis(requests),
                         fromTrace: fromTrace)
    }
}
