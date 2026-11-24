import Combine
import Foundation

struct DeveloperPerformanceAnnotation: Identifiable, Equatable {
    /// One end of an entries link: a Main track entry, by its name and
    /// time, so the link finds it again in a saved and reopened trace.
    struct Entry: Equatable {
        let name: String
        /// Milliseconds relative to the beginning of the recording.
        let range: ClosedRange<Double>
    }

    /// Chrome's entries link: an arrow from one entry to another.
    struct Link: Equatable {
        let from: Entry
        let to: Entry
    }

    let id: UUID
    let label: String
    /// Milliseconds relative to the beginning of the recording. For a
    /// link, from the earlier entry's start to the later one's end.
    let range: ClosedRange<Double>
    /// Set for an entries link; nil for a label on a range or an event.
    let link: Link?

    init(id: UUID = UUID(), label: String, range: ClosedRange<Double>, link: Link? = nil) {
        self.id = id
        self.label = label
        self.range = range
        self.link = link
    }

    /// An entries link from `from` to `to`, labelled with both names.
    static func linking(_ from: Entry, to: Entry) -> DeveloperPerformanceAnnotation {
        let lower = min(from.range.lowerBound, to.range.lowerBound)
        let upper = max(lower, max(from.range.upperBound, to.range.upperBound))
        return DeveloperPerformanceAnnotation(label: String((from.name + " → " + to.name).prefix(120)),
                                              range: lower...upper, link: Link(from: from, to: to))
    }

    /// The entry in `events` that `entry` names: the one with its name
    /// and time, to within a microsecond.
    static func find(_ entry: Entry, in events: [DeveloperPerformanceEvent]) -> DeveloperPerformanceEvent? {
        let slack = 0.001
        return events.first { event in
            abs(event.start - entry.range.lowerBound) <= slack && abs(event.end - entry.range.upperBound) <= slack
                && event.title == entry.name
        }
    }
}

/// Chrome's recording history: the session's last few recordings, newest
/// first, to switch back to from the Performance toolbar's menu. Each
/// keeps its own annotations.
struct DeveloperPerformanceRecordings {
    typealias Timing = DeveloperToolsSession.Timing

    /// As many as Chrome's TimelineHistoryManager keeps.
    static let limit = 5

    struct Entry: Identifiable {
        /// The recording's key (`key(_:)`).
        let id: String
        let date: Date
        /// The page it was recorded on.
        let url: String?
        let timings: [Timing]
        var annotations: [DeveloperPerformanceAnnotation]
        /// How long it ran, in ms.
        let duration: Double

        /// Chrome's menu item: the page's host and when, with the length.
        var title: String {
            let host = url.flatMap { URL(string: $0)?.host } ?? "Recording"
            let time = date.formatted(date: .omitted, time: .shortened)
            return "\(host) · \(time) · \(DeveloperPerformanceRuler.label(duration))"
        }
    }

    private(set) var entries: [Entry] = []

    /// What tells one recording from another: its records' count and the
    /// last one's id, as the Performance panel tells a new one.
    static func key(_ timings: [Timing]) -> String {
        "\(timings.count)-\(timings.last?.id.uuidString ?? "")"
    }

    func contains(_ key: String) -> Bool { entries.contains { $0.id == key } }

    /// A recording shown for the first time goes first; past the limit
    /// the oldest goes. One already here stays where it is.
    mutating func add(_ timings: [Timing], annotations: [DeveloperPerformanceAnnotation], url: String?,
                      date: Date = Date()) {
        guard !timings.isEmpty else { return }
        let key = Self.key(timings)
        guard !contains(key) else { return }
        var lower = Double.infinity, upper = -Double.infinity
        for timing in timings {
            lower = min(lower, timing.start)
            upper = max(upper, timing.end)
        }
        let duration = lower.isFinite && upper.isFinite ? max(0, (upper - lower) * 1_000) : 0
        entries.insert(Entry(id: key, date: date, url: url, timings: timings, annotations: annotations,
                             duration: duration), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// The annotations a recording has now, kept for when it is shown again.
    mutating func update(_ key: String, annotations: [DeveloperPerformanceAnnotation]) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        entries[index].annotations = annotations
    }

    mutating func clear() { entries = [] }
}

/// Each DevTools session's recording history, kept while its Performance
/// panel is off screen.
@MainActor
final class DeveloperPerformanceHistoryStore: ObservableObject {
    private static var stores: [ObjectIdentifier: DeveloperPerformanceHistoryStore] = [:]

