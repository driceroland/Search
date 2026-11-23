import Foundation

// What the Lighthouse panel audits: the page as DeveloperLighthouse-collect.js
// read it, the requests the Network panel recorded, the load metrics the
// observer script measured, and the Console's and Issues' findings. Plain
// values, so the rules (DeveloperLighthouseRules.swift) can be tested
// without a page.

struct DeveloperLighthousePage: Equatable {
    struct Doctype: Equatable {
        var name: String
        var publicID: String
        var systemID: String
    }

    struct Image: Equatable {
        var node: DeveloperLighthouseNode
        var src: String
        var naturalWidth: Double
        var naturalHeight: Double
        var displayedWidth: Double
        var displayedHeight: Double
        /// The `alt` attribute; nil when there's none.
        var alt: String?
        var role: String?
        var name = ""
        var widthAttribute = false
        var heightAttribute = false
        /// Sized by its inline style or an aspect-ratio with one dimension set.
        var cssSized = false
        var position = "static"
        var objectFit = "fill"
        var pixelated = false
        var visible = true
        var ariaHidden = false
        var inViewport = false
        /// Its box in the document scrolled to the top: top, left, bottom,
        /// right; nil when the page script didn't say.
        var documentRect: [Double]? = nil
        /// `loading="lazy"`.
        var lazy = false

        var isSVG: Bool {
            let lower = src.lowercased()
            return lower.hasPrefix("data:image/svg") || lower.split(separator: "?").first?.hasSuffix(".svg") == true
        }
        var presentational: Bool { ["none", "presentation"].contains(role?.lowercased() ?? "") }
    }

    /// A control and its accessible name, as the page script worked it out.
    struct Named: Equatable {
        var node: DeveloperLighthouseNode
        var name: String
        var role: String? = nil
    }

    struct Link: Equatable {
        var node: DeveloperLighthouseNode
        var name: String
        var text: String
        /// The `href` attribute as written; nil when there's none.
        var rawHref: String?
        /// The resolved URL.
        var href: String = ""
        var role: String? = nil
        var onclick = false
        var nameAttribute = false
        var visible = true
        var tag = "a"
    }

    struct Heading: Equatable {
        var node: DeveloperLighthouseNode
        var level: Int
    }

    struct Aria: Equatable {
        var node: DeveloperLighthouseNode
        var tag: String
        var role: String?
        var attributes: [String]
        var native = false
        /// The element's implicit ARIA role where the page script knows it
        /// ("generic" for a div or span); nil when it doesn't.
        var implicitRole: String? = nil
    }

    /// A control a pointer or finger activates, and its box in the viewport.
    struct Target: Equatable {
        var node: DeveloperLighthouseNode
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// A table cell with a `headers` attribute: the ids it names, those of
    /// them that are cells of its own table, and its own id.
    struct HeadersCell: Equatable {
        var node: DeveloperLighthouseNode
        var headers: [String]
        var found: [String]
        var id = ""
    }

    /// An element other than `<html>` with a `lang` (or `xml:lang`).
    struct Lang: Equatable {
        var node: DeveloperLighthouseNode
        var lang: String
    }

    struct MetaRefresh: Equatable {
        var node: DeveloperLighthouseNode
        var content: String
    }

    /// An `@font-face` the page script could read: its family, its
    /// `font-display` ("" when unset) and its sources' URLs, resolved.
    struct FontFace: Equatable {
        var family: String
        var display: String
        var urls: [String]
    }

    /// A call to a permission API the page made, and where from.
    struct PermissionCall: Equatable {
        enum API: String { case geolocation, notification }
        var api: API
        var url: String
        var line: Int
        var column: Int
        /// Made while the page had a user gesture (navigator.userActivation).
        var gesture = false
    }

    struct TabIndex: Equatable {
        var node: DeveloperLighthouseNode
        var value: Int
    }

