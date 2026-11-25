import Foundation

/// Chrome's Performance panel extensibility ("Performance panel
/// extensibility" on developer.chrome.com): what a page says about its own
/// work for the Performance view to draw.
///
/// - `performance.measure(name, {start, end, detail: {devtools: {dataType:
///   "track-entry", track, trackGroup?, color?, properties?, tooltipText?}}})`
///   is a bar on a custom track named `track`, grouped under `trackGroup`.
/// - `performance.mark(name, {detail: {devtools: {dataType: "marker",
///   color?, properties?, tooltipText?}}})` is a marker down the timeline,
///   named in the Timings track.
/// - `console.timeStamp(label, start, end, trackName, trackGroup, color)`
///   is a bar on the custom track `trackName`, or in Timings without one.
///
/// The page's metrics script (DeveloperPerformance-metrics.js) copies each
/// detail.devtools to plain strings, flagging one too big; this checks
/// them, and a recording keeps each as a "PerformanceExtension" record
/// (data kind, name, source, track, trackGroup, color, tooltip and
/// properties, as JSON pairs), within its own budget, so a saved profile
/// opens with them.
enum DeveloperPerformanceExtensions {
    typealias Timing = DeveloperToolsSession.Timing

    /// The record type a recording keeps them as, and how many it keeps.
    static let type = "PerformanceExtension"
    static let limit = 2_000
    /// The longest name, track, track group or color, in characters.
    static let textLimit = 200
    static let tooltipLimit = 1_000
    static let propertyLimit = 50
    static let propertyValueLimit = 1_000
    /// The most a detail.devtools may say in all; past it, it's ignored.
    static let sizeLimit = 8_192
    /// The most rows a custom track stacks its bars in.
    static let rowLimit = 6

    struct Property: Equatable {
        let key: String
        let value: String
    }

    enum DataType: String {
        case trackEntry = "track-entry"
        case marker
    }

    /// A detail.devtools, checked.
    struct Detail: Equatable {
        let dataType: DataType
        let track: String?
        let group: String?
        /// A palette name, "primary" when none or an unknown one was given.
        let color: String
        let tooltip: String?
        let properties: [Property]
    }

    // MARK: Colors

    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Chrome's palette names for extension entries, as its colours.
    static let palette: [String: RGB] = [
        "primary": RGB(red: 0.10, green: 0.45, blue: 0.91),
        "primary-light": RGB(red: 0.54, green: 0.71, blue: 0.97),
        "primary-dark": RGB(red: 0.04, green: 0.26, blue: 0.63),
        "secondary": RGB(red: 0.35, green: 0.42, blue: 0.53),
        "secondary-light": RGB(red: 0.66, green: 0.72, blue: 0.80),
        "secondary-dark": RGB(red: 0.20, green: 0.25, blue: 0.33),
        "tertiary": RGB(red: 0.12, green: 0.56, blue: 0.24),
        "tertiary-light": RGB(red: 0.51, green: 0.79, blue: 0.58),
        "tertiary-dark": RGB(red: 0.05, green: 0.40, blue: 0.18),
        "error": RGB(red: 0.85, green: 0.19, blue: 0.15),
        "warning": RGB(red: 0.98, green: 0.67, blue: 0.0),
    ]

    static let defaultColor = "primary"

    /// The palette name for what the page gave: Chrome's names, any case;
    /// anything else is "primary".
    static func colorName(_ raw: Any?) -> String {
        guard let text = raw as? String else { return defaultColor }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return palette[name] == nil ? defaultColor : name
    }

    static func rgb(_ name: String) -> RGB {
        palette[name] ?? palette[defaultColor] ?? RGB(red: 0.10, green: 0.45, blue: 0.91)
    }

    /// Whether a bar in this colour wants dark text on it.
    static func isLight(_ name: String) -> Bool {
        name.hasSuffix("-light") || name == "warning"
    }

    // MARK: Reading the page's

