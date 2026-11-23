import Foundation

// Search's Lighthouse panel: its report's shape, Lighthouse's scoring and
// the LHR JSON export. Lighthouse itself is a Node program driving the
// Chrome DevTools Protocol and can't run against WebKit, so the audits are
// Search's own implementation of Lighthouse's (DeveloperLighthouseRules.swift,
// over what DeveloperLighthouse-collect.js reads from the page and what the
// Network panel recorded); the categories, weights, score curves and
// report layout follow Lighthouse's so a report reads, and exports, the
// same way. The run itself is DeveloperLighthouseModel.swift.
//
// Sources for the numbers (Lighthouse 10–12, GoogleChrome/lighthouse):
// - core/lib/statistics.js: getLogNormalScore and its erf approximation
//   (Abramowitz & Stegun 7.1.26); core/audits/audit.js computeLogNormalScore
//   (the boost above 0.9 and the floor to two places).
// - core/audits/metrics/*.js: each metric's `options` control points,
//   mobile and desktop (FCP 1800/3000 and 934/1600, SI 3387/5800 and
//   1311/2300, LCP 2500/4000 and 1200/2400, TBT 200/600 and 150/350,
//   CLS 0.1/0.25 for both).
// - core/config/default-config.js: the Performance weights since v10
//   (FCP 10, SI 10, LCP 25, TBT 30, CLS 25), Best practices' and SEO's
//   weights, and the audit groups.
// - Accessibility weights follow Lighthouse 11+'s mapping from axe-core's
//   impact (critical 10, serious 7, moderate 3, minor 1).
// - core/audits/byte-efficiency/byte-efficiency-audit.js: scoreForWastedMs
//   (0 ms → 1, <300 → 0.9, <750 → 0.65, else 0) and the throttled
//   throughput opportunities' milliseconds are estimated at (mobile slow 4G
//   1.6 Mbps, desktop 10 Mbps, core/config/constants.js).

enum DeveloperLighthouseMode: String, CaseIterable, Identifiable, Codable {
    case navigation = "Navigation"
    case timespan = "Timespan"
    case snapshot = "Snapshot"

    var id: Self { self }
    /// LHR's `gatherMode`.
    var gatherMode: String { rawValue.lowercased() }
    var summary: String {
        switch self {
        case .navigation: "Reloads the page and audits it as it loads, as Lighthouse's default mode does."
        case .timespan: "Audits the page over a period of time you choose, while you interact with it."
        case .snapshot: "Audits the page as it is now, without reloading it. No load metrics."
        }
    }

    /// The categories Lighthouse runs in this mode: Accessibility and SEO
    /// look at a page's state, which a timespan doesn't have.
    var categories: [DeveloperLighthouseCategoryID] {
        self == .timespan ? [.performance, .bestPractices] : DeveloperLighthouseCategoryID.allCases
    }
}

enum DeveloperLighthouseFormFactor: String, CaseIterable, Identifiable, Codable {
    case mobile = "Mobile"
    case desktop = "Desktop"

    var id: Self { self }
    var lhr: String { rawValue.lowercased() }

    /// Lighthouse's screen emulation (core/config/constants.js): a Moto G
    /// Power for mobile, 1350×940 at 1× for desktop.
    var width: Int { self == .mobile ? 412 : 1350 }
    var height: Int { self == .mobile ? 823 : 940 }
    var deviceScaleFactor: Double { self == .mobile ? 1.75 : 1 }
    /// Lighthouse's throttled throughput, in kilobits a second, that an
    /// opportunity's byte savings are turned into milliseconds at.
    var throughputKbps: Double { self == .mobile ? 1_638.4 : 10_240 }
}

enum DeveloperLighthouseCategoryID: String, CaseIterable, Identifiable, Codable {
    case performance
    case accessibility
    case bestPractices = "best-practices"
    case seo

    var id: Self { self }

    var title: String {
        switch self {
        case .performance: "Performance"
        case .accessibility: "Accessibility"
        case .bestPractices: "Best practices"
        case .seo: "SEO"
        }
    }

    var description: String {
        switch self {
        case .performance: "Values are estimated and may vary. The performance score is calculated directly from these metrics."
        case .accessibility: "These checks highlight opportunities to improve the accessibility of your web app. Automatic detection can only detect a subset of issues and does not guarantee the accessibility of your web app."
        case .bestPractices: "These checks look at the page's security and modern web development practices."
        case .seo: "These checks ensure that your page is following basic search engine optimization advice."
        }
    }
}