    struct ListElement: Equatable {
        var node: DeveloperLighthouseNode
        /// Each element child's tag and role.
        var children: [(tag: String, role: String?)]

        static func == (a: Self, b: Self) -> Bool {
            a.node == b.node && a.children.map { $0.tag } == b.children.map { $0.tag } && a.children.map { $0.role } == b.children.map { $0.role }
        }
    }

    struct ListItem: Equatable {
        var node: DeveloperLighthouseNode
        var parentTag: String
        var parentRole: String?
        var role: String? = nil
    }

    struct DuplicateID: Equatable {
        var id: String
        var referenced: Bool
        var nodes: [DeveloperLighthouseNode]
    }

    /// Text and what's behind it: its colour, and the background colours
    /// from it up to the root; nil when a background image is in the way.
    struct Text: Equatable {
        var node: DeveloperLighthouseNode
        var color: String
        var backgrounds: [String]?
        var fontSize: String
        var fontWeight: String
    }

    struct HeadResource: Equatable {
        enum Kind: String { case script, stylesheet }
        var node: DeveloperLighthouseNode
        var kind: Kind
        var url: String
        var async = false
        var deferred = false
        var module = false
        var mediaMatches = true
        var disabled = false
    }

    /// One Resource Timing entry, in the page's own clock (ms since navigation start).
    struct Timing: Equatable {
        var url: String
        var initiatorType: String
        var startTime: Double
        var responseEnd: Double
        var transferSize: Double
        var encodedBodySize: Double
        var decodedBodySize: Double
        var renderBlockingStatus: String?
    }

    struct DOMStats: Equatable {
        var elements = 0
        var depth = 0
        var depthNode: DeveloperLighthouseNode?
        var widestChildren = 0
        var widestNode: DeveloperLighthouseNode?
    }

    var url = ""
    /// The `<title>`'s text; nil when there's no title element.
    var title: String?
    var lang: String?
    var xmlLang: String?
    var doctype: Doctype?
    var compatMode = "CSS1Compat"
    var characterSet = "UTF-8"
    var charsetMeta = false
    var viewport: String?
    var metaDescription: String?
    var robots: [String] = []
    /// `rel=canonical` hrefs as written, and resolved.
    var canonicals: [(raw: String, resolved: String)] = []
    var hreflangs: [(lang: String, raw: String, resolved: String)] = []
    var images: [Image] = []
    var inputImages: [Named] = []
    var buttons: [Named] = []
    var fields: [Named] = []
    var frames: [Named] = []
    var links: [Link] = []
    var headings: [Heading] = []
    var aria: [Aria] = []
    var tabIndexes: [TabIndex] = []
    var lists: [ListElement] = []
    var listItems: [ListItem] = []
    var duplicateIDs: [DuplicateID] = []
    var texts: [Text] = []
    var headResources: [HeadResource] = []
    var timings: [Timing] = []
    var dom = DOMStats()
    var devicePixelRatio = 1.0
    var viewportWidth = 0.0
    var viewportHeight = 0.0
    /// `<select>`s and their names (select-name; `fields` leaves them out).
    var selects: [Named] = []
    /// Visible `main` landmarks (`<main>`, `[role=main]`).
    var mainLandmarks = 0
    /// Whether `<body>` has `aria-hidden="true"`, and the body.
    var bodyAriaHidden = false
    var bodyNode: DeveloperLighthouseNode?
    var targets: [Target] = []
    var headersCells: [HeadersCell] = []
    var langs: [Lang] = []
    var metaRefreshes: [MetaRefresh] = []
    var fontFaces: [FontFace] = []
    /// Stylesheets whose rules the page can't read (other origins).
    var unreadableStyleSheets = 0
    /// `<link rel=preconnect>` and `rel=dns-prefetch` hrefs, resolved.
    var preconnects: [String] = []
    /// `<meta http-equiv="Content-Security-Policy">` contents.
    var metaCSPs: [String] = []
    /// Inputs and text areas whose `paste` event the page cancels.
    var pasteBlocked: [DeveloperLighthouseNode] = []
    /// Calls to the geolocation and notification permission APIs; nil when
    /// they weren't watched (only a Navigation run watches from the start).
    var permissionCalls: [PermissionCall]?

