import CoreGraphics
import Foundation

// Chrome DevTools' Performance monitor (More tools › Performance monitor),
// over WebKit: CPU usage from CPUProfiler.trackingUpdate, the JavaScript
// heap from Memory.trackingUpdate's "javascript" category, DOM nodes,
// documents and frames counted by the page once a second, and layouts and
// style recalculations per second from the Timeline records the
// Performance panel's recording brings. This file is the arithmetic, apart
// from the page: the metrics, a ring buffer of samples, per-second rates,
// the readings in words and the charts' scales.

/// One of the monitor's metrics, in Chrome's order.
enum DeveloperPerformanceMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU usage"
    case jsHeap = "JS heap size"
    case domNodes = "DOM Nodes"
    case eventListeners = "JS event listeners"
    case documents = "Documents"
    case frames = "Document Frames"
    case layouts = "Layouts / sec"
    case styleRecalcs = "Style recalcs / sec"

    var id: Self { self }

    enum Kind { case percent, bytes, count, rate }

    var kind: Kind {
        switch self {
        case .cpu: .percent
        case .jsHeap: .bytes
        case .domNodes, .eventListeners, .documents, .frames: .count
        case .layouts, .styleRecalcs: .rate
        }
    }

    /// Chrome's default: the first four on.
    static let defaults: Set<DeveloperPerformanceMetric> = [.cpu, .jsHeap, .domNodes, .eventListeners]

    /// WebKit gives no way to count every listener without walking each
    /// node through DOM.getEventListenersForNode, far too slow once a
    /// second; the row stays, as n/a.
    var neverAvailable: Bool { self == .eventListeners }

    /// Counted from the Performance panel's Timeline records.
    var needsTimeline: Bool { self == .layouts || self == .styleRecalcs }

    /// Why the metric reads n/a, for its tooltip.
    var unavailableReason: String {
        switch self {
        case .eventListeners:
            "WebKit can’t count the page’s event listeners cheaply: it reports them only node by node."
        case .layouts, .styleRecalcs:
            "Counted from WebKit’s timeline, which the Performance panel runs. Start a recording there to see it here; "
                + "the page has one timeline, so the monitor doesn’t start its own and fill the panel’s recording."
        default:
            "Waiting for the page."
        }
    }

    /// The reading as Chrome writes it: `12.3%`, `8.4 MB`, `1,204`, `3.0`.
    func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        switch kind {
        case .percent: return DeveloperMetricFormat.decimal(value, digits: 1) + "%"
        case .bytes: return DeveloperMetricFormat.bytes(value)
        case .count: return DeveloperMetricFormat.integer(value)
        case .rate: return DeveloperMetricFormat.decimal(value, digits: 1)
        }
    }

    /// The least the chart's top may be: CPU starts at 100%, counts at a
    /// few so a flat line sits low rather than on the roof.
    var scaleFloor: Double {
        switch kind {
        case .percent: 100
        case .bytes: 1_000_000
        case .count: 10
        case .rate: 5
        }
    }
}

/// The readings in words.
enum DeveloperMetricFormat {
    private static func formatter(_ digits: Int, grouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter
    }

    private static let whole = formatter(0, grouping: true)
    private static let tenths = formatter(1, grouping: true)
    private static let hundredths = formatter(2, grouping: true)

    static func integer(_ value: Double) -> String {
        whole.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        let formatter = digits <= 0 ? whole : digits == 1 ? tenths : hundredths
        // No "-0.0" for a value a hair under zero.
        let shown = abs(value) < 0.5 * pow(10, -Double(max(0, digits))) ? 0 : value
        return formatter.string(from: NSNumber(value: shown)) ?? String(shown)
    }

    /// Chrome's bytesToString: decimal units, a tenth under 100 of a unit.
    static func bytes(_ value: Double) -> String {
        let value = max(0, value)
        if value < 1000 { return integer(value) + " B" }
        let units = ["kB", "MB", "GB", "TB"]
        var scaled = value / 1000
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        let text = scaled < 100 ? decimal(scaled, digits: 1) : integer(scaled)
        return text + " " + units[unit]
    }
}

/// A fixed-size buffer that keeps the newest elements, oldest first.
struct DeveloperRingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    /// Where the next element goes once the buffer is full.
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    var elements: [Element] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head - 1 + storage.count) % storage.count]
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// One reading: when (seconds, on any steady clock) and what; nil for a
/// moment the metric couldn't be read, which breaks the line.
struct DeveloperMetricSample: Equatable {
    var time: Double
    var value: Double?
}

/// A running count turned into a rate per second between readings.
struct DeveloperRateMeter {
    private var previous: (time: Double, count: Double)?

    /// The rate since the last reading; nil for the first, or when the
    /// count went backwards (its source started over) or no time passed.
    mutating func rate(count: Double, at time: Double) -> Double? {
        defer { previous = (time, count) }
        guard let previous, count >= previous.count, time > previous.time else { return nil }
        return (count - previous.count) / (time - previous.time)
    }

    mutating func reset() { previous = nil }
}

/// The charts' arithmetic: how tall the scale goes, where samples land and
/// where the time grid falls.
enum DeveloperChartScale {
    /// How much history the charts show, as Chrome's do.
    static let window: Double = 60

    /// A round top for the scale over `value`: 1, 2 or 5 times a power of
    /// ten, with a little headroom, and never under `floor`.
    static func niceMaximum(_ value: Double, floor: Double = 1) -> Double {
        let target = max(floor, value.isFinite ? value * 1.1 : 0)
        guard target > 0 else { return 1 }
        let power = pow(10, (log10(target)).rounded(.down))
        for step in [1.0, 2, 5, 10] where step * power >= target * (1 - 1e-9) {
            return step * power
        }
        return 10 * power
    }