/// The five metrics the Performance score is made of.
enum DeveloperLighthouseMetric: String, CaseIterable, Identifiable {
    case firstContentfulPaint = "first-contentful-paint"
    case largestContentfulPaint = "largest-contentful-paint"
    case totalBlockingTime = "total-blocking-time"
    case cumulativeLayoutShift = "cumulative-layout-shift"
    case speedIndex = "speed-index"
    /// Timespan mode's responsiveness metric, in place of the load metrics.
    case interactionToNextPaint = "interaction-to-next-paint"

    var id: Self { self }

    var title: String {
        switch self {
        case .firstContentfulPaint: "First Contentful Paint"
        case .largestContentfulPaint: "Largest Contentful Paint"
        case .totalBlockingTime: "Total Blocking Time"
        case .cumulativeLayoutShift: "Cumulative Layout Shift"
        case .speedIndex: "Speed Index"
        case .interactionToNextPaint: "Interaction to Next Paint"
        }
    }

    var acronym: String {
        switch self {
        case .firstContentfulPaint: "FCP"
        case .largestContentfulPaint: "LCP"
        case .totalBlockingTime: "TBT"
        case .cumulativeLayoutShift: "CLS"
        case .speedIndex: "SI"
        case .interactionToNextPaint: "INP"
        }
    }

    /// The Performance category's weights since Lighthouse 10 (INP's is 0:
    /// it is only measured in Timespan mode, which has no score).
    var weight: Double {
        switch self {
        case .firstContentfulPaint, .speedIndex: 10
        case .largestContentfulPaint, .cumulativeLayoutShift: 25
        case .totalBlockingTime: 30
        case .interactionToNextPaint: 0
        }
    }

    var unitless: Bool { self == .cumulativeLayoutShift }
}

// MARK: Scoring

enum DeveloperLighthouseScoring {
    struct Curve: Equatable {
        var p10: Double
        var median: Double
    }

    /// Each metric's control points, from its audit's `options`.
    static func curve(_ metric: DeveloperLighthouseMetric, _ formFactor: DeveloperLighthouseFormFactor) -> Curve {
        let mobile = formFactor == .mobile
        switch metric {
        case .firstContentfulPaint: return mobile ? Curve(p10: 1_800, median: 3_000) : Curve(p10: 934, median: 1_600)
        case .speedIndex: return mobile ? Curve(p10: 3_387, median: 5_800) : Curve(p10: 1_311, median: 2_300)
        case .largestContentfulPaint: return mobile ? Curve(p10: 2_500, median: 4_000) : Curve(p10: 1_200, median: 2_400)
        case .totalBlockingTime: return mobile ? Curve(p10: 200, median: 600) : Curve(p10: 150, median: 350)
        case .cumulativeLayoutShift: return Curve(p10: 0.1, median: 0.25)
        // interaction-to-next-paint.js: the same for mobile and desktop.
        case .interactionToNextPaint: return Curve(p10: 200, median: 500)
        }
    }

    /// Lighthouse's erf: Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7).
    static func erf(_ x: Double) -> Double {
        // Math.sign, as Lighthouse has it: erf(0) is exactly 0, so the median scores exactly 0.5.
        let sign: Double = x > 0 ? 1 : (x < 0 ? -1 : 0)
        let value = abs(x)
        let a1 = 0.254829592, a2 = -0.284496736, a3 = 1.421413741, a4 = -1.453152027, a5 = 1.061405429
        let p = 0.3275911
        let t = 1 / (1 + p * value)
        let y = t * (a1 + t * (a2 + t * (a3 + t * (a4 + t * a5))))
        return sign * (1 - y * exp(-value * value))
    }

    /// statistics.js getLogNormalScore: the share of a log-normal
    /// distribution (with this median, and 10% of values under p10) above
    /// `value`. 0.5 at the median, 0.9 at p10.
    static func logNormal(_ value: Double, _ curve: Curve) -> Double {
        guard curve.median > 0, curve.p10 > 0, curve.p10 < curve.median else { return 0 }
        guard value > 0 else { return 1 }
        let inverseErfcOneFifth = 0.9061938024368232
        let xLogRatio = log(max(Double.leastNonzeroMagnitude, value / curve.median))
        let p10LogRatio = -log(max(Double.leastNonzeroMagnitude, curve.p10 / curve.median))
        let standardized = xLogRatio * inverseErfcOneFifth / p10LogRatio
        let score = (1 - erf(standardized)) / 2
        return min(1, max(0, score))
    }

