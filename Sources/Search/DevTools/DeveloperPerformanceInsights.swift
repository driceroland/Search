import Foundation

/// One of Performance › Insights' cards, as Chrome DevTools shows them
/// beside the timeline: a check over the recording, whether it passed,
/// what it found (each row a time or a record to show), and what to
/// highlight on the timeline while the card is hovered or open.
struct DeveloperPerformanceInsight: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case lcpBreakdown, lcpDiscovery, inpBreakdown, renderBlocking, networkDependencyTree, documentLatency,
             imageDelivery, fontDisplay, layoutShifts, forcedReflow, cacheLifetimes, viewport, modernHTTP,
             duplicatedJavaScript, legacyJavaScript, longTasks, thirdParties, domSize, characterSet
    }

    enum Verdict { case fail, info, pass }

    struct Row: Identifiable, Equatable {
        let id: Int
        let label: String
        let value: String
        var detail: String?
        /// A range of the recording to show, in ms.
        var range: ClosedRange<Double>?
        /// A record to select, in `events`.
        var event: Int?
        var failing = false
    }

    let kind: Kind
    let title: String
    let verdict: Verdict
    /// What the insight is about, as Chrome describes it.
    let explanation: String
    /// Its finding in a few words: "LCP 2.8 s", "3 requests".
    let headline: String?
    var rows: [Row] = []
    /// What to highlight on the timeline.
    var ranges: [ClosedRange<Double>] = []
    var events: [Int] = []

    var id: String { kind.rawValue }

    /// The part of the recording the card is about: all of its ranges and records.
    func span(in profile: DeveloperPerformanceProfile) -> ClosedRange<Double>? {
        var lower = Double.infinity, upper = -Double.infinity
        for range in ranges {
            lower = min(lower, range.lowerBound)
            upper = max(upper, range.upperBound)
        }
        for id in events where profile.events.indices.contains(id) {
            lower = min(lower, profile.events[id].start)
            upper = max(upper, profile.events[id].end)
        }
        guard lower.isFinite, upper.isFinite else { return nil }
        return lower...max(lower, upper)
    }
}

/// Insights' checks: heuristics over a recorded profile in the spirit of
/// Chrome's, each with Chrome's thresholds.
enum DeveloperPerformanceInsights {
    typealias Insight = DeveloperPerformanceInsight
    typealias Row = DeveloperPerformanceInsight.Row
    typealias Profile = DeveloperPerformanceProfile

    /// As Chrome: LCP over 2.5 s, INP over 200 ms, CLS over 0.1 fail.
    static let goodLCP = 2_500.0
    static let goodINP = 200.0
    static let goodCLS = 0.1
    /// A document response over 600 ms is slow, as Chrome's Document request latency says.
    static let slowServer = 600.0
    /// Lighthouse's DOM size limits.
    static let largeDOM = 1_400
    static let deepDOM = 32
    /// A document smaller than this needn't be compressed.
    static let compressionMinimum = 1_400.0

    /// Every insight the recording has the data for, failing ones first.
    /// The JavaScript insights also need the page's scripts
    /// (DeveloperPerformanceInsightsJavaScript); without them they're left out.
    static func all(_ profile: Profile, page: URL? = nil, scripts: [DeveloperPerformanceScript]? = nil) -> [Insight] {
        var found = [
            lcpBreakdown(profile, page: page), lcpDiscovery(profile, page: page), inpBreakdown(profile),
            renderBlocking(profile), networkDependencyTree(profile, page: page), documentLatency(profile, page: page),
            imageDelivery(profile), fontDisplay(profile), layoutShifts(profile), forcedReflow(profile),
            cacheLifetimes(profile), viewport(profile), modernHTTP(profile, page: page), longTasks(profile),
            thirdParties(profile, page: page), domSize(profile), characterSet(profile, page: page),
        ].compactMap { $0 }
        if let scripts { found += javaScriptInsights(profile, scripts: scripts) }
        return ranked(found)
    }

    /// Failing first, then those that only inform, then passing; else in
    /// `Kind`'s order, Chrome's.
    static func ranked(_ found: [Insight]) -> [Insight] {
        let order = Dictionary(uniqueKeysWithValues: Insight.Kind.allCases.enumerated().map { ($0.element, $0.offset) })
        func rank(_ verdict: Insight.Verdict) -> Int {
            switch verdict {
            case .fail: 0
            case .info: 1
            case .pass: 2
            }
        }
        return found.enumerated().sorted { a, b in
            let x = rank(a.element.verdict), y = rank(b.element.verdict)
            if x != y { return x < y }
            let p = order[a.element.kind] ?? 0, q = order[b.element.kind] ?? 0
            return p != q ? p < q : a.offset < b.offset
        }.map(\.element)
    }

