import AppKit
import Foundation

// Lighthouse's audits, on WebKit. Lighthouse itself is a Node program that
// drives Chrome over its debugging protocol, so it can't run here; what this
// does is this package's own version of a subset of its audits, over what the page
// scripts read (LighthouseScripts.swift) and the main document's answer. The
// categories, weights, score curves, titles and the report's JSON follow
// Lighthouse's, so a report reads, and exports, the same way.
//
// Adapted from Lighthouse (Apache License 2.0, Copyright Google LLC; see
// THIRD_PARTY_NOTICES.md): the audit ids, titles and descriptions, the
// category weights (core/config/default-config.js), the metric score curves
// (core/audits/metrics/*.js), the log-normal scoring (core/lib/statistics.js
// and core/audits/audit.js) and the LHR's shape. The Speed Index follows
// Speedline's histogram method (MIT, see the same file).

enum LighthouseCategory: String, CaseIterable, Identifiable {
    case performance, accessibility
    case bestPractices = "best-practices"
    case seo

    var id: Self { self }

    var title: String {
        switch self {
        case .performance: "Performance"
        case .accessibility: "Accessibility"
        case .bestPractices: "Best Practices"
        case .seo: "SEO"
        }
    }
}

enum LighthouseMode: String, CaseIterable, Identifiable {
    case navigation, snapshot
    var id: Self { self }
    var title: String { self == .navigation ? "Navigation" : "Snapshot" }
}

enum LighthouseFormFactor: String, CaseIterable, Identifiable {
    case mobile, desktop
    var id: Self { self }
    var title: String { self == .mobile ? "Mobile" : "Desktop" }
    /// Lighthouse's screen for the form factor (core/config/constants.js).
    var size: CGSize { self == .mobile ? CGSize(width: 412, height: 823) : CGSize(width: 1350, height: 940) }
    /// Lighthouse's throttled throughput, kilobits a second, that byte
    /// savings are turned into milliseconds at.
    var throughputKbps: Double { self == .mobile ? 1_638.4 : 10_240 }
}

enum LighthouseMetric: String, CaseIterable {
    case fcp = "first-contentful-paint"
    case lcp = "largest-contentful-paint"
    case tbt = "total-blocking-time"
    case cls = "cumulative-layout-shift"
    case si = "speed-index"

    /// The control points: the value scoring 0.9, and the median, 0.5.
    func curve(_ form: LighthouseFormFactor) -> (p10: Double, median: Double) {
        let mobile = form == .mobile
        switch self {
        case .fcp: return mobile ? (1_800, 3_000) : (934, 1_600)
        case .si: return mobile ? (3_387, 5_800) : (1_311, 2_300)
        case .lcp: return mobile ? (2_500, 4_000) : (1_200, 2_400)
        case .tbt: return mobile ? (200, 600) : (150, 350)
        case .cls: return (0.1, 0.25)
        }
    }

    func display(_ value: Double) -> String {
        switch self {
        case .cls: return String(format: "%.3f", value)
        case .tbt: return "\(Int(value.rounded())) ms"
        default: return String(format: "%.1f s", value / 1000)
        }
    }
}

enum LighthouseScoring {
    /// Abramowitz & Stegun 7.1.26, as Lighthouse's erf.
    static func erf(_ x: Double) -> Double {
        let sign: Double = x > 0 ? 1 : (x < 0 ? -1 : 0)
        let value = abs(x)
        let t = 1 / (1 + 0.3275911 * value)
        let y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
        return sign * (1 - y * exp(-value * value))
    }

    /// The share of a log-normal distribution above `value`: 0.9 at p10,
    /// 0.5 at the median; above 0.9 nudged up, then floored to two places.
    static func score(_ value: Double, p10: Double, median: Double) -> Double {
        guard median > 0, p10 > 0, p10 < median else { return 0 }
        guard value > 0 else { return 1 }
        let standardized = log(value / median) * 0.9061938024368232 / -log(p10 / median)
        var percentile = min(1, max(0, (1 - erf(standardized)) / 2))
        if percentile > 0.9 { percentile += 0.05 * (percentile - 0.9) }
        return (percentile * 100).rounded(.down) / 100
    }