    /// audit.js computeLogNormalScore: scores above 0.9 nudged up (so 0.99
    /// isn't shown as 1), then floored to two places.
    static func score(_ value: Double, _ curve: Curve) -> Double {
        var percentile = logNormal(value, curve)
        if percentile > 0.9 { percentile += 0.05 * (percentile - 0.9) }
        return (percentile * 100).rounded(.down) / 100
    }

    static func score(_ metric: DeveloperLighthouseMetric, value: Double,
                      _ formFactor: DeveloperLighthouseFormFactor) -> Double {
        score(value, curve(metric, formFactor))
    }

    /// The weighted mean of the scored entries; entries without a score
    /// (not applicable, informative, unmeasured) drop out and the others'
    /// weights are re-normalised over what's left. Nil when nothing with
    /// weight is left.
    static func weightedMean(_ entries: [(score: Double?, weight: Double)]) -> Double? {
        var total = 0.0
        var weights = 0.0
        for entry in entries {
            guard let score = entry.score, entry.weight > 0 else { continue }
            total += score * entry.weight
            weights += entry.weight
        }
        guard weights > 0 else { return nil }
        return total / weights
    }

    /// byte-efficiency-audit.js scoreForWastedMs.
    static func scoreForWastedMs(_ wasted: Double) -> Double {
        if wasted <= 0 { return 1 }
        if wasted < 300 { return 0.9 }
        if wasted < 750 { return 0.65 }
        return 0
    }

    /// Bytes as the milliseconds they take at Lighthouse's throttled throughput.
    static func milliseconds(forBytes bytes: Double, _ formFactor: DeveloperLighthouseFormFactor) -> Double {
        guard bytes > 0 else { return 0 }
        return bytes * 8 / formFactor.throughputKbps
    }

    enum Rating: String {
        case fail, average, pass
    }

    /// Lighthouse's colours: 0–49 red, 50–89 orange, 90–100 green.
    static func rating(_ score: Double) -> Rating {
        let shown = (score * 100).rounded()
        if shown >= 90 { return .pass }
        if shown >= 50 { return .average }
        return .fail
    }
}

// MARK: The report

/// One value in an audit's details table.
enum DeveloperLighthouseValue: Equatable {
    case text(String)
    case url(String)
    case code(String)
    case bytes(Double)
    case ms(Double)
    case numeric(Double)
    case node(DeveloperLighthouseNode)

    var valueType: String {
        switch self {
        case .text: "text"
        case .url: "url"
        case .code: "code"
        case .bytes: "bytes"
        case .ms: "ms"
        case .numeric: "numeric"
        case .node: "node"
        }
    }
}

/// An element the page script found, by its index in the scan's holder
/// (for highlight and reveal) and as Lighthouse shows a node.
struct DeveloperLighthouseNode: Equatable, Hashable {
    var index: Int
    var snippet: String
    var selector: String
    var label: String

    init(index: Int, snippet: String = "", selector: String = "", label: String = "") {
        self.index = index
        self.snippet = snippet
        self.selector = selector
        self.label = label
    }

    /// `[index, snippet, selector, label]`, as the page script sends one.
    init?(_ raw: Any?) {
        guard let parts = raw as? [Any], let index = (parts.first as? NSNumber)?.intValue else { return nil }
        func text(_ at: Int) -> String { parts.count > at ? parts[at] as? String ?? "" : "" }
        self.init(index: index, snippet: text(1), selector: text(2), label: text(3))
    }
}

struct DeveloperLighthouseDetails: Equatable {
    enum Kind: String {
        case table, opportunity
    }

    struct Heading: Equatable {
        var key: String
        var label: String
        var valueType: String
    }

    var kind: Kind
    var headings: [Heading]
    var items: [[String: DeveloperLighthouseValue]]
    var overallSavingsMs: Double?
    var overallSavingsBytes: Double?

    init(_ kind: Kind = .table, headings: [Heading], items: [[String: DeveloperLighthouseValue]],
         savingsMs: Double? = nil, savingsBytes: Double? = nil) {
        self.kind = kind
        self.headings = headings
        self.items = items
        overallSavingsMs = savingsMs
        overallSavingsBytes = savingsBytes
    }