    static func ==(a: Self, b: Self) -> Bool {
        a.url == b.url && a.title == b.title && a.images == b.images && a.links == b.links && a.texts == b.texts
            && a.canonicals.map { $0.raw } == b.canonicals.map { $0.raw } && a.hreflangs.map { $0.raw } == b.hreflangs.map { $0.raw }
            && a.dom == b.dom && a.aria == b.aria
    }
}

// MARK: Reading the page script's answer

extension DeveloperLighthousePage {
    init(_ raw: [String: Any]) {
        func string(_ value: Any?) -> String? { value as? String }
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }
        func list(_ key: String) -> [[String: Any]] { raw[key] as? [[String: Any]] ?? [] }
        func node(_ item: [String: Any]) -> DeveloperLighthouseNode { DeveloperLighthouseNode(item["n"]) ?? DeveloperLighthouseNode(index: -1) }
        func named(_ key: String) -> [Named] {
            list(key).map { Named(node: node($0), name: string($0["name"]) ?? "", role: string($0["role"])) }
        }

        url = string(raw["url"]) ?? ""
        title = string(raw["title"])
        lang = string(raw["lang"])
        xmlLang = string(raw["xmlLang"])
        if let doctype = raw["doctype"] as? [String: Any] {
            self.doctype = Doctype(name: string(doctype["name"]) ?? "", publicID: string(doctype["publicId"]) ?? "",
                                   systemID: string(doctype["systemId"]) ?? "")
        }
        compatMode = string(raw["compatMode"]) ?? compatMode
        characterSet = string(raw["characterSet"]) ?? characterSet
        charsetMeta = bool(raw["charsetMeta"])
        viewport = string(raw["viewport"])
        metaDescription = string(raw["description"])
        robots = raw["robots"] as? [String] ?? []
        canonicals = (raw["canonicals"] as? [[String]] ?? []).compactMap { $0.count == 2 ? (raw: $0[0], resolved: $0[1]) : nil }
        hreflangs = (raw["hreflangs"] as? [[String]] ?? []).compactMap { $0.count == 3 ? (lang: $0[0], raw: $0[1], resolved: $0[2]) : nil }
        images = list("images").map { item in
            Image(node: node(item), src: string(item["src"]) ?? "",
                  naturalWidth: number(item["nw"]), naturalHeight: number(item["nh"]),
                  displayedWidth: number(item["dw"]), displayedHeight: number(item["dh"]),
                  alt: string(item["alt"]), role: string(item["role"]), name: string(item["name"]) ?? "",
                  widthAttribute: bool(item["wa"]), heightAttribute: bool(item["ha"]), cssSized: bool(item["css"]),
                  position: string(item["position"]) ?? "static", objectFit: string(item["fit"]) ?? "fill",
                  pixelated: bool(item["pixelated"]), visible: bool(item["visible"]), ariaHidden: bool(item["hidden"]),
                  inViewport: bool(item["inViewport"]),
                  documentRect: (item["rect"] as? [NSNumber]).flatMap { $0.count == 4 ? $0.map(\.doubleValue) : nil },
                  lazy: bool(item["lazy"]))
        }
        inputImages = named("inputImages")
        buttons = named("buttons")
        fields = named("fields")
        frames = named("frames")
        links = list("links").map { item in
            Link(node: node(item), name: string(item["name"]) ?? "", text: string(item["text"]) ?? "",
                 rawHref: string(item["raw"]), href: string(item["href"]) ?? "", role: string(item["role"]),
                 onclick: bool(item["onclick"]), nameAttribute: bool(item["nameAttr"]), visible: bool(item["visible"]),
                 tag: string(item["tag"]) ?? "a")
        }
        headings = list("headings").map { Heading(node: node($0), level: Int(number($0["level"]))) }
        aria = list("aria").map {
            Aria(node: node($0), tag: string($0["tag"]) ?? "", role: string($0["role"]),
                 attributes: $0["attrs"] as? [String] ?? [], native: bool($0["native"]), implicitRole: string($0["implicit"]))
        }
        tabIndexes = list("tabindex").map { TabIndex(node: node($0), value: Int(number($0["value"]))) }
        lists = list("lists").map { item in
            let children = (item["children"] as? [[Any]] ?? []).map { pair in
                (tag: pair.first as? String ?? "", role: pair.count > 1 ? pair[1] as? String : nil)
            }
            return ListElement(node: node(item), children: children)
        }
        listItems = list("listItems").map {
            ListItem(node: node($0), parentTag: string($0["parent"]) ?? "", parentRole: string($0["parentRole"]),
                     role: string($0["role"]))
        }
        duplicateIDs = list("duplicateIds").map { item in
            DuplicateID(id: string(item["id"]) ?? "", referenced: bool(item["referenced"]),
                        nodes: (item["nodes"] as? [Any] ?? []).compactMap { DeveloperLighthouseNode($0) })
        }
        texts = list("texts").map {
            Text(node: node($0), color: string($0["color"]) ?? "", backgrounds: $0["backgrounds"] as? [String],
                 fontSize: string($0["fontSize"]) ?? "16px", fontWeight: string($0["fontWeight"]) ?? "400")
        }
        headResources = list("head").map { item in
            HeadResource(node: node(item), kind: HeadResource.Kind(rawValue: string(item["kind"]) ?? "") ?? .script,
                         url: string(item["url"]) ?? "", async: bool(item["async"]), deferred: bool(item["defer"]),
                         module: bool(item["module"]), mediaMatches: item["media"] == nil || bool(item["media"]),
                         disabled: bool(item["disabled"]))
        }
        timings = list("resources").map {
            Timing(url: string($0["name"]) ?? "", initiatorType: string($0["type"]) ?? "",
                   startTime: number($0["start"]), responseEnd: number($0["end"]), transferSize: number($0["transfer"]),
                   encodedBodySize: number($0["encoded"]), decodedBodySize: number($0["decoded"]),
                   renderBlockingStatus: string($0["blocking"]))
        }
        if let stats = raw["dom"] as? [String: Any] {
            dom = DOMStats(elements: Int(number(stats["elements"])), depth: Int(number(stats["depth"])),
                           depthNode: DeveloperLighthouseNode(stats["depthNode"]),
                           widestChildren: Int(number(stats["children"])),
                           widestNode: DeveloperLighthouseNode(stats["widestNode"]))
        }
        devicePixelRatio = max(1, number(raw["dpr"]))
        viewportWidth = number(raw["width"])
        viewportHeight = number(raw["height"])
        selects = named("selects")
        mainLandmarks = Int(number(raw["mains"]))
        bodyAriaHidden = bool(raw["bodyHidden"])
        bodyNode = DeveloperLighthouseNode(raw["body"])
        targets = list("targets").map {
            Target(node: node($0), x: number($0["x"]), y: number($0["y"]), width: number($0["w"]), height: number($0["h"]))
        }
        headersCells = list("headersCells").map {
            HeadersCell(node: node($0), headers: $0["headers"] as? [String] ?? [], found: $0["found"] as? [String] ?? [],
                        id: string($0["id"]) ?? "")
        }
        langs = list("langs").map { Lang(node: node($0), lang: string($0["lang"]) ?? "") }
        metaRefreshes = list("metaRefresh").map { MetaRefresh(node: node($0), content: string($0["content"]) ?? "") }
        fontFaces = list("fontFaces").map {
            FontFace(family: string($0["family"]) ?? "", display: string($0["display"]) ?? "", urls: $0["urls"] as? [String] ?? [])
        }
        unreadableStyleSheets = Int(number(raw["unreadableSheets"]))
        preconnects = raw["preconnects"] as? [String] ?? []
        metaCSPs = raw["metaCSP"] as? [String] ?? []
        pasteBlocked = (raw["pasteBlocked"] as? [Any] ?? []).compactMap { DeveloperLighthouseNode($0) }
        if let calls = raw["permissionCalls"] as? [[String: Any]] {
            permissionCalls = calls.compactMap { call in
                guard let api = PermissionCall.API(rawValue: string(call["api"]) ?? "") else { return nil }
                return PermissionCall(api: api, url: string(call["url"]) ?? "", line: Int(number(call["line"])),
                                      column: Int(number(call["column"])), gesture: bool(call["gesture"]))
            }
        }
    }
}