    /// detail.devtools for a "mark" or "measure", or nil when it isn't one
    /// Chrome would draw (a measure's dataType is "track-entry", with a
    /// track; a mark's "marker") or it says too much.
    static func detail(_ raw: Any?, for kind: String) -> Detail? {
        guard let raw = raw as? [String: Any], raw["oversized"] as? Bool != true else { return nil }
        var oversized = false
        var size = 0
        func text(_ value: Any?, limit: Int) -> String? {
            guard let value = value as? String else { return nil }
            size += value.count
            if value.count > limit { oversized = true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let typeName = raw["dataType"] as? String ?? (kind == "measure" ? DataType.trackEntry.rawValue : "")
        guard let dataType = DataType(rawValue: typeName) else { return nil }
        switch (kind, dataType) {
        case ("measure", .trackEntry), ("mark", .marker): break
        default: return nil
        }
        let track = text(raw["track"], limit: textLimit)
        let group = text(raw["trackGroup"], limit: textLimit)
        _ = text(raw["color"], limit: textLimit)
        let tooltip = text(raw["tooltipText"], limit: tooltipLimit)
        var properties: [Property] = []
        if let pairs = raw["properties"] as? [Any] {
            if pairs.count > propertyLimit { oversized = true }
            for pair in pairs.prefix(propertyLimit) {
                guard let pair = pair as? [Any], pair.count >= 2, let key = text(pair[0], limit: textLimit) else { continue }
                let value: String?
                if let number = pair[1] as? NSNumber { value = number.stringValue } else { value = text(pair[1], limit: propertyValueLimit) }
                if let value { properties.append(Property(key: key, value: value)) }
            }
        }
        guard !oversized, size <= sizeLimit else { return nil }
        if dataType == .trackEntry, track == nil { return nil }
        return Detail(dataType: dataType, track: dataType == .trackEntry ? track : nil,
                      group: dataType == .trackEntry ? group : nil, color: colorName(raw["color"]),
                      tooltip: tooltip, properties: properties)
    }

    /// A record as the page's script answered it, on the page's clock (ms).
    struct PageRecord: Equatable {
        let type: String
        let start: Double
        let end: Double
        let data: [String: String]
    }

    /// A mark or measure the page gave a detail.devtools: an extension
    /// record, or, if Chrome wouldn't draw it so, a plain Timings one.
    static func pageRecord(_ raw: [String: Any]) -> PageRecord? {
        guard let kind = raw["kind"] as? String, kind == "mark" || kind == "measure",
              let start = DeveloperMeasure.finite(raw["start"]) else { return nil }
        let end = kind == "mark" ? start : max(start, DeveloperMeasure.finite(raw["end"]) ?? start)
        let name = (raw["name"] as? String).map { String($0.prefix(textLimit)) } ?? kind
        guard let checked = Self.detail(raw["devtools"], for: kind) else {
            return PageRecord(type: "PageTiming", start: start, end: end, data: ["kind": kind, "name": name])
        }
        var data = ["kind": checked.dataType.rawValue, "name": name, "source": "performance.\(kind)", "color": checked.color]
        if let track = checked.track { data["track"] = track }
        if let group = checked.group { data["trackGroup"] = group }
        if let tooltip = checked.tooltip { data["tooltip"] = tooltip }
        if !checked.properties.isEmpty { data["properties"] = encode(checked.properties) }
        return PageRecord(type: type, start: start, end: end, data: data)
    }

    /// Where console.timeStamp's start or end falls on the page's clock: a
    /// number is a time; a string names a mark or an earlier timestamp, as
    /// the page found it when called (`names`); anything else, or a name
    /// not found, is the time of the call.
    static func resolve(_ value: Any?, at: Double, names: [String: Any]) -> Double {
        if let name = value as? String { return DeveloperMeasure.finite(names[name]) ?? at }
        return DeveloperMeasure.finite(value) ?? at
    }

    /// One extended console.timeStamp call the page's script kept: a bar on
    /// its track, or in Timings (a measure, or a mark when it has no length)
    /// when it named no track.
    static func timeStamp(_ raw: [String: Any]) -> PageRecord? {
        guard let label = raw["label"] as? String, let at = DeveloperMeasure.finite(raw["at"]) else { return nil }
        let names = raw["names"] as? [String: Any] ?? [:]
        let first = resolve(raw["start"], at: at, names: names)
        let second = resolve(raw["end"], at: at, names: names)
        let start = min(first, second), end = max(first, second)
        let name = String(label.prefix(textLimit))
        func text(_ key: String) -> String? {
            guard let value = raw[key] as? String, value.count <= textLimit,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        guard let track = text("track") else {
            var data = ["kind": end > start ? "measure" : "mark", "name": name]
            if text("color") != nil { data["color"] = colorName(raw["color"]) }
            return PageRecord(type: "PageTiming", start: start, end: end, data: data)
        }
        var data = ["kind": DataType.trackEntry.rawValue, "name": name, "source": "console.timeStamp",
                    "track": track, "color": colorName(raw["color"])]
        if let group = text("trackGroup") { data["trackGroup"] = group }
        return PageRecord(type: type, start: start, end: end, data: data)
    }

    /// The page's extension marks and measures and its timestamps, the
    /// newest `limit` of them by start.
    static func pageRecords(_ page: [String: Any]) -> [PageRecord] {
        let marked = (page["extensions"] as? [[String: Any]] ?? []).suffix(limit).compactMap(pageRecord)
        let stamped = (page["stamps"] as? [[String: Any]] ?? []).suffix(limit).compactMap(timeStamp)
        let all = (marked + stamped).sorted { $0.start < $1.start }
        return Array(all.suffix(limit))
    }

    static func encode(_ properties: [Property]) -> String {
        let pairs = properties.map { [$0.key, $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decode(_ text: String?) -> [Property] {
        guard let text, let data = text.data(using: .utf8),
              let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return [] }
        return pairs.prefix(propertyLimit).compactMap { pair in
            guard pair.count >= 2, let key = pair[0] as? String else { return nil }
            if let value = pair[1] as? String { return Property(key: key, value: value) }
            if let value = pair[1] as? NSNumber { return Property(key: key, value: value.stringValue) }
            return nil
        }
    }

    // MARK: In a profile

    /// A bar on a custom track, in ms from the recording's start.
    struct Entry: Equatable {
        let name: String
        /// "performance.measure" or "console.timeStamp".
        let source: String
        let start: Double
        let end: Double
        let color: String
        let tooltip: String?
        let properties: [Property]
        var row = 0

        var duration: Double { end - start }
    }

    /// A marker down the timeline, named in the Timings track.
    struct Marker: Equatable {
        let name: String
        let time: Double
        let color: String
        let tooltip: String?
        let properties: [Property]
    }

    /// A custom track and its bars, stacked into `rows`.
    struct Track: Equatable {
        let name: String
        let group: String?
        var entries: [Entry]
        var rows = 0
    }

    /// What a click chose: an entry of a custom track, or a marker when
    /// `track` is nil.
    struct Selection: Equatable {
        let track: Int?
        let index: Int
    }

    /// What Summary shows of an entry or a marker.
    struct Summary: Equatable {
        let title: String
        /// "Track entry" or "Marker".
        let kind: String
        let source: String
        let track: String?
        let group: String?
        let start: Double
        let duration: Double?
        let color: String
        let tooltip: String?
        let properties: [Property]
    }

    /// A record of a recording as an entry (with its track and group) or a
    /// marker; `start` and `end` in ms from the recording's start.
    static func entry(_ data: [String: String], start: Double, end: Double) -> (track: String, group: String?, entry: Entry)? {
        guard data["kind"] == DataType.trackEntry.rawValue, let track = data["track"], !track.isEmpty else { return nil }
        let entry = Entry(name: data["name"] ?? track, source: data["source"] ?? "performance.measure",
                          start: start, end: max(start, end), color: colorName(data["color"]),
                          tooltip: data["tooltip"], properties: decode(data["properties"]))
        return (track: track, group: data["trackGroup"].flatMap { $0.isEmpty ? nil : $0 }, entry: entry)
    }

    static func marker(_ data: [String: String], at time: Double) -> Marker? {
        guard data["kind"] == DataType.marker.rawValue else { return nil }
        return Marker(name: data["name"] ?? "Marker", time: time, color: colorName(data["color"]),
                      tooltip: data["tooltip"], properties: decode(data["properties"]))
    }

    /// The custom tracks, each its bars stacked: a group's tracks kept
    /// together, groups and ungrouped tracks in the order they first have
    /// something, as are the tracks in a group. The same name in two groups
    /// is two tracks.
    static func tracks(_ items: [(track: String, group: String?, entry: Entry)]) -> [Track] {
        struct Found {
            var track: Track
            var first: Double
            let position: Int
        }
        var found: [String: Found] = [:]
        var order: [String] = []
        for item in items {
            let key = (item.group ?? "") + "\u{1}" + item.track
            if found[key] == nil {
                found[key] = Found(track: Track(name: item.track, group: item.group, entries: []),
                                   first: item.entry.start, position: order.count)
                order.append(key)
            }
            found[key]?.track.entries.append(item.entry)
            if let first = found[key]?.first, item.entry.start < first { found[key]?.first = item.entry.start }
        }
        struct Section {
            var first: Double
            let position: Int
            var tracks: [Found]
        }
        var sections: [Section] = []
        var groups: [String: Int] = [:]
        for key in order {
            guard let track = found[key] else { continue }
            if let group = track.track.group, let index = groups[group] {
                sections[index].tracks.append(track)
                sections[index].first = min(sections[index].first, track.first)
            } else {
                if let group = track.track.group { groups[group] = sections.count }
                sections.append(Section(first: track.first, position: track.position, tracks: [track]))
            }
        }
        func before(_ a: Double, _ x: Int, _ b: Double, _ y: Int) -> Bool { a != b ? a < b : x < y }
        sections.sort { before($0.first, $0.position, $1.first, $1.position) }
        var result: [Track] = []
        for section in sections {
            for item in section.tracks.sorted(by: { before($0.first, $0.position, $1.first, $1.position) }) {
                var track = item.track
                track.entries.sort { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
                track.rows = DeveloperPerformanceProfile.stack(&track.entries, start: \.start, end: \.end, row: \.row,
                                                               most: rowLimit)
                result.append(track)
            }
        }
        return result
    }
}

extension DeveloperPerformanceProfile {
    /// The entry of custom track `track` at `time` in `row`.
    func customEntry(track: Int, at time: Double, row: Int, tolerance: Double = 0) -> Int? {
        guard customTracks.indices.contains(track) else { return nil }
        let entries = customTracks[track].entries
        return entries.indices.last {
            entries[$0].row == row && entries[$0].start - tolerance <= time && time <= entries[$0].end + tolerance
        }
    }

    /// The extension marker nearest `time`, within `tolerance`.
    func customMarker(at time: Double, tolerance: Double) -> Int? {
        extensionMarkers.indices
            .filter { abs(extensionMarkers[$0].time - time) <= tolerance }
            .min { abs(extensionMarkers[$0].time - time) < abs(extensionMarkers[$1].time - time) }
    }

    func customSummary(_ selection: DeveloperPerformanceExtensions.Selection) -> DeveloperPerformanceExtensions.Summary? {
        if let index = selection.track {
            guard customTracks.indices.contains(index), customTracks[index].entries.indices.contains(selection.index) else {
                return nil
            }
            let track = customTracks[index]
            let entry = track.entries[selection.index]
            return DeveloperPerformanceExtensions.Summary(title: entry.name, kind: "Track entry", source: entry.source, track: track.name, group: track.group,
                         start: entry.start, duration: entry.duration, color: entry.color, tooltip: entry.tooltip,
                         properties: entry.properties)
        }
        guard extensionMarkers.indices.contains(selection.index) else { return nil }
        let marker = extensionMarkers[selection.index]
        return DeveloperPerformanceExtensions.Summary(title: marker.name, kind: "Marker", source: "performance.mark", track: nil, group: nil,
                     start: marker.time, duration: nil, color: marker.color, tooltip: marker.tooltip,
                     properties: marker.properties)
    }
}