    /// byte-efficiency-audit.js scoreForWastedMs.
    static func wasted(_ ms: Double) -> Double {
        ms <= 0 ? 1 : ms < 300 ? 0.9 : ms < 750 ? 0.65 : 0
    }

    static func weighted(_ entries: [(Double?, Double)]) -> Double? {
        var total = 0.0, weights = 0.0
        for (score, weight) in entries where weight > 0 {
            guard let score else { continue }
            total += score * weight
            weights += weight
        }
        return weights > 0 ? total / weights : nil
    }
}

// MARK: - The report

struct LighthouseNode: Equatable, Hashable {
    var snippet: String
    var selector: String
    var label: String

    init(snippet: String, selector: String = "", label: String = "") {
        self.snippet = snippet
        self.selector = selector
        self.label = label
    }

    init?(_ raw: Any?) {
        guard let parts = raw as? [Any], let snippet = parts.first as? String else { return nil }
        self.init(snippet: snippet, selector: parts.count > 1 ? parts[1] as? String ?? "" : "",
                  label: parts.count > 2 ? parts[2] as? String ?? "" : "")
    }
}

/// One row of an audit's details.
struct LighthouseItem: Equatable {
    var node: LighthouseNode?
    var url: String?
    var text: String?
    var bytes: Double?
    var ms: Double?
}

struct LighthouseAudit: Equatable, Identifiable {
    enum Display: String {
        case numeric, binary, notApplicable, informative, error
    }

    var id: String
    var score: Double?
    var display: Display
    var value: Double?
    var unit: String?
    var displayValue: String?
    var items: [LighthouseItem] = []
    /// Why it couldn't be measured, or what to know about the result.
    var explanation: String?
    var savingsMs: Double?
    var savingsBytes: Double?

    var entry: LighthouseCatalog.Entry? { LighthouseCatalog.byID[id] }
    var title: String { passed || display == .notApplicable ? entry?.title ?? id : entry?.failureTitle ?? id }
    var passed: Bool { (score ?? 0) >= 0.9 }
    var scored: Bool { (display == .numeric || display == .binary) && score != nil }
}

struct LighthouseReport: Equatable, Identifiable {
    var id = UUID()
    var url: String
    var fetched: Date
    var mode: LighthouseMode
    var form: LighthouseFormFactor
    var categories: [LighthouseCategory]
    var audits: [String: LighthouseAudit]
    var userAgent = ""
    var viewport = CGSize.zero
    var warnings: [String] = []
    var duration: Double = 0

    func score(_ category: LighthouseCategory) -> Double? {
        // Snapshot mode has no load, so no Performance score: Lighthouse
        // shows how many of its audits passed instead.
        if category == .performance, mode != .navigation { return nil }
        return LighthouseScoring.weighted(LighthouseCatalog.refs(category).map { ref in
            let audit = audits[ref.id]
            return (audit?.scored == true ? audit?.score : nil, ref.weight)
        })
    }

    func audits(in category: LighthouseCategory) -> [LighthouseAudit] {
        LighthouseCatalog.refs(category).compactMap { audits[$0.id] }
    }

    func fraction(_ category: LighthouseCategory) -> (passed: Int, total: Int) {
        let scored = audits(in: category).filter(\.scored)
        return (scored.filter(\.passed).count, scored.count)
    }
}

// MARK: - The catalogue

enum LighthouseCatalog {
    struct Ref {
        let category: LighthouseCategory
        let weight: Double
        let group: String
    }

    struct Entry {
        let id: String
        let title: String
        let failureTitle: String
        let description: String
        let refs: [Ref]
        /// Run in Navigation mode only: it needs the load.
        var load = false
    }

    private static func e(_ id: String, _ title: String, _ failure: String, _ description: String,
                          _ refs: [(LighthouseCategory, Double, String)], load: Bool = false) -> Entry {
        Entry(id: id, title: title, failureTitle: failure, description: description,
              refs: refs.map { Ref(category: $0.0, weight: $0.1, group: $0.2) }, load: load)
    }

