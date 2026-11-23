import Foundation

/// Network request times captured independently of the Network panel's log.
struct DeveloperPerformanceNetworkRecording {
    private struct Request {
        let start: Double
        var end: Double?
        let url: String
        var type: String
        /// When the response's headers came, for Document request latency.
        var response: Double?
        var status: Int?
        var mimeType: String?
        /// The response's Content-Encoding header.
        var encoding: String?
        /// Bytes over the network: the loadingFinished metrics, else the
        /// encoded data received.
        var transferSize: Int?
        var received = 0
        /// Redirect hops before this request, and when the first began.
        var redirects = 0
        var firstStart: Double?
        var isRedirect = false
        /// For Insights' cache, HTTP, dependency tree and image checks:
        /// the caching headers, the protocol and priority WebKit's metrics
        /// name, who asked for it, where it came from, its decoded size.
        var cacheControl: String?
        var expires: String?
        var pragma: String?
        var networkProtocol: String?
        var priority: String?
        var initiatorType: String?
        var initiatorURL: String?
        var source: String?
        var decodedSize: Int?
        var decoded = 0
        /// The response's Content-Type header, for Insights' Character set.
        var contentType: String?
    }

    /// Who asked for a request: WebKit's initiator type ("parser",
    /// "script", "other") and the document or script that did, its URL
    /// or else its stack's first frame with one.
    static func initiator(_ value: Any?) -> (type: String?, url: String?) {
        guard let initiator = value as? [String: Any] else { return (nil, nil) }
        let type = initiator["type"] as? String
        if let url = initiator["url"] as? String, !url.isEmpty { return (type, url) }
        var frames: [[String: Any]] = []
        if let stack = initiator["stackTrace"] as? [[String: Any]] {
            frames = stack
        } else if let stack = initiator["stackTrace"] as? [String: Any] {
            frames = stack["callFrames"] as? [[String: Any]] ?? []
        }
        let url = frames.lazy.compactMap { $0["url"] as? String }.first { !$0.isEmpty }
        return (type, url)
    }

    private var requests: [String: Request] = [:]
    private var redirects: [Request] = []

    /// `start` is the recording's start: a request sent before it (an event
    /// still queued when Record was pressed) isn't part of the recording.
    mutating func capture(_ method: String, params: [String: Any], targetID: String?, since start: Double = -.infinity) {
        guard let id = params["requestId"] as? String, let time = params["timestamp"] as? Double,
              time.isFinite else { return }
        let key = (targetID ?? "") + ":" + id
        switch method {
        case "Network.requestWillBeSent", "Network.requestServedFromMemoryCache":
            // The cap is on new requests: a redirect hop replaces its request.
            guard time >= start, requests[key] != nil || requests.count < 2_000,
                  let resource = (params["request"] ?? params["resource"]) as? [String: Any],
                  let url = resource["url"] as? String else { return }
            let type = (params["type"] ?? resource["type"]) as? String ?? "Other"
            let cachedAt = method == "Network.requestServedFromMemoryCache" ? time : nil
            var request = Request(start: time, end: cachedAt, url: url, type: type)
            let initiator = Self.initiator(params["initiator"])
            request.initiatorType = initiator.type.map { String($0.prefix(40)) }
            request.initiatorURL = initiator.url.map { String($0.prefix(2_000)) }
            if params["redirectResponse"] != nil, var previous = requests[key] {
                request.redirects = previous.redirects + 1
                request.firstStart = previous.firstStart ?? previous.start
                if redirects.count < 2_000 {
                    previous.end = time
                    previous.isRedirect = true
                    previous.response = previous.response ?? time
                    redirects.append(previous)
                }
            }
            if method == "Network.requestServedFromMemoryCache" {
                request.response = time
                request.transferSize = 0
                request.source = "memory-cache"
                // Network.CachedResource: what was served, for insights
                // that judge a resource by its own size (images).
                if let resource = params["resource"] as? [String: Any] {
                    if let size = (resource["bodySize"] as? NSNumber)?.intValue, size > 0 { request.decodedSize = size }
                    if let response = resource["response"] as? [String: Any] {
                        // WebKit gives a memory-cache hit no bodySize; its
                        // headers still carry the file's length.
                        if request.decodedSize == nil, let headers = response["headers"] as? [String: Any],
                           let length = headers.first(where: { $0.key.lowercased() == "content-length" })?.value as? String,
                           let size = Int(length.trimmingCharacters(in: .whitespaces)), size > 0 {
                            request.decodedSize = size
                        }
                        request.mimeType = request.mimeType ?? response["mimeType"] as? String
                        request.status = request.status ?? (response["status"] as? NSNumber)?.intValue
                    }
                    if let type = resource["type"] as? String { request.type = type }
                }
            }
            requests[key] = request
        case "Network.responseReceived":
            if let type = params["type"] as? String { requests[key]?.type = type }
            requests[key]?.response = time
            if let response = params["response"] as? [String: Any] {
                requests[key]?.status = (response["status"] as? NSNumber)?.intValue
                requests[key]?.mimeType = response["mimeType"] as? String
                let headers = response["headers"] as? [String: Any] ?? [:]
                func header(_ name: String) -> String? {
                    (headers.first { $0.key.lowercased() == name }?.value as? String).map { String($0.prefix(300)) }
                }
                if let encoding = header("content-encoding") {
                    requests[key]?.encoding = String(encoding.prefix(40))
                }
                requests[key]?.cacheControl = header("cache-control")
                // For Insights' Character set: the charset it declares.
                requests[key]?.contentType = header("content-type")
                requests[key]?.expires = header("expires")
                requests[key]?.pragma = header("pragma")
                if let source = response["source"] as? String { requests[key]?.source = String(source.prefix(40)) }
            }
        case "Network.dataReceived":
            let bytes = (params["encodedDataLength"] as? NSNumber)?.intValue ?? (params["dataLength"] as? NSNumber)?.intValue ?? 0
            if bytes > 0, let received = requests[key]?.received {
                requests[key]?.received = received &+ bytes
            }
            if let length = (params["dataLength"] as? NSNumber)?.intValue, length > 0, let decoded = requests[key]?.decoded {
                requests[key]?.decoded = decoded &+ length
            }
        case "Network.loadingFinished", "Network.loadingFailed":
            requests[key]?.end = time
            if let metrics = params["metrics"] as? [String: Any] {
                let headers = (metrics["responseHeaderBytesReceived"] as? NSNumber)?.intValue
                let body = (metrics["responseBodyBytesReceived"] as? NSNumber)?.intValue
                if headers != nil || body != nil {
                    requests[key]?.transferSize = max(0, headers ?? 0) &+ max(0, body ?? 0)
                }
                if let decoded = (metrics["responseBodyDecodedSize"] as? NSNumber)?.intValue, decoded >= 0 {
                    requests[key]?.decodedSize = decoded
                }
                if let value = metrics["protocol"] as? String, !value.isEmpty {
                    requests[key]?.networkProtocol = String(value.prefix(40))
                }
                if let value = metrics["priority"] as? String, !value.isEmpty { requests[key]?.priority = String(value.prefix(20)) }
            }
        default: break
        }
    }

