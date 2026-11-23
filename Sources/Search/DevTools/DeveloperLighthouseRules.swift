import Foundation

// The Lighthouse panel's audits over one run's input (DeveloperLighthousePage.swift):
// each one Search's implementation of the Lighthouse audit of the same id,
// with its pass and fail titles, scoring mode and details table as
// Lighthouse's has them. Where Lighthouse simulates (savings in ms) the
// numbers are estimated from bytes at Lighthouse's throttled throughput,
// and say so. Pure, for the tests.

enum DeveloperLighthouseRules {
    typealias Audit = DeveloperLighthouseAudit
    typealias Heading = DeveloperLighthouseDetails.Heading
    typealias Value = DeveloperLighthouseValue

    // MARK: The report

    static func report(_ input: DeveloperLighthouseInput, totalTime: Double = 0) -> DeveloperLighthouseReport {
        var input = input
        // Throttling applies to a page load; a timespan is measured as it was.
        if input.mode != .navigation { input.throttling = .none }
        if input.throttling == .simulated, input.simulated == nil {
            input.simulated = DeveloperLighthouseLantern.estimate(for: input)
        }
        let audits = audits(input)
        var warnings = input.warnings
        if input.mode != .snapshot {
            switch input.throttling {
            case .simulated:
                if input.simulated == nil {
                    warnings.append("The load couldn't be simulated (it needs First Contentful Paint and the main document's request), so the metrics are as measured on this Mac, unthrottled.")
                }
            case .devtools:
                warnings.append(input.formFactor == .mobile
                    ? "The network was throttled to Slow 4G through the Network panel. WebKit can't slow the CPU, so CPU work is as fast as this Mac's."
                    : "Lighthouse's desktop DevTools throttling adds no network latency, and WebKit can't slow the CPU: the metrics are as measured on this Mac.")
            case .none:
                warnings.append("No network or CPU throttling was applied: the metrics are as measured on this Mac.")
            }
        }
        var report = DeveloperLighthouseReport(
            requestedURL: input.requestedURL, finalURL: input.page.url.isEmpty ? input.requestedURL : input.page.url,
            fetchTime: input.fetchTime, mode: input.mode, formFactor: input.formFactor,
            categories: DeveloperLighthouseCatalog.categories(input.categories, audits: audits, mode: input.mode),
            audits: audits, warnings: warnings, userAgent: input.userAgent, emulation: input.emulation, totalTime: totalTime)
        report.throttling = input.throttling
        report.simulation = input.simulated
        if input.page.viewportWidth > 0, input.page.viewportHeight > 0 {
            report.viewport = .init(width: input.page.viewportWidth, height: input.page.viewportHeight,
                                    devicePixelRatio: input.page.devicePixelRatio)
        }
        return report
    }

    /// The audits the chosen categories refer to, by id.
    static func audits(_ input: DeveloperLighthouseInput) -> [String: Audit] {
        let wanted = Set(input.categories.filter { input.mode.categories.contains($0) }
            .flatMap { DeveloperLighthouseCatalog.refs($0, mode: input.mode).map(\.id) })
        var out: [String: Audit] = [:]
        for id in wanted { out[id] = audit(id, input) }
        return out
    }

    static func audit(_ id: String, _ input: DeveloperLighthouseInput) -> Audit {
        if let metric = DeveloperLighthouseMetric(rawValue: id) { return metricAudit(metric, input) }
        let page = input.page
        switch id {
        case "render-blocking-resources": return renderBlocking(input)
        case "uses-responsive-images": return responsiveImages(input)
        case "modern-image-formats": return modernFormats(input)
        case "uses-text-compression": return textCompression(input)
        case "server-response-time": return serverResponseTime(input)
        case "uses-long-cache-ttl": return cachePolicy(input)
        case "total-byte-weight": return totalByteWeight(input)
        case "dom-size": return domSize(page)
        case "unsized-images": return unsizedImages(page)
        case "image-alt": return imageAlt(page)
        case "input-image-alt": return nameAudit(id, page.inputImages)
        case "label": return nameAudit(id, page.fields)
        case "button-name": return nameAudit(id, page.buttons)
        case "link-name": return nameAudit(id, page.links.filter { $0.rawHref != nil && $0.visible }
            .map { DeveloperLighthousePage.Named(node: $0.node, name: $0.name) })
        case "frame-title": return nameAudit(id, page.frames)
        case "document-title": return documentTitle(page)
        case "aria-valid-attr": return ariaValidAttributes(page)
        case "aria-required-attr": return ariaRequiredAttributes(page)
        case "duplicate-id-aria": return duplicateIDs(page)
        case "color-contrast": return colorContrast(page)
        case "heading-order": return headingOrder(page)
        case "tabindex": return tabIndex(page)
        case "html-has-lang": return htmlHasLang(page)
        case "html-lang-valid": return htmlLangValid(page)
        case "list": return lists(page)
        case "listitem": return listItems(page)
        case "meta-viewport": return metaViewport(page)
        case "is-on-https": return https(input)
        case "image-aspect-ratio": return aspectRatio(page)
        case "image-size-responsive": return sizeResponsive(page)
        case "doctype": return doctype(page)
        case "charset": return charset(input)
        case "errors-in-console": return consoleErrors(input)
        case "deprecations": return deprecations(input)
        case "inspector-issues": return inspectorIssues(input)
        case "viewport": return viewport(page)
        case "meta-description": return metaDescription(page)
        case "http-status-code": return httpStatus(input)
        case "link-text": return linkText(page)
        case "crawlable-anchors": return crawlableAnchors(page)
        case "is-crawlable": return crawlable(input)
        case "hreflang": return hreflang(page)
        case "canonical": return canonical(page)
        case "offscreen-images": return offscreenImages(input)
        case "unminified-css": return unminified(id, kind: .stylesheet, minPercent: 5, input)
        case "unminified-javascript": return unminified(id, kind: .script, minPercent: 10, input)
        case "unused-css-rules": return unusedCSS(input)
        case "unused-javascript": return unusedJavaScript(input)
        case "redirects": return redirects(input)
        case "uses-rel-preconnect": return preconnect(input)
        case "font-display": return fontDisplay(input)
        case "lcp-lazy-loaded": return lcpLazyLoaded(input)
        case "select-name": return selectName(page)
        case "aria-allowed-attr": return ariaAllowedAttributes(page)
        case "aria-hidden-body": return ariaHiddenBody(page)
        case "aria-roles": return ariaRolesAudit(page)
        case "bypass": return bypass(page)
        case "valid-lang": return validLang(page)
        case "td-headers-attr": return tdHeadersAttribute(page)
        case "meta-refresh": return metaRefresh(page)
        case "landmark-one-main": return landmarkOneMain(page)
        case "target-size": return targetSize(page)
        case "geolocation-on-start": return permissionOnStart(id, api: .geolocation, input)
        case "notification-on-start": return permissionOnStart(id, api: .notification, input)
        case "csp-xss": return cspXSS(input)
        case "paste-preventing-inputs": return pastePreventing(page)
        case "valid-source-maps": return validSourceMaps(input)
        case "robots-txt": return robotsTxt(input)
        default: return notApplicable(id, "Not implemented in Search.")
        }
    }