/// One request the Network panel recorded during the run.
struct DeveloperLighthouseRequest: Equatable {
    var url: String
    /// WebKit's resource type: Document, Script, Stylesheet, Image, Font, Media, XHR, Fetch, Other…
    var type: String
    var mimeType: String
    var status: Int?
    /// Bytes over the wire (headers and body); nil when unknown.
    var transferSize: Double?
    /// The decoded body's size.
    var resourceSize: Double?
    /// Response headers by lowercased name.
    var headers: [String: String] = [:]
    var cached = false
    var durationMs: Double?
    var failed = false
    /// When it started and ended, in WebKit's network clock (seconds).
    var startedAt: Double?
    var endedAt: Double?
    /// DNS lookup to connected, in ms, when the request opened a new
    /// connection; nil when it reused one or WebKit didn't time it.
    var connectMs: Double?
    /// The URL first asked for, when the request was redirected.
    var originalURL: String?
    /// When the request was sent and its response's headers came, in the
    /// same clock as `startedAt` (seconds), for the simulation's server
    /// response times.
    var sentAt: Double?
    var receivedAt: Double?
    /// Who asked for it: WebKit's initiator type ("parser", "script",
    /// "other") and the document or script that did.
    var initiatorType: String?
    var initiatorURL: String?
    /// The protocol and priority WebKit's metrics name ("h2", "high").
    var networkProtocol: String?
    var priority: String?