    static let groups: [String: String] = [
        "metrics": "Metrics", "load-opportunities": "Opportunities", "diagnostics": "Diagnostics",
        "a11y-names-labels": "Names and labels", "a11y-aria": "ARIA", "a11y-color-contrast": "Contrast",
        "a11y-navigation": "Navigation", "a11y-language": "Internationalization and localization",
        "a11y-tables-lists": "Tables and lists", "a11y-best-practices": "Best practices",
        "best-practices-trust-safety": "Trust and Safety", "best-practices-ux": "User Experience",
        "best-practices-browser-compat": "Browser Compatibility", "best-practices-general": "General",
        "seo-mobile": "Mobile Friendly", "seo-content": "Content Best Practices", "seo-crawl": "Crawling and Indexing",
    ]

    static let entries: [Entry] = [
        e("first-contentful-paint", "First Contentful Paint", "First Contentful Paint",
          "First Contentful Paint marks the time at which the first text or image is painted.",
          [(.performance, 10, "metrics")], load: true),
        e("largest-contentful-paint", "Largest Contentful Paint", "Largest Contentful Paint",
          "Largest Contentful Paint marks the time at which the largest text or image is painted.",
          [(.performance, 25, "metrics")], load: true),
        e("total-blocking-time", "Total Blocking Time", "Total Blocking Time",
          "Sum of all time periods between FCP and the end of the load, when task length exceeded 50ms, expressed in milliseconds. Measured here from gaps in a timer loop, as WebKit has no long task entries.",
          [(.performance, 30, "metrics")], load: true),
        e("cumulative-layout-shift", "Cumulative Layout Shift", "Cumulative Layout Shift",
          "Cumulative Layout Shift measures the movement of visible elements within the viewport. Estimated here by comparing element boxes, as WebKit has no layout shift entries.",
          [(.performance, 25, "metrics")], load: true),
        e("speed-index", "Speed Index", "Speed Index",
          "Speed Index shows how quickly the contents of a page are visibly populated.",
          [(.performance, 10, "metrics")], load: true),
        e("render-blocking-resources", "Eliminate render-blocking resources", "Eliminate render-blocking resources",
          "Resources are blocking the first paint of your page. Consider delivering critical JS/CSS inline and deferring all non-critical JS/styles.",
          [(.performance, 0, "load-opportunities")]),
        e("uses-text-compression", "Enable text compression", "Enable text compression",
          "Text-based resources should be served with compression (gzip, deflate or brotli) to minimize total network bytes.",
          [(.performance, 0, "load-opportunities")]),
        e("modern-image-formats", "Serve images in modern formats", "Serve images in modern formats",
          "Image formats like WebP and AVIF often provide better compression than PNG or JPEG, which means faster downloads and less data consumption.",
          [(.performance, 0, "load-opportunities")]),
        e("uses-responsive-images", "Properly size images", "Properly size images",
          "Serve images that are appropriately-sized to save cellular data and improve load time.",
          [(.performance, 0, "load-opportunities")]),
        e("offscreen-images", "Defer offscreen images", "Defer offscreen images",
          "Consider lazy-loading offscreen and hidden images after all critical resources have finished loading to lower time to interactive.",
          [(.performance, 0, "load-opportunities")]),
        e("server-response-time", "Initial server response time was short", "Reduce initial server response time",
          "Keep the server response time for the main document short because all other requests depend on it.",
          [(.performance, 0, "diagnostics")], load: true),
        e("redirects", "Avoid multiple page redirects", "Avoid multiple page redirects",
          "Redirects introduce additional delays before the page can be loaded.",
          [(.performance, 0, "diagnostics")], load: true),
        e("total-byte-weight", "Avoids enormous network payloads", "Avoid enormous network payloads",
          "Large network payloads cost users real money and are highly correlated with long load times.",
          [(.performance, 0, "diagnostics")]),
        e("dom-size", "Avoids an excessive DOM size", "Avoid an excessive DOM size",
          "A large DOM will increase memory usage, cause longer style calculations, and produce costly layout reflows.",
          [(.performance, 0, "diagnostics")]),
        e("unsized-images", "Image elements have explicit `width` and `height`", "Image elements do not have explicit `width` and `height`",
          "Set an explicit width and height on image elements to reduce layout shifts and improve CLS.",
          [(.performance, 0, "diagnostics")]),
        e("lcp-lazy-loaded", "Largest Contentful Paint image was not lazily loaded", "Largest Contentful Paint image was lazily loaded",
          "Above-the-fold images that are lazily loaded render later in the page lifecycle, which can delay the largest contentful paint.",
          [(.performance, 0, "diagnostics")], load: true),

        e("image-alt", "Image elements have `[alt]` attributes", "Image elements do not have `[alt]` attributes",
          "Informative elements should aim for short, descriptive alternate text. Decorative elements can be ignored with an empty alt attribute.",
          [(.accessibility, 10, "a11y-names-labels"), (.seo, 1, "seo-content")]),
        e("input-image-alt", "`<input type=\"image\">` elements have `[alt]` text", "`<input type=\"image\">` elements do not have `[alt]` text",
          "When an image is being used as an `<input>` button, providing alternative text can help screen reader users understand the purpose of the button.",
          [(.accessibility, 10, "a11y-names-labels")]),
        e("button-name", "Buttons have an accessible name", "Buttons do not have an accessible name",
          "When a button doesn't have an accessible name, screen readers announce it as \"button\", making it unusable for users who rely on screen readers.",
          [(.accessibility, 10, "a11y-names-labels")]),
        e("link-name", "Links have a discernible name", "Links do not have a discernible name",
          "Link text (and alternate text for images, when used as links) that is discernible, unique, and focusable improves the navigation experience for screen reader users.",
          [(.accessibility, 7, "a11y-names-labels")]),
        e("label", "Form elements have associated labels", "Form elements do not have associated labels",
          "Labels ensure that form controls are announced properly by assistive technologies, like screen readers.",
          [(.accessibility, 7, "a11y-names-labels")]),
        e("select-name", "Select elements have associated label elements.", "Select elements do not have associated label elements.",
          "Form elements without effective labels can create frustrating experiences for screen reader users.",
          [(.accessibility, 7, "a11y-names-labels")]),
        e("frame-title", "`<frame>` or `<iframe>` elements have a title", "`<frame>` or `<iframe>` elements do not have a title",
          "Screen reader users rely on frame titles to describe the contents of frames.",
          [(.accessibility, 7, "a11y-names-labels")]),
        e("document-title", "Document has a `<title>` element", "Document doesn't have a `<title>` element",
          "The title gives screen reader users an overview of the page, and search engine users rely on it heavily to determine if a page is relevant to their search.",
          [(.accessibility, 7, "a11y-names-labels"), (.seo, 1, "seo-content")]),
        e("aria-valid-attr", "`[aria-*]` attributes are valid and not misspelled", "`[aria-*]` attributes are not valid or misspelled",
          "Assistive technologies, like screen readers, can't interpret ARIA attributes with invalid names.",
          [(.accessibility, 10, "a11y-aria")]),
        e("aria-roles", "`[role]` values are valid", "`[role]` values are not valid",
          "ARIA roles must have valid values in order to perform their intended accessibility functions.",
          [(.accessibility, 7, "a11y-aria")]),
        e("aria-hidden-body", "`[aria-hidden=\"true\"]` is not present on the document `<body>`", "`[aria-hidden=\"true\"]` is present on the document `<body>`",
          "Assistive technologies, like screen readers, work inconsistently when `aria-hidden=\"true\"` is set on the document `<body>`.",
          [(.accessibility, 10, "a11y-aria")]),
        e("duplicate-id-aria", "ARIA IDs are unique", "ARIA IDs are not unique",
          "The value of an ARIA ID must be unique to prevent other instances from being overlooked by assistive technologies.",
          [(.accessibility, 10, "a11y-aria")]),
        e("color-contrast", "Background and foreground colors have a sufficient contrast ratio", "Background and foreground colors do not have a sufficient contrast ratio",
          "Low-contrast text is difficult or impossible for many users to read.",
          [(.accessibility, 7, "a11y-color-contrast")]),
        e("heading-order", "Heading elements appear in a sequentially-descending order", "Heading elements are not in a sequentially-descending order",
          "Properly ordered headings that do not skip levels convey the semantic structure of the page, making it easier to navigate and understand when using assistive technologies.",
          [(.accessibility, 3, "a11y-navigation")]),
        e("tabindex", "No element has a `[tabindex]` value greater than 0", "Some elements have a `[tabindex]` value greater than 0",
          "A value greater than 0 implies an explicit navigation ordering. Although technically valid, this often creates frustrating experiences for users who rely on assistive technologies.",
          [(.accessibility, 7, "a11y-navigation")]),
        e("landmark-one-main", "Document has a main landmark.", "Document does not have a main landmark.",
          "One main landmark helps screen reader users navigate a web page.",
          [(.accessibility, 3, "a11y-best-practices")]),
        e("html-has-lang", "`<html>` element has a `[lang]` attribute", "`<html>` element does not have a `[lang]` attribute",
          "If a page doesn't specify a `lang` attribute, a screen reader assumes that the page is in the default language that the user chose when setting up the screen reader.",
          [(.accessibility, 7, "a11y-language")]),
        e("html-lang-valid", "`<html>` element has a valid value for its `[lang]` attribute", "`<html>` element does not have a valid value for its `[lang]` attribute",
          "Specifying a valid BCP 47 language helps screen readers announce text properly.",
          [(.accessibility, 7, "a11y-language")]),
        e("list", "Lists contain only `<li>` elements and script supporting elements", "Lists do not contain only `<li>` elements and script supporting elements",
          "Screen readers have a specific way of announcing lists. Ensuring proper list structure aids screen reader output.",
          [(.accessibility, 7, "a11y-tables-lists")]),
        e("listitem", "List items (`<li>`) are contained within `<ul>`, `<ol>` or `<menu>` parent elements", "List items (`<li>`) are not contained within `<ul>`, `<ol>` or `<menu>` parent elements",
          "Screen readers require list items (`<li>`) to be contained within a parent `<ul>`, `<ol>` or `<menu>` to be announced properly.",
          [(.accessibility, 7, "a11y-tables-lists")]),
        e("meta-viewport", "`[user-scalable=\"no\"]` is not used in the `<meta name=\"viewport\">` element and the `[maximum-scale]` attribute is not less than 5.",
          "`[user-scalable=\"no\"]` is used in the `<meta name=\"viewport\">` element or the `[maximum-scale]` attribute is less than 5.",
          "Disabling zooming is problematic for users with low vision who rely on screen magnification to properly see the contents of a web page.",
          [(.accessibility, 10, "a11y-best-practices")]),
        e("meta-refresh", "The document does not use `<meta http-equiv=\"refresh\">`", "The document uses `<meta http-equiv=\"refresh\">`",
          "Users do not expect a page to refresh automatically, and doing so will move focus back to the top of the page.",
          [(.accessibility, 10, "a11y-best-practices")]),

        e("is-on-https", "Uses HTTPS", "Does not use HTTPS",
          "All sites should be protected with HTTPS, even ones that don't handle sensitive data.",
          [(.bestPractices, 5, "best-practices-trust-safety")]),
        e("image-aspect-ratio", "Displays images with correct aspect ratio", "Displays images with incorrect aspect ratio",
          "Image display dimensions should match natural aspect ratio.",
          [(.bestPractices, 1, "best-practices-ux")]),
        e("doctype", "Page has the HTML doctype", "Page lacks the HTML doctype, thus triggering quirks-mode",
          "Specifying a doctype prevents the browser from switching to quirks-mode.",
          [(.bestPractices, 1, "best-practices-browser-compat")]),
        e("charset", "Properly defines charset", "Charset declaration is missing or occurs too late in the HTML",
          "A character encoding declaration is required.",
          [(.bestPractices, 1, "best-practices-browser-compat")]),
        e("errors-in-console", "No browser errors logged to the console", "Browser errors were logged to the console",
          "Errors indicate unresolved problems. Counted here from the errors the page threw and the resources that failed to load.",
          [(.bestPractices, 1, "best-practices-general")], load: true),

        e("viewport", "Has a `<meta name=\"viewport\">` tag with `width` or `initial-scale`", "Does not have a `<meta name=\"viewport\">` tag with `width` or `initial-scale`",
          "A `<meta name=\"viewport\">` not only optimizes your app for mobile screen sizes, but also prevents a 300 millisecond delay to user input.",
          [(.seo, 1, "seo-mobile")]),
        e("meta-description", "Document has a meta description", "Document does not have a meta description",
          "Meta descriptions may be included in search results to concisely summarize page content.",
          [(.seo, 1, "seo-content")]),
        e("http-status-code", "Page has successful HTTP status code", "Page has unsuccessful HTTP status code",
          "Pages with unsuccessful HTTP status codes may not be indexed properly.",
          [(.seo, 1, "seo-crawl")]),
        e("link-text", "Links have descriptive text", "Links do not have descriptive text",
          "Descriptive link text helps search engines understand your content.",
          [(.seo, 1, "seo-content")]),
        e("crawlable-anchors", "Links are crawlable", "Links are not crawlable",
          "Search engines may use `href` attributes on links to crawl websites. Ensure that the `href` attribute of anchor elements links to an appropriate destination.",
          [(.seo, 1, "seo-crawl")]),
        e("is-crawlable", "Page isn't blocked from indexing", "Page is blocked from indexing",
          "Search engines are unable to include your pages in search results if they don't have permission to crawl them.",
          [(.seo, 4.043478260869565, "seo-crawl")]),
        e("robots-txt", "robots.txt is valid", "robots.txt is not valid",
          "If your robots.txt file is malformed, crawlers may not be able to understand how you want your website to be crawled or indexed.",
          [(.seo, 1, "seo-crawl")]),
        e("hreflang", "Document has a valid `hreflang`", "Document doesn't have a valid `hreflang`",
          "hreflang links tell search engines what version of a page they should list in search results for a given language or region.",
          [(.seo, 1, "seo-content")]),
        e("canonical", "Document has a valid `rel=canonical`", "Document does not have a valid `rel=canonical`",
          "Canonical links suggest which URL should be shown in search results.",
          [(.seo, 1, "seo-content")]),
    ]

