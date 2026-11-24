import Foundation

// The Media drawer tool's pure logic: HTMLMediaElement's state names, the
// players as the page script reports them, each player's event log (a ring),
// the buffered and played ranges in words and as fractions of the timeline
// bar, and which console messages are about media. WebKit has no Media
// domain, so all of it comes from DeveloperMedia-observe.js in the page.

/// HTMLMediaElement's numeric states and MediaError's codes, by the names
/// the HTML spec gives them (as Chrome's Media panel shows them).
enum DeveloperMediaState {
    static func readyState(_ value: Int?) -> String {
        named(value, ["HAVE_NOTHING", "HAVE_METADATA", "HAVE_CURRENT_DATA", "HAVE_FUTURE_DATA", "HAVE_ENOUGH_DATA"])
    }

    static func networkState(_ value: Int?) -> String {
        named(value, ["NETWORK_EMPTY", "NETWORK_IDLE", "NETWORK_LOADING", "NETWORK_NO_SOURCE"])
    }

    static func errorCode(_ code: Int?) -> String {
        named(code, ["MEDIA_ERR_ABORTED", "MEDIA_ERR_NETWORK", "MEDIA_ERR_DECODE", "MEDIA_ERR_SRC_NOT_SUPPORTED"], from: 1)
    }

    /// `names[value - first]`, the number itself past them, or "—" for none.
    private static func named(_ value: Int?, _ names: [String], from first: Int = 0) -> String {
        guard let value else { return "—" }
        return names.indices.contains(value - first) ? names[value - first] : "\(value)"
    }

    /// The media events the page script listens for, in Chrome's order.
    static let events = [
        "loadstart", "durationchange", "loadedmetadata", "loadeddata", "progress", "canplay", "canplaythrough",
        "play", "playing", "pause", "seeking", "seeked", "waiting", "stalled", "suspend", "ended", "error",
        "abort", "emptied", "ratechange", "volumechange", "resize", "encrypted", "waitingforkey",
    ]

    /// Events worth a warning colour in the log.
    static func isTrouble(_ event: String) -> Bool {
        ["error", "stalled", "waiting", "abort", "emptied", "waitingforkey"].contains(event)
    }
}