    static func of(_ session: DeveloperToolsSession) -> DeveloperPerformanceHistoryStore {
        let key = ObjectIdentifier(session)
        if let store = stores[key], store.session === session { return store }
        stores = stores.filter { $0.value.session != nil }
        let store = DeveloperPerformanceHistoryStore(session: session)
        stores[key] = store
        return store
    }

    private(set) weak var session: DeveloperToolsSession?
    @Published var history = DeveloperPerformanceRecordings()

    private init(session: DeveloperToolsSession) {
        self.session = session
    }
}

/// Performance › Save profile (⌘S) and Load profile (⌘O), as in Chrome
/// DevTools. A recording is saved in Chrome's trace event format — a JSON
/// array of complete events, {name, cat, ph: "X", ts, dur, pid, tid, args},
/// times in microseconds, on a thread named CrRendererMain — so the file
/// opens in Chrome's Performance panel too. What Chrome's format has no
/// place for (WebKit's own record type, the nesting depth, the call stack)
/// goes in each event's args.perch, so a file saved here opens here as it
/// was recorded.
///
/// Saved with "Include script content and source maps", as Chrome saves
/// them: the file becomes {"traceEvents": [...], "metadata": {...}}, each
/// script a ScriptRundown event (its URL and map's) with its text in
/// ScriptRundownSource, each map in metadata.sourceMaps as {url,
/// sourceMapUrl, sourceMap}; loading reads them back for the Duplicated
/// and Legacy JavaScript insights.
///
/// Loading takes that format (as an array or as Chrome's own
/// {"traceEvents": [...]} object, with complete, instant and begin/end
/// events, keeping only the page's main thread from a trace Chrome
/// recorded), or WebKit's timeline records as Timeline.eventRecorded sends
/// them (an array, or {"records": [...]}).
enum DeveloperPerformanceTrace {
    typealias Timing = DeveloperToolsSession.Timing

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't a performance profile."
            case .empty: "The profile has no events to show."
            }
        }
    }

    static let processID = 1
    static let threadID = 1
    static let category = "devtools.timeline"
    private static let annotationCategory = "perch.annotation"

    struct Recording {
        let timings: [Timing]
        let annotations: [DeveloperPerformanceAnnotation]
        /// The scripts the file carries; nil when it has none.
        var scripts: [DeveloperPerformanceScript]? = nil
    }

    /// WebKit's record types under Chrome's names, where the two differ.
    static let chromeNames: [String: String] = [
        "RecalculateStyles": "UpdateLayoutTree",
        "Composite": "CompositeLayers",
        "GCEvent": "MajorGC",
    ]

    /// Chrome's event names as WebKit's record types, where they differ.
    static let webKitNames: [String: String] = {
        var names: [String: String] = [:]
        for (webKit, chrome) in chromeNames { names[chrome] = webKit }
        names["MinorGC"] = "GCEvent"
        names["ScheduleStyleInvalidationTracking"] = "ScheduleStyleRecalculation"
        return names
    }()

    /// Chrome's milestone events, as the Timings track's markers.
    static let chromeMarkers: [String: String] = [
        "firstPaint": "FP",
        "firstContentfulPaint": "FCP",
        "largestContentfulPaint::Candidate": "LCP",
        "MarkDOMContent": "DCL",
        "MarkLoad": "L",
    ]

    static let markerNames: [String: String] = [
        "FP": "First Paint",
        "FCP": "First Contentful Paint",
        "LCP": "Largest Contentful Paint",
        "DCL": "DOMContentLoaded event",
        "L": "Onload event",
    ]

    /// Chrome's bookkeeping events, which aren't work the page did.
    private static let skipped: Set<String> = ["TracingStartedInBrowser", "TracingStartedInPage", "TracingSessionIdForWorker",
                                               rundown, rundownSource]
    private static let rundown = "ScriptRundown"
    private static let rundownSource = "ScriptRundownSource"
    /// Chrome's V8 isolate, which with the script id names each script.
    private static let isolate = "1"

    // MARK: Saving

    /// The recording as a trace file. `url` is the page it was recorded on;
    /// `scripts`, when given, go in with their maps.
    static func export(_ timings: [Timing], url: String? = nil, annotations: [DeveloperPerformanceAnnotation] = [],
                       scripts: [DeveloperPerformanceScript]? = nil) throws -> Data {
        let ids: [String: Any] = ["pid": processID, "tid": threadID]
        func event(_ fields: [String: Any]) -> [String: Any] { fields.merging(ids) { first, _ in first } }
        let origin = timings.map(\.start).min() ?? 0
        var events: [[String: Any]] = [
            event(["name": "process_name", "ph": "M", "cat": "__metadata", "ts": 0, "args": ["name": "Renderer"]]),
            event(["name": "thread_name", "ph": "M", "cat": "__metadata", "ts": 0, "args": ["name": "CrRendererMain"]]),
            event(["name": "TracingStartedInBrowser", "ph": "I", "s": "t", "cat": "disabled-by-default-devtools.timeline",
                   "ts": origin * 1_000_000,
                   "args": ["data": ["frameTreeNodeId": 1, "persistentIds": true,
                                     "frames": [["frame": "perch-main-frame", "url": url ?? "", "name": "",
                                                 "processId": processID]]]]]),
        ]
        events.reserveCapacity(timings.count + events.count)
        for timing in timings {
            if timing.type == "Screenshot", let image = timing.data["imageData"] {
                // As Chrome writes its filmstrip: base64 image data in args.snapshot.
                let base64 = image.range(of: "base64,").map { String(image[$0.upperBound...]) } ?? image
                events.append(event([
                    "name": "Screenshot", "cat": "disabled-by-default-devtools.screenshot", "ph": "O",
                    "id": "0x1", "ts": timing.start * 1_000_000, "args": ["snapshot": base64],
                ]))
                continue
            }
            var data: [String: Any] = [:]
            for (key, value) in timing.data { data[key] = jsonValue(value) }
            var perch: [String: Any] = ["type": timing.type, "depth": timing.depth]
            if !timing.stack.isEmpty { perch["stack"] = timing.stack }
            // As Chrome writes a record's stack: args.data.stackTrace, 1-based.
            if !timing.frames.isEmpty {
                data["stackTrace"] = timing.frames.map { frame -> [String: Any] in
                    var item: [String: Any] = ["functionName": frame.functionName, "url": frame.url,
                                               "lineNumber": frame.lineNumber, "columnNumber": frame.columnNumber]
                    if let id = frame.scriptID { item["scriptId"] = id }
                    return item
                }
            }
            events.append(event([
                "name": chromeNames[timing.type] ?? timing.type,
                "cat": category,
                "ph": "X",
                "ts": timing.start * 1_000_000,
                "dur": max(0, timing.end - timing.start) * 1_000_000,
                "args": ["data": data, "perch": perch],
            ]))
        }
        for annotation in annotations {
            var args: [String: Any] = ["id": annotation.id.uuidString, "label": annotation.label]
            if let link = annotation.link {
                args["linkFrom"] = linkEnd(link.from)
                args["linkTo"] = linkEnd(link.to)
            }
            events.append(event([
                "name": "PerchAnnotation", "cat": annotationCategory, "ph": "X",
                "ts": (origin * 1_000 + annotation.range.lowerBound) * 1_000,
                "dur": (annotation.range.upperBound - annotation.range.lowerBound) * 1_000,
                "args": args,
            ]))
        }
        guard let scripts, !scripts.isEmpty else { return try JSONSerialization.data(withJSONObject: events, options: []) }
        var maps: [[String: Any]] = []
        for (index, script) in scripts.enumerated() {
            var data: [String: Any] = ["isolate": isolate, "scriptId": index + 1, "url": script.url, "isModule": false,
                                       "startLine": 0, "startColumn": 0, "length": script.text.utf16.count]
            var map: [String: Any] = ["url": script.url]
            if let mapURL = script.mapURL { data["sourceMapUrl"] = mapURL; map["sourceMapUrl"] = mapURL }
            for (name, category, args) in [
                (rundown, "disabled-by-default-devtools.v8-source-rundown", data),
                (rundownSource, "disabled-by-default-devtools.v8-source-rundown-sources",
                 ["isolate": isolate, "scriptId": index + 1, "length": script.text.utf16.count, "sourceText": script.text]),
            ] as [(String, String, [String: Any])] {
                events.append(event(["name": name, "cat": category, "ph": "I", "s": "t", "ts": origin * 1_000_000,
                                     "args": ["data": args]]))
            }
            if let json = script.mapText.flatMap(DeveloperSourceMap.json) {
                map["sourceMap"] = json
                maps.append(map)
            }
        }
        return try JSONSerialization.data(withJSONObject: ["traceEvents": events,
                                                           "metadata": ["source": "DevTools", "sourceMaps": maps]])
    }

    /// An entries link's end, its times in ms from the recording's start.
    private static func linkEnd(_ entry: DeveloperPerformanceAnnotation.Entry) -> [String: Any] {
        ["name": entry.name, "start": entry.range.lowerBound, "end": entry.range.upperBound]
    }

    private static func linkEnd(_ value: Any?) -> DeveloperPerformanceAnnotation.Entry? {
        guard let object = value as? [String: Any], let name = object["name"] as? String, !name.isEmpty,
              let start = number(object["start"]), let end = number(object["end"]),
              start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        return DeveloperPerformanceAnnotation.Entry(name: String(name.prefix(200)), range: start...end)
    }

    /// A data value as JSON: whole numbers as numbers, as Chrome writes
    /// line numbers and ids, the rest as text.
    static func jsonValue(_ text: String) -> Any {
        if let number = Int(text), String(number) == text { return number }
        return text
    }

    // MARK: Loading

    static func timings(from data: Data) throws -> [Timing] {
        try recording(from: data).timings
    }

    static func recording(from data: Data) throws -> Recording {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = json as? [String: Any]
        guard let list = json as? [Any] ?? object?["traceEvents"] as? [Any] ?? object?["records"] as? [Any] else {
            throw Failure.unreadable
        }
        let objects = list.compactMap { $0 as? [String: Any] }
        let annotationEvents = objects.lazy.filter { $0["cat"] as? String == annotationCategory }
        let result: [Timing]
        if objects.contains(where: { $0["ph"] == nil && $0["type"] is String }) {
            // WebKit's timeline records, nested as WebKit sends them.
            var records: [Timing] = []
            for record in objects { DeveloperToolsSession.addTimings(record, to: &records) }
            result = records
        } else if objects.contains(where: { $0["ph"] is String }) {
            result = traceTimings(objects.filter { $0["cat"] as? String != annotationCategory })
        } else {
            throw Failure.unreadable
        }
        guard !result.isEmpty else { throw Failure.empty }
        let origin = (result.map(\.start).min() ?? 0) * 1_000
        let annotations: [DeveloperPerformanceAnnotation] = annotationEvents.prefix(256).compactMap { event in
            guard let args = event["args"] as? [String: Any], let label = args["label"] as? String, !label.isEmpty,
                  let ts = number(event["ts"]), let dur = number(event["dur"]), ts.isFinite, dur.isFinite else { return nil }
            let start = max(0, ts / 1_000 - origin)
            let end = max(start, start + dur / 1_000)
            guard end.isFinite else { return nil }
            let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            var link: DeveloperPerformanceAnnotation.Link?
            if let from = linkEnd(args["linkFrom"]), let to = linkEnd(args["linkTo"]) {
                link = DeveloperPerformanceAnnotation.Link(from: from, to: to)
            }
            return DeveloperPerformanceAnnotation(id: id, label: String(label.prefix(120)), range: start...end, link: link)
        }
        return Recording(timings: result, annotations: annotations,
                         scripts: traceScripts(objects, metadata: object?["metadata"] as? [String: Any]))
    }

    /// The scripts a trace carries: each ScriptRundown with the text its
    /// ScriptRundownSource events hold (in pieces, for a long one), and
    /// the map metadata.sourceMaps has for it. Nil when there are none.
    static func traceScripts(_ events: [[String: Any]], metadata: [String: Any]?) -> [DeveloperPerformanceScript]? {
        func payload(_ event: [String: Any]) -> [String: Any]? { (event["args"] as? [String: Any])?["data"] as? [String: Any] }
        func key(_ data: [String: Any]) -> String { "\(data["isolate"] ?? "").\(data["scriptId"] ?? "")" }
        var pieces: [String: [Int: String]] = [:]
        for event in events where event["name"] as? String == rundownSource {
            guard let data = payload(event), let text = data["sourceText"] as? String else { continue }
            let index = (data["splitIndex"] as? NSNumber)?.intValue ?? pieces[key(data)]?.count ?? 0
            pieces[key(data), default: [:]][index] = text
        }
        let maps = metadata?["sourceMaps"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var scripts: [DeveloperPerformanceScript] = []
        for event in events where event["name"] as? String == rundown {
            guard let data = payload(event), let url = data["url"] as? String, !url.isEmpty,
                  let parts = pieces[key(data)], seen.insert(url).inserted else { continue }
            let mapURL = data["sourceMapUrl"] as? String
            let entry = maps.first { $0["url"] as? String == url && $0["sourceMapUrl"] as? String == mapURL }
                ?? maps.first { $0["url"] as? String == url }
            let json = entry?["sourceMap"] as? [String: Any]
            let base = (entry?["sourceMapUrl"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("data:") ? nil : $0 }
            scripts.append(DeveloperPerformanceScript(
                url: url, text: parts.sorted { $0.key < $1.key }.map(\.value).joined(),
                map: json.flatMap { try? DeveloperSourceMap(json: $0, base: base ?? url) },
                mapText: json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) },
                mapURL: base))
        }
        return scripts.isEmpty ? nil : scripts
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func thread(_ event: [String: Any]) -> String {
        let pid = event["pid"].map { "\($0)" } ?? ""
        let tid = event["tid"].map { "\($0)" } ?? ""
        return pid + ":" + tid
    }

    /// The page's main thread in a trace Chrome recorded: the CrRendererMain
    /// thread with the most events. Nil when no thread is named so, and
    /// every thread is kept.
    static func mainThread(_ events: [[String: Any]]) -> String? {
        var renderers = Set<String>()
        for event in events where event["ph"] as? String == "M" && event["name"] as? String == "thread_name" {
            if (event["args"] as? [String: Any])?["name"] as? String == "CrRendererMain" { renderers.insert(thread(event)) }
        }
        guard renderers.count > 1 else { return renderers.first }
        var counts: [String: Int] = [:]
        for event in events where event["ph"] as? String != "M" {
            let key = thread(event)
            if renderers.contains(key) { counts[key, default: 0] += 1 }
        }
        return renderers.max { (counts[$0] ?? 0, $1) < (counts[$1] ?? 0, $0) }
    }

    private static func traceTimings(_ events: [[String: Any]]) -> [Timing] {
        let main = mainThread(events)
        var result: [Timing] = []
        // Begin events waiting for their end, by thread.
        var begun: [String: [[String: Any]]] = [:]
        for event in events {
            guard let phase = event["ph"] as? String, let name = event["name"] as? String,
                  let ts = number(event["ts"]), !skipped.contains(name) else { continue }
            let key = thread(event)
            // Chrome's filmstrip, recorded off the main thread.
            if name == "Screenshot", let snapshot = (event["args"] as? [String: Any])?["snapshot"] as? String {
                result.append(Timing(type: "Screenshot", start: ts / 1_000_000, end: ts / 1_000_000, depth: 0,
                                     data: ["imageData": snapshot], stack: []))
                continue
            }
            if let main, key != main { continue }
            switch phase {
            case "X":
                let duration = max(0, number(event["dur"]) ?? 0)
                result.append(timing(event, name: name, start: ts, end: ts + duration))
            case "I", "i", "R":
                result.append(timing(event, name: name, start: ts, end: ts))
            case "B":
                begun[key, default: []].append(event)
            case "E":
                guard let open = begun[key]?.popLast(), let start = number(open["ts"]) else { continue }
                let openName = open["name"] as? String ?? name
                result.append(timing(open, name: openName, start: start, end: max(start, ts)))
            default:
                // Metadata, async, counter, flow and sample events.
                continue
            }
        }
        return result
    }

    /// One trace event as a record; `start` and `end` in microseconds.
    private static func timing(_ event: [String: Any], name: String, start: Double, end: Double) -> Timing {
        let args = event["args"] as? [String: Any] ?? [:]
        let perch = args["perch"] as? [String: Any]
        let raw = args["data"] as? [String: Any] ?? [:]
        let data = raw.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
        if perch == nil {
            // Chrome's page milestones and performance.mark()s, for the
            // Timings track.
            if let kind = chromeMarkers[name] {
                return Timing(type: "PageTiming", start: start / 1_000_000, end: start / 1_000_000,
                              data: ["kind": kind, "name": markerNames[kind] ?? kind])
            }
            if (event["cat"] as? String)?.contains("blink.user_timing") == true, end == start {
                return Timing(type: "PageTiming", start: start / 1_000_000, end: start / 1_000_000,
                              data: ["kind": "mark", "name": name])
            }
        }
        let stack = perch?["stack"] as? [String] ?? (raw["stackTrace"] as? [[String: Any]] ?? []).prefix(5).map(Timing.frame)
        return Timing(type: perch?["type"] as? String ?? webKitNames[name] ?? name,
                      start: start / 1_000_000, end: end / 1_000_000,
                      depth: (perch?["depth"] as? NSNumber)?.intValue ?? 0, data: data, stack: stack,
                      frames: Timing.frames(raw["stackTrace"]))
    }

    /// The name a saved profile gets, as Chrome names its own:
    /// Trace-20261122T153000.json.
    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return "Trace-\(formatter.string(from: date)).json"
    }
}