    static func nodes(_ nodes: [DeveloperLighthouseNode], label: String = "Failing Elements",
                      extra: [(key: String, label: String, values: [DeveloperLighthouseValue])] = []) -> DeveloperLighthouseDetails {
        var headings = [Heading(key: "node", label: label, valueType: "node")]
        for column in extra { headings.append(Heading(key: column.key, label: column.label, valueType: column.values.first?.valueType ?? "text")) }
        let items = nodes.enumerated().map { offset, node -> [String: DeveloperLighthouseValue] in
            var item: [String: DeveloperLighthouseValue] = ["node": .node(node)]
            for column in extra where offset < column.values.count { item[column.key] = column.values[offset] }
            return item
        }
        return DeveloperLighthouseDetails(headings: headings, items: items)
    }
}

struct DeveloperLighthouseAudit: Equatable, Identifiable {
    /// LHR's scoreDisplayMode.
    enum Mode: String {
        case numeric, binary, notApplicable, informative, manual, error
    }

    var id: String
    var title: String
    var description: String
    var score: Double?
    var mode: Mode
    var numericValue: Double?
    var numericUnit: String?
    var displayValue: String?
    var details: DeveloperLighthouseDetails?
    var warnings: [String] = []
    /// Why it's not applicable or couldn't be measured, shown in its place.
    var explanation: String?

    /// Lighthouse lists an audit as passed at 0.9 and up.
    var passed: Bool { score.map { $0 >= 0.9 } ?? false }
    var scored: Bool { (mode == .numeric || mode == .binary) && score != nil }
}

struct DeveloperLighthouseAuditRef: Equatable {
    var id: String
    var weight: Double
    var group: String?
}

struct DeveloperLighthouseCategory: Equatable, Identifiable {
    var id: DeveloperLighthouseCategoryID
    var refs: [DeveloperLighthouseAuditRef]
    var score: Double?

    var title: String { id.title }
}

struct DeveloperLighthouseReport: Equatable, Identifiable {
    var id = UUID()
    var requestedURL: String
    var finalURL: String
    var fetchTime: Date
    var mode: DeveloperLighthouseMode
    var formFactor: DeveloperLighthouseFormFactor
    var categories: [DeveloperLighthouseCategory]
    var audits: [String: DeveloperLighthouseAudit]
    var warnings: [String] = []
    var userAgent = ""
    /// How the page was shown: the emulated screen, or the window's own.
    var emulation = ""
    var totalTime: Double = 0
    /// How the load metrics were throttled, and Lantern's estimates when simulated.
    var throttling = DeveloperLighthouseThrottling.none
    var simulation: DeveloperLighthouseLantern.Estimates?
    /// The page's JavaScript by script and source-map module, for View treemap.
    var treemap: [DeveloperLighthouseTreemap.Node] = []
    /// The viewport the page actually had (innerWidth × innerHeight, CSS
    /// px) and its device pixel ratio: what visual metrics such as Speed
    /// Index and CLS depend on, set beside the emulated screen.
    var viewport: Viewport?

    struct Viewport: Equatable {
        var width: Double
        var height: Double
        var devicePixelRatio: Double