    static func time(_ value: Double) -> String { DeveloperPerformanceRuler.label(value) }

    static func file(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let last = parsed.lastPathComponent
        if last.isEmpty || last == "/" { return parsed.host ?? url }
        return last
    }

    static func stripped(_ url: String) -> String {
        url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
    }

    // MARK: The page's document

    /// The page's main document request: the one for the page's address,
    /// or else the first document requested.
    static func mainDocument(_ profile: Profile, page: URL? = nil) -> Profile.NetworkBar? {
        let documents = profile.network.filter { $0.resourceType == "Document" && !$0.isRedirect }
            .sorted { $0.start < $1.start }
        let address = profile.pageInfo["url"] ?? page?.absoluteString
        if let address, let match = documents.first(where: { stripped($0.url) == stripped(address) }) { return match }
        return documents.first
    }

    /// When the navigation began: the document's first redirect hop, or its request.
    static func navigationStart(_ document: Profile.NetworkBar) -> Double {
        document.start - document.redirectTime
    }

    // MARK: LCP breakdown

    static func lcpBreakdown(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard let lcp = profile.markers.last(where: { $0.kind == "LCP" }) else { return nil }
        let explanation = "Each phase has specific improvement strategies. Ideally, most of the LCP time should be spent "
            + "on loading the resources, not within delays."
        guard let document = mainDocument(profile, page: page), navigationStart(document) <= lcp.start else {
            return Insight(kind: .lcpBreakdown, title: "LCP breakdown", verdict: .info,
                           explanation: explanation + " Record the page load to see its phases.",
                           headline: nil, ranges: [lcp.start...lcp.start])
        }
        let start = navigationStart(document)
        let value = lcp.start - start
        let firstByte = min(lcp.start, max(start, document.responseStart ?? document.end))
        var phases: [(String, ClosedRange<Double>)] = [("Time to first byte", start...firstByte)]
        let address = profile.pageInfo["lcpURL"].map(stripped)
        if let address, let request = profile.network.first(where: { !$0.isRedirect && stripped($0.url) == address }) {
            let loadStart = min(lcp.start, max(firstByte, request.start))
            let loadEnd = min(lcp.start, max(loadStart, request.end))
            phases += [("Resource load delay", firstByte...loadStart), ("Resource load duration", loadStart...loadEnd),
                       ("Element render delay", loadEnd...lcp.start)]
        } else {
            phases.append(("Element render delay", firstByte...lcp.start))
        }
        let rows = phases.enumerated().map { index, phase in
            Row(id: index, label: phase.0, value: time(phase.1.upperBound - phase.1.lowerBound), range: phase.1)
        }
        let failing = value > goodLCP
        return Insight(kind: .lcpBreakdown, title: "LCP breakdown", verdict: failing ? .fail : .pass,
                       explanation: explanation, headline: "LCP \(time(value))", rows: rows,
                       ranges: phases.map { $0.1 })
    }

    // MARK: INP breakdown

    static func inpBreakdown(_ profile: Profile) -> Insight? {
        guard let slowest = profile.interactions.max(by: { $0.duration < $1.duration }) else { return nil }
        let phases: [(String, ClosedRange<Double>)] = [
            ("Input delay", slowest.start...slowest.processingStart),
            ("Processing duration", slowest.processingStart...slowest.processingEnd),
            ("Presentation delay", slowest.processingEnd...slowest.end),
        ]
        let longest = phases.map { $0.1.upperBound - $0.1.lowerBound }.max() ?? 0
        let rows = phases.enumerated().map { index, phase in
            let length = phase.1.upperBound - phase.1.lowerBound
            return Row(id: index, label: phase.0, value: time(length), range: phase.1,
                       event: index == 1 ? slowest.event : nil, failing: length == longest && slowest.duration > goodINP)
        }
        return Insight(kind: .inpBreakdown, title: "INP breakdown", verdict: slowest.duration > goodINP ? .fail : .pass,
                       explanation: "Start investigating with the longest subpart. Delays can be minimized. "
                           + "To reduce processing duration, optimize the main-thread costs, often JS.",
                       headline: "\(slowest.type) \(time(slowest.duration))", rows: rows,
                       ranges: [slowest.start...slowest.end], events: [slowest.event])
    }

    // MARK: Render blocking requests

    static func isRenderBlockingType(_ bar: Profile.NetworkBar) -> Bool {
        isRenderBlockingType(bar.resourceType, mimeType: bar.mimeType)
    }

