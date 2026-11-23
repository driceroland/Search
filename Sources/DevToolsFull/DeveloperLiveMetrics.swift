import SwiftUI
import WebKit

/// How a Core Web Vital rates, with Chrome DevTools' colours for each.
enum DeveloperVitalRating: String {
    case good = "Good"
    case needsImprovement = "Needs improvement"
    case poor = "Poor"

    var color: Color {
        switch self {
        case .good: Color(red: 0.05, green: 0.56, blue: 0.27)
        case .needsImprovement: Color(red: 0.84, green: 0.48, blue: 0.0)
        case .poor: Color(red: 0.85, green: 0.19, blue: 0.15)
        }
    }
}

/// The Core Web Vitals Performance's landing view shows as Chrome's local
/// metrics, with Chrome's thresholds.
enum DeveloperWebVital: String, CaseIterable, Identifiable {
    case lcp = "LCP"
    case cls = "CLS"
    case inp = "INP"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lcp: "Largest Contentful Paint (LCP)"
        case .cls: "Cumulative Layout Shift (CLS)"
        case .inp: "Interaction to Next Paint (INP)"
        }
    }

    /// The most a good value can be, and the most one needing improvement
    /// can be; above that it is poor. Milliseconds, or a score for CLS.
    var thresholds: (good: Double, poor: Double) {
        switch self {
        case .lcp: (2_500, 4_000)
        case .cls: (0.1, 0.25)
        case .inp: (200, 500)
        }
    }

    func rating(_ value: Double) -> DeveloperVitalRating {
        if value <= thresholds.good { return .good }
        if value <= thresholds.poor { return .needsImprovement }
        return .poor
    }

    /// "1.23 s" or "850 ms" for LCP, "0.05" for CLS, "120 ms" for INP.
    func format(_ value: Double) -> String {
        switch self {
        case .lcp: value >= 1_000 ? String(format: "%.2f s", value / 1_000) : "\(Int(value.rounded())) ms"
        case .cls: String(format: "%.2f", value)
        case .inp: "\(Int(value.rounded())) ms"
        }
    }
}

/// What the page's metrics script (DeveloperPerformance-metrics.js) read.
struct DeveloperLiveMetrics: Equatable {
    enum Reading: Equatable {
        /// This WebKit has no entries to measure it with.
        case unavailable
        /// Nothing measured yet.
        case waiting
        case value(Double)
    }

    var url: String?
    var lcpSupported = false
    var lcp: Double?
    var lcpElement: String?
    var clsEstimated = false
    var cls: Double?
    var inpSupported = false
    var inp: Double?
    var inpEvent: String?
    var inpTarget: String?
    var interactions = 0

    init() {}

    init?(raw: Any?) {
        guard let raw = raw as? [String: Any] else { return nil }
        let number = DeveloperProtocolValue.measure
        url = raw["url"] as? String
        lcpSupported = raw["lcpSupported"] as? Bool ?? false
        lcp = number(raw["lcp"])
        lcpElement = raw["lcpElement"] as? String
        clsEstimated = raw["clsEstimated"] as? Bool ?? false
        cls = number(raw["cls"])
        inpSupported = raw["inpSupported"] as? Bool ?? false
        if let inp = raw["inp"] as? [String: Any] {
            self.inp = number(inp["value"])
            inpEvent = inp["name"] as? String
            inpTarget = inp["target"] as? String
        }
        interactions = (raw["interactions"] as? NSNumber)?.intValue ?? 0
    }

    func reading(_ vital: DeveloperWebVital) -> Reading {
        switch vital {
        case .lcp:
            guard lcpSupported else { return Reading.unavailable }
            return lcp.map { Reading.value($0) } ?? Reading.waiting
        // Measured from layout-shift entries, or estimated without them.
        case .cls:
            return Reading.value(cls ?? 0)
        case .inp:
            guard inpSupported else { return Reading.unavailable }
            return inp.map { Reading.value($0) } ?? Reading.waiting
        }
    }
}