    var scheme: String { URL(string: url)?.scheme?.lowercased() ?? "" }
    var host: String { URL(string: url)?.host()?.lowercased() ?? "" }
}

/// What the observer script measured during the load, in the page's clock.
struct DeveloperLighthouseMetrics: Equatable {
    enum TaskSource: String {
        /// PerformanceObserver `longtask` entries.
        case longTask = "longtask"
        /// Estimated from gaps in a zero-delay timer loop: WebKit has no `longtask`.
        /// A gap also holds the timer's own clamp and anything queued ahead
        /// of it, so it runs a few ms long per task.
        case eventLoopGaps = "gaps"
        /// The top-level tasks of the run's WebKit timeline recording: the
        /// task bounds Lighthouse reads from Chrome's trace.
        case trace
        case none
    }

    var fcp: Double?
    var lcp: Double?
    var lcpSupported = false
    var lcpElement: String?
    /// The LCP entry's image address, when it was an image.
    var lcpURL: String?
    var cls: Double?
    var clsSupported = false
    /// Measured by the observer's own Layout Instability run, WebKit having
    /// no layout-shift entries.
    var clsEstimated = false
    var layoutShifts = 0
    /// Main-thread tasks as (start, duration) in ms.
    var tasks: [(start: Double, duration: Double)] = []
    var taskSource = TaskSource.none
    /// Until when tasks were watched.
    var observedUntil: Double?
    var ttfb: Double?
    /// When the document's response began, in the page's clock (ms).
    var responseStart: Double?
    var domContentLoaded: Double?
    var load: Double?
    /// From snapshots of the view during the load (DeveloperSpeedIndex).
    var speedIndex: Double?
    var speedIndexFrames = 0
    /// The observer's state was found (a Timespan's is lost if the page navigates).
    var observed = true
    /// When the observer started watching, in the page's clock.
    var started: Double?
    /// This WebKit reports `event` entries (the Event Timing API).
    var inpSupported = false
    /// Interaction to Next Paint, and the interaction it was.
    var inp: Double?
    var interactions = 0
    var inpEvent: String?
    var inpTarget: String?
    /// The LCP element is an `<img>` (or the entry names an image's URL),
    /// and whether it has `loading="lazy"`.
    var lcpImage = false
    var lcpLazy = false
    /// The navigation's redirects (Navigation Timing counts same-origin
    /// ones only) and the time they took, when it says.
    var redirects = 0
    var redirectMs: Double?