    static let byID: [String: Entry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func refs(_ category: LighthouseCategory) -> [(id: String, weight: Double, group: String)] {
        entries.flatMap { entry in
            entry.refs.filter { $0.category == category }.map { (entry.id, $0.weight, $0.group) }
        }
    }
}

// MARK: - LHR export

/// The report as Lighthouse's result JSON (LHR), for tools that read it.
enum LighthouseJSON {
    static let version = "12.0.0"
    static let note = "Search Developer Tools Lite's own implementation of a subset of Lighthouse's audits, run on WebKit; not Lighthouse itself."

    static func object(_ report: LighthouseReport) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var audits: [String: Any] = [:]
        for (id, audit) in report.audits { audits[id] = object(audit) }
        var categories: [String: Any] = [:]
        for category in report.categories {
            categories[category.rawValue] = [
                "id": category.rawValue, "title": category.title,
                "score": report.score(category).map { $0 as Any } ?? NSNull(),
                "auditRefs": LighthouseCatalog.refs(category).filter { report.audits[$0.id] != nil }
                    .map { ["id": $0.id, "weight": $0.weight, "group": $0.group] as [String: Any] },
            ] as [String: Any]
        }
        return [
            "lighthouseVersion": version,
            "requestedUrl": report.url, "mainDocumentUrl": report.url, "finalDisplayedUrl": report.url, "finalUrl": report.url,
            "fetchTime": iso.string(from: report.fetched),
            "gatherMode": report.mode.rawValue,
            "userAgent": report.userAgent,
            "environment": ["networkUserAgent": report.userAgent, "hostUserAgent": report.userAgent, "benchmarkIndex": 0,
                            "viewport": ["width": report.viewport.width, "height": report.viewport.height]] as [String: Any],
            "runWarnings": [note] + report.warnings,
            "configSettings": ["formFactor": report.form.rawValue, "locale": "en-US", "throttlingMethod": "provided",
                               "onlyCategories": report.categories.map(\.rawValue),
                               "screenEmulation": ["mobile": report.form == .mobile, "width": report.form.size.width,
                                                   "height": report.form.size.height, "disabled": false] as [String: Any]] as [String: Any],
            "audits": audits,
            "categories": categories,
            "categoryGroups": LighthouseCatalog.groups.mapValues { ["title": $0] },
            "timing": ["total": report.duration],
            "i18n": ["rendererFormattedStrings": [String: String]()],
        ]
    }