    /// A stylesheet or script, by its resource type or else its MIME type.
    static func isRenderBlockingType(_ resourceType: String, mimeType: String?) -> Bool {
        if ["Stylesheet", "StyleSheet", "Script"].contains(resourceType) { return true }
        let type = (mimeType ?? "").lowercased()
        return type.contains("css") || type.contains("javascript") || type.contains("ecmascript")
    }

    /// Stylesheets and scripts begun and done before the first contentful
    /// paint: the page waited for them to paint.
    static func renderBlocking(_ profile: Profile) -> Insight? {
        guard let fcp = profile.markers.first(where: { $0.kind == "FCP" }) else { return nil }
        let blocking = profile.network.filter {
            !$0.isRedirect && isRenderBlockingType($0) && $0.start < fcp.start && $0.end <= fcp.start
        }
        .sorted { $0.duration > $1.duration }
        let rows = blocking.prefix(20).enumerated().map { index, bar in
            Row(id: index, label: file(bar.url), value: time(bar.duration), detail: bar.url, range: bar.start...bar.end,
                failing: true)
        }
        return Insight(kind: .renderBlocking, title: "Render blocking requests", verdict: blocking.isEmpty ? .pass : .fail,
                       explanation: "Requests are blocking the page's initial render, which may delay LCP. Deferring or "
                           + "inlining can move these network requests out of the critical path.",
                       headline: blocking.isEmpty ? "No render blocking requests"
                           : blocking.count == 1 ? "1 request" : "\(blocking.count) requests",
                       rows: Array(rows), ranges: blocking.map { $0.start...$0.end })
    }

    // MARK: Document request latency

    static func documentLatency(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard let document = mainDocument(profile, page: page) else { return nil }
        let start = navigationStart(document)
        var rows: [Row] = []
        let redirected = document.redirects > 0
        rows.append(Row(id: 0, label: redirected ? "Had redirects" : "Avoids redirects",
                        value: redirected ? "\(document.redirects) · \(time(document.redirectTime))" : "0",
                        range: redirected ? start...document.start : nil, failing: redirected))
        if let response = document.responseStart {
            let wait = response - document.start
            let slow = wait > slowServer
            rows.append(Row(id: 1, label: slow ? "Server responded slowly" : "Server responds quickly",
                            value: time(wait), range: document.start...response, failing: slow))
        }
        if let encoding = document.encoding?.lowercased(), !encoding.isEmpty, encoding != "identity" {
            rows.append(Row(id: 2, label: "Applies text compression", value: encoding))
        } else if document.responseStart != nil || document.status != nil {
            let small = (document.transferSize ?? .infinity) < compressionMinimum
            rows.append(Row(id: 2, label: small ? "Applies text compression" : "No compression applied",
                            value: small ? "Not needed" : document.transferSize.map(DeveloperMetricFormat.bytes) ?? "None",
                            failing: !small))
        }
        let failing = rows.contains { $0.failing }
        return Insight(kind: .documentLatency, title: "Document request latency", verdict: failing ? .fail : .pass,
                       explanation: "Your first network request is the most important. Reduce its latency by avoiding "
                           + "redirects, ensuring a fast server response, and enabling text compression.",
                       headline: file(document.url), rows: rows, ranges: [start...document.end])
    }

    // MARK: Layout shift culprits

    static func layoutShifts(_ profile: Profile) -> Insight? {
        let explanation = "Layout shifts occur when elements move absent any user interaction. Investigate the causes "
            + "of layout shifts, such as elements being added, removed, or their fonts changing as the page loads."
        guard let worst = profile.shiftClusters.max(by: { $0.score < $1.score }) else {
            // Only when the page's shifts were watched for.
            guard !profile.markers.isEmpty || !profile.pageInfo.isEmpty else { return nil }
            return Insight(kind: .layoutShifts, title: "Layout shift culprits", verdict: .pass,
                           explanation: explanation, headline: "No layout shifts")
        }
        var rows: [Row] = []
        for index in worst.shifts where profile.layoutShifts.indices.contains(index) {
            let shift = profile.layoutShifts[index]
            rows.append(Row(id: index, label: "Layout shift at \(time(shift.time))",
                            value: String(format: "%.4f", shift.score),
                            detail: shift.nodes.isEmpty ? nil : shift.nodes.joined(separator: ", "),
                            range: shift.time...shift.time))
        }
        let failing = worst.score > goodCLS
        return Insight(kind: .layoutShifts, title: "Layout shift culprits", verdict: failing ? .fail : .pass,
                       explanation: explanation,
                       headline: "Worst cluster \(String(format: "%.4f", worst.score))", rows: rows,
                       ranges: [worst.start...worst.end])
    }

