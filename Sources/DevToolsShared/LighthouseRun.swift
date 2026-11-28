import AppKit
import WebKit

// A Lighthouse run on the tab, and the audits worked out from what it read.
//
// Navigation loads the page again from a blank one, as Lighthouse does: the
// load observer goes in for that load only (PageObserver.source), the
// page is photographed small about every 16 ms for the Speed Index,
// and once it has settled the metrics are read, then the page itself.
// Snapshot reads the page as it is. Mobile scores against Lighthouse's
// mobile curves and, unless the device toolbar is already up, shows the
// page at Lighthouse's phone size for the run.
//
// The only request of its own is robots.txt, for the SEO audits: an
// ephemeral session through Search's proxy, with no cookies, no credentials
// and no cache, only for an http(s) page.

@MainActor
final class LighthouseModel: ObservableObject {
    weak var session: DevToolsSession?

    @Published var mode = LighthouseMode.navigation { didSet { save() } }
    @Published var form = LighthouseFormFactor.desktop { didSet { save() } }
    @Published var categories = Set(LighthouseCategory.allCases) { didSet { save() } }
    @Published private(set) var running = false
    @Published private(set) var stage = ""
    @Published var report: LighthouseReport?
    @Published var notice: String?

    private var observing = false
    private var task: Task<Void, Never>?
    static let key = "lighthouse"
    private var restoring = false

    func restore() {
        guard let kept = session?.setting(Self.key) as? [String: Any] else { return }
        restoring = true
        defer { restoring = false }
        mode = (kept["mode"] as? String).flatMap(LighthouseMode.init) ?? .navigation
        form = (kept["form"] as? String).flatMap(LighthouseFormFactor.init) ?? .desktop
        let chosen = Set(((kept["categories"] as? [String]) ?? []).compactMap(LighthouseCategory.init))
        if !chosen.isEmpty { categories = chosen }
    }

    private func save() {
        guard !restoring else { return }
        session?.keep(["mode": mode.rawValue, "form": form.rawValue,
                       "categories": LighthouseCategory.allCases.filter(categories.contains).map(\.rawValue)], Self.key)
    }

    func scripts() -> [WKUserScript] {
        guard observing, let session else { return [] }
        return [WKUserScript(source: PageObserver.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: session.world)]
    }

    func run() {
        guard let session, !running, !categories.isEmpty else { return }
        running = true
        notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            let report = await self.audit(in: session)
            self.finish(session)
            if let report { self.report = report } else if !Task.isCancelled { self.notice = "The page couldn't be audited" }
            self.running = false
            self.stage = ""
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let session { finish(session) }
        running = false
    }

    private var lent = false

    private func finish(_ session: DevToolsSession) {
        if observing {
            observing = false
            session.rearm()
        }
        if lent {
            lent = false
            session.device.on = false
        }
    }

    // MARK: the run

    private func audit(in session: DevToolsSession) async -> LighthouseReport? {
        guard let web = session.web, let url = web.url else { return nil }
        let started = Date()
        let mode = self.mode, form = self.form
        var metrics: [String: Any]?
        var speedIndex: Double?
        if mode == .navigation {
            if form == .mobile, !session.device.on {
                session.device.device = "Moto G Power"
                session.device.landscape = false
                session.device.on = true
                lent = true
            }
            stage = "Loading the page"
            web.load(URLRequest(url: URL(string: "about:blank")!))
            await session.settle(timeout: 5, quiet: 0.2)
            observing = true
            session.rearm()
            session.response = nil
            let film = Task { await Self.film(web) }
            web.load(URLRequest(url: url))
            await session.settle(timeout: 45, quiet: 1.5)
            guard !Task.isCancelled else { film.cancel(); return nil }
            stage = "Measuring"
            metrics = await session.call(LighthouseScripts.metrics) as? [String: Any]
            film.cancel()
            let captures = await film.value
            if let origin = LighthouseAudits.number(metrics?["timeOrigin"]), origin.isFinite {
                let frames = captures.frames.map { ($0.ms - origin, $0.histogram) }
                speedIndex = SpeedIndex.speedIndex(frames, fcp: LighthouseAudits.number(metrics?["fcp"]),
                                                   end: captures.end.map { $0 - origin })
            }
            observing = false
            session.rearm()
        }
        guard !Task.isCancelled else { return nil }
        stage = "Auditing"
        guard let page = await session.call(LighthouseScripts.collect) as? [String: Any] else { return nil }
        var robots: Robots?
        if categories.contains(.seo), let address = page["url"] as? String, let here = URL(string: address),
           ["http", "https"].contains(here.scheme ?? "") {
            stage = "Reading robots.txt"
            if let fetcher = session.plugin?.host?.ephemeralSession() { robots = await Robots.fetch(for: here, with: fetcher) }
        }
        guard !Task.isCancelled else { return nil }
        let input = LighthouseInput(mode: mode, form: form, page: page, metrics: metrics,
                                    speedIndex: speedIndex, response: session.response, robots: robots)
        var report = LighthouseAudits.report(input, categories: LighthouseCategory.allCases.filter(categories.contains))
        report.duration = Date().timeIntervalSince(started) * 1000
        return report
    }

