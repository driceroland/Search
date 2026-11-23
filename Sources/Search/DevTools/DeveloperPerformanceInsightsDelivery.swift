import Foundation

/// Insights over how the page's resources were asked for and delivered,
/// as Chrome DevTools' newer insights check them: LCP request discovery,
/// the network dependency tree, image delivery, font display, cache
/// lifetimes, the viewport and modern HTTP. They read the request details
/// the recording keeps (headers, protocol, priority, initiator) and what
/// the page said about itself as it stopped (DeveloperPerformanceInsightsPage);
/// an older recording without them has none of these cards. Where the
/// Lighthouse panel already has the same rule (cache lifetimes, image
/// formats, the viewport's properties) it is reused.
extension DeveloperPerformanceInsights {
    typealias Page = DeveloperPerformanceInsightsPage

    /// Whether the recording kept requests' newer details: which of the
    /// checks over them can say anything.
    static func hasRequestDetails(_ profile: Profile) -> Bool {
        profile.network.contains {
            $0.source != nil || $0.networkProtocol != nil || $0.initiatorType != nil || $0.priority != nil
        }
    }

    static func request(for url: String, in profile: Profile) -> Profile.NetworkBar? {
        let key = stripped(url)
        return profile.network.first { !$0.isRedirect && stripped($0.url) == key }
    }

    /// The bytes a request cost: over the network, or decoded when it came from a cache.
    static func size(of bar: Profile.NetworkBar) -> Double? {
        if let size = bar.transferSize, size > 0 { return size }
        if let size = bar.decodedSize, size > 0 { return size }
        return nil
    }

    /// An image's own size, as Chrome judges it: what it decodes from,
    /// not what this load happened to transfer. A cache hit or a 304
    /// transfers little or nothing of an image that is still too big.
    static func imageSize(of bar: Profile.NetworkBar) -> Double? {
        let cached = bar.status == 304 || (bar.source ?? "").lowercased().contains("cache")
        if cached, let size = bar.decodedSize, size > 0 { return size }
        return size(of: bar)
    }

    // MARK: LCP request discovery

    /// How the LCP image was asked for, as Chrome checks it: with
    /// fetchpriority=high, found in the document's HTML (or preloaded),
    /// and not lazy-loaded. Its savings are the load delay: from the
    /// document's first byte to the image's request.
    static func lcpDiscovery(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard let lcp = profile.markers.last(where: { $0.kind == "LCP" }),
              let address = profile.pageInfo["lcpURL"], !address.hasPrefix("data:") else { return nil }
        let info = profile.pageInfo
        let request = Self.request(for: address, in: profile)
        // A recording from before these were read can't say.
        guard info["lcpTag"] != nil || request?.initiatorType != nil else { return nil }
        let document = mainDocument(profile, page: page)
        let prioritized = info["lcpFetchPriority"] == "high"
        let lazy = info["lcpLoading"] == "lazy"
        let discoverable = isDiscoverable(request, document: document, profile: profile)
        var delay = 0.0
        if let request, let document {
            delay = max(0, request.start - (document.responseStart ?? document.end))
        }
        let rows = [
            Row(id: 0, label: prioritized ? "fetchpriority=high applied" : "fetchpriority=high should be applied",
                value: prioritized ? "Yes" : "No", failing: !prioritized),
            Row(id: 1, label: discoverable ? "Request is discoverable in initial document"
                    : "Request should be discoverable in initial document",
                value: discoverable ? "Yes" : "No", failing: !discoverable),
            Row(id: 2, label: lazy ? "Lazy load should not be applied" : "Lazy load not applied",
                value: lazy ? "loading=lazy" : "No", failing: lazy),
            Row(id: 3, label: file(address), value: request.map { time($0.duration) } ?? "", detail: address,
                range: request.map { $0.start...$0.end }),
        ]
        let failing = !prioritized || !discoverable || lazy
        let saving = failing && delay > 0
        var ranges = [lcp.start...lcp.start]
        if let request { ranges.insert(request.start...request.end, at: 0) }
        return Insight(kind: .lcpDiscovery, title: "LCP request discovery", verdict: failing ? .fail : .pass,
                       explanation: "Optimize LCP by making the LCP image discoverable from the HTML immediately, "
                           + "and avoiding lazy-loading.",
                       headline: saving ? "Est savings \(time(delay))" : file(address), rows: rows, ranges: ranges)
    }