        var summary: String {
            let sizeFormat = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0))
            return "\(width.rounded().formatted(sizeFormat))×\(height.rounded().formatted(sizeFormat)) CSS px at \(devicePixelRatio.formatted())×"
        }
    }

    func audit(_ id: String) -> DeveloperLighthouseAudit? { audits[id] }

    func category(_ id: DeveloperLighthouseCategoryID) -> DeveloperLighthouseCategory? {
        categories.first { $0.id == id }
    }

    /// In Snapshot mode, as in Lighthouse, Performance shows how many of
    /// its audits passed instead of a score.
    func fraction(_ category: DeveloperLighthouseCategory) -> (passed: Int, total: Int) {
        let scored = category.refs.compactMap { audits[$0.id] }.filter(\.scored)
        return (scored.filter(\.passed).count, scored.count)
    }

    var title: String {
        let host = URL(string: finalURL)?.host() ?? finalURL
        return host + " · " + fetchTime.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: The catalogue

/// Every audit the panel runs: its category, weight and group in the
/// category as default-config.js has them, and its titles.
enum DeveloperLighthouseCatalog {
    struct Entry {
        var id: String
        var categories: [(DeveloperLighthouseCategoryID, weight: Double, group: String?)]
        var title: String
        var failureTitle: String
        var description: String
    }

    /// The audits Lighthouse runs over a timespan (their `supportedModes`
    /// include "timespan"): the responsiveness metrics, the byte-efficiency
    /// opportunities and diagnostics over the requests made during it, and
    /// the Best practices audits that read the console, the Issues tool and
    /// the requests.
    static let timespanAudits: Set<String> = [
        "total-blocking-time", "cumulative-layout-shift", "interaction-to-next-paint",
        "uses-responsive-images", "modern-image-formats", "uses-text-compression", "uses-long-cache-ttl",
        "total-byte-weight", "is-on-https", "errors-in-console", "deprecations", "inspector-issues",
    ]

    /// Whether Lighthouse runs the audit in the mode.
    static func supports(_ id: String, _ mode: DeveloperLighthouseMode) -> Bool {
        switch mode {
        case .timespan: return timespanAudits.contains(id)
        case .navigation, .snapshot: return id != DeveloperLighthouseMetric.interactionToNextPaint.rawValue
        }
    }

    static let groups: [String: (title: String, description: String?)] = [
        "metrics": ("Metrics", nil),
        "load-opportunities": ("Opportunities", "These suggestions can help your page load faster. They don't directly affect the Performance score."),
        "diagnostics": ("Diagnostics", "More information about the performance of your application. These numbers don't directly affect the Performance score."),
        "a11y-names-labels": ("Names and labels", "These are opportunities to improve the semantics of the controls in your application."),
        "a11y-aria": ("ARIA", "These are opportunities to improve the usage of ARIA in your application."),
        "a11y-color-contrast": ("Contrast", "These are opportunities to improve the legibility of your content."),
        "a11y-navigation": ("Navigation", "These are opportunities to improve keyboard navigation in your application."),
        "a11y-language": ("Internationalization and localization", "These are opportunities to improve the interpretation of your content by users in different locales."),
        "a11y-tables-lists": ("Tables and lists", "These are opportunities to improve the experience of reading tabular or list data using assistive technology."),
        "a11y-best-practices": ("Best practices", "These items highlight common accessibility best practices."),
        "best-practices-trust-safety": ("Trust and Safety", nil),
        "best-practices-ux": ("User Experience", nil),
        "best-practices-browser-compat": ("Browser Compatibility", nil),
        "best-practices-general": ("General", nil),
        "seo-mobile": ("Mobile Friendly", "Make sure your pages are mobile friendly so users don't have to pinch or zoom in order to read the content pages."),
        "seo-content": ("Content Best Practices", "Format your HTML in a way that enables crawlers to better understand your app's content."),
        "seo-crawl": ("Crawling and Indexing", "To appear in search results, crawlers need access to your app."),
    ]

    /// The audits after the metrics, in Resources/data/DeveloperLighthouse-audits.json
    /// (build.sh copies it into the app), read the first time the catalogue is.
    static let auditsFileName = "DeveloperLighthouse-audits.json"

    private struct StoredEntry: Decodable {
        struct Category: Decodable {
            let category: DeveloperLighthouseCategoryID
            let weight: Double
            let group: String?
        }
        let id: String
        let categories: [Category]
        let title: String
        let failureTitle: String
        let description: String
    }

    private static func loadAudits() -> [Entry] {
        let stored: [StoredEntry] = DeveloperMeasure.bundled([StoredEntry].self, named: auditsFileName) ?? []
        return stored.map { (entry: StoredEntry) -> Entry in
            Entry(id: entry.id, categories: entry.categories.map { ($0.category, weight: $0.weight, group: $0.group) },
                  title: entry.title, failureTitle: entry.failureTitle, description: entry.description)
        }
    }

    static let entries: [Entry] = {
        var list: [Entry] = DeveloperLighthouseMetric.allCases.map { metric in
            Entry(id: metric.rawValue, categories: [(.performance, metric.weight, "metrics")],
                  title: metric.title, failureTitle: metric.title, description: metricDescription(metric))
        }
        list += loadAudits()
        return list
    }()

    static let byID: [String: Entry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func metricDescription(_ metric: DeveloperLighthouseMetric) -> String {
        switch metric {
        case .firstContentfulPaint: "First Contentful Paint marks the time at which the first text or image is painted."
        case .largestContentfulPaint: "Largest Contentful Paint marks the time at which the largest text or image is painted."
        case .totalBlockingTime: "Sum of all time periods between FCP and the end of the run, when task length exceeded 50ms, expressed in milliseconds."
        case .cumulativeLayoutShift: "Cumulative Layout Shift measures the movement of visible elements within the viewport."
        case .speedIndex: "Speed Index shows how quickly the contents of a page are visibly populated."
        case .interactionToNextPaint: "Interaction to Next Paint measures page responsiveness, how long it takes the page to visibly respond to user input."
        }
    }

    /// A category's audit refs in a mode, in the catalogue's order.
    static func refs(_ category: DeveloperLighthouseCategoryID,
                     mode: DeveloperLighthouseMode = .navigation) -> [DeveloperLighthouseAuditRef] {
        entries.filter { supports($0.id, mode) }.flatMap { entry in
            entry.categories.filter { $0.0 == category }.map { DeveloperLighthouseAuditRef(id: entry.id, weight: $0.weight, group: $0.group) }
        }
    }

    /// The categories with their scores over these audits.
    static func categories(_ ids: [DeveloperLighthouseCategoryID], audits: [String: DeveloperLighthouseAudit],
                           mode: DeveloperLighthouseMode) -> [DeveloperLighthouseCategory] {
        ids.filter { mode.categories.contains($0) }.map { id in
            let refs = refs(id, mode: mode)
            var score = DeveloperLighthouseScoring.weightedMean(refs.map { ref -> (score: Double?, weight: Double) in
                let audit = audits[ref.id]
                return (audit?.scored == true ? audit?.score : nil, ref.weight)
            })
            // Snapshot and Timespan modes have no load metrics, so no
            // Performance score; the fraction of passed audits is shown instead.
            if id == .performance, mode != .navigation { score = nil }
            return DeveloperLighthouseCategory(id: id, refs: refs, score: score)
        }
    }
}

// MARK: LHR export

/// The report as Lighthouse's result JSON (LHR), so it opens in Lighthouse
/// Viewer and other LHR tools where they accept it.
enum DeveloperLighthouseLHR {
    static let version = "12.0.0"
    static let note = "Search's own implementation of Lighthouse's audits, run on WebKit; not Lighthouse itself."

    /// Lighthouse's environment, plus the viewport the page really had
    /// (Search's own key: Lighthouse keeps it in its artifacts, not the LHR).
    static func environment(_ report: DeveloperLighthouseReport) -> [String: Any] {
        var out: [String: Any] = ["networkUserAgent": report.userAgent, "hostUserAgent": report.userAgent, "benchmarkIndex": 0]
        if let viewport = report.viewport {
            out["viewport"] = ["width": viewport.width, "height": viewport.height, "devicePixelRatio": viewport.devicePixelRatio]
        }
        return out
    }

    static func object(_ report: DeveloperLighthouseReport) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var audits: [String: Any] = [:]
        for (id, audit) in report.audits { audits[id] = object(audit) }
        var categories: [String: Any] = [:]
        for category in report.categories {
            var refs: [[String: Any]] = []
            for ref in category.refs {
                var entry: [String: Any] = ["id": ref.id, "weight": ref.weight]
                if let group = ref.group { entry["group"] = group }
                if let acronym = DeveloperLighthouseMetric(rawValue: ref.id)?.acronym { entry["acronym"] = acronym }
                refs.append(entry)
            }
            let entry: [String: Any] = [
                "id": category.id.rawValue, "title": category.title, "description": category.id.description,
                "score": category.score.map { $0 as Any } ?? NSNull(),
                "supportedModes": DeveloperLighthouseMode.allCases.filter { $0.categories.contains(category.id) }.map(\.gatherMode),
                "auditRefs": refs,
            ]
            categories[category.id.rawValue] = entry
        }
        var groups: [String: Any] = [:]
        for (id, group) in DeveloperLighthouseCatalog.groups {
            var entry: [String: Any] = ["title": group.title]
            if let description = group.description { entry["description"] = description }
            groups[id] = entry
        }
        let ff = report.formFactor
        return [
            "lighthouseVersion": version,
            "requestedUrl": report.requestedURL,
            "mainDocumentUrl": report.finalURL,
            "finalDisplayedUrl": report.finalURL,
            "finalUrl": report.finalURL,
            "fetchTime": iso.string(from: report.fetchTime),
            "gatherMode": report.mode.gatherMode,
            "userAgent": report.userAgent,
            "environment": environment(report),
            "runWarnings": [note] + report.warnings,
            "configSettings": [
                "formFactor": ff.lhr, "locale": "en-US", "channel": "perch-devtools",
                "onlyCategories": report.categories.map(\.id.rawValue),
                "throttlingMethod": report.throttling.lhr,
                "throttling": throttling(report),
                "screenEmulation": ["mobile": ff == .mobile, "width": ff.width, "height": ff.height,
                                    "deviceScaleFactor": ff.deviceScaleFactor, "disabled": report.mode != .navigation] as [String: Any],
                "emulatedUserAgent": report.userAgent,
            ] as [String: Any],
            "audits": audits,
            "categories": categories,
            "categoryGroups": groups,
            "timing": ["total": report.totalTime],
            "i18n": ["rendererFormattedStrings": [String: String]()],
            "stackPacks": [Any](),
        ]
    }

    /// configSettings.throttling: Lighthouse's settings for the form factor
    /// (constants.js), or none when the run wasn't throttled.
    static func throttling(_ report: DeveloperLighthouseReport) -> [String: Any] {
        guard report.throttling != .none else {
            return ["rttMs": 0, "throughputKbps": 0, "cpuSlowdownMultiplier": 1,
                    "requestLatencyMs": 0, "downloadThroughputKbps": 0, "uploadThroughputKbps": 0]
        }
        let settings = DeveloperLighthouseLantern.Settings.lighthouse(report.formFactor)
        let mobile = report.formFactor == .mobile
        return [
            "rttMs": settings.rttMs, "throughputKbps": settings.throughputKbps,
            // DevTools throttling can't slow WebKit's CPU.
            "cpuSlowdownMultiplier": report.throttling == .simulated ? settings.cpuSlowdownMultiplier : 1,
            "requestLatencyMs": mobile ? 150 * 3.75 : 0, "downloadThroughputKbps": mobile ? 1.6 * 1_024 * 0.9 : 0,
            "uploadThroughputKbps": mobile ? 750 * 0.9 : 0,
        ]
    }

    static func object(_ audit: DeveloperLighthouseAudit) -> [String: Any] {
        var out: [String: Any] = [
            "id": audit.id, "title": audit.title, "description": audit.description,
            "score": audit.score.map { $0 as Any } ?? NSNull(),
            "scoreDisplayMode": audit.mode.rawValue,
        ]
        if let value = audit.numericValue { out["numericValue"] = value }
        if let unit = audit.numericUnit { out["numericUnit"] = unit }
        if let display = audit.displayValue { out["displayValue"] = display }
        if let explanation = audit.explanation { out["explanation"] = explanation }
        if !audit.warnings.isEmpty { out["warnings"] = audit.warnings }
        if let details = audit.details { out["details"] = object(details) }
        return out
    }

    static func object(_ details: DeveloperLighthouseDetails) -> [String: Any] {
        var out: [String: Any] = [
            "type": details.kind.rawValue,
            "headings": details.headings.map { ["key": $0.key, "label": $0.label, "valueType": $0.valueType] },
            "items": details.items.map { item in item.mapValues(Self.value) },
        ]
        if details.kind == .opportunity {
            out["overallSavingsMs"] = details.overallSavingsMs ?? 0
            out["overallSavingsBytes"] = details.overallSavingsBytes ?? 0
        }
        return out
    }

    static func value(_ value: DeveloperLighthouseValue) -> Any {
        switch value {
        case .text(let text), .url(let text):
            return text
        case .code(let text):
            return ["type": "code", "value": text]
        case .bytes(let number), .ms(let number), .numeric(let number):
            return number
        case .node(let node):
            let out: [String: Any] = [
                "type": "node", "lhId": "page-\(node.index)", "snippet": node.snippet,
                "selector": node.selector, "nodeLabel": node.label, "path": "",
            ]
            return out
        }
    }

    static func data(_ report: DeveloperLighthouseReport) -> Data? {
        try? JSONSerialization.data(withJSONObject: object(report), options: [.prettyPrinted, .sortedKeys])
    }
}