    /// Sample small bitmaps for about 50 seconds at most, keeping frames
    /// that changed. Use the time the snapshot arrived so an in-flight
    /// snapshot never appears earlier in the trace.
    private static func film(_ web: WKWebView) async -> (frames: [(ms: Double, histogram: [Int])], end: Double?) {
        var frames: [(ms: Double, histogram: [Int])] = []
        var end: Double?
        var captured = 0
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 160
        configuration.afterScreenUpdates = false
        for _ in 0..<3_000 where !Task.isCancelled {
            if let image = try? await web.takeSnapshot(configuration: configuration),
               let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard !Task.isCancelled else { break }
                let time = Date().timeIntervalSince1970 * 1_000
                let histogram = SpeedIndex.histogram(picture)
                if frames.last?.histogram != histogram { frames.append((time, histogram)) }
                captured += 1
                end = time
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard captured >= 2 else { return (frames: [], end: nil) }
        return (frames: frames, end: end)
    }

    // MARK: saving

    func saveReport() {
        guard let report, let data = LighthouseJSON.data(report) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let host = URL(string: report.url)?.host() ?? "page"
        panel.nameFieldStringValue = "\(host)-\(report.fetched.formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { notice = "Couldn't save: \(error.localizedDescription)" }
    }
}

extension DevToolsSession {
    /// Until the tab has loaded what it was loading and gone quiet: up to
    /// `timeout` seconds, then `quiet` more.
    func settle(timeout: TimeInterval, quiet: TimeInterval = 0.5) async {
        guard let web else { return }
        let start = Date()
        var seen = web.isLoading
        while Date().timeIntervalSince(start) < timeout, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if web.isLoading { seen = true; continue }
            if seen || Date().timeIntervalSince(start) > 1 { break }
        }
        try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
    }
}

/// The site's robots.txt, as the SEO audits need it.
struct Robots: Equatable {
    var status: Int
    var body: String

    static func fetch(for page: URL, with session: URLSession) async -> Robots? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/robots.txt"
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Read up to the first 500 kB only: a server that never stops
        // can't fill memory.
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        var data = [UInt8]()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 500_000 { break }
            }
        } catch {
            return nil
        }
        bytes.task.cancel()
        return Robots(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    /// Lines that aren't a known directive, by line number.
    var invalidLines: [(Int, String)] {
        let known: Set<String> = ["user-agent", "disallow", "allow", "sitemap", "crawl-delay", "clean-param", "host",
                                  "request-rate", "visit-time", "noindex"]
        var out: [(Int, String)] = []
        for (number, raw) in body.components(separatedBy: .newlines).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":"),
                  known.contains(trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) else {
                out.append((number + 1, String(trimmed.prefix(120))))
                continue
            }
        }
        return out
    }

    /// Whether the rules for every crawler block this path.
    func blocks(_ path: String) -> Bool {
        var applies = false
        var group = false
        var disallowed: [String] = []
        var allowed: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "user-agent":
                if !group { applies = false }
                group = true
                if value == "*" { applies = true }
            case "disallow":
                group = false
                if applies, !value.isEmpty { disallowed.append(value) }
            case "allow":
                group = false
                if applies, !value.isEmpty { allowed.append(value) }
            default:
                continue
            }
        }
        let longest = { (rules: [String]) in rules.filter { path.hasPrefix($0.replacingOccurrences(of: "*", with: "")) }.map(\.count).max() ?? -1 }
        return longest(disallowed) > longest(allowed)
    }
}

/// What a run read, for the audits.
struct LighthouseInput {
    var mode: LighthouseMode
    var form: LighthouseFormFactor
    var page: [String: Any]
    var metrics: [String: Any]?
    var speedIndex: Double?
    var response: HTTPURLResponse?
    var robots: Robots?
}