    /// Whether the LCP image was asked for by the document's own markup
    /// (or preloaded), not by script or a stylesheet: the request's
    /// initiator, else what the page's Resource Timing said, else whether
    /// the element is an image.
    static func isDiscoverable(_ request: Profile.NetworkBar?, document: Profile.NetworkBar?, profile: Profile) -> Bool {
        let info = profile.pageInfo
        if info["lcpPreloaded"] == "true" { return true }
        if let request, let type = request.initiatorType?.lowercased() {
            if type == "script" { return false }
            if type == "parser" {
                guard let initiator = request.initiator else { return true }
                if let document, stripped(initiator) == stripped(document.url) { return true }
                // A stylesheet's background image isn't in the HTML.
                return Self.request(for: initiator, in: profile)?.resourceType == "Document"
            }
        }
        if let type = info["lcpInitiator"]?.lowercased() {
            if ["css", "script", "xmlhttprequest", "fetch", "other"].contains(type) { return false }
            if ["img", "image", "link", "picture"].contains(type) { return info["lcpTag"].map { $0 != "DIV" } ?? true }
        }
        return info["lcpTag"] == "IMG"
    }

    // MARK: Network dependency tree

    static let criticalTypes: Set<String> = ["Document", "Stylesheet", "StyleSheet", "Script", "Font"]

    /// A request the page needed to render, as Chrome's critical request
    /// chains pick them: the document, stylesheets, scripts and fonts not
    /// asked for at low priority, begun before the LCP.
    static func isCritical(_ bar: Profile.NetworkBar, before limit: Double) -> Bool {
        !bar.isRedirect && criticalTypes.contains(bar.resourceType) && bar.priority?.lowercased() != "low"
            && bar.start <= limit
    }

    struct ChainNode: Equatable {
        /// In the profile's `network`.
        let request: Int
        let depth: Int
        var children: [Int] = []
    }