/// Performance's local metrics: the page's LCP, CLS and INP, read once a
/// second while the landing view is shown. The load observer
/// (Shared/PageObserver.swift, Lighthouse's too) goes into the tab, in the
/// package's own world, while the Performance panel is open, so a reload is
/// measured from its start, and it keeps the page's shifts and timings for
/// a recording's tracks. One per DevTools session.
@MainActor
final class DeveloperLiveMetricsModel: ObservableObject {
    @Published private(set) var metrics: DeveloperLiveMetrics?

    static let script = PageObserver.source
    static let interval: Duration = .seconds(1)
    private static let api = "window.__searchDeveloperLoad"
    static let objectGroup = "search-performance-metrics"

    private weak var session: DeveloperToolsSession?
    private weak var observedWeb: WKWebView?
    private(set) var userScript: WKUserScript?
    private var poll: Task<Void, Never>?
    private var address: URL?

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperLiveMetricsModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperLiveMetricsModel {
        for (key, entry) in models where entry.session.value == nil {
            entry.model.detach()
            models[key] = nil
        }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperLiveMetricsModel(session: session)
        if !session.isClosed { models[key] = (WeakSession(value: session), model) }
        return model
    }

    /// The session's model, if it has one: its script for the next document.
    static func existing(for session: DeveloperToolsSession) -> DeveloperLiveMetricsModel? {
        models[ObjectIdentifier(session)].flatMap { $0.session.value === session ? $0.model : nil }
    }

    /// DevTools closed: the script comes out of the tab.
    static func closed(_ session: DeveloperToolsSession) {
        models.removeValue(forKey: ObjectIdentifier(session))?.model.detach()
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    static var world: WKContentWorld { FullPlugin.current?.world ?? .defaultClient }

    // MARK: The script in the tab

    /// The Performance panel opened: the script goes into the tab (the
    /// host asks the session's pageScripts at each document) and into the
    /// page already loaded.
    func attach() {
        guard let session, let web = session.web else { return }
        if observedWeb !== web { removeScript() }
        guard userScript == nil else { return }
        userScript = WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
        observedWeb = web
        FullPlugin.current?.host?.rearm(web)
        web.evaluateJavaScript(Self.script, in: nil, in: Self.world, completionHandler: nil)
    }

    /// The panel put away, or DevTools closed: the script comes out of the
    /// tab, and the page's copy stops watching unless a recording is
    /// still using it.
    func detach() {
        stopPolling()
        let web = observedWeb
        removeScript()
        if let web, session?.recordingTimeline != true {
            web.evaluateJavaScript("(() => { const api = \(Self.api); return api ? api.stop() : true; })()",
                                   in: nil, in: Self.world, completionHandler: nil)
        }
        metrics = nil
    }

    private func removeScript() {
        let web = observedWeb
        userScript = nil
        observedWeb = nil
        if let web { FullPlugin.current?.host?.rearm(web) }
    }

    // MARK: Reading

    /// While the landing view is shown: a reading a second.
    func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            // Ends with the model, should it go without stopPolling().
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func tick() async {
        // Not while recording (the reads would be in the recording), nor
        // while the debugger holds the page, which wouldn't answer.
        guard let session, session.ready, !session.paused, !session.recordingTimeline, let web = session.web else { return }
        if session.address != address {
            metrics = nil
            address = session.address
        }
        let read = DeveloperLiveMetrics(raw: await Self.call(web, "api.read()"))
        guard !Task.isCancelled else { return }
        if read != metrics { metrics = read }
    }

    /// `call` on the page's metrics script, put there first if it isn't.
    static func call(_ web: WKWebView, _ call: String) async -> Any? {
        let body = script + "\nconst api = \(api);\nreturn api ? \(call) : null;"
        return try? await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)
    }

    // MARK: Recording

    /// A recording starting or ending: the estimator keeps going while it
    /// records, whether or not anything reads.
    static func hold(_ web: WKWebView, _ value: Bool) async {
        _ = await call(web, "api.hold(\(value))")
    }