enum LighthouseAudits {
    static func report(_ input: LighthouseInput, categories: [LighthouseCategory], at date: Date = Date()) -> LighthouseReport {
        var audits: [String: LighthouseAudit] = [:]
        let wanted = Set(categories)
        for entry in LighthouseCatalog.entries where entry.refs.contains(where: { wanted.contains($0.category) }) {
            if entry.load, input.mode != .navigation { continue }
            audits[entry.id] = audit(entry.id, input)
        }
        let page = input.page
        var warnings: [String] = []
        if input.mode == .navigation, input.speedIndex == nil {
            warnings.append("Speed Index needs the page on screen while it loads.")
        }
        return LighthouseReport(url: page["url"] as? String ?? "", fetched: date, mode: input.mode, form: input.form,
                                categories: categories, audits: audits, userAgent: page["userAgent"] as? String ?? "",
                                viewport: CGSize(width: number(page["width"]) ?? 0, height: number(page["height"]) ?? 0),
                                devicePixelRatio: number(page["dpr"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1,
                                warnings: warnings)
    }

    static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    /// The same host, or the same last two labels (a lenient reading of a
    /// registrable domain: enough to tell another site's canonical apart).
    static func sameSite(_ one: String, _ other: String) -> Bool {
        let a = one.lowercased(), b = other.lowercased()
        if a == b { return true }
        let tail = { (host: String) in host.split(separator: ".").suffix(2).joined(separator: ".") }
        return a.contains(".") && tail(a) == tail(b)
    }

    static func audit(_ id: String, _ input: LighthouseInput) -> LighthouseAudit {
        let page = input.page
        if let metric = LighthouseMetric(rawValue: id) { return measured(metric, input) }
        switch id {
        case "html-lang-valid":
            guard let lang = page["lang"] as? String, !lang.trimmingCharacters(in: .whitespaces).isEmpty else {
                return LighthouseAudit(id: id, display: .notApplicable)
            }
            return binary(id, validLanguage(lang), items: [LighthouseItem(text: lang)])
        case "is-on-https":
            let scheme = page["protocol"] as? String ?? ""
            let local = ["localhost", "127.0.0.1", "[::1]"].contains(URL(string: page["url"] as? String ?? "")?.host() ?? "")
            return binary(id, scheme == "https:" || local, items: scheme == "https:" || local ? [] : [LighthouseItem(url: page["url"] as? String)])
        case "doctype":
            let ok = (page["doctype"] as? String)?.lowercased() == "html" && (page["compatMode"] as? String) == "CSS1Compat"
            return binary(id, ok)
        case "charset":
            let header = input.response?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("charset") == true
            return binary(id, header || page["charsetMeta"] as? Bool == true)
        case "errors-in-console":
            let errors = (input.metrics?["errors"] as? [[Any]]) ?? []
            return binary(id, errors.isEmpty, items: errors.prefix(20).map {
                LighthouseItem(url: $0.count > 1 ? $0[1] as? String : nil, text: $0.first as? String)
            })
        case "viewport":
            guard let content = page["viewport"] as? String else {
                return binary(id, false, explanation: "No `<meta name=\"viewport\">` tag found")
            }
            let ok = content.lowercased().contains("width") || content.lowercased().contains("initial-scale")
            return binary(id, ok)
        case "meta-description":
            let text = (page["description"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return binary(id, !text.isEmpty, explanation: page["description"] == nil || page["description"] is NSNull ? nil
                          : text.isEmpty ? "Description text is empty." : nil)
        case "http-status-code":
            guard let status = input.response?.statusCode else {
                return LighthouseAudit(id: id, display: .notApplicable,
                                       explanation: "The status code is read from the page's load: run Navigation to check it.")
            }
            return binary(id, status < 400, items: status < 400 ? [] : [LighthouseItem(text: "Status \(status)")])
        case "is-crawlable":
            return crawlable(input)
        case "robots-txt":
            guard let robots = input.robots else {
                return LighthouseAudit(id: id, display: .notApplicable, explanation: "robots.txt couldn't be read for this page.")
            }
            if robots.status >= 500 { return binary(id, false, explanation: "robots.txt answered with status \(robots.status).") }
            if robots.status >= 400 { return LighthouseAudit(id: id, display: .notApplicable, explanation: "No robots.txt (status \(robots.status)).") }
            let bad = robots.invalidLines
            return binary(id, bad.isEmpty, items: bad.prefix(20).map { LighthouseItem(text: "Line \($0.0): \($0.1)") })
        case "hreflang":
            let links = (page["hreflangs"] as? [[Any]]) ?? []
            let bad = links.filter { link in
                let code = link.first as? String ?? ""
                return !(code.lowercased() == "x-default" || validLanguage(code)) || (link.count > 1 ? link[1] as? String ?? "" : "").isEmpty
            }
            return binary(id, bad.isEmpty, items: bad.map { LighthouseItem(text: $0.first as? String ?? "") })
        case "canonical":
            let links = (page["canonicals"] as? [[Any]]) ?? []
            guard !links.isEmpty else { return LighthouseAudit(id: id, display: .notApplicable) }
            let targets = Set(links.compactMap { $0.count > 1 ? $0[1] as? String : nil })
            if targets.count > 1 { return binary(id, false, explanation: "Multiple conflicting URLs (\(targets.sorted().joined(separator: ", ")))") }
            guard let target = targets.first, let url = URL(string: target), ["http", "https"].contains(url.scheme ?? "") else {
                return binary(id, false, explanation: "Invalid URL (\(links.first?.first as? String ?? ""))")
            }
            if let here = URL(string: page["url"] as? String ?? ""), !sameSite(url.host() ?? "", here.host() ?? "") {
                return binary(id, false, explanation: "Points to a different domain (\(url.host() ?? ""))")
            }
            return binary(id, true)
        case "dom-size":
            let dom = page["dom"] as? [String: Any] ?? [:]
            let count = number(dom["elements"]) ?? 0
            var audit = LighthouseAudit(id: id, score: LighthouseScoring.score(count, p10: 818, median: 1_400), display: .numeric,
                                        value: count, unit: "element", displayValue: "\(Int(count)) elements")
            audit.items = [LighthouseItem(text: "Total DOM elements: \(Int(count))"),
                           LighthouseItem(text: "Maximum DOM depth: \(Int(number(dom["depth"]) ?? 0))"),
                           LighthouseItem(text: "Maximum child elements: \(Int(number(dom["children"]) ?? 0))")]
            return audit
        case "render-blocking-resources", "uses-text-compression", "modern-image-formats", "uses-responsive-images",
             "offscreen-images", "total-byte-weight":
            return network(id, input)
        case "server-response-time":
            guard let ttfb = number(input.metrics?["ttfb"]) else { return LighthouseAudit(id: id, display: .notApplicable) }
            var audit = binary(id, ttfb < 600)
            audit.value = ttfb
            audit.unit = "millisecond"
            audit.displayValue = "Root document took \(Int(ttfb.rounded())) ms"
            return audit
        case "redirects":
            let count = Int(number(input.metrics?["redirects"]) ?? 0)
            var audit = binary(id, count < 2)
            if count > 0 { audit.displayValue = "\(count) redirect\(count == 1 ? "" : "s")" }
            return audit
        case "lcp-lazy-loaded":
            guard input.metrics?["lcpElement"] is String else { return LighthouseAudit(id: id, display: .notApplicable) }
            let lazy = input.metrics?["lcpLazy"] as? Bool == true
            return binary(id, !lazy, items: [LighthouseItem(node: LighthouseNode(snippet: input.metrics?["lcpElement"] as? String ?? ""))])
        default:
            return found(id, page)
        }
    }

    /// The audits the page script checked: how many, and which failed.
    static func found(_ id: String, _ page: [String: Any]) -> LighthouseAudit {
        guard let finding = (page["findings"] as? [String: Any])?[id] as? [String: Any] else {
            return LighthouseAudit(id: id, display: .error, explanation: "Not checked")
        }
        let checked = Int(number(finding["checked"]) ?? 0)
        let failing = (finding["failing"] as? [Any] ?? []).compactMap(LighthouseNode.init)
        let values = finding["values"] as? [String] ?? []
        guard checked > 0 || !failing.isEmpty else { return LighthouseAudit(id: id, display: .notApplicable) }
        let items = failing.enumerated().map { index, node in
            LighthouseItem(node: node, text: index < values.count ? values[index] : nil)
        }
        return binary(id, failing.isEmpty, items: items)
    }

    static func binary(_ id: String, _ passed: Bool, items: [LighthouseItem] = [], explanation: String? = nil) -> LighthouseAudit {
        LighthouseAudit(id: id, score: passed ? 1 : 0, display: .binary, items: passed ? [] : items, explanation: explanation)
    }

    /// A BCP 47 tag, as far as its shape goes.
    static func validLanguage(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count) || first.count == 8,
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
            && Locale.LanguageCode(String(first)).isISOLanguage
    }

    static func crawlable(_ input: LighthouseInput) -> LighthouseAudit {
        var items: [LighthouseItem] = []
        let blocked = { (value: String) in
            value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { $0 == "noindex" || $0 == "none" }
        }
        for content in (input.page["robots"] as? [String]) ?? [] where blocked(content) {
            items.append(LighthouseItem(text: "<meta name=\"robots\" content=\"\(content)\">"))
        }
        if let header = input.response?.value(forHTTPHeaderField: "X-Robots-Tag"), blocked(header) {
            items.append(LighthouseItem(text: "X-Robots-Tag: \(header)"))
        }
        if let robots = input.robots, robots.status < 400, let url = URL(string: input.page["url"] as? String ?? ""),
           robots.blocks(url.path.isEmpty ? "/" : url.path) {
            items.append(LighthouseItem(text: "robots.txt blocks this page"))
        }
        return binary("is-crawlable", items.isEmpty, items: items)
    }

    static func measured(_ metric: LighthouseMetric, _ input: LighthouseInput) -> LighthouseAudit {
        let metrics = input.metrics ?? [:]
        let fcp = number(metrics["fcp"])
        var value: Double?
        var why: String?
        switch metric {
        case .fcp:
            value = fcp
            why = "The page painted nothing that counts, or WebKit didn't report it (the page must be on screen)."
        case .lcp:
            value = number(metrics["lcp"])
            why = metrics["lcpSupported"] as? Bool == true ? "No largest contentful paint was reported."
                : "This WebKit doesn't report largest contentful paint."
        case .cls:
            value = number(metrics["cls"])
        case .tbt:
            guard let fcp else { why = "Needs First Contentful Paint."; break }
            let end = number(metrics["load"]).map { max($0, fcp) + 5_000 } ?? number(metrics["now"]) ?? .infinity
            var total = 0.0
            for task in (metrics["tasks"] as? [[Any]]) ?? [] {
                guard task.count == 2, let start = number(task[0]), let duration = number(task[1]) else { continue }
                let from = max(start, fcp), to = min(start + duration, end)
                guard to > from else { continue }
                // Only what's over 50 ms blocks, counted for the part after FCP.
                total += max(0, (to - from) - max(0, 50 - (from - start)))
            }
            value = total
        case .si:
            value = input.speedIndex
            why = "Speed Index needs pictures of the page as it loads: the tab must be on screen."
        }
        guard let value, value.isFinite else {
            return LighthouseAudit(id: metric.rawValue, display: .error, explanation: why)
        }
        let curve = metric.curve(input.form)
        return LighthouseAudit(id: metric.rawValue, score: LighthouseScoring.score(value, p10: curve.p10, median: curve.median),
                               display: .numeric, value: value, unit: metric == .cls ? "unitless" : "millisecond",
                               displayValue: metric.display(value))
    }

    // MARK: requests

    struct Resource {
        let url: String
        let type: String
        let start: Double
        let end: Double
        let transfer: Double
        let encoded: Double
        let decoded: Double

        init?(_ raw: Any) {
            guard let raw = raw as? [String: Any], let url = raw["name"] as? String else { return nil }
            self.url = url
            type = raw["type"] as? String ?? ""
            start = number(raw["start"]) ?? 0
            end = number(raw["end"]) ?? 0
            transfer = number(raw["transfer"]) ?? 0
            encoded = number(raw["encoded"]) ?? 0
            decoded = number(raw["decoded"]) ?? 0
        }

        /// Resource timing gives sizes only for the page's own origin, or
        /// another that says Timing-Allow-Origin.
        var bytes: Double { max(transfer, encoded) }
    }

    static func network(_ id: String, _ input: LighthouseInput) -> LighthouseAudit {
        let page = input.page
        let resources = ((page["resources"] as? [Any]) ?? []).compactMap(Resource.init)
        let byURL = Dictionary(resources.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let ms = { (bytes: Double) in bytes * 8 / input.form.throughputKbps }
        func opportunity(_ items: [LighthouseItem], bytes: Double, msOverride: Double? = nil) -> LighthouseAudit {
            let wastedMs = msOverride ?? ms(bytes)
            var audit = LighthouseAudit(id: id, score: items.isEmpty ? 1 : LighthouseScoring.wasted(wastedMs), display: .numeric,
                                        items: items, savingsMs: wastedMs, savingsBytes: bytes)
            if !items.isEmpty {
                audit.displayValue = bytes > 0 ? "Est. savings of \(Int((bytes / 1024).rounded())) KiB" : "Est. savings of \(Int(wastedMs)) ms"
            }
            return audit
        }
        switch id {
        case "render-blocking-resources":
            let head = (page["head"] as? [[String: Any]]) ?? []
            let fcp = number(input.metrics?["fcp"])
            var items: [LighthouseItem] = []
            var longest = 0.0
            for entry in head {
                guard let url = entry["url"] as? String, let resource = byURL[url] else { continue }
                if let fcp, resource.start > fcp { continue }
                let duration = max(0, resource.end - resource.start)
                longest = max(longest, duration)
                items.append(LighthouseItem(url: url, bytes: resource.bytes, ms: duration))
            }
            return opportunity(items, bytes: 0, msOverride: items.isEmpty ? 0 : longest)
        case "uses-text-compression":
            let textual: Set<String> = ["script", "css", "link", "xmlhttprequest", "fetch", "navigation"]
            var items: [LighthouseItem] = []
            var saved = 0.0
            var candidates = resources.filter { textual.contains($0.type) }
            if let document = page["document"] as? [String: Any], let url = page["url"] as? String,
               let made = Resource(["name": url, "type": "navigation", "transfer": document["transfer"] ?? 0,
                                    "encoded": document["encoded"] ?? 0, "decoded": document["decoded"] ?? 0]) {
                candidates.append(made)
            }
            for resource in candidates where resource.decoded >= 1_400 && resource.encoded > 0 && resource.encoded >= resource.decoded * 0.95 {
                // A typical gzip of text saves about two thirds.
                let wasted = resource.encoded * 0.65
                guard wasted >= 1_400 else { continue }
                saved += wasted
                items.append(LighthouseItem(url: resource.url, bytes: wasted))
            }
            return opportunity(items, bytes: saved)
        case "modern-image-formats", "uses-responsive-images", "offscreen-images":
            let images = (page["images"] as? [[String: Any]]) ?? []
            let viewportHeight = number(page["height"]) ?? 800
            let ratio = number(page["dpr"]) ?? 1
            var items: [LighthouseItem] = []
            var saved = 0.0
            var seen = Set<String>()
            for image in images {
                guard let src = image["src"] as? String, !src.hasPrefix("data:"), seen.insert(src).inserted,
                      let resource = byURL[src], resource.bytes > 0 else { continue }
                let bytes = resource.bytes
                var wasted = 0.0
                switch id {
                case "modern-image-formats":
                    let path = (URL(string: src)?.path ?? src).lowercased()
                    let share = path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") ? 0.3
                        : path.hasSuffix(".png") || path.hasSuffix(".gif") || path.hasSuffix(".bmp") ? 0.5 : 0
                    wasted = bytes * share
                case "uses-responsive-images":
                    let natural = (number(image["nw"]) ?? 0) * (number(image["nh"]) ?? 0)
                    let shown = (number(image["dw"]) ?? 0) * (number(image["dh"]) ?? 0) * ratio * ratio
                    if natural > 0, shown > 0, natural > shown { wasted = bytes * (1 - shown / natural) }
                default:
                    let top = number(image["top"]) ?? 0
                    if top > viewportHeight * 3, image["lazy"] as? Bool != true { wasted = bytes }
                }
                guard wasted >= 4_096 else { continue }
                saved += wasted
                items.append(LighthouseItem(node: LighthouseNode(image["n"]), url: src, bytes: wasted))
            }
            return opportunity(items, bytes: saved)
        default:
            // total-byte-weight: what the page asked for, where sizes are known.
            var total = resources.reduce(0) { $0 + $1.bytes }
            if let document = page["document"] as? [String: Any] {
                total += max(number(document["transfer"]) ?? 0, number(document["encoded"]) ?? 0)
            }
            let largest = resources.sorted { $0.bytes > $1.bytes }.prefix(10)
            var audit = LighthouseAudit(id: id, score: LighthouseScoring.score(total, p10: 2_667 * 1024, median: 4_000 * 1024),
                                        display: .numeric, value: total, unit: "byte",
                                        displayValue: "Total size was \(Int((total / 1024).rounded())) KiB")
            audit.items = largest.map { LighthouseItem(url: $0.url, bytes: $0.bytes) }
            return audit
        }
    }
}
