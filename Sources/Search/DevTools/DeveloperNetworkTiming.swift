import Foundation

enum DeveloperRequestKind: String, CaseIterable, Identifiable {
    case fetch = "Fetch/XHR", document = "Doc", stylesheet = "CSS", script = "JS"
    case font = "Font", image = "Img", media = "Media", manifest = "Manifest"
    case socket = "Socket", wasm = "Wasm", other = "Other"

    var id: Self { self }

    init(_ request: DeveloperToolsSession.Request) {
        let mime = request.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("application/wasm") {
            self = .wasm
            return
        }
        if mime.hasPrefix("application/manifest+json") || URL(string: request.url)?.pathExtension.lowercased() == "webmanifest" {
            self = .manifest
            return
        }
        switch request.type.lowercased() {
        case "fetch", "xhr": self = .fetch
        case "document": self = .document
        case "stylesheet": self = .stylesheet
        case "script": self = .script
        case "font": self = .font
        case "image": self = .image
        case "media", "audio", "video": self = .media
        case "manifest": self = .manifest
        case "websocket": self = .socket
        default: self = .other
        }
    }
}

/// WebKit uses monotonic seconds for events. The ruler is shared across the
/// recording and keeps its scale when the visible requests are filtered.
struct DeveloperNetworkTiming {
    enum Phase: String {
        case beforeSend = "Before sending"
        case waiting = "Waiting for response"
        case receiving = "Receiving response"
        case total = "Recorded time"
    }

    struct Segment {
        let phase: Phase
        let start: Double
        let end: Double

        var milliseconds: Double { (end - start) * 1_000 }
    }

    let origin: Double
    let span: Double

    /// `marks` (DOMContentLoaded and load) widen the ruler to show them.
    init(_ requests: [DeveloperToolsSession.Request], marks: [Double] = []) {
        var first = Double.infinity
        var last = -Double.infinity
        for request in requests {
            guard let start = request.started, start.isFinite else { continue }
            first = min(first, start)
            let end = request.ended ?? request.received ?? start
            last = max(last, start, end.isFinite ? end : start)
        }
        for mark in marks where mark.isFinite && first.isFinite && mark >= first && mark - first < 600 {
            last = max(last, mark)
        }
        origin = first.isFinite ? first : 0
        let elapsed = last - first
        span = elapsed.isFinite ? max(0.1, elapsed) : 0.1
    }

    init(origin: Double, span: Double) {
        self.origin = origin
        self.span = max(0.000_001, span)
    }

    var end: Double { origin + span }

    /// The same ruler cut down to `window`, as the waterfall column draws
    /// it while part of the overview is chosen.
    func zoomed(to window: ClosedRange<Double>?) -> DeveloperNetworkTiming {
        guard let window else { return self }
        return DeveloperNetworkTiming(origin: window.lowerBound, span: window.upperBound - window.lowerBound)
    }

    /// The time at `fraction` of the ruler, 0 at its start and 1 at its end.
    func time(at fraction: CGFloat) -> Double {
        origin + Double(min(1, max(0, fraction))) * span
    }

    /// Whether any of the request falls in `window`, as DevTools keeps a
    /// request in the list while any part of its bar is in the chosen part
    /// of the overview. A request still going runs on to the window's end.
    static func overlaps(_ request: DeveloperToolsSession.Request, _ window: ClosedRange<Double>) -> Bool {
        guard let start = request.started, start.isFinite else { return false }
        let finished = [request.ended, request.received].compactMap { $0 }.first { $0.isFinite }
        let end = finished.map { max($0, start) } ?? .infinity
        return start <= window.upperBound && end >= window.lowerBound
    }

    func fraction(_ time: Double) -> CGFloat {
        guard time.isFinite else { return 0 }
        return CGFloat(min(1, max(0, (time - origin) / span)))
    }

    func ticks(width: CGFloat) -> [(offset: Double, fraction: CGFloat)] {
        let wanted = span / Double(max(2, Int(width / 67)))
        let power = pow(10, floor(log10(wanted)))
        let step = [1.0, 2, 5, 10].first { $0 * power >= wanted } ?? 10
        let interval = step * power
        return (0...Int(span / interval)).map { index in
            let offset = Double(index) * interval
            return (offset, CGFloat(offset / span))
        }
    }

    static func segments(for request: DeveloperToolsSession.Request) -> [Segment] {
        guard let start = request.started, start.isFinite else { return [] }
        let finished = request.ended.flatMap { $0.isFinite && $0 >= start ? $0 : nil }
        guard let response = request.received, response.isFinite, response >= start,
              response <= (finished ?? response) else {
            return [Segment(phase: .total, start: start, end: finished ?? start)]
        }
        var segments: [Segment] = []
        if let sent = request.sent, sent.isFinite, sent > start, sent < response {
            segments.append(Segment(phase: .beforeSend, start: start, end: sent))
            segments.append(Segment(phase: .waiting, start: sent, end: response))
        } else {
            segments.append(Segment(phase: .waiting, start: start, end: response))
        }
        if let finished, finished > response {
            segments.append(Segment(phase: .receiving, start: response, end: finished))
        }
        return segments
    }
}