    // MARK: Building audits

    static func base(_ id: String, passed: Bool) -> Audit {
        let entry = DeveloperLighthouseCatalog.byID[id]
        return Audit(id: id, title: (passed ? entry?.title : entry?.failureTitle) ?? id,
                     description: entry?.description ?? "", score: passed ? 1 : 0, mode: .binary)
    }

    static func binary(_ id: String, passed: Bool, details: DeveloperLighthouseDetails? = nil,
                       displayValue: String? = nil) -> Audit {
        var audit = base(id, passed: passed)
        audit.details = details
        audit.displayValue = displayValue
        return audit
    }

    static func notApplicable(_ id: String, _ why: String? = nil) -> Audit {
        var audit = base(id, passed: true)
        audit.score = nil
        audit.mode = .notApplicable
        audit.explanation = why
        return audit
    }

    static func informative(_ id: String, details: DeveloperLighthouseDetails? = nil, displayValue: String? = nil) -> Audit {
        var audit = base(id, passed: true)
        audit.score = nil
        audit.mode = .informative
        audit.details = details
        audit.displayValue = displayValue
        return audit
    }

    /// An audit over elements: passes with none failing, not applicable when
    /// there were none to check.
    static func elements(_ id: String, checked: Int, failing: [DeveloperLighthouseNode],
                         extra: [(key: String, label: String, values: [Value])] = []) -> Audit {
        guard checked > 0 else { return notApplicable(id) }
        guard !failing.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: .nodes(failing, extra: extra))
    }

    /// The pass or fail title, for an audit whose score was set after it was made.
    static func retitle(_ audit: inout Audit) {
        guard let entry = DeveloperLighthouseCatalog.byID[audit.id] else { return }
        let passed = audit.passed
        audit.title = passed ? entry.title : entry.failureTitle
    }

    static func found(_ count: Int, _ noun: String = "resource") -> String {
        count == 1 ? "1 \(noun) found" : "\(count) \(noun)s found"
    }

    static func kib(_ bytes: Double) -> String {
        Int((bytes / 1024).rounded()).formatted() + " KiB"
    }

    static func ms(_ value: Double) -> String {
        Int(value.rounded()).formatted() + " ms"
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value / 1000)
    }

    // MARK: Metrics

    static let speedIndexReason = "Speed Index needs a filmstrip of the load, and no snapshots of the view were taken after First Contentful Paint."

    static func metricAudit(_ metric: DeveloperLighthouseMetric, _ input: DeveloperLighthouseInput) -> Audit {
        let id = metric.rawValue
        guard input.mode != .snapshot else { return notApplicable(id, "Snapshot mode doesn't measure load metrics.") }
        guard let metrics = input.metrics else { return notApplicable(id, "The page's timings couldn't be read.") }
        let timespan = input.mode == .timespan
        var warning: String?
        let measured: Double?
        switch metric {
        case .firstContentfulPaint:
            measured = metrics.fcp
            if measured == nil { return notApplicable(id, "The page reported no first-contentful-paint.") }
        case .largestContentfulPaint:
            guard metrics.lcpSupported else { return notApplicable(id, "This WebKit doesn't report largest-contentful-paint entries.") }
            measured = metrics.lcp
            if measured == nil { return notApplicable(id, "The page reported no largest-contentful-paint.") }
        case .cumulativeLayoutShift:
            guard metrics.clsSupported || metrics.clsEstimated else {
                return notApplicable(id, "This WebKit doesn't report layout-shift entries.")
            }
            measured = metrics.cls ?? 0
            if metrics.clsEstimated {
                warning = "Estimated by running the Layout Instability algorithm on element positions every 50 ms (\(metrics.layoutShifts) shifts seen): WebKit doesn't report layout-shift entries."
            }
        case .totalBlockingTime:
            guard metrics.taskSource != .none else { return notApplicable(id, "No main-thread task timings were available.") }
            if timespan {
                // Over a timespan every task counts, from its start to its end.
                measured = metrics.timespanBlockingTime
            } else {
                guard metrics.fcp != nil else { return notApplicable(id, "Total Blocking Time is counted from First Contentful Paint, which wasn't reported.") }
                measured = metrics.totalBlockingTime
            }
            if metrics.taskSource == .eventLoopGaps {
                warning = "Estimated from gaps in a zero-delay timer loop: WebKit doesn't report long tasks."
            }
        case .speedIndex:
            guard let value = metrics.speedIndex else { return notApplicable(id, speedIndexReason) }
            measured = value
            warning = "Measured from \(metrics.speedIndexFrames) snapshots of the view, one per display frame, rather than from a trace's screenshots."
        case .interactionToNextPaint:
            guard metrics.inpSupported else {
                return notApplicable(id, "This WebKit doesn't report event timing entries, so interactions can't be timed.")
            }
            guard metrics.interactions > 0, let value = metrics.inp else {
                return notApplicable(id, "No user interactions were recorded during the timespan.")
            }
            measured = value
        }
        guard var value = measured else { return notApplicable(id) }
        // Simulated throttling: Lantern's estimate in place of what was observed.
        if !timespan, let simulated = input.simulated {
            let estimate: DeveloperLighthouseLantern.Estimate? = switch metric {
            case .firstContentfulPaint: simulated.fcp
            case .largestContentfulPaint: simulated.lcp
            case .speedIndex: simulated.speedIndex
            case .totalBlockingTime: simulated.totalBlockingTime
            case .cumulativeLayoutShift, .interactionToNextPaint: nil
            }
            if let estimate {
                let note = "Simulated (\(simulated.settings.summary)) from the unthrottled load, where it was \(displayValue(metric, value))."
                warning = [note, warning].compactMap { $0 }.joined(separator: " ")
                value = estimate.value
            }
        }
        var audit = base(id, passed: true)
        audit.mode = .numeric
        audit.score = DeveloperLighthouseScoring.score(metric, value: value, input.formFactor)
        audit.numericValue = value
        audit.numericUnit = metric.unitless ? "unitless" : "millisecond"
        audit.displayValue = displayValue(metric, value)
        if let warning { audit.warnings = [warning] }
        if metric == .largestContentfulPaint, let element = metrics.lcpElement, !element.isEmpty {
            audit.details = DeveloperLighthouseDetails(headings: [Heading(key: "element", label: "Element", valueType: "code")],
                                                       items: [["element": .code(element)]])
        }
        if metric == .interactionToNextPaint {
            var item: [String: Value] = ["duration": .ms(value)]
            if let event = metrics.inpEvent { item["eventType"] = .text(event) }
            if let target = metrics.inpTarget, !target.isEmpty { item["element"] = .code(target) }
            audit.details = DeveloperLighthouseDetails(headings: [
                Heading(key: "element", label: "Element", valueType: "code"),
                Heading(key: "eventType", label: "Event", valueType: "text"),
                Heading(key: "duration", label: "Duration", valueType: "ms"),
            ], items: [item])
        }
        return audit
    }

    static func displayValue(_ metric: DeveloperLighthouseMetric, _ value: Double) -> String {
        switch metric {
        case .cumulativeLayoutShift: String(format: "%.3f", value)
        case .totalBlockingTime, .interactionToNextPaint: ms(value)
        default: seconds(value)
        }
    }

    // MARK: Performance opportunities

    /// The request for a URL, ignoring its fragment.
    static func request(_ url: String, in requests: [DeveloperLighthouseRequest]) -> DeveloperLighthouseRequest? {
        let key = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
        return requests.first { ($0.url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? $0.url) == key }
    }

    static func bytes(of url: String, _ input: DeveloperLighthouseInput) -> Double? {
        if let found = request(url, in: input.requests), let size = found.transferSize ?? found.resourceSize, size > 0 {
            return size
        }
        if let timing = input.page.timings.first(where: { $0.url == url }) {
            let size = timing.transferSize > 0 ? timing.transferSize : timing.encodedBodySize
            if size > 0 { return size }
        }
        return nil
    }

    static func opportunity(_ id: String, items: [[String: Value]], headings: [Heading], savingsBytes: Double,
                            savingsMs: Double, _ formFactor: DeveloperLighthouseFormFactor) -> Audit {
        var audit = base(id, passed: items.isEmpty)
        audit.mode = .numeric
        audit.score = items.isEmpty ? 1 : DeveloperLighthouseScoring.scoreForWastedMs(savingsMs)
        audit.numericValue = savingsMs
        audit.numericUnit = "millisecond"
        if !items.isEmpty {
            var parts: [String] = []
            if savingsBytes > 0 { parts.append(kib(savingsBytes)) }
            if savingsMs > 0, savingsBytes <= 0 { parts.append(ms(savingsMs)) }
            audit.displayValue = parts.isEmpty ? nil : "Est savings of " + parts.joined(separator: ", ")
            audit.details = DeveloperLighthouseDetails(.opportunity, headings: headings, items: items,
                                                       savingsMs: savingsMs, savingsBytes: savingsBytes)
        }
        return audit
    }

    static func renderBlocking(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "render-blocking-resources"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        let fcp = input.metrics?.fcp
        var items: [[String: Value]] = []
        var spanStart = Double.infinity
        var spanEnd = 0.0
        var total = 0.0
        for resource in input.page.headResources {
            let blocking: Bool
            switch resource.kind {
            case .script: blocking = !resource.async && !resource.deferred && !resource.module
            case .stylesheet: blocking = resource.mediaMatches && !resource.disabled
            }
            guard blocking, !resource.url.isEmpty else { continue }
            let timing = input.page.timings.first { $0.url == resource.url }
            if timing?.renderBlockingStatus == "non-blocking" { continue }
            // Only what finished before the first paint held it up.
            if let fcp, let end = timing?.responseEnd, end > fcp { continue }
            let wasted = timing.map { max(0, $0.responseEnd - $0.startTime) } ?? 0
            if let timing {
                spanStart = min(spanStart, timing.startTime)
                spanEnd = max(spanEnd, timing.responseEnd)
            }
            let size = bytes(of: resource.url, input) ?? 0
            total += size
            items.append(["url": .url(resource.url), "totalBytes": .bytes(size), "wastedMs": .ms(wasted)])
        }
        let savings = spanEnd > spanStart ? spanEnd - spanStart : 0
        return opportunity(id, items: items, headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "totalBytes", label: "Transfer Size", valueType: "bytes"),
            Heading(key: "wastedMs", label: "Est Savings", valueType: "ms"),
        ], savingsBytes: 0, savingsMs: savings, input.formFactor)
    }

    static func responsiveImages(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "uses-responsive-images"
        let dpr = input.page.devicePixelRatio
        var best: [String: (image: DeveloperLighthousePage.Image, expected: Double)] = [:]
        var order: [String] = []
        for image in input.page.images where image.visible && !image.isSVG && image.naturalWidth > 0 && image.naturalHeight > 0
            && image.displayedWidth > 0 && image.displayedHeight > 0 && !image.src.isEmpty {
            let expected = image.displayedWidth * dpr * image.displayedHeight * dpr
            if let found = best[image.src] {
                if expected > found.expected { best[image.src] = (image, expected) }
            } else {
                best[image.src] = (image, expected)
                order.append(image.src)
            }
        }
        var items: [[String: Value]] = []
        var wastedTotal = 0.0
        for src in order {
            guard let entry = best[src], let size = bytes(of: src, input) else { continue }
            let image = entry.image, expected = entry.expected
            let actual = image.naturalWidth * image.naturalHeight
            guard actual > expected else { continue }
            let wasted = size * (1 - expected / actual)
            // Lighthouse's IGNORE_THRESHOLD_IN_BYTES.
            guard wasted > 4_096 else { continue }
            wastedTotal += wasted
            items.append(["node": .node(image.node), "url": .url(src), "totalBytes": .bytes(size), "wastedBytes": .bytes(wasted)])
        }
        items.sort { (number($0["wastedBytes"]) ?? 0) > (number($1["wastedBytes"]) ?? 0) }
        return opportunity(id, items: items, headings: [
            Heading(key: "node", label: "", valueType: "node"),
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "totalBytes", label: "Resource Size", valueType: "bytes"),
            Heading(key: "wastedBytes", label: "Est Savings", valueType: "bytes"),
        ], savingsBytes: wastedTotal, savingsMs: DeveloperLighthouseScoring.milliseconds(forBytes: wastedTotal, input.formFactor),
           input.formFactor)
    }

    static func number(_ value: Value?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .bytes(let n), .ms(let n), .numeric(let n): return n
        default: return nil
        }
    }

    /// Estimated share saved by re-encoding as WebP/AVIF: Lighthouse
    /// re-encodes to measure it; Search can't, so it uses typical ratios.
    static func modernFormatSavings(mime: String) -> Double? {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg", "image/pjpeg": 0.3
        case "image/png", "image/gif", "image/bmp", "image/x-ms-bmp", "image/tiff": 0.5
        default: nil
        }
    }

    static func modernFormats(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "modern-image-formats"
        guard !input.requests.isEmpty else { return notApplicable(id, "No network requests were recorded.") }
        var items: [[String: Value]] = []
        var total = 0.0
        var seen = Set<String>()
        for request in input.requests where !request.url.hasPrefix("data:") && seen.insert(request.url).inserted {
            guard let share = modernFormatSavings(mime: request.mimeType), let size = request.transferSize ?? request.resourceSize,
                  size > 8_192 else { continue }
            let wasted = size * share
            total += wasted
            items.append(["url": .url(request.url), "totalBytes": .bytes(size), "wastedBytes": .bytes(wasted)])
        }
        return opportunity(id, items: items, headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "totalBytes", label: "Resource Size", valueType: "bytes"),
            Heading(key: "wastedBytes", label: "Est Savings", valueType: "bytes"),
        ], savingsBytes: total, savingsMs: DeveloperLighthouseScoring.milliseconds(forBytes: total, input.formFactor), input.formFactor)
    }

    static func isText(mime: String) -> Bool {
        let lower = mime.lowercased()
        if lower.hasPrefix("text/") { return true }
        return ["javascript", "json", "xml", "ecmascript", "svg", "x-font-ttf", "vnd.ms-fontobject", "manifest"]
            .contains { lower.contains($0) }
    }

    static func textCompression(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "uses-text-compression"
        guard !input.requests.isEmpty else { return notApplicable(id, "No network requests were recorded.") }
        var items: [[String: Value]] = []
        var total = 0.0
        for request in input.requests where !request.cached && request.status != 304 && !request.headers.isEmpty {
            guard isText(mime: request.mimeType), ["http", "https"].contains(request.scheme) else { continue }
            let encoding = request.headers["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard encoding.isEmpty || encoding == "identity" else { continue }
            let size = request.resourceSize ?? request.transferSize ?? 0
            // Lighthouse skips under 1.4 KB and savings under 10%; gzip
            // typically takes text to a third of its size.
            let wasted = size * 0.65
            guard size > 1_400, wasted > 1_400 else { continue }
            total += wasted
            items.append(["url": .url(request.url), "totalBytes": .bytes(size), "wastedBytes": .bytes(wasted)])
        }
        return opportunity(id, items: items, headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "totalBytes", label: "Transfer Size", valueType: "bytes"),
            Heading(key: "wastedBytes", label: "Est Savings", valueType: "bytes"),
        ], savingsBytes: total, savingsMs: DeveloperLighthouseScoring.milliseconds(forBytes: total, input.formFactor), input.formFactor)
    }

    // MARK: Performance diagnostics

    static func serverResponseTime(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "server-response-time"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard let ttfb = input.metrics?.ttfb, ttfb >= 0 else { return notApplicable(id, "The document's timing wasn't available.") }
        // Lighthouse's TOO_SLOW_THRESHOLD_MS.
        var audit = base(id, passed: ttfb < 600)
        audit.mode = .numeric
        audit.numericValue = ttfb
        audit.numericUnit = "millisecond"
        audit.displayValue = "Root document took " + ms(ttfb)
        audit.details = DeveloperLighthouseDetails(headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "responseTime", label: "Time Spent", valueType: "ms"),
        ], items: [["url": .url(input.page.url), "responseTime": .ms(ttfb)]])
        return audit
    }

    /// An Expires header's date, made once rather than for every request.
    private static let expiresFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// cache-headers.js: a Cache-Control or Expires lifetime in seconds;
    /// nil when there's none.
    static func cacheLifetime(_ headers: [String: String], now: Date = Date()) -> Double? {
        if let control = headers["cache-control"]?.lowercased() {
            let directives = control.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if directives.contains("no-cache") || directives.contains("no-store") { return 0 }
            for directive in directives where directive.hasPrefix("max-age=") {
                if let value = Double(directive.dropFirst("max-age=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
                    return max(0, value)
                }
            }
        } else if headers["pragma"]?.lowercased().contains("no-cache") == true {
            return 0
        }
        if let expires = headers["expires"] {
            guard let date = expiresFormat.date(from: expires) else { return 0 }
            return max(0, (date.timeIntervalSince(now)).rounded(.up))
        }
        return nil
    }

    /// Whether a resource's policy means it shouldn't be cached long anyway.
    static func skipsCaching(_ headers: [String: String]) -> Bool {
        guard let control = headers["cache-control"]?.lowercased() else { return false }
        let directives = control.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return directives.contains { ["no-cache", "no-store", "must-revalidate", "private"].contains($0) }
    }

    /// cache-headers.js getCacheHitProbability: how likely a repeat visit
    /// finds a resource with this lifetime still cached, interpolated
    /// between the deciles of resource age.
    static func cacheHitProbability(_ seconds: Double) -> Double {
        let deciles: [Double] = [0, 0.2, 1, 3, 8, 12, 24, 48, 72, 168, 8_760, .infinity]
        let hours = seconds / 3_600
        guard let upper = deciles.firstIndex(where: { $0 >= hours }) else { return 1 }
        if upper == deciles.count - 1 { return 1 }
        if upper == 0 { return 0 }
        let upperValue = deciles[upper], lowerValue = deciles[upper - 1]
        let upperDecile = Double(upper) / 10, lowerDecile = Double(upper - 1) / 10
        return lowerDecile + (hours - lowerValue) * (upperDecile - lowerDecile) / (upperValue - lowerValue)
    }

    static func cachePolicy(_ input: DeveloperLighthouseInput, now: Date = Date()) -> Audit {
        let id = "uses-long-cache-ttl"
        guard !input.requests.isEmpty else { return notApplicable(id, "No network requests were recorded.") }
        let staticTypes: Set<String> = ["script", "stylesheet", "image", "font", "media"]
        var items: [[String: Value]] = []
        var wastedTotal = 0.0
        var seen = Set<String>()
        for request in input.requests where [200, 203, 206].contains(request.status ?? 0) && !request.headers.isEmpty {
            guard staticTypes.contains(request.type.lowercased()), ["http", "https"].contains(request.scheme),
                  seen.insert(request.url).inserted, !skipsCaching(request.headers) else { continue }
            let lifetime = cacheLifetime(request.headers, now: now) ?? 0
            let probability = cacheHitProbability(lifetime)
            // Lighthouse's IGNORE_THRESHOLD_IN_PERCENT.
            guard probability < 0.925 else { continue }
            let size = request.transferSize ?? request.resourceSize ?? 0
            let wasted = (1 - probability) * size
            wastedTotal += wasted
            items.append(["url": .url(request.url), "cacheLifetimeMs": .ms(lifetime * 1_000), "totalBytes": .bytes(size),
                          "wastedBytes": .bytes(wasted)])
        }
        items.sort { (number($0["totalBytes"]) ?? 0) > (number($1["totalBytes"]) ?? 0) }
        var audit = base(id, passed: items.isEmpty)
        audit.mode = .numeric
        audit.score = DeveloperLighthouseScoring.score(wastedTotal, .init(p10: 28 * 1_024, median: 128 * 1_024))
        audit.numericValue = wastedTotal
        audit.numericUnit = "byte"
        retitle(&audit)
        if !items.isEmpty {
            audit.displayValue = found(items.count)
            audit.details = DeveloperLighthouseDetails(headings: [
                Heading(key: "url", label: "URL", valueType: "url"),
                Heading(key: "cacheLifetimeMs", label: "Cache TTL", valueType: "ms"),
                Heading(key: "totalBytes", label: "Transfer Size", valueType: "bytes"),
            ], items: items)
        }
        return audit
    }

    static func totalByteWeight(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "total-byte-weight"
        guard input.mode != .snapshot else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard !input.requests.isEmpty else { return notApplicable(id, "No network requests were recorded.") }
        let sized = input.requests.compactMap { request in request.transferSize.map { (request.url, $0) } }
        let total = sized.reduce(0.0) { $0 + $1.1 }
        var audit = base(id, passed: true)
        audit.mode = .numeric
        audit.score = DeveloperLighthouseScoring.score(total, .init(p10: 2_667 * 1_024, median: 4_000 * 1_024))
        retitle(&audit)
        audit.numericValue = total
        audit.numericUnit = "byte"
        audit.displayValue = "Total size was " + kib(total)
        let top = sized.sorted { $0.1 > $1.1 }.prefix(10)
        audit.details = DeveloperLighthouseDetails(headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "totalBytes", label: "Transfer Size", valueType: "bytes"),
        ], items: top.map { ["url": .url($0.0), "totalBytes": .bytes($0.1)] })
        return audit
    }

    static func domSize(_ page: DeveloperLighthousePage) -> Audit {
        let id = "dom-size"
        let count = Double(page.dom.elements)
        var audit = base(id, passed: true)
        audit.mode = .numeric
        // dom-size.js (v12) control points.
        audit.score = DeveloperLighthouseScoring.score(count, .init(p10: 818, median: 1_400))
        retitle(&audit)
        audit.numericValue = count
        audit.numericUnit = "element"
        audit.displayValue = page.dom.elements == 1 ? "1 element" : "\(page.dom.elements.formatted()) elements"
        var items: [[String: Value]] = [["statistic": .text("Total DOM Elements"), "value": .numeric(count)]]
        var depth: [String: Value] = ["statistic": .text("Maximum DOM Depth"), "value": .numeric(Double(page.dom.depth))]
        if let node = page.dom.depthNode { depth["node"] = .node(node) }
        items.append(depth)
        var widest: [String: Value] = ["statistic": .text("Maximum Child Elements"), "value": .numeric(Double(page.dom.widestChildren))]
        if let node = page.dom.widestNode { widest["node"] = .node(node) }
        items.append(widest)
        audit.details = DeveloperLighthouseDetails(headings: [
            Heading(key: "statistic", label: "Statistic", valueType: "text"),
            Heading(key: "node", label: "Element", valueType: "node"),
            Heading(key: "value", label: "Value", valueType: "numeric"),
        ], items: items)
        return audit
    }

    static func unsizedImages(_ page: DeveloperLighthousePage) -> Audit {
        let candidates = page.images.filter { $0.visible && !["fixed", "absolute"].contains($0.position) }
        let failing = candidates.filter { !($0.widthAttribute && $0.heightAttribute) && !$0.cssSized }
        return elements("unsized-images", checked: candidates.count, failing: failing.map(\.node),
                        extra: [("url", "URL", failing.map { Value.url($0.src) })])
    }

    // MARK: Accessibility

    static func imageAlt(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.images.filter { !$0.ariaHidden }
        let failing = checked.filter { $0.alt == nil && !$0.presentational && $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        return elements("image-alt", checked: checked.count, failing: failing.map(\.node))
    }

    static func nameAudit(_ id: String, _ controls: [DeveloperLighthousePage.Named]) -> Audit {
        let failing = controls.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return elements(id, checked: controls.count, failing: failing.map(\.node))
    }

    static func documentTitle(_ page: DeveloperLighthousePage) -> Audit {
        let present = !(page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return binary("document-title", passed: present)
    }

    static func htmlHasLang(_ page: DeveloperLighthousePage) -> Audit {
        let lang = (page.lang ?? "").trimmingCharacters(in: .whitespaces)
        let xml = (page.xmlLang ?? "").trimmingCharacters(in: .whitespaces)
        return binary("html-has-lang", passed: !lang.isEmpty || !xml.isEmpty)
    }

    /// A BCP 47 tag's shape: a 2–3 letter primary language and subtags of
    /// 1–8 letters or digits.
    static func validLanguage(_ tag: String) -> Bool {
        let parts = tag.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    static func htmlLangValid(_ page: DeveloperLighthousePage) -> Audit {
        let id = "html-lang-valid"
        guard let lang = page.lang?.trimmingCharacters(in: .whitespaces), !lang.isEmpty else { return notApplicable(id) }
        return binary(id, passed: validLanguage(lang), displayValue: validLanguage(lang) ? nil : "lang=\"\(lang)\"")
    }

    /// WAI-ARIA 1.2's states and properties, with 1.3's additions that
    /// WebKit and axe accept.
    static let ariaAttributes: Set<String> = [
        "aria-activedescendant", "aria-atomic", "aria-autocomplete", "aria-braillelabel", "aria-brailleroledescription",
        "aria-busy", "aria-checked", "aria-colcount", "aria-colindex", "aria-colindextext", "aria-colspan", "aria-controls",
        "aria-current", "aria-describedby", "aria-description", "aria-details", "aria-disabled", "aria-dropeffect",
        "aria-errormessage", "aria-expanded", "aria-flowto", "aria-grabbed", "aria-haspopup", "aria-hidden", "aria-invalid",
        "aria-keyshortcuts", "aria-label", "aria-labelledby", "aria-level", "aria-live", "aria-modal", "aria-multiline",
        "aria-multiselectable", "aria-orientation", "aria-owns", "aria-placeholder", "aria-posinset", "aria-pressed",
        "aria-readonly", "aria-relevant", "aria-required", "aria-roledescription", "aria-rowcount", "aria-rowindex",
        "aria-rowindextext", "aria-rowspan", "aria-selected", "aria-setsize", "aria-sort", "aria-valuemax", "aria-valuemin",
        "aria-valuenow", "aria-valuetext",
    ]

    static func ariaValidAttributes(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.aria.filter { !$0.attributes.isEmpty }
        var failing: [DeveloperLighthouseNode] = []
        var names: [Value] = []
        for element in checked {
            let bad = element.attributes.filter { !ariaAttributes.contains($0.lowercased()) }
            guard !bad.isEmpty else { continue }
            failing.append(element.node)
            names.append(.code(bad.joined(separator: ", ")))
        }
        return elements("aria-valid-attr", checked: checked.count, failing: failing,
                        extra: [("attributes", "Invalid attributes", names)])
    }

    /// ARIA 1.2's required states and properties, for the roles axe checks.
    static let requiredAttributes: [String: [String]] = [
        "checkbox": ["aria-checked"], "combobox": ["aria-expanded"], "menuitemcheckbox": ["aria-checked"],
        "menuitemradio": ["aria-checked"], "meter": ["aria-valuenow"], "radio": ["aria-checked"],
        "scrollbar": ["aria-valuenow"], "slider": ["aria-valuenow"], "switch": ["aria-checked"],
    ]

    static func ariaRequiredAttributes(_ page: DeveloperLighthousePage) -> Audit {
        var checked = 0
        var failing: [DeveloperLighthouseNode] = []
        var missing: [Value] = []
        for element in page.aria where !element.native {
            guard let role = element.role?.lowercased().split(separator: " ").first.map(String.init),
                  let required = requiredAttributes[role] else { continue }
            checked += 1
            let present = Set(element.attributes.map { $0.lowercased() })
            let absent = required.filter { !present.contains($0) }
            guard !absent.isEmpty else { continue }
            failing.append(element.node)
            missing.append(.code("role=\"\(role)\" needs " + absent.joined(separator: ", ")))
        }
        return elements("aria-required-attr", checked: checked, failing: failing, extra: [("missing", "Missing", missing)])
    }

    static func duplicateIDs(_ page: DeveloperLighthousePage) -> Audit {
        let id = "duplicate-id-aria"
        let referenced = page.duplicateIDs.filter(\.referenced)
        // Applies to pages that use ARIA at all.
        guard !referenced.isEmpty else { return page.aria.isEmpty ? notApplicable(id) : binary(id, passed: true) }
        let nodes = referenced.flatMap(\.nodes)
        let ids = referenced.flatMap { duplicate in duplicate.nodes.map { _ in Value.code("id=\"\(duplicate.id)\"") } }
        return binary(id, passed: false, details: .nodes(nodes, extra: [("id", "ID", ids)]))
    }

    /// What's behind a text: the background colours from it up,
    /// composited down to the first opaque one, over white when none is.
    static func effectiveBackground(_ layers: [String]) -> DeveloperCSSColor {
        var stack: [DeveloperCSSColor] = []
        for text in layers {
            guard let color = DeveloperCSSColor.parse(text), !color.isTransparent else { continue }
            stack.append(color)
            if color.isOpaque { break }
        }
        var result = DeveloperCSSColor.white
        for color in stack.reversed() { result = color.over(result) }
        return result
    }

    static func colorContrast(_ page: DeveloperLighthousePage) -> Audit {
        var checked = 0
        var failing: [DeveloperLighthouseNode] = []
        var details: [Value] = []
        for text in page.texts {
            guard let backgrounds = text.backgrounds, let color = DeveloperCSSColor.parse(text.color), !color.isTransparent
            else { continue }
            checked += 1
            let background = effectiveBackground(backgrounds)
            let ratio = DeveloperCSSColor.contrast(color, background)
            let bar = DeveloperCSSOverview.threshold(large: DeveloperCSSOverview.isLargeText(fontSize: text.fontSize,
                                                                                            fontWeight: text.fontWeight))
            guard ratio < bar else { continue }
            failing.append(text.node)
            details.append(.text("\(DeveloperCSSOverview.ratioLabel(ratio)) (\(color.hex) on \(background.hex), needs \(bar.formatted()):1)"))
        }
        return elements("color-contrast", checked: checked, failing: failing, extra: [("contrast", "Contrast", details)])
    }

    static func headingOrder(_ page: DeveloperLighthousePage) -> Audit {
        var failing: [DeveloperLighthouseNode] = []
        var notes: [Value] = []
        var previous: Int?
        for heading in page.headings where (1...6).contains(heading.level) {
            if let previous, heading.level > previous + 1 {
                failing.append(heading.node)
                notes.append(.text("h\(heading.level) after h\(previous)"))
            }
            previous = heading.level
        }
        return elements("heading-order", checked: page.headings.count, failing: failing, extra: [("order", "Order", notes)])
    }

    static func tabIndex(_ page: DeveloperLighthousePage) -> Audit {
        let failing = page.tabIndexes.filter { $0.value > 0 }
        guard !page.tabIndexes.isEmpty else { return notApplicable("tabindex") }
        return elements("tabindex", checked: page.tabIndexes.count, failing: failing.map(\.node),
                        extra: [("value", "tabindex", failing.map { Value.numeric(Double($0.value)) })])
    }

    static func lists(_ page: DeveloperLighthousePage) -> Audit {
        let allowed: Set<String> = ["li", "script", "template"]
        let failing = page.lists.filter { list in
            list.children.contains { child in
                let tag = child.tag.lowercased()
                let role = child.role?.lowercased()
                if role == "listitem" { return false }
                if tag == "li" { return role != nil && role != "none" && role != "presentation" }
                return !allowed.contains(tag)
            }
        }
        return elements("list", checked: page.lists.count, failing: failing.map(\.node))
    }

    static func listItems(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.listItems.filter { $0.role == nil || $0.role?.lowercased() == "listitem" }
        let failing = checked.filter { item in
            !["ul", "ol", "menu"].contains(item.parentTag.lowercased()) && item.parentRole?.lowercased() != "list"
        }
        return elements("listitem", checked: checked.count, failing: failing.map(\.node))
    }

    /// A viewport meta's `content`, as `key=value` pairs.
    static func viewportProperties(_ content: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in content.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let key = parts.first, !key.isEmpty else { continue }
            out[key] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    static func metaViewport(_ page: DeveloperLighthousePage) -> Audit {
        let id = "meta-viewport"
        guard let content = page.viewport else { return notApplicable(id) }
        let properties = viewportProperties(content)
        var problems: [String] = []
        if let scalable = properties["user-scalable"], ["no", "0"].contains(scalable) { problems.append("user-scalable=\(scalable)") }
        if let maximum = properties["maximum-scale"].flatMap(Double.init), maximum < 5 {
            problems.append("maximum-scale=\(properties["maximum-scale"] ?? "")")
        }
        guard !problems.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(
            headings: [Heading(key: "content", label: "Viewport", valueType: "code")],
            items: [["content": .code(content)]]), displayValue: problems.joined(separator: ", "))
    }

    // MARK: Best practices

    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func https(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "is-on-https"
        var insecure: [String] = []
        if let page = URL(string: input.page.url), page.scheme?.lowercased() == "http", !isLocal(page.host()?.lowercased() ?? "") {
            insecure.append(input.page.url)
        }
        for request in input.requests where request.scheme == "http" || request.scheme == "ws" {
            guard !isLocal(request.host), !insecure.contains(request.url) else { continue }
            insecure.append(request.url)
        }
        guard !insecure.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(
            headings: [Heading(key: "url", label: "Insecure URL", valueType: "url")],
            items: insecure.map { ["url": .url($0)] }), displayValue: found(insecure.count, "insecure request"))
    }

    static func aspectRatio(_ page: DeveloperLighthousePage) -> Audit {
        let fits: Set<String> = ["cover", "contain", "scale-down", "none"]
        let checked = page.images.filter {
            $0.visible && !$0.isSVG && !fits.contains($0.objectFit) && $0.naturalWidth > 0 && $0.naturalHeight > 0
                && $0.displayedWidth > 1 && $0.displayedHeight > 1
        }
        var failing: [DeveloperLighthousePage.Image] = []
        for image in checked {
            let actual = image.naturalWidth / image.naturalHeight
            let target = image.displayedWidth / actual
            // image-aspect-ratio.js THRESHOLD_PX.
            if abs(target - image.displayedHeight) >= 2 { failing.append(image) }
        }
        func ratio(_ w: Double, _ h: Double) -> String {
            "\(Int(w.rounded())) x \(Int(h.rounded())) (\(String(format: "%.2f", w / h)))"
        }
        return elements("image-aspect-ratio", checked: checked.count, failing: failing.map(\.node), extra: [
            ("url", "URL", failing.map { Value.url($0.src) }),
            ("displayedAspectRatio", "Aspect Ratio (Displayed)", failing.map { Value.text(ratio($0.displayedWidth, $0.displayedHeight)) }),
            ("actualAspectRatio", "Aspect Ratio (Actual)", failing.map { Value.text(ratio($0.naturalWidth, $0.naturalHeight)) }),
        ])
    }

    /// image-size-responsive.js: the pixel ratio rounded down to 1, 1.5 or 2.
    static func quantizedDPR(_ dpr: Double) -> Double {
        if dpr >= 2 { return 2 }
        if dpr >= 1.5 { return 1.5 }
        return 1
    }

    /// The natural size an image displayed at this size needs, with
    /// Lighthouse's tolerance (75% for small images, 50% for large).
    static func expectedSize(_ displayed: Double, dpr: Double) -> Double {
        let tolerance = displayed <= 64 ? 0.75 : 0.5
        return (displayed * quantizedDPR(dpr) * tolerance).rounded(.up)
    }

    static func sizeResponsive(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.images.filter {
            $0.visible && !$0.isSVG && !$0.pixelated && $0.naturalWidth > 0 && $0.naturalHeight > 0
                && $0.displayedWidth > 1 && $0.displayedHeight > 1
        }
        let dpr = page.devicePixelRatio
        let failing = checked.filter {
            $0.naturalWidth < expectedSize($0.displayedWidth, dpr: dpr) || $0.naturalHeight < expectedSize($0.displayedHeight, dpr: dpr)
        }
        func size(_ w: Double, _ h: Double) -> Value { .text("\(Int(w.rounded())) x \(Int(h.rounded()))") }
        return elements("image-size-responsive", checked: checked.count, failing: failing.map(\.node), extra: [
            ("url", "URL", failing.map { Value.url($0.src) }),
            ("displayedSize", "Displayed size", failing.map { size($0.displayedWidth, $0.displayedHeight) }),
            ("actualSize", "Actual size", failing.map { size($0.naturalWidth, $0.naturalHeight) }),
            ("expectedSize", "Expected size", failing.map { size(expectedSize($0.displayedWidth, dpr: dpr), expectedSize($0.displayedHeight, dpr: dpr)) }),
        ])
    }

    static func doctype(_ page: DeveloperLighthousePage) -> Audit {
        let id = "doctype"
        let problem: String?
        if let doctype = page.doctype {
            if doctype.name.lowercased() != "html" {
                problem = "Doctype name must be the string `html`"
            } else if !doctype.publicID.isEmpty {
                problem = "Expected publicId to be an empty string"
            } else if !doctype.systemID.isEmpty {
                problem = "Expected systemId to be an empty string"
            } else if page.compatMode == "BackCompat" {
                problem = "Document contains a `doctype` that triggers `quirks-mode`"
            } else {
                problem = nil
            }
        } else {
            problem = "Document must contain a doctype"
        }
        var audit = binary(id, passed: problem == nil)
        audit.explanation = problem
        return audit
    }

    static func charset(_ input: DeveloperLighthouseInput) -> Audit {
        let header = mainDocument(input)?.headers["content-type"]?.lowercased() ?? ""
        return binary("charset", passed: input.page.charsetMeta || header.contains("charset="))
    }

    static func consoleErrors(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "errors-in-console"
        guard !input.consoleErrors.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "sourceLocation", label: "Source", valueType: "url"),
            Heading(key: "description", label: "Description", valueType: "code"),
        ], items: input.consoleErrors.prefix(100).map { error in
            ["sourceLocation": .url(error.url ?? ""), "description": .code(error.text)]
        }), displayValue: found(input.consoleErrors.count, "error"))
    }

    static func deprecations(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "deprecations"
        guard let issues = input.issues else { return notApplicable(id, "The Issues tool couldn't be read.") }
        let found = issues.filter(\.deprecation)
        guard !found.isEmpty else { return binary(id, passed: true) }
        let count = found.reduce(0) { $0 + $1.count }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "value", label: "Deprecation / Warning", valueType: "text"),
            Heading(key: "count", label: "Count", valueType: "numeric"),
        ], items: found.map { ["value": .text($0.subtitle ?? $0.title), "count": .numeric(Double($0.count))] }),
        displayValue: count == 1 ? "1 warning found" : "\(count) warnings found")
    }

    static func inspectorIssues(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "inspector-issues"
        guard let issues = input.issues else { return notApplicable(id, "The Issues tool couldn't be read.") }
        let found = issues.filter { $0.scored && !$0.deprecation && $0.category != DeveloperIssueCategory.lowTextContrast.rawValue }
        guard !found.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "issueType", label: "Issue type", valueType: "text"),
            Heading(key: "title", label: "Issue", valueType: "text"),
            Heading(key: "count", label: "Count", valueType: "numeric"),
        ], items: found.map { ["issueType": .text($0.category), "title": .text($0.title), "count": .numeric(Double($0.count))] }))
    }

    // MARK: SEO

    static func mainDocument(_ input: DeveloperLighthouseInput) -> DeveloperLighthouseRequest? {
        let documents = input.requests.filter { $0.type.lowercased() == "document" }
        let final = input.page.url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? input.page.url
        return documents.last { $0.url == final } ?? documents.first
    }

    static func viewport(_ page: DeveloperLighthousePage) -> Audit {
        let id = "viewport"
        guard let content = page.viewport else {
            var audit = binary(id, passed: false)
            audit.explanation = "No `<meta name=\"viewport\">` tag found"
            return audit
        }
        let properties = viewportProperties(content)
        let ok = properties["width"] != nil || properties["initial-scale"] != nil
        var audit = binary(id, passed: ok)
        if !ok { audit.explanation = "No `width` or `initial-scale` property found" }
        return audit
    }

    static func metaDescription(_ page: DeveloperLighthousePage) -> Audit {
        let id = "meta-description"
        guard let description = page.metaDescription else { return binary(id, passed: false) }
        var audit = binary(id, passed: !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if !audit.passed { audit.explanation = "Description text is empty." }
        return audit
    }

    static func httpStatus(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "http-status-code"
        // As in Lighthouse, where the audit supports Navigation mode only.
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard let document = mainDocument(input), let status = document.status else {
            return notApplicable(id, "The page's document request wasn't recorded.")
        }
        return binary(id, passed: status < 400, displayValue: status >= 400 ? "\(status)" : nil)
    }

    /// link-text.js's blocklist (English).
    static let genericLinkText: Set<String> = [
        "click here", "click this", "go", "here", "information", "learn more", "more", "more info",
        "more information", "right here", "read more", "see more", "start", "this",
    ]

    static func linkText(_ page: DeveloperLighthousePage) -> Audit {
        let id = "link-text"
        let pageBase = page.url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? page.url
        let checked = page.links.filter { link in
            guard let raw = link.rawHref, link.tag == "a" else { return false }
            let href = link.href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? link.href
            return !raw.lowercased().hasPrefix("javascript:") && !raw.hasPrefix("#") && href != pageBase
        }
        let failing = checked.filter {
            genericLinkText.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: .punctuationCharacters))
        }
        guard !checked.isEmpty else { return binary(id, passed: true) }
        guard !failing.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "href", label: "Link destination", valueType: "url"),
            Heading(key: "text", label: "Link Text", valueType: "text"),
        ], items: failing.map { ["href": .url($0.href), "text": .text($0.text)] }), displayValue: found(failing.count, "link"))
    }

    /// crawlable-anchors.js: whether an anchor fails to give crawlers a
    /// destination.
    static func uncrawlable(_ link: DeveloperLighthousePage.Link) -> Bool {
        if let role = link.role, !role.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        guard let rawHref = link.rawHref else {
            // An `<a>` with no href is a placeholder, unless script makes it act as a link.
            return link.onclick && !link.nameAttribute
        }
        let raw = rawHref.filter { !$0.isWhitespace }
        let lower = raw.lowercased()
        if lower.hasPrefix("mailto:") { return false }
        if lower.hasPrefix("file:") { return true }
        if link.nameAttribute { return false }
        if raw.isEmpty { return true }
        if lower.hasPrefix("javascript:") { return true }
        if URL(string: raw) == nil, URL(string: link.href) == nil { return true }
        return false
    }

    static func crawlableAnchors(_ page: DeveloperLighthousePage) -> Audit {
        let anchors = page.links.filter { $0.tag == "a" }
        let failing = anchors.filter(uncrawlable)
        return elements("crawlable-anchors", checked: anchors.count, failing: failing.map(\.node),
                        extra: [("href", "Uncrawlable Link", failing.map { Value.code($0.rawHref ?? "(no href)") })])
    }

    static func blocksIndexing(_ directives: String) -> Bool {
        let tokens = directives.lowercased().split(whereSeparator: { $0 == "," || $0 == " " || $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return tokens.contains("noindex") || tokens.contains("none")
    }

    static func crawlable(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "is-crawlable"
        var blocking: [[String: Value]] = []
        for content in input.page.robots where blocksIndexing(content) {
            blocking.append(["source": .code("<meta name=\"robots\" content=\"\(content)\">")])
        }
        if let header = mainDocument(input)?.headers["x-robots-tag"] {
            // A header naming another user agent ("otherbot: noindex") doesn't apply.
            let parts = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for part in parts where blocksIndexing(part) {
                let agent = part.split(separator: ":", maxSplits: 1)
                if agent.count == 2, !["noindex", "none"].contains(agent[0].lowercased()),
                   !["googlebot", "*"].contains(agent[0].lowercased().trimmingCharacters(in: .whitespaces)) { continue }
                blocking.append(["source": .code("x-robots-tag: " + part)])
            }
        }
        guard !blocking.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(
            headings: [Heading(key: "source", label: "Blocking Directive Source", valueType: "code")], items: blocking))
    }

    static func validHreflang(_ value: String) -> Bool {
        value.lowercased() == "x-default" || validLanguage(value)
    }

    static func hreflang(_ page: DeveloperLighthousePage) -> Audit {
        let id = "hreflang"
        var items: [[String: Value]] = []
        for link in page.hreflangs {
            if !validHreflang(link.lang) {
                items.append(["source": .code("<link rel=\"alternate\" hreflang=\"\(link.lang)\" href=\"\(link.raw)\">"),
                              "reason": .text("Unexpected language code")])
            } else if URL(string: link.raw)?.scheme == nil {
                items.append(["source": .code("<link rel=\"alternate\" hreflang=\"\(link.lang)\" href=\"\(link.raw)\">"),
                              "reason": .text("Relative href value")])
            }
        }
        guard !items.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "source", label: "Source", valueType: "code"),
            Heading(key: "reason", label: "Reason", valueType: "text"),
        ], items: items))
    }

    static func canonical(_ page: DeveloperLighthousePage) -> Audit {
        let id = "canonical"
        guard !page.canonicals.isEmpty else { return notApplicable(id) }
        func fail(_ why: String) -> Audit {
            var audit = binary(id, passed: false)
            audit.explanation = why
            return audit
        }
        let distinct = Array(Set(page.canonicals.map { $0.resolved }))
        if distinct.count > 1 { return fail("Multiple conflicting URLs (\(distinct.sorted().joined(separator: ", ")))") }
        let canonical = page.canonicals[0]
        guard let url = URL(string: canonical.resolved), url.scheme != nil, url.host() != nil else {
            return fail("Invalid URL (\(canonical.raw))")
        }
        if URL(string: canonical.raw)?.scheme == nil { return fail("Is not an absolute URL (\(canonical.raw))") }
        if let current = URL(string: page.url), current.host() == url.host(),
           url.path.isEmpty || url.path == "/", !(current.path.isEmpty || current.path == "/") {
            return fail("Points to the domain's root URL (the homepage), instead of an equivalent page of content")
        }
        return binary(id, passed: true)
    }
}