    /// For Performance › Insights: the LCP element's resource and how it
    /// was asked for (its tag, loading and fetchpriority, a preload), the
    /// viewport meta tag, the images' natural and displayed sizes, the
    /// @font-face rules' font-display, and the DOM's size (elements,
    /// deepest nesting, most children), counted with a cap so a huge page
    /// answers quickly.
    static let pageInfo = """
        (() => {
            const info = {url: location.href};
            try {
                const lcp = performance.getEntriesByType("largest-contentful-paint");
                const last = lcp[lcp.length - 1];
                if (last && last.url) info.lcpURL = String(last.url);
                const element = last && last.element;
                if (element) {
                    info.lcpTag = String(element.tagName || "").toUpperCase();
                    info.lcpLoading = String(element.getAttribute("loading") || "").toLowerCase();
                    info.lcpFetchPriority = String(element.getAttribute("fetchpriority") || "").toLowerCase();
                }
                if (last && last.url) {
                    let preloaded = false;
                    for (const link of document.querySelectorAll("link[rel~=preload]")) {
                        if (link.href === last.url) {
                            preloaded = true;
                            const priority = String(link.getAttribute("fetchpriority") || "").toLowerCase();
                            if (priority && !info.lcpFetchPriority) info.lcpFetchPriority = priority;
                        }
                    }
                    info.lcpPreloaded = String(preloaded);
                    const timing = performance.getEntriesByName(last.url, "resource")[0];
                    if (timing && timing.initiatorType) info.lcpInitiator = String(timing.initiatorType);
                }
            } catch (error) {}
            try {
                let viewport = null;
                for (const meta of document.querySelectorAll("meta[name]")) {
                    if (String(meta.getAttribute("name")).trim().toLowerCase() === "viewport") {
                        viewport = String(meta.getAttribute("content") || "").slice(0, 500);
                        break;
                    }
                }
                info.viewport = JSON.stringify(viewport);
                info.devicePixelRatio = String(window.devicePixelRatio || 1);
            } catch (error) {}
            try {
                // Character set: the first <meta charset> (or http-equiv
                // Content-Type with a charset), and how many bytes into the
                // markup it ends, estimated from the serialized document.
                let charsetMeta = null;
                for (const meta of document.querySelectorAll("meta[charset], meta[http-equiv]")) {
                    let charset = meta.getAttribute("charset");
                    if (charset === null) {
                        if (String(meta.getAttribute("http-equiv")).trim().toLowerCase() !== "content-type") continue;
                        const match = /charset\\s*=\\s*["']?([^"';\\s]+)/i.exec(meta.getAttribute("content") || "");
                        if (!match) continue;
                        charset = match[1];
                    }
                    const doctype = document.doctype ? new XMLSerializer().serializeToString(document.doctype) : "";
                    const markup = doctype + document.documentElement.outerHTML;
                    const tag = meta.outerHTML;
                    const at = markup.indexOf(tag);
                    const end = at < 0 ? -1 : new TextEncoder().encode(markup.slice(0, at + tag.length)).length;
                    charsetMeta = {charset: String(charset).trim().slice(0, 60), end: end};
                    break;
                }
                info.charsetMeta = JSON.stringify(charsetMeta);
            } catch (error) {}
            try {
                const images = [];
                for (const img of Array.from(document.images).slice(0, 300)) {
                    const src = img.currentSrc || img.src || "";
                    if (!src || src.startsWith("data:")) continue;
                    const rect = img.getBoundingClientRect();
                    images.push({src: src.slice(0, 2000), nw: img.naturalWidth, nh: img.naturalHeight,
                                 dw: Math.round(rect.width), dh: Math.round(rect.height)});
                }
                info.pageImages = JSON.stringify(images);
            } catch (error) {}
            try {
                const faces = [];
                const visit = (rules, base, depth) => {
                    for (const rule of Array.from(rules || [])) {
                        if (faces.length >= 100) return;
                        if (rule.type === 5) {
                            const style = rule.style;
                            const src = String(style.getPropertyValue("src") || "");
                            const urls = [];
                            let at = src.indexOf("url(");
                            while (at >= 0 && urls.length < 5) {
                                const close = src.indexOf(")", at);
                                if (close < 0) break;
                                let address = src.slice(at + 4, close).trim();
                                if (address[0] === '"' || address[0] === "'") address = address.slice(1, -1);
                                try { urls.push(new URL(address, base).href.slice(0, 2000)); } catch (error) {}
                                at = src.indexOf("url(", close);
                            }
                            faces.push({family: String(style.getPropertyValue("font-family") || "").slice(0, 200),
                                        display: String(style.getPropertyValue("font-display") || "auto").toLowerCase(), urls});
                        } else if (depth < 4) {
                            // @import's sheet, or @media and @supports' rules.
                            try {
                                if (rule.styleSheet) visit(rule.styleSheet.cssRules, rule.styleSheet.href || base, depth + 1);
                                else if (rule.cssRules) visit(rule.cssRules, base, depth + 1);
                            } catch (error) {}
                        }
                    }
                };
                for (const sheet of Array.from(document.styleSheets).slice(0, 200)) {
                    try { visit(sheet.cssRules, sheet.href || location.href, 0); } catch (error) {}
                }
                info.fontFaces = JSON.stringify(faces);
            } catch (error) {}
            try {
                const root = document.documentElement;
                if (root) {
                    let elements = 0, depth = 0, children = 0;
                    const walk = [[root, 1]];
                    while (walk.length && elements < 50000) {
                        const [node, level] = walk.pop();
                        elements += 1;
                        if (level > depth) depth = level;
                        const count = node.childElementCount;
                        if (count > children) children = count;
                        for (let child = node.firstElementChild; child; child = child.nextElementSibling) walk.push([child, level + 1]);
                    }
                    info.domElements = elements;
                    info.domDepth = depth;
                    info.domChildren = children;
                }
            } catch (error) {}
            return info;
        })()
        """