    /// The distinct elements the worst cluster moved, as Chrome lists its culprits.
    static func culprits(_ profile: Profile) -> [String] {
        guard let worst = profile.shiftClusters.max(by: { $0.score < $1.score }) else { return [] }
        var seen: [String] = []
        for index in worst.shifts where profile.layoutShifts.indices.contains(index) {
            for node in profile.layoutShifts[index].nodes where !seen.contains(node) { seen.append(node) }
        }
        return seen
    }

    // MARK: Forced reflow

    static let scriptTypes: Set<String> = ["FunctionCall", "EvaluateScript"]

    /// Layout and style recalculation that script waited for: those
    /// records nested in a script's, and the script code that asked.
    static func forcedReflows(_ profile: Profile) -> [(event: Int, source: String)] {
        var found: [(event: Int, source: String)] = []
        for event in profile.events where event.type == "Layout" || event.type == "RecalculateStyles" {
            var parent = event.parent
            var frame: DeveloperPerformanceEvent?
            var script: DeveloperPerformanceEvent?
            while let index = parent, profile.events.indices.contains(index) {
                let outer = profile.events[index]
                if frame == nil, outer.type == "JavaScriptFrame" { frame = outer }
                if Self.scriptTypes.contains(outer.type) {
                    script = outer
                    break
                }
                parent = outer.parent
            }
            guard let script else { continue }
            let source = event.stack.first ?? frame?.activity ?? script.activity
            found.append((event.id, source))
        }
        return found
    }

    static func forcedReflow(_ profile: Profile) -> Insight? {
        let reflows = forcedReflows(profile)
        guard !profile.events.isEmpty else { return nil }
        var groups: [String: (time: Double, events: [Int])] = [:]
        for reflow in reflows {
            var group = groups[reflow.source] ?? (time: 0, events: [])
            group.time += profile.events[reflow.event].duration
            group.events.append(reflow.event)
            groups[reflow.source] = group
        }
        let sorted = groups.sorted { $0.value.time != $1.value.time ? $0.value.time > $1.value.time : $0.key < $1.key }
        let rows = sorted.prefix(10).enumerated().map { index, group in
            let longest = group.value.events.max { profile.events[$0].duration < profile.events[$1].duration }
            return Row(id: index, label: group.key, value: time(group.value.time),
                       detail: group.value.events.count == 1 ? nil : "\(group.value.events.count) reflows",
                       event: longest, failing: true)
        }
        let total = reflows.reduce(0) { $0 + profile.events[$1.event].duration }
        return Insight(kind: .forcedReflow, title: "Forced reflow", verdict: reflows.isEmpty ? .pass : .fail,
                       explanation: "A forced reflow occurs when JavaScript queries geometric properties (such as "
                           + "offsetWidth) after styles have been invalidated by a change to the DOM state. This can "
                           + "result in poor performance.",
                       headline: reflows.isEmpty ? "No forced reflows" : "Total reflow time \(time(total))",
                       rows: Array(rows), events: Array(reflows.map { $0.event }.prefix(500)))
    }

    // MARK: Long tasks