    static func object(_ audit: LighthouseAudit) -> [String: Any] {
        var out: [String: Any] = [
            "id": audit.id, "title": audit.title, "description": audit.entry?.description ?? "",
            "score": audit.score.map { $0 as Any } ?? NSNull(), "scoreDisplayMode": audit.display.rawValue,
        ]
        if let value = audit.value { out["numericValue"] = value }
        if let unit = audit.unit { out["numericUnit"] = unit }
        if let shown = audit.displayValue { out["displayValue"] = shown }
        if let explanation = audit.explanation { out["explanation"] = explanation }
        if !audit.items.isEmpty {
            var headings: [[String: String]] = []
            let first = audit.items[0]
            if first.node != nil { headings.append(["key": "node", "valueType": "node", "label": "Element"]) }
            if first.url != nil { headings.append(["key": "url", "valueType": "url", "label": "URL"]) }
            if first.text != nil { headings.append(["key": "text", "valueType": "text", "label": ""]) }
            if first.bytes != nil { headings.append(["key": "wastedBytes", "valueType": "bytes", "label": "Size"]) }
            if first.ms != nil { headings.append(["key": "wastedMs", "valueType": "ms", "label": "Time"]) }
            let items: [[String: Any]] = audit.items.map { item in
                var row: [String: Any] = [:]
                if let node = item.node {
                    row["node"] = ["type": "node", "snippet": node.snippet, "selector": node.selector, "nodeLabel": node.label]
                }
                if let url = item.url { row["url"] = url }
                if let text = item.text { row["text"] = text }
                if let bytes = item.bytes { row["wastedBytes"] = bytes }
                if let ms = item.ms { row["wastedMs"] = ms }
                return row
            }
            var details: [String: Any] = ["type": audit.savingsBytes != nil ? "opportunity" : "table", "headings": headings, "items": items]
            if let bytes = audit.savingsBytes { details["overallSavingsBytes"] = bytes; details["overallSavingsMs"] = audit.savingsMs ?? 0 }
            out["details"] = details
        }
        return out
    }