    /// Just before a recording stops: the page's clock lined up with the
    /// timeline's (a console.timeStamp the recording catches) and its
    /// marks, measures, milestones and shifts (DeveloperPerformancePageTimings), and
    /// what pageInfo says.
    static func recording(_ web: WKWebView) async -> [String: Any]? {
        guard var page = await call(web, "api.recording()") as? [String: Any] else { return nil }
        let info = try? await web.callAsyncJavaScript("return \(pageInfo);", arguments: [:], in: nil, contentWorld: world)
        if var info = info as? [String: Any] {
            // WebKit's naturalWidth of a scaled-down image is its decoded size.
            if let text = info["pageImages"] as? String, let data = text.data(using: .utf8),
               let images = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let ratio = Double(info["devicePixelRatio"] as? String ?? "") ?? 1
                let corrected = await DeveloperImageNaturalSize.correct(images, ratio: ratio, in: web)
                if let json = try? JSONSerialization.data(withJSONObject: corrected),
                   let string = String(data: json, encoding: .utf8) { info["pageImages"] = string }
            }
            page.merge(info) { current, _ in current }
        }
        return page
    }

    // MARK: Elements

    /// The LCP element in Elements.
    func revealLCP() {
        reveal("api.lcpNode()", missing: "The LCP element is no longer in the page.")
    }

    /// One of a recorded layout shift's moved elements in Elements.
    func revealShiftNode(index: Int, node: Int) {
        reveal("api.shiftNode(\(index), \(node))",
               missing: "This node is no longer in the page, or the recording came from another page.")
    }

    /// Shows the element in the Elements panel, once Elements has read the
    /// document afresh (as the Media tool's reveal does).
    private func reveal(_ call: String, missing: String) {
        guard let session, let web = session.web else { return }
        session.hideHighlight()
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task {
            // The observer is in the package's world, which the inspector
            // can't evaluate in: it says where the element is, as a path of
            // child positions, and the page's document is asked for that.
            let path = await Self.call(web, """
                (() => { let node = \(call); const steps = [];
                  while (node && node.parentElement) { steps.unshift(Array.prototype.indexOf.call(node.parentElement.children, node) + 1); node = node.parentElement; }
                  return node === document.documentElement ? steps : null; })()
                """) as? [Int]
            guard let path else {
                session.message = missing
                return
            }
            let expression = "[\(path.map(String.init).joined(separator: ","))].reduce((node, index) => node && node.children[index - 1], document.documentElement) || null"
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let node = await Self.node(session, expression) else {
                session.message = missing
                return
            }
            for _ in 0..<40 where session.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(node)
        }
    }

    /// The element `expression` gives, evaluated in the page, as an
    /// inspector node.
    static func node(_ session: DeveloperToolsSession, _ expression: String) async -> Int? {
        let target = session.runtimeTargetID
        guard let reply = try? await session.command("Runtime.evaluate", [
            "expression": expression, "objectGroup": objectGroup,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target), reply["wasThrown"] as? Bool != true,
            let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
        guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return nil }
        return id
    }
}