    static func == (a: Self, b: Self) -> Bool {
        a.fcp == b.fcp && a.lcp == b.lcp && a.cls == b.cls && a.taskSource == b.taskSource
            && a.tasks.map { $0.start } == b.tasks.map { $0.start } && a.tasks.map { $0.duration } == b.tasks.map { $0.duration }
    }

    init(fcp: Double? = nil, lcp: Double? = nil, lcpSupported: Bool = false, cls: Double? = nil, clsSupported: Bool = false,
         tasks: [(start: Double, duration: Double)] = [], taskSource: TaskSource = .none, ttfb: Double? = nil) {
        self.fcp = fcp
        self.lcp = lcp
        self.lcpSupported = lcpSupported
        self.cls = cls
        self.clsSupported = clsSupported
        self.tasks = tasks
        self.taskSource = taskSource
        self.ttfb = ttfb
    }

    init(_ raw: [String: Any]) {
        func number(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
        fcp = number("fcp")
        lcpSupported = (raw["lcpSupported"] as? NSNumber)?.boolValue ?? false
        lcp = lcpSupported ? number("lcp") : nil
        lcpElement = raw["lcpElement"] as? String
        lcpURL = (raw["lcpURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        clsSupported = (raw["clsSupported"] as? NSNumber)?.boolValue ?? false
        clsEstimated = !clsSupported && (raw["clsEstimated"] as? NSNumber)?.boolValue == true
        layoutShifts = (raw["shifts"] as? NSNumber)?.intValue ?? 0
        cls = clsSupported || clsEstimated ? number("cls") ?? 0 : nil
        taskSource = TaskSource(rawValue: raw["taskSource"] as? String ?? "") ?? .none
        tasks = (raw["tasks"] as? [[NSNumber]] ?? []).compactMap { pair in
            pair.count == 2 ? (start: pair[0].doubleValue, duration: pair[1].doubleValue) : nil
        }
        observedUntil = number("now")
        observed = (raw["observed"] as? NSNumber)?.boolValue ?? true
        started = number("started")
        inpSupported = (raw["inpSupported"] as? NSNumber)?.boolValue ?? false
        inp = number("inp")
        interactions = (raw["interactions"] as? NSNumber)?.intValue ?? 0
        inpEvent = raw["inpEvent"] as? String
        inpTarget = raw["inpTarget"] as? String
        lcpImage = (raw["lcpImage"] as? NSNumber)?.boolValue ?? false
        lcpLazy = (raw["lcpLazy"] as? NSNumber)?.boolValue ?? false
        redirects = (raw["redirects"] as? NSNumber)?.intValue ?? 0
        redirectMs = number("redirectMs")
        ttfb = number("ttfb")
        responseStart = number("responseStart")
        domContentLoaded = number("dcl")
        load = number("load")
    }

    /// Lighthouse's TBT: each task's time past 50 ms, counting only the
    /// part after FCP (a task that straddles FCP is clipped to it).
    static func totalBlockingTime(_ tasks: [(start: Double, duration: Double)], after fcp: Double,
                                  until end: Double = .infinity) -> Double {
        var total = 0.0
        for task in tasks {
            let taskEnd = task.start + task.duration
            let start = max(task.start, fcp)
            let finish = min(taskEnd, end)
            guard finish > start else { continue }
            // Lighthouse counts the blocking part of the clipped task.
            let clipped = finish - start
            total += max(0, clipped - 50)
        }
        return total
    }

    var totalBlockingTime: Double? {
        guard taskSource != .none, let fcp else { return nil }
        return Self.totalBlockingTime(tasks, after: fcp, until: observedUntil ?? .infinity)
    }

    /// TBT over a timespan: every task from when the timespan started.
    var timespanBlockingTime: Double? {
        guard taskSource != .none else { return nil }
        return Self.totalBlockingTime(tasks, after: started ?? 0, until: observedUntil ?? .infinity)
    }
}

struct DeveloperLighthouseConsoleError: Equatable {
    var text: String
    var url: String?
}

struct DeveloperLighthouseIssue: Equatable {
    var title: String
    var category: String
    var subtitle: String?
    var count: Int
    var deprecation: Bool
    /// One of the issue types Lighthouse's inspector-issues audit fails on.
    var scored = true
}

/// A script's or stylesheet's text as WebKit has it (Page.getResourceContent).
struct DeveloperLighthouseContent: Equatable {
    enum Kind: String { case script, stylesheet }
    var url: String
    var kind: Kind
    var text: String
}

/// A source map DevTools loaded, or failed to load, for a script.
struct DeveloperLighthouseSourceMap: Equatable {
    var scriptURL: String
    var mapURL: String
    /// Why it couldn't be loaded or read; nil when it was.
    var error: String?
}

/// The origin's /robots.txt as fetched: nil status when it couldn't be.
struct DeveloperLighthouseRobots: Equatable {
    var status: Int?
    var content: String?
}

/// Everything one run audits.
struct DeveloperLighthouseInput {
    var mode: DeveloperLighthouseMode
    var formFactor: DeveloperLighthouseFormFactor
    var categories: [DeveloperLighthouseCategoryID]
    var requestedURL: String
    var page: DeveloperLighthousePage
    var requests: [DeveloperLighthouseRequest] = []
    var metrics: DeveloperLighthouseMetrics?
    var consoleErrors: [DeveloperLighthouseConsoleError] = []
    /// Nil when the Issues tool couldn't be read.
    var issues: [DeveloperLighthouseIssue]?
    var fetchTime = Date()
    var userAgent = ""
    var emulation = ""
    var warnings: [String] = []
    /// Coverage over the load, per file (DeveloperCoverage): scripts from
    /// JavaScriptCore's control flow profiler, stylesheets by selector
    /// matching. Nil when it wasn't measured.
    var scriptCoverage: [DeveloperCoverageMath.Entry]?
    var styleCoverage: [DeveloperCoverageMath.Entry]?
    /// The page's scripts' and stylesheets' text; nil when not read.
    var contents: [DeveloperLighthouseContent]?
    /// The maps DevTools loaded for the page's scripts; nil when JavaScript
    /// source maps are turned off in Settings.
    var sourceMaps: [DeveloperLighthouseSourceMap]?
    var robots: DeveloperLighthouseRobots?
    /// How the load metrics are throttled. `.none` scores them as measured.
    var throttling = DeveloperLighthouseThrottling.none
    /// The main thread's tasks from the run's trace (DeveloperLighthouseLantern),
    /// in the requests' clock (seconds); nil when no trace was recorded, and
    /// the simulation falls back on the observer's long tasks.
    var traceTasks: [DeveloperLighthouseLantern.CPUTask]?
    /// The simulated metrics, filled in by the report when `throttling` is simulated.
    var simulated: DeveloperLighthouseLantern.Estimates?
}