    /// The scale's top for a metric's samples in the window.
    static func maximum(_ samples: [DeveloperMetricSample], metric: DeveloperPerformanceMetric) -> Double {
        niceMaximum(samples.compactMap(\.value).max() ?? 0, floor: metric.scaleFloor)
    }

    /// A sample's place in a chart `size` wide and tall whose right edge
    /// is `now` and left edge `window` seconds before.
    static func point(_ sample: DeveloperMetricSample, value: Double, now: Double, window: Double = window,
                      maximum: Double, size: CGSize) -> CGPoint {
        let x = size.width - CGFloat((now - sample.time) / window) * size.width
        let fraction = maximum > 0 ? min(1, max(0, value / maximum)) : 0
        return CGPoint(x: x, y: size.height - CGFloat(fraction) * size.height)
    }

    /// The line's runs: consecutive readings in (or just left of) the
    /// window, broken where a reading is missing.
    static func segments(_ samples: [DeveloperMetricSample], now: Double, window: Double = window,
                         maximum: Double, size: CGSize) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        let start = now - window
        // One reading before the window, so the line reaches the edge.
        let firstInside = samples.firstIndex { $0.time >= start } ?? samples.count
        let from = max(0, firstInside - 1)
        for sample in samples[from...] where sample.time <= now + 1 {
            guard let value = sample.value, value.isFinite else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            current.append(point(sample, value: value, now: now, window: window, maximum: maximum, size: size))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The vertical grid's times: every `step` seconds on the clock, in the window.
    static func gridTimes(now: Double, window: Double = window, step: Double = 10) -> [Double] {
        guard step > 0, window > 0 else { return [] }
        var times: [Double] = []
        var time = (now / step).rounded(.down) * step
        while time > now - window {
            times.append(time)
            time -= step
        }
        return times
    }
}

/// What the page reports when sampled: its counts, from the expression
/// below, run in the page once a second.
struct DeveloperPageCounts: Equatable {
    var nodes: Double?
    var documents: Double?
    var frames: Double?

    init(nodes: Double? = nil, documents: Double? = nil, frames: Double? = nil) {
        self.nodes = nodes
        self.documents = documents
        self.frames = frames
    }

    init(raw: Any?) {
        let raw = raw as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? {
            guard let value = (raw[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        self.init(nodes: number("nodes"), documents: number("documents"), frames: number("frames"))
    }

    /// Elements in the page and every same-origin frame's document;
    /// documents, the page's and its same-origin frames'; frames, the page
    /// and every frame under it, cross-origin ones counted by their window.
    static let expression = """
        (() => {
            let nodes = 0, documents = 0, frames = 0;
            const visit = (view, depth) => {
                frames += 1;
                try {
                    const doc = view.document;
                    if (doc) { documents += 1; nodes += doc.getElementsByTagName("*").length; }
                } catch {}
                if (depth > 16) return;
                let count = 0;
                try { count = view.frames.length; } catch {}
                for (let i = 0; i < count && frames < 5000; i++) {
                    try { visit(view.frames[i], depth + 1); } catch {}
                }
            };
            visit(window, 0);
            return {nodes, documents, frames};
        })()
        """
}

/// The samples of every metric, kept for the window and a little more.
struct DeveloperPerformanceHistory {
    /// Readings come about twice a second at most; this keeps over 60 s.
    static let capacity = 200

    private(set) var series: [DeveloperPerformanceMetric: DeveloperRingBuffer<DeveloperMetricSample>] = [:]
    private var layoutMeter = DeveloperRateMeter()
    private var styleMeter = DeveloperRateMeter()

    init() {
        for metric in DeveloperPerformanceMetric.allCases {
            series[metric] = DeveloperRingBuffer(capacity: Self.capacity)
        }
    }

    mutating func add(_ metric: DeveloperPerformanceMetric, _ value: Double?, at time: Double) {
        series[metric, default: DeveloperRingBuffer(capacity: Self.capacity)]
            .append(DeveloperMetricSample(time: time, value: value))
    }

    /// The counts the page sent, and listeners, which it can't.
    mutating func addPage(_ counts: DeveloperPageCounts, at time: Double) {
        add(.domNodes, counts.nodes, at: time)
        add(.documents, counts.documents, at: time)
        add(.frames, counts.frames, at: time)
        add(.eventListeners, nil, at: time)
    }

    /// The timeline's running counts of layouts and style recalculations,
    /// as rates; nil counts (no recording) read n/a and start the rates over.
    mutating func addTimeline(layouts: Double?, styles: Double?, at time: Double) {
        if let layouts {
            add(.layouts, layoutMeter.rate(count: layouts, at: time), at: time)
        } else {
            layoutMeter.reset()
            add(.layouts, nil, at: time)
        }
        if let styles {
            add(.styleRecalcs, styleMeter.rate(count: styles, at: time), at: time)
        } else {
            styleMeter.reset()
            add(.styleRecalcs, nil, at: time)
        }
    }

    func samples(_ metric: DeveloperPerformanceMetric) -> [DeveloperMetricSample] {
        series[metric]?.elements ?? []
    }

    /// The newest reading, if it still is one (not older than `stale` seconds).
    func latest(_ metric: DeveloperPerformanceMetric, now: Double, stale: Double = 5) -> Double? {
        guard let last = series[metric]?.last, now - last.time <= stale else { return nil }
        return last.value
    }

    mutating func removeAll() {
        for metric in DeveloperPerformanceMetric.allCases { series[metric]?.removeAll() }
        layoutMeter.reset()
        styleMeter.reset()
    }
}