    /// What a task spent its time on: the activities nested in it, by
    /// self time, busiest first.
    static func busiest(_ task: DeveloperPerformanceEvent, in profile: Profile, limit: Int = 3) -> [String] {
        var totals: [String: Double] = [:]
        var stack = task.children
        var visited = 0
        while let id = stack.popLast(), visited < 20_000 {
            visited += 1
            guard profile.events.indices.contains(id) else { continue }
            let event = profile.events[id]
            totals[event.activity, default: 0] += event.selfTime
            stack += event.children
        }
        if totals.isEmpty { return [task.activity] }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    static func totalBlockingTime(_ profile: Profile) -> Double {
        profile.longTasks.reduce(0) { $0 + max(0, profile.events[$1].duration - Profile.longTask) }
    }

    static func longTasks(_ profile: Profile) -> Insight? {
        guard !profile.events.isEmpty else { return nil }
        let tasks = profile.longTasks.sorted { profile.events[$0].duration > profile.events[$1].duration }
        let blocking = totalBlockingTime(profile)
        let rows = tasks.prefix(5).enumerated().map { index, id in
            let task = profile.events[id]
            return Row(id: index, label: task.activity, value: time(task.duration),
                       detail: busiest(task, in: profile).joined(separator: ", "), event: id, failing: true)
        }
        let headline = tasks.isEmpty ? "No long tasks"
            : "\(tasks.count == 1 ? "1 long task" : "\(tasks.count) long tasks") · total blocking time \(time(blocking))"
        return Insight(kind: .longTasks, title: "Long main-thread tasks", verdict: tasks.isEmpty ? .pass : .fail,
                       explanation: "Tasks over 50 ms block the main thread, so the page can't respond to input. "
                           + "Break long tasks up, or move their work off the main thread.",
                       headline: headline, rows: Array(rows), events: tasks)
    }

    // MARK: 3rd parties

    /// A host's site, as close to Chrome's entities as a host can say:
    /// its last two labels, or three under a country's second level
    /// ("example.co.uk").
    static func site(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        if labels.allSatisfy({ Int($0) != nil }) { return labels.joined(separator: ".") }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        let take = last.count == 2 && second.count <= 3 ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func site(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return site(host)
    }

    struct ThirdParty: Equatable {
        let site: String
        var transferSize = 0.0
        var mainThreadTime = 0.0
        var requests = 0
    }

    /// Requests and script time grouped by site, the page's own left out.
    static func thirdPartyUsage(_ profile: Profile, page: URL? = nil) -> [ThirdParty] {
        let address = profile.pageInfo["url"] ?? page?.absoluteString ?? mainDocument(profile)?.url
        guard let address, let own = site(of: address) else { return [] }
        var parties: [String: ThirdParty] = [:]
        for bar in profile.network where !bar.isRedirect {
            guard let name = site(of: bar.url), name != own else { continue }
            parties[name, default: ThirdParty(site: name)].requests += 1
            parties[name, default: ThirdParty(site: name)].transferSize += bar.transferSize ?? 0
        }
        for event in profile.events where event.selfTime > 0 {
            guard let url = event.data["url"] ?? event.data["scriptName"], let name = site(of: url), name != own else { continue }
            parties[name, default: ThirdParty(site: name)].mainThreadTime += event.selfTime
        }
        return parties.values.sorted {
            if $0.mainThreadTime != $1.mainThreadTime { return $0.mainThreadTime > $1.mainThreadTime }
            if $0.transferSize != $1.transferSize { return $0.transferSize > $1.transferSize }
            return $0.site < $1.site
        }
    }

    static func thirdParties(_ profile: Profile, page: URL? = nil) -> Insight? {
        guard !profile.network.isEmpty else { return nil }
        let parties = thirdPartyUsage(profile, page: page)
        let rows = parties.prefix(10).enumerated().map { index, party in
            Row(id: index, label: party.site,
                value: "\(DeveloperMetricFormat.bytes(party.transferSize)) · \(time(party.mainThreadTime))",
                detail: party.requests == 1 ? "1 request" : "\(party.requests) requests")
        }
        let sites = Set(parties.prefix(10).map(\.site))
        let ranges = profile.network.filter { !$0.isRedirect && site(of: $0.url).map { sites.contains($0) } == true }
            .prefix(200).map { $0.start...$0.end }
        return Insight(kind: .thirdParties, title: "3rd parties", verdict: parties.isEmpty ? .pass : .info,
                       explanation: "3rd party code can significantly impact load performance. Reduce and defer "
                           + "loading of 3rd party code to prioritize your page's content.",
                       headline: parties.isEmpty ? "No 3rd parties" : "Transfer size · main thread time",
                       rows: Array(rows), ranges: Array(ranges))
    }

    // MARK: DOM size

    static func domSize(_ profile: Profile) -> Insight? {
        guard let elements = profile.pageInfo["domElements"].flatMap({ Int($0) }) else { return nil }
        let depth = profile.pageInfo["domDepth"].flatMap { Int($0) }
        let children = profile.pageInfo["domChildren"].flatMap { Int($0) }
        var rows = [Row(id: 0, label: "Total elements", value: DeveloperMetricFormat.integer(Double(elements)),
                        failing: elements > largeDOM)]
        if let depth {
            rows.append(Row(id: 1, label: "DOM depth", value: DeveloperMetricFormat.integer(Double(depth)),
                            failing: depth > deepDOM))
        }
        if let children {
            rows.append(Row(id: 2, label: "Most children", value: DeveloperMetricFormat.integer(Double(children))))
        }
        let failing = rows.contains { $0.failing }
        return Insight(kind: .domSize, title: "DOM size", verdict: failing ? .fail : .pass,
                       explanation: "A large DOM can increase the duration of style calculations and layout reflows, "
                           + "impacting page responsiveness. A large DOM will also increase memory usage.",
                       headline: "\(DeveloperMetricFormat.integer(Double(elements))) elements", rows: rows)
    }
}