    static func data(_ report: LighthouseReport) -> Data? {
        try? JSONSerialization.data(withJSONObject: object(report), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - Speed Index

/// Speed Index from frames of the page as it loaded, as Speedline works it
/// out: each frame's colour histogram (near-white pixels left out), its
/// progress how far it has come from the first frame's histogram toward the
/// last's, and the index the area above the progress curve, in ms.
enum SpeedIndex {
    struct Frame {
        let time: Double
        let histogram: [[Int]]
    }

    static func histogram(_ image: CGImage) -> [[Int]]? {
        let width = min(image.width, 160)
        let height = max(1, image.height * width / max(1, image.width))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var out = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            if r > 249 && g > 249 && b > 249 { continue }
            out[0][Int(r)] += 1
            out[1][Int(g)] += 1
            out[2][Int(b)] += 1
        }
        return out
    }

    static func progress(_ frame: [[Int]], first: [[Int]], last: [[Int]]) -> Double {
        var total = 0.0
        for channel in 0..<3 {
            var whole = 0, now = 0
            for bin in 0..<256 {
                whole += abs(first[channel][bin] - last[channel][bin])
                now += abs(frame[channel][bin] - last[channel][bin])
            }
            total += whole == 0 ? 1 : max(0, 1 - Double(now) / Double(whole))
        }
        return total / 3
    }

    /// Nil with fewer than two frames.
    static func index(_ frames: [Frame]) -> Double? {
        guard frames.count >= 2, let first = frames.first?.histogram, let last = frames.last?.histogram else { return nil }
        var index = 0.0
        var previous = (time: 0.0, progress: 0.0)
        for frame in frames {
            index += (1 - previous.progress) * max(0, frame.time - previous.time)
            previous = (frame.time, progress(frame.histogram, first: first, last: last))
        }
        return index
    }
}