    /// The critical requests the document led to, by initiator: each
    /// node's request, its depth under the document (which is 0), in the
    /// order a depth-first walk meets them.
    static func criticalChains(_ profile: Profile, page: URL? = nil) -> [ChainNode] {
        guard let document = mainDocument(profile, page: page),
              let root = profile.network.firstIndex(where: { $0.url == document.url && $0.start == document.start })
        else { return [] }
        let limit = profile.markers.last(where: { $0.kind == "LCP" })?.start ?? profile.duration
        var children: [Int: [Int]] = [:]
        for (index, bar) in profile.network.enumerated() where index != root && isCritical(bar, before: limit) {
            guard let initiator = bar.initiator.map(stripped) else { continue }
            // The latest critical request for the initiator's address begun before this one.
            let parent = profile.network.indices.last { other in
                other != index && stripped(profile.network[other].url) == initiator
                    && profile.network[other].start <= bar.start
                    && (other == root || isCritical(profile.network[other], before: limit))
            }
            if let parent { children[parent, default: []].append(index) }
        }
        var nodes: [ChainNode] = []
        var seen: Set<Int> = []
        func walk(_ index: Int, depth: Int) {
            guard seen.insert(index).inserted, nodes.count < 500, depth < 32 else { return }
            let kids = (children[index] ?? []).sorted { profile.network[$0].start < profile.network[$1].start }
            nodes.append(ChainNode(request: index, depth: depth, children: kids))
            for child in kids { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return nodes
    }

    static func networkDependencyTree(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard hasRequestDetails(profile), profile.network.contains(where: { $0.initiator != nil }),
              let document = mainDocument(profile, page: page) else { return nil }
        let nodes = criticalChains(profile, page: page)
        guard !nodes.isEmpty else { return nil }
        let start = navigationStart(document)
        // The longest chain: the deepest node's path back to the document.
        let longest = nodes.max { profile.network[$0.request].end < profile.network[$1.request].end }
        var path: Set<Int> = []
        if let longest {
            var target = longest.request
            path.insert(target)
            var steps = 0
            while steps < nodes.count, let parent = nodes.first(where: { $0.children.contains(target) }) {
                path.insert(parent.request)
                target = parent.request
                steps += 1
            }
        }
        let latency = longest.map { profile.network[$0.request].end - start } ?? 0
        let depth = nodes.map(\.depth).max() ?? 0
        let rows = nodes.prefix(40).enumerated().map { offset, node in
            let bar = profile.network[node.request]
            let size = Self.size(of: bar).map { " · " + DeveloperMetricFormat.bytes($0) } ?? ""
            return Row(id: offset, label: String(repeating: "  ", count: node.depth) + file(bar.url),
                       value: time(bar.end - start) + size, detail: bar.url, range: bar.start...bar.end,
                       failing: depth > 1 && path.contains(node.request))
        }
        let verdict: Insight.Verdict = depth > 1 ? .fail : depth == 1 ? .info : .pass
        return Insight(kind: .networkDependencyTree, title: "Network dependency tree", verdict: verdict,
                       explanation: "Avoid chaining critical requests by reducing the length of chains, reducing the "
                           + "download size of resources, or deferring the download of unnecessary resources to "
                           + "improve page load.",
                       headline: nodes.count == 1 ? "No chained critical requests"
                           : "Max critical path latency \(time(latency))",
                       rows: Array(rows), ranges: nodes.map { profile.network[$0.request] }.map { $0.start...$0.end })
    }

    // MARK: Improve image delivery

    /// Chrome's ImageDelivery thresholds: savings under 4 KB aren't worth
    /// a row, nor resizing under 12 KB; a GIF over 100 KB is better as video.
    static let imageByteThreshold = 4_096.0
    static let responsiveByteThreshold = 12_000.0
    static let gifVideoThreshold = 100.0 * 1_024
    /// AVIF's bytes per pixel at a good quality, Chrome's estimate of what
    /// a well-encoded image needs.
    static let modernBytesPerPixel = 2.0 / 12

    struct ImageFinding: Equatable {
        let url: String
        let bytes: Double
        var wasted: Double
        var reasons: [String]
    }

    static func isImage(_ bar: Profile.NetworkBar) -> Bool {
        bar.resourceType == "Image" || (bar.mimeType ?? "").lowercased().hasPrefix("image/")
    }

    /// Each image the page could have sent in fewer bytes: in a modern
    /// format or compressed harder, at the size it's shown, or as video for
    /// a large GIF; the image's savings are its largest.
    static func imageFindings(_ profile: Profile) -> [ImageFinding] {
        let images = Page.images(profile.pageInfo) ?? []
        let ratio = Page.devicePixelRatio(profile.pageInfo)
        var found: [ImageFinding] = []
        var seen: Set<String> = []
        for bar in profile.network where !bar.isRedirect && isImage(bar) && !bar.url.hasPrefix("data:") {
            let key = stripped(bar.url)
            guard seen.insert(key).inserted, let bytes = imageSize(of: bar) else { continue }
            let mime = (bar.mimeType ?? "").lowercased()
            if mime.contains("svg") || key.lowercased().hasSuffix(".svg") { continue }
            // Where the page shows it largest.
            let shown = images.filter { stripped($0.src) == key }
                .max { $0.displayedWidth * $0.displayedHeight < $1.displayedWidth * $1.displayedHeight }
            var finding = ImageFinding(url: bar.url, bytes: bytes, wasted: 0, reasons: [])
            func add(_ wasted: Double, _ reason: String) {
                finding.reasons.append(reason)
                finding.wasted = max(finding.wasted, wasted)
            }
            let pixels = (shown?.naturalWidth ?? 0) * (shown?.naturalHeight ?? 0)
            if mime == "image/gif", bytes > gifVideoThreshold {
                // Lighthouse's efficient-animated-content estimate of WebM's saving.
                let share = min(1, max(0, (29.1 * log10(bytes) - 100.7) / 100))
                add(bytes * share, "Using video formats instead of GIFs can improve the download size of animated content.")
            } else if mime == "image/webp" || mime == "image/avif" {
                if pixels > 0 {
                    let wasted = bytes - pixels * modernBytesPerPixel
                    if wasted > imageByteThreshold {
                        add(wasted, "Increasing the image compression factor could improve this image's download size.")
                    }
                }
            } else {
                let wasted = pixels > 0 ? bytes - pixels * modernBytesPerPixel
                    : bytes * (DeveloperLighthouseRules.modernFormatSavings(mime: mime) ?? 0)
                if wasted > imageByteThreshold {
                    add(wasted, "Using a modern image format (WebP, AVIF) or increasing the image compression could "
                        + "improve this image's download size.")
                }
            }
            if let shown, pixels > 0, shown.displayedWidth > 0, shown.displayedHeight > 0 {
                let expected = shown.displayedWidth * ratio * shown.displayedHeight * ratio
                if pixels > expected {
                    let wasted = bytes * (1 - expected / pixels)
                    if wasted > responsiveByteThreshold {
                        func dimensions(_ w: Double, _ h: Double) -> String { "\(Int(w.rounded()))x\(Int(h.rounded()))" }
                        add(wasted, "This image file is larger than it needs to be "
                            + "(\(dimensions(shown.naturalWidth, shown.naturalHeight))) for its displayed dimensions "
                            + "(\(dimensions(shown.displayedWidth, shown.displayedHeight))). Use responsive images to "
                            + "reduce the image download size.")
                    }
                }
            }
            if !finding.reasons.isEmpty { found.append(finding) }
        }
        return found.sorted { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.url < $1.url }
    }

    static func imageDelivery(_ profile: Profile) -> Insight? {
        let requests = profile.network.filter { !$0.isRedirect && isImage($0) && !$0.url.hasPrefix("data:") }
        guard !requests.isEmpty, Page.images(profile.pageInfo) != nil || hasRequestDetails(profile) else { return nil }
        let findings = imageFindings(profile)
        let total = findings.reduce(0) { $0 + $1.wasted }
        let rows = findings.prefix(20).enumerated().map { index, finding in
            let bar = request(for: finding.url, in: profile)
            return Row(id: index, label: file(finding.url),
                       value: "\(DeveloperMetricFormat.bytes(finding.bytes)) · Est savings "
                           + DeveloperMetricFormat.bytes(finding.wasted),
                       detail: finding.reasons.joined(separator: " "), range: bar.map { $0.start...$0.end }, failing: true)
        }
        return Insight(kind: .imageDelivery, title: "Improve image delivery", verdict: findings.isEmpty ? .pass : .fail,
                       explanation: "Reducing the download time of images can improve the perceived load time of the "
                           + "page and LCP.",
                       headline: findings.isEmpty ? "No images to improve"
                           : "Est savings \(DeveloperMetricFormat.bytes(total))",
                       rows: Array(rows), ranges: findings.prefix(200).compactMap { finding in
                           request(for: finding.url, in: profile).map { $0.start...$0.end }
                       })
    }

    // MARK: Font display

    /// How long text stays invisible while a font with this font-display
    /// loads: its block period. swap and optional don't hide it.
    static func blockPeriod(_ display: String) -> Double? {
        switch display {
        case "swap", "optional": nil
        case "fallback": 100
        default: 3_000
        }
    }

    static func fontDisplay(_ profile: Profile) -> Insight? {
        guard let faces = Page.fontFaces(profile.pageInfo) else { return nil }
        let fonts = profile.network.filter {
            !$0.isRedirect && ($0.resourceType == "Font" || ($0.mimeType ?? "").lowercased().contains("font"))
        }
        var items: [(bar: Profile.NetworkBar, face: Page.FontFace, wasted: Double)] = []
        var seen: Set<String> = []
        for bar in fonts where seen.insert(stripped(bar.url)).inserted {
            let key = stripped(bar.url)
            guard let face = faces.first(where: { $0.urls.contains { stripped($0) == key } }),
                  let period = blockPeriod(face.display) else { continue }
            items.append((bar, face, min(bar.duration, period)))
        }
        items.sort { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.bar.url < $1.bar.url }
        let rows = items.prefix(20).enumerated().map { index, item in
            Row(id: index, label: file(item.bar.url), value: time(item.wasted),
                detail: "font-display: \(item.face.display)" + (item.face.family.isEmpty ? "" : " · \(item.face.family)"),
                range: item.bar.start...item.bar.end, failing: true)
        }
        let longest = items.first?.wasted ?? 0
        return Insight(kind: .fontDisplay, title: "Font display", verdict: items.isEmpty ? .pass : .fail,
                       explanation: "Consider setting font-display to swap or optional to ensure text is consistently "
                           + "visible. swap can be further optimized to mitigate layout shifts with font metric overrides.",
                       headline: items.isEmpty ? (fonts.isEmpty ? "No web fonts" : "Fonts display text while loading")
                           : "Est savings \(time(longest))",
                       rows: Array(rows), ranges: items.map { $0.bar.start...$0.bar.end })
    }

    // MARK: Use efficient cache lifetimes

    static let cachedTypes: Set<String> = ["script", "stylesheet", "image", "font", "media"]

    /// A cache lifetime as Chrome shows it: "None", "10 m", "1 d".
    static func lifetime(_ seconds: Double) -> String {
        if seconds <= 0 { return "None" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) m" }
        if seconds < 86_400 { return "\(Int((seconds / 3_600).rounded())) h" }
        return "\(Int((seconds / 86_400).rounded())) d"
    }

    struct CacheFinding: Equatable {
        let url: String
        let lifetime: Double
        let bytes: Double
        let wasted: Double
    }

    /// Lighthouse's uses-long-cache-ttl over the recorded requests: static
    /// resources whose lifetime a repeat visit is unlikely to find them in
    /// the cache within (DeveloperLighthouseRules' cache rules).
    static func cacheFindings(_ profile: Profile, now: Date = Date()) -> [CacheFinding] {
        var found: [CacheFinding] = []
        var seen: Set<String> = []
        for bar in profile.network where !bar.isRedirect && [200, 203, 206].contains(bar.status ?? 0) {
            let scheme = URL(string: bar.url)?.scheme?.lowercased() ?? ""
            let headers = bar.cacheHeaders
            guard cachedTypes.contains(bar.resourceType.lowercased()), ["http", "https"].contains(scheme),
                  seen.insert(bar.url).inserted, !DeveloperLighthouseRules.skipsCaching(headers) else { continue }
            let lifetime = DeveloperLighthouseRules.cacheLifetime(headers, now: now) ?? 0
            let probability = DeveloperLighthouseRules.cacheHitProbability(lifetime)
            guard probability < 0.925 else { continue }
            let bytes = size(of: bar) ?? 0
            found.append(CacheFinding(url: bar.url, lifetime: lifetime, bytes: bytes, wasted: (1 - probability) * bytes))
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url < $1.url }
    }

    static func cacheLifetimes(_ profile: Profile, now: Date = Date()) -> Insight? {
        guard hasRequestDetails(profile) else { return nil }
        let findings = cacheFindings(profile, now: now)
        let wasted = findings.reduce(0) { $0 + $1.wasted }
        let rows = findings.prefix(20).enumerated().map { index, finding in
            let bar = request(for: finding.url, in: profile)
            return Row(id: index, label: file(finding.url),
                       value: "\(lifetime(finding.lifetime)) · \(DeveloperMetricFormat.bytes(finding.bytes))",
                       detail: finding.url, range: bar.map { $0.start...$0.end }, failing: true)
        }
        return Insight(kind: .cacheLifetimes, title: "Use efficient cache lifetimes",
                       verdict: findings.isEmpty ? .pass : .fail,
                       explanation: "A long cache lifetime can speed up repeat visits to your page.",
                       headline: findings.isEmpty ? "No static resources with short cache lifetimes"
                           : "Est savings \(DeveloperMetricFormat.bytes(wasted))",
                       rows: Array(rows), ranges: findings.prefix(200).compactMap { finding in
                           request(for: finding.url, in: profile).map { $0.start...$0.end }
                       })
    }

    // MARK: Optimize viewport for mobile

    static func viewport(_ profile: Profile) -> Insight? {
        guard let content = Page.viewport(profile.pageInfo) else { return nil }
        let explanation = "Tap interactions may be delayed by up to 300 ms if the viewport is not optimized for mobile."
        guard let content else {
            return Insight(kind: .viewport, title: "Optimize viewport for mobile", verdict: .fail,
                           explanation: explanation, headline: "No viewport meta tag",
                           rows: [Row(id: 0, label: "<meta name=\"viewport\">", value: "Missing", failing: true)])
        }
        let properties = DeveloperLighthouseRules.viewportProperties(content)
        let optimized = properties["width"] == "device-width"
        return Insight(kind: .viewport, title: "Optimize viewport for mobile", verdict: optimized ? .pass : .fail,
                       explanation: explanation,
                       headline: optimized ? "Viewport is optimized for mobile" : "Viewport isn't width=device-width",
                       rows: [Row(id: 0, label: "<meta name=\"viewport\">", value: content.isEmpty ? "(empty)" : content,
                                  failing: !optimized)])
    }

    // MARK: Modern HTTP

    /// Lighthouse's uses-http2: an origin needs this many HTTP/1.1
    /// requests before multiplexing would have helped.
    static let http1OriginMinimum = 6

    static func isLegacyProtocol(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "http/1.1" || value == "http/1.0" || value == "http/0.9"
    }

    /// Origins that served several requests over HTTP/1.1 and how many,
    /// most first; requests from a cache and local hosts aside.
    static func legacyOrigins(_ profile: Profile) -> [(origin: String, requests: [Int])] {
        var origins: [String: [Int]] = [:]
        for (index, bar) in profile.network.enumerated() where !bar.isRedirect && isLegacyProtocol(bar.networkProtocol) {
            guard let url = URL(string: bar.url), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !DeveloperLighthouseRules.isLocal(host) else { continue }
            if let source = bar.source?.lowercased(), source.contains("cache") { continue }
            let origin = scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
            origins[origin, default: []].append(index)
        }
        return origins.filter { $0.value.count >= http1OriginMinimum }
            .map { (origin: $0.key, requests: $0.value) }
            .sorted { $0.requests.count != $1.requests.count ? $0.requests.count > $1.requests.count : $0.origin < $1.origin }
    }

    static func modernHTTP(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard profile.network.contains(where: { $0.networkProtocol != nil }) else { return nil }
        let origins = legacyOrigins(profile)
        let count = origins.reduce(0) { $0 + $1.requests.count }
        let rows = origins.prefix(10).enumerated().map { index, entry in
            let protocols = Set(entry.requests.compactMap { profile.network[$0].networkProtocol?.lowercased() })
            return Row(id: index, label: entry.origin,
                       value: entry.requests.count == 1 ? "1 request" : "\(entry.requests.count) requests",
                       detail: protocols.sorted().joined(separator: ", "), failing: true)
        }
        return Insight(kind: .modernHTTP, title: "Modern HTTP", verdict: origins.isEmpty ? .pass : .fail,
                       explanation: "HTTP/2 and HTTP/3 offer many benefits over HTTP/1.1, such as multiplexing.",
                       headline: origins.isEmpty ? "No requests over HTTP/1.1"
                           : count == 1 ? "1 request over HTTP/1.1" : "\(count) requests over HTTP/1.1",
                       rows: Array(rows),
                       ranges: origins.flatMap(\.requests).prefix(200).map { profile.network[$0].start...profile.network[$0].end })
    }
}