    func timings(from start: Double, to end: Double) -> [DeveloperToolsSession.Timing] {
        (redirects + requests.values).compactMap { request in
            guard request.start >= start, request.start <= end else { return nil }
            let finish = max(request.start, min(end, request.end ?? end))
            var data = ["url": request.url, "resourceType": request.type]
            // Times as milliseconds after the request began, so they stay
            // right whatever clock a saved profile is opened on.
            if let response = request.response, response >= request.start {
                data["responseOffset"] = String(min(finish, response) * 1_000 - request.start * 1_000)
            }
            if let status = request.status { data["status"] = String(status) }
            if let mimeType = request.mimeType { data["mimeType"] = mimeType }
            if let encoding = request.encoding { data["encoding"] = encoding }
            if let size = request.transferSize ?? (request.received > 0 ? request.received : nil) {
                data["transferSize"] = String(size)
            }
            if request.redirects > 0 {
                data["redirects"] = String(request.redirects)
                if let first = request.firstStart { data["redirectOffset"] = String((request.start - first) * 1_000) }
            }
            if request.isRedirect { data["redirect"] = "true" }
            if let value = request.cacheControl { data["cacheControl"] = value }
            if let value = request.expires { data["expires"] = value }
            if let value = request.pragma { data["pragma"] = value }
            if let value = request.networkProtocol { data["protocol"] = value }
            if let value = request.priority { data["priority"] = value }
            if let value = request.initiatorType { data["initiatorType"] = value }
            if let value = request.initiatorURL { data["initiator"] = value }
            if let value = request.source { data["source"] = value }
            if let value = request.contentType { data["contentType"] = value }
            if let size = request.decodedSize ?? (request.decoded > 0 ? request.decoded : nil) {
                data["decodedSize"] = String(size)
            }
            return .init(type: "NetworkRequest", start: request.start, end: finish, data: data)
        }.sorted { $0.start < $1.start }
    }
}

/// The page's own timings in a recording: what its metrics script
/// (DeveloperPerformance-metrics.js) answered just before the recording
/// stopped, on the page's clock (performance.now(), in milliseconds),
/// moved onto the timeline's (WebKit's record times, in seconds since the
/// inspector's stopwatch began). The two are lined up by the script's
/// console.timeStamp, which the recording caught as a TimeStamp record:
/// its message is the page's time, its start the timeline's. Without it,
/// the page's time of answering is taken as the recording's end.
enum DeveloperPerformancePageTimings {
    typealias Timing = DeveloperToolsSession.Timing