/// Chrome's local metrics on the Performance panel's landing view: LCP,
/// CLS and INP for the inspected page as it is used, coloured as Chrome
/// rates them, with the LCP element linked to Elements.
struct DeveloperLiveMetricsView: View {
    @ObservedObject private var model: DeveloperLiveMetricsModel

    init(session: DeveloperToolsSession) {
        model = DeveloperLiveMetricsModel.model(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local metrics").font(.system(size: 13, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { cards }
                VStack(alignment: .leading, spacing: 10) { cards }
            }
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer-performance-live-metrics")
    }

    private var cards: some View {
        ForEach(DeveloperWebVital.allCases) { vital in card(vital) }
    }

    private func card(_ vital: DeveloperWebVital) -> some View {
        let metrics = model.metrics ?? DeveloperLiveMetrics()
        // Before the first reading, every metric waits.
        let reading = model.metrics.map { $0.reading(vital) } ?? DeveloperLiveMetrics.Reading.waiting
        return VStack(alignment: .leading, spacing: 4) {
            Text(vital.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            switch reading {
            case .unavailable:
                Text("Not available in WebKit").font(.system(size: 12)).foregroundStyle(.secondary)
                    .help(vital == .lcp ? "This version of WebKit has no largest-contentful-paint entries."
                                        : "This version of WebKit has no event timing entries.")
            case .waiting:
                Text("-").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
            case .value(let value):
                let rating = vital.rating(value)
                Text(vital.format(value)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(rating.color)
                    .accessibilityValue("\(vital.format(value)), \(rating.rawValue)")
                    .help(rating.rawValue)
            }
            details(vital, metrics: metrics)
        }
        .padding(10)
        .frame(minWidth: 110, maxWidth: 220, alignment: .topLeading)
        .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("developer-performance-metric-\(vital.rawValue.lowercased())")
    }

    @ViewBuilder private func details(_ vital: DeveloperWebVital, metrics: DeveloperLiveMetrics) -> some View {
        switch vital {
        case .lcp:
            if let element = metrics.lcpElement {
                HStack(spacing: 4) {
                    Text("LCP element").foregroundStyle(.secondary)
                    Button(element) { model.revealLCP() }
                        .buttonStyle(.link)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Reveal in Elements panel")
                        .accessibilityIdentifier("developer-performance-lcp-element")
                }
                .font(.system(size: 11))
            }
        case .cls:
            if metrics.clsEstimated {
                Text("Estimated").font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("This version of WebKit has no layout-shift entries, so shifts are estimated from how the page's elements move.")
            }
        case .inp:
            if metrics.inp != nil, let event = metrics.inpEvent {
                Text(metrics.inpTarget.map { "\(event) on \($0)" } ?? event)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