/// A fixed-size log that keeps the newest entries, counting what it let go.
struct DeveloperMediaEventLog<Entry: Equatable>: Equatable {
    let capacity: Int
    private(set) var entries: [Entry] = []
    /// How many older entries were dropped to make room.
    private(set) var dropped = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst()
            dropped += 1
        }
    }

    mutating func append<S: Sequence>(contentsOf more: S) where S.Element == Entry {
        for entry in more { append(entry) }
    }

    mutating func removeAll() {
        entries = []
        dropped = 0
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// One media event as the page saw it.
struct DeveloperMediaEvent: Equatable, Identifiable {
    /// The page's own running number, unique per player.
    let seq: Int
    let name: String
    /// When it fired, as milliseconds since 1970.
    let time: Double
    /// The element's currentTime then.
    let mediaTime: Double?
    /// Anything the event carries: an `encrypted` event's initDataType,
    /// the new size on `resize`, the rate on `ratechange`.
    let detail: String?

    var id: Int { seq }

    init?(_ raw: [String: Any]) {
        guard let seq = (raw["seq"] as? NSNumber)?.intValue, let name = raw["name"] as? String else { return nil }
        self.seq = seq
        self.name = name
        time = raw.double("time") ?? 0
        mediaTime = raw.double("mediaTime")
        detail = (raw["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A Messages-tab row: a player's MediaError, or a console line about media.
struct DeveloperMediaMessage: Equatable, Identifiable {
    enum Level: String { case error, warning, info }
    let id: String
    let level: Level
    let text: String
    let time: Double?
}

/// A media time range, in seconds.
struct DeveloperMediaRange: Equatable {
    let start: Double
    let end: Double
}

/// Time ranges: read from the page, said in words, drawn on the bar.
enum DeveloperMediaRanges {
    static func parse(_ raw: Any?) -> [DeveloperMediaRange] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { item in
            guard let pair = item as? [Any], pair.count == 2,
                  let start = (pair[0] as? NSNumber)?.doubleValue, let end = (pair[1] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite else { return nil }
            return DeveloperMediaRange(start: start, end: max(start, end))
        }
    }

    /// "0.00–12.50 s, 20.00–30.00 s", or "none".
    static func format(_ ranges: [DeveloperMediaRange]) -> String {
        guard !ranges.isEmpty else { return "none" }
        return ranges.map { DeveloperMediaTime.seconds($0.start) + "–" + DeveloperMediaTime.seconds($0.end) + " s" }
            .joined(separator: ", ")
    }

    /// Each range as a part of the bar from 0 to 1, clamped. Without a
    /// finite duration (a live stream) the bar runs to the last range's end.
    static func fractions(_ ranges: [DeveloperMediaRange], duration: Double?) -> [(start: Double, end: Double)] {
        let length: Double
        if let duration, duration.isFinite, duration > 0 {
            length = duration
        } else if let last = ranges.map(\.end).max(), last > 0 {
            length = last
        } else {
            return []
        }
        return ranges.compactMap { range -> (start: Double, end: Double)? in
            let start = min(max(range.start / length, 0), 1)
            let end = min(max(range.end / length, 0), 1)
            return end > start ? (start, end) : nil
        }
    }

    /// Seconds buffered ahead of the playhead, within the range it's in.
    static func ahead(_ ranges: [DeveloperMediaRange], at time: Double) -> Double {
        guard let range = ranges.first(where: { $0.start <= time && time <= $0.end }) else { return 0 }
        return range.end - time
    }
}

enum DeveloperMediaTime {
    /// Seconds to two places: "12.50".
    static func seconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// A media position as Chrome writes it: "1:02:03.250", "2:03.250", "3.250".
    static func clock(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard value.isFinite else { return value > 0 ? "∞" : "NaN" }
        let millis = Int((value * 1_000).rounded())
        let hours = millis / 3_600_000
        let minutes = (millis / 60_000) % 60
        let seconds = Double(millis % 60_000) / 1_000
        if hours > 0 { return String(format: "%d:%02d:%06.3f", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%d:%06.3f", minutes, seconds) }
        return String(format: "%.3f", seconds)
    }

    /// An event's time, from the first event seen: "+1.234 s".
    static func offset(_ time: Double, from start: Double) -> String {
        String(format: "+%.3f s", max(0, time - start) / 1_000)
    }
}

/// A player as the page script last described it.
struct DeveloperMediaPlayer: Equatable, Identifiable {
    struct Track: Equatable {
        let kind: String
        let label: String
        let language: String
        let on: Bool
    }

    let id: String
    /// The document it lives in; one page script per document.
    let document: String
    var tag: String = "video"
    var frameURL: String = ""
    var topFrame = true
    var connected = true
    var currentSrc = ""
    /// "File", "MSE", "MediaStream", "blob", "data" or "none".
    var sourceKind = "none"
    var duration: Double?
    var durationText: String?
    var currentTime: Double = 0
    var readyState: Int?
    var networkState: Int?
    var paused = true
    var ended = false
    var seeking = false
    var loop = false
    var autoplay = false
    var controls = false
    var preload = ""
    var playbackRate: Double = 1
    var volume: Double = 1
    var muted = false
    var videoWidth = 0
    var videoHeight = 0
    var buffered: [DeveloperMediaRange] = []
    var played: [DeveloperMediaRange] = []
    var seekable: [DeveloperMediaRange] = []
    var decodedFrames: Int?
    var droppedFrames: Int?
    var corruptedFrames: Int?
    var audioTracks: [Track] = []
    var videoTracks: [Track] = []
    var textTracks: [Track] = []
    var mseMimeTypes: [String] = []
    var mseReadyState: String?
    var mseManaged = false
    var hasMediaKeys = false
    var keySystem: String?
    var initDataTypes: [String] = []
    var errorCode: Int?
    var errorMessage: String?
    var label = ""

    init(id: String, document: String) {
        self.id = id
        self.document = document
    }

    /// Updated from the page script's description; unknown fields keep
    /// their defaults.
    mutating func update(_ raw: [String: Any]) {
        func number(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
        func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (raw[key] as? NSNumber)?.boolValue ?? false }
        func string(_ key: String) -> String { raw[key] as? String ?? "" }
        tag = string("tag").isEmpty ? tag : string("tag")
        frameURL = string("frameURL")
        topFrame = (raw["top"] as? NSNumber)?.boolValue ?? true
        connected = (raw["connected"] as? NSNumber)?.boolValue ?? true
        currentSrc = string("currentSrc")
        sourceKind = string("sourceKind").isEmpty ? "none" : string("sourceKind")
        duration = number("duration")
        durationText = raw["durationText"] as? String
        currentTime = number("currentTime") ?? 0
        readyState = int("readyState")
        networkState = int("networkState")
        paused = bool("paused")
        ended = bool("ended")
        seeking = bool("seeking")
        loop = bool("loop")
        autoplay = bool("autoplay")
        controls = bool("controls")
        preload = string("preload")
        playbackRate = number("playbackRate") ?? 1
        volume = number("volume") ?? 1
        muted = bool("muted")
        videoWidth = int("videoWidth") ?? 0
        videoHeight = int("videoHeight") ?? 0
        buffered = DeveloperMediaRanges.parse(raw["buffered"])
        played = DeveloperMediaRanges.parse(raw["played"])
        seekable = DeveloperMediaRanges.parse(raw["seekable"])
        let quality = raw["quality"] as? [String: Any]
        decodedFrames = (quality?["total"] as? NSNumber)?.intValue
        droppedFrames = (quality?["dropped"] as? NSNumber)?.intValue
        corruptedFrames = (quality?["corrupted"] as? NSNumber)?.intValue
        audioTracks = Self.tracks(raw["audioTracks"])
        videoTracks = Self.tracks(raw["videoTracks"])
        textTracks = Self.tracks(raw["textTracks"])
        let mse = raw["mse"] as? [String: Any]
        mseMimeTypes = mse?["mimeTypes"] as? [String] ?? []
        mseReadyState = mse?["readyState"] as? String
        mseManaged = (mse?["managed"] as? NSNumber)?.boolValue ?? false
        hasMediaKeys = bool("mediaKeys")
        keySystem = (raw["keySystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        initDataTypes = raw["initDataTypes"] as? [String] ?? []
        let error = raw["error"] as? [String: Any]
        errorCode = (error?["code"] as? NSNumber)?.intValue
        errorMessage = (error?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        label = string("label")
    }

    private static func tracks(_ raw: Any?) -> [Track] {
        (raw as? [[String: Any]] ?? []).map {
            Track(kind: $0["kind"] as? String ?? "", label: $0["label"] as? String ?? "",
                  language: $0["language"] as? String ?? "", on: ($0["on"] as? NSNumber)?.boolValue ?? false)
        }
    }

    /// The list's name: the file the source points at, as Chrome names a
    /// player after its URL.
    var name: String { DeveloperMediaNames.name(src: currentSrc, kind: sourceKind, tag: tag) }

    /// The frame it's in: "top" or the frame's host.
    var frame: String { DeveloperMediaNames.frame(url: frameURL, top: topFrame) }

    /// What Chrome's "kPlaybackState"-style summary would say.
    var playback: String {
        if errorCode != nil { return "Error" }
        if ended { return "Ended" }
        if seeking { return "Seeking" }
        if paused { return "Paused" }
        if (readyState ?? 0) < 3 { return "Buffering" }
        return "Playing"
    }
}

enum DeveloperMediaNames {
    static func name(src: String, kind: String, tag: String) -> String {
        if src.isEmpty { return kind == "MediaStream" ? "MediaStream" : "<\(tag)> (no source)" }
        if src.hasPrefix("blob:") { return kind == "MSE" ? "MediaSource (blob)" : "blob" }
        if src.hasPrefix("data:") {
            let type = src.dropFirst(5).prefix { $0 != ";" && $0 != "," }
            return type.isEmpty ? "data URL" : "data:" + type
        }
        guard let url = URL(string: src) else { return src }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last.removingPercentEncoding ?? last }
        return url.host() ?? src
    }

    static func frame(url: String, top: Bool) -> String {
        if top { return "top" }
        return URL(string: url)?.host() ?? (url.isEmpty ? "frame" : url)
    }
}

/// Which console messages the Messages tab shows: warnings and errors
/// that are about media playback.
enum DeveloperMediaMessages {
    private static let words = [
        "video", "audio", "media", "mediasource", "sourcebuffer", "codec", "decode", "mse", "eme", "mediakeys",
        "keysystem", "playback", "autoplay", "play()", "hls", "m3u8", "mp4", "webm", "texttrack",
    ]

    static func isMediaRelated(_ text: String) -> Bool {
        let lower = text.lowercased()
        return words.contains { word in
            guard let range = lower.range(of: word) else { return false }
            // Whole words only for the short ones, so "MSE:" counts but "promised" doesn't.
            if word.count > 4 { return true }
            let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
            let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
            return !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
        }
    }

    /// A player's error and the media console lines, newest last.
    static func messages(for player: DeveloperMediaPlayer, errorTime: Double?,
                         console: [(level: String, text: String)]) -> [DeveloperMediaMessage] {
        var output: [DeveloperMediaMessage] = []
        if let code = player.errorCode {
            let text = DeveloperMediaState.errorCode(code) + " (\(code))" + (player.errorMessage.map { ": " + $0 } ?? "")
            output.append(DeveloperMediaMessage(id: "error", level: .error, text: text, time: errorTime))
        }
        for (index, line) in console.enumerated() where ["error", "warning"].contains(line.level) && isMediaRelated(line.text) {
            output.append(DeveloperMediaMessage(id: "console-\(index)", level: line.level == "error" ? .error : .warning,
                                                text: line.text, time: nil))
        }
        return output
    }
}