    static let syncPrefix = "perch-sync "

    /// The page's marks, measures, milestones (and shifts) added to
    /// `record` within `bounds`, the sync timestamp taken out of it.
    static func merge(_ page: [String: Any], into record: inout [Timing], bounds: ClosedRange<Double>) {
        var sync: (page: Double, timeline: Double)?
        if let index = record.lastIndex(where: { $0.type == "TimeStamp" && ($0.data["message"] ?? "").hasPrefix(syncPrefix) }) {
            let stamp = record[index]
            if let message = stamp.data["message"], let value = Double(message.dropFirst(syncPrefix.count)), value.isFinite {
                sync = (page: value, timeline: stamp.start)
            }
            record.remove(at: index)
        }
        if sync == nil, let now = DeveloperMeasure.finite(page["now"]) { sync = (page: now, timeline: bounds.upperBound) }
        guard let sync else { return }
        record += timings(page, sync: sync, bounds: bounds)
    }

    /// The page's entries as records: "PageTiming" (data kind and name),
    /// "PerformanceExtension" (DeveloperPerformanceExtensions) and
    /// "LayoutShift" (data score, index and nodes).
    static func timings(_ page: [String: Any], sync: (page: Double, timeline: Double),
                        bounds: ClosedRange<Double>) -> [Timing] {
        func time(_ milliseconds: Double) -> Double { sync.timeline + (milliseconds - sync.page) / 1_000 }
        var result: [Timing] = []
        for entry in (page["entries"] as? [[String: Any]] ?? []).prefix(2_000) {
            guard let kind = entry["kind"] as? String, let start = DeveloperMeasure.finite(entry["start"]) else { continue }
            let from = time(start), to = time(max(start, DeveloperMeasure.finite(entry["end"]) ?? start))
            guard to >= bounds.lowerBound, from <= bounds.upperBound else { continue }
            let name = (entry["name"] as? String).map { String($0.prefix(200)) } ?? kind
            result.append(Timing(type: "PageTiming", start: max(from, bounds.lowerBound), end: min(to, bounds.upperBound),
                                 data: ["kind": kind, "name": name]))
        }
        // Chrome's extensibility API: marks and measures with a
        // detail.devtools, and extended console.timeStamps
        // (DeveloperPerformanceExtensions), within their own budget.
        for item in DeveloperPerformanceExtensions.pageRecords(page) {
            let from = time(item.start), to = time(max(item.start, item.end))
            guard to >= bounds.lowerBound, from <= bounds.upperBound else { continue }
            result.append(Timing(type: item.type, start: max(from, bounds.lowerBound), end: min(to, bounds.upperBound),
                                 data: item.data))
        }
        for shift in (page["shifts"] as? [[String: Any]] ?? []).suffix(500) {
            guard let at = DeveloperMeasure.finite(shift["time"]), let score = DeveloperMeasure.finite(shift["value"]), score >= 0 else { continue }
            let when = time(at)
            guard bounds.contains(when) else { continue }
            var data = ["score": String(score)]
            if let index = (shift["index"] as? NSNumber)?.intValue { data["index"] = String(index) }
            let nodes = (shift["nodes"] as? [String] ?? []).prefix(5).map { String($0.prefix(120)) }
            if !nodes.isEmpty { data["nodes"] = nodes.joined(separator: "\n") }
            result.append(Timing(type: "LayoutShift", start: when, end: when, data: data))
        }
        // What the page can say cheaply about itself, for Insights: the
        // LCP element's image and the DOM's size.
        var info: [String: String] = [:]
        if let url = page["lcpURL"] as? String, !url.isEmpty { info["lcpURL"] = String(url.prefix(2_000)) }
        if let address = page["url"] as? String, !address.isEmpty { info["url"] = String(address.prefix(2_000)) }
        if let elements = (page["domElements"] as? NSNumber)?.intValue { info["domElements"] = String(elements) }
        if let depth = (page["domDepth"] as? NSNumber)?.intValue { info["domDepth"] = String(depth) }
        if let children = (page["domChildren"] as? NSNumber)?.intValue { info["domChildren"] = String(children) }
        // And what the newer Insights read (DeveloperPerformanceInsightsPage):
        // the viewport, images, @font-face rules and the LCP element, each
        // a string the page made, JSON for the lists.
        for key in DeveloperPerformanceInsightsPage.keys {
            if let value = page[key] as? String, value.count <= DeveloperPerformanceInsightsPage.limit { info[key] = value }
        }
        if !info.isEmpty {
            result.append(Timing(type: "PageInfo", start: bounds.upperBound, end: bounds.upperBound, data: info))
        }
        return result
    }
}
