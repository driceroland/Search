import Foundation

/// The report as one self-contained HTML page, as Lighthouse's "Save as
/// HTML" writes one: a gauge per category, the metrics, the audits of each
/// category in their groups (failed, then passed, then not applicable),
/// the opportunities with their savings, the diagnostics, each audit's
/// details table, and the run's environment. Search's own markup and
/// styles, inline, with no scripts: it opens anywhere, offline.
enum DeveloperLighthouseHTML {
    static func html(_ report: DeveloperLighthouseReport) -> String {
        var out = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Lighthouse report: \(escape(report.finalURL))</title>
            <style>\(style)</style>
            </head>
            <body>
            <header>
            <h1>Lighthouse report</h1>
            <p class="url"><a href="\(escape(report.finalURL))">\(escape(report.finalURL))</a></p>
            <p class="note">\(escape(DeveloperLighthouseLHR.note))</p>
            </header>
            <nav class="gauges">
            """
        for category in report.categories {
            out += "<a class=\"gauge-link\" href=\"#\(escape(category.id.rawValue))\">"
                + gauge(report, category) + "<span>\(escape(category.title))</span></a>\n"
        }
        out += "</nav>\n"
        out += """
            <p class="legend"><span class="dot fail"></span>0–49 <span class="dot average"></span>50–89 \
            <span class="dot pass"></span>90–100</p>\n
            """
        if !report.warnings.isEmpty {
            out += "<section class=\"warnings\"><h2>Runtime warnings</h2><ul>"
            for warning in report.warnings { out += "<li>\(inline(warning))</li>" }
            out += "</ul></section>\n"
        }
        for category in report.categories { out += section(report, category) }
        out += environment(report)
        out += "</body>\n</html>\n"
        return out
    }

    // MARK: Categories

    private static func gauge(_ report: DeveloperLighthouseReport, _ category: DeveloperLighthouseCategory,
                              size: Int = 96) -> String {
        let fraction = report.mode != .navigation && category.id == .performance ? report.fraction(category) : nil
        let rating: String
        let filled: Double
        let label: String
        if let fraction {
            rating = "neutral"
            filled = fraction.total > 0 ? Double(fraction.passed) / Double(fraction.total) : 0
            label = "\(fraction.passed)/\(fraction.total)"
        } else if let score = category.score {
            rating = DeveloperLighthouseScoring.rating(score).rawValue
            filled = score
            label = "\(Int((score * 100).rounded()))"
        } else {
            rating = "neutral"
            filled = 0
            label = "–"
        }
        let radius = 42.0
        let circumference = 2 * Double.pi * radius
        let dash = String(format: "%.2f %.2f", circumference * max(0, min(1, filled)), circumference)
        return """
            <svg class="gauge \(rating)" width="\(size)" height="\(size)" viewBox="0 0 100 100" role="img" \
            aria-label="\(escape(category.title)): \(escape(label))">\
            <circle class="track" cx="50" cy="50" r="\(radius)"/>\
            <circle class="arc" cx="50" cy="50" r="\(radius)" stroke-dasharray="\(dash)" transform="rotate(-90 50 50)"/>\
            <text x="50" y="50" dominant-baseline="central" text-anchor="middle">\(escape(label))</text></svg>
            """
    }

    private typealias Entry = (ref: DeveloperLighthouseAuditRef, audit: DeveloperLighthouseAudit)

    /// Whether an audit is one that passes or fails on a score.
    private static func scored(_ audit: DeveloperLighthouseAudit) -> Bool {
        audit.mode == .numeric || audit.mode == .binary
    }

    private static func section(_ report: DeveloperLighthouseReport, _ category: DeveloperLighthouseCategory) -> String {
        var out = "<section class=\"category\" id=\"\(escape(category.id.rawValue))\">\n"
        out += "<div class=\"category-head\">" + gauge(report, category, size: 120)
            + "<div><h2>\(escape(category.title))</h2><p>\(inline(category.id.description))</p></div></div>\n"
        let entries: [Entry] = category.refs.compactMap { (ref: DeveloperLighthouseAuditRef) -> Entry? in
            guard let audit = report.audits[ref.id] else { return nil }
            return (ref: ref, audit: audit)
        }
        let performance: Bool = category.id == .performance
        if performance {
            let metrics: [Entry] = entries.filter { $0.ref.group == "metrics" }
            if !metrics.isEmpty {
                out += "<h3>Metrics</h3>\n<div class=\"metrics\">"
                for entry in metrics { out += metric(entry.audit) }
                out += "</div>\n"
            }
        }
        let rest: [Entry] = entries.filter { (entry: Entry) -> Bool in !(performance && entry.ref.group == "metrics") }
        let failing: [Entry] = rest.filter { (entry: Entry) -> Bool in
            scored(entry.audit) && entry.audit.score != nil && !entry.audit.passed
        } + rest.filter { (entry: Entry) -> Bool in entry.audit.mode == .informative || entry.audit.mode == .error }
        let passed: [Entry] = rest.filter { (entry: Entry) -> Bool in scored(entry.audit) && entry.audit.passed }
        let manual: [Entry] = rest.filter { (entry: Entry) -> Bool in entry.audit.mode == .manual }
        let notApplicable: [Entry] = rest.filter { (entry: Entry) -> Bool in
            entry.audit.mode == .notApplicable || (scored(entry.audit) && entry.audit.score == nil)
        }
        out += failingGroups(failing)
        out += collapsed("Passed audits", passed, status: "pass")
        out += collapsed("Additional items to manually check", manual, status: "manual")
        out += collapsed("Not applicable", notApplicable, status: "na")
        out += "</section>\n"
        return out
    }

    /// The failing audits, in their groups in the catalogue's order.
    private static func failingGroups(_ failing: [Entry]) -> String {
        var out = ""
        var groupOrder: [String] = []
        for entry in failing {
            let group: String = entry.ref.group ?? ""
            if !groupOrder.contains(group) { groupOrder.append(group) }
        }
        for group in groupOrder {
            let members: [Entry] = failing.filter { ($0.ref.group ?? "") == group }
            out += "<div class=\"group\">"
            if let info = DeveloperLighthouseCatalog.groups[group] {
                out += "<h3>\(escape(info.title))</h3>"
                if let description = info.description { out += "<p class=\"group-description\">\(inline(description))</p>" }
            }
            if group == "load-opportunities" {
                out += "<div class=\"opportunity-head\"><span>Opportunity</span><span>Estimated savings</span></div>"
            }
            for entry in members {
                let status: String = entry.audit.mode == .informative ? "informative" : "fail"
                out += audit(entry.audit, status: status)
            }
            out += "</div>\n"
        }
        return out
    }

    private static func collapsed(_ title: String, _ entries: [Entry], status: String) -> String {
        guard !entries.isEmpty else { return "" }
        var out = "<details class=\"clump \(status)\"><summary>\(escape(title)) <span class=\"count\">(\(entries.count))</span></summary>"
        for entry in entries { out += audit(entry.audit, status: status) }
        return out + "</details>\n"
    }

    private static func metric(_ audit: DeveloperLighthouseAudit) -> String {
        let rating = audit.mode == .numeric ? audit.score.map { DeveloperLighthouseScoring.rating($0).rawValue } ?? "na" : "na"
        let value = audit.displayValue ?? (audit.mode == .notApplicable ? "Not applicable" : "–")
        var out = "<div class=\"metric \(rating)\" id=\"\(escape(audit.id))\"><div class=\"metric-title\">"
            + "<span class=\"marker\"></span>\(inline(audit.title))</div><div class=\"metric-value\">\(escape(value))</div>"
        if let explanation = audit.explanation { out += "<p class=\"explanation\">\(inline(explanation))</p>" }
        out += "<p class=\"description\">\(inline(audit.description))</p></div>"
        return out
    }

    private static func audit(_ audit: DeveloperLighthouseAudit, status: String) -> String {
        let rating: String
        switch status {
        case "pass": rating = "pass"
        case "fail": rating = audit.score.map { DeveloperLighthouseScoring.rating($0).rawValue } ?? "fail"
        default: rating = status
        }
        var out = "<details class=\"audit \(rating)\" id=\"\(escape(audit.id))\"><summary><span class=\"marker\"></span>"
            + "<span class=\"audit-title\">\(inline(audit.title))</span>"
        if let savings = savings(audit) {
            out += "<span class=\"savings\">\(escape(savings))</span>"
        } else if let display = audit.displayValue, !display.isEmpty {
            out += "<span class=\"display\">\(escape(display))</span>"
        }
        out += "</summary><div class=\"audit-body\">"
        out += "<p class=\"description\">\(inline(audit.description))</p>"
        if let explanation = audit.explanation { out += "<p class=\"explanation\">\(inline(explanation))</p>" }
        if !audit.warnings.isEmpty {
            out += "<ul class=\"audit-warnings\">"
            for warning in audit.warnings { out += "<li>\(inline(warning))</li>" }
            out += "</ul>"
        }
        if let details = audit.details { out += table(details) }
        return out + "</div></details>\n"
    }

    /// An opportunity's estimated savings, as Lighthouse shows them beside it.
    static func savings(_ audit: DeveloperLighthouseAudit) -> String? {
        guard let details = audit.details, details.kind == .opportunity else { return nil }
        var parts: [String] = []
        if let ms = details.overallSavingsMs, ms > 0 { parts.append(milliseconds(ms)) }
        if let bytes = details.overallSavingsBytes, bytes > 0 { parts.append(kibibytes(bytes)) }
        guard !parts.isEmpty else { return nil }
        return "Est savings of " + parts.joined(separator: ", ")
    }

    private static func table(_ details: DeveloperLighthouseDetails) -> String {
        guard !details.items.isEmpty, !details.headings.isEmpty else { return "" }
        var out = "<table class=\"details\"><thead><tr>"
        for heading in details.headings {
            let numeric = ["bytes", "ms", "numeric"].contains(heading.valueType)
            out += "<th\(numeric ? " class=\"number\"" : "")>\(inline(heading.label))</th>"
        }
        out += "</tr></thead><tbody>"
        for item in details.items {
            out += "<tr>"
            for heading in details.headings {
                guard let value = item[heading.key] else { out += "<td></td>"; continue }
                out += cell(value)
            }
            out += "</tr>"
        }
        return out + "</tbody></table>"
    }

    private static func cell(_ value: DeveloperLighthouseValue) -> String {
        switch value {
        case .text(let text):
            return "<td>\(escape(text))</td>"
        case .url(let text):
            return "<td class=\"url-cell\" title=\"\(escape(text))\">\(escape(text))</td>"
        case .code(let text):
            return "<td><code>\(escape(text))</code></td>"
        case .bytes(let number):
            return "<td class=\"number\">\(escape(kibibytes(number)))</td>"
        case .ms(let number):
            return "<td class=\"number\">\(escape(milliseconds(number)))</td>"
        case .numeric(let number):
            return "<td class=\"number\">\(escape(number.formatted(.number.precision(.fractionLength(0...3)))))</td>"
        case .node(let node):
            var out = "<td class=\"node\">"
            if !node.label.isEmpty { out += "<div class=\"node-label\">\(escape(node.label))</div>" }
            if !node.snippet.isEmpty { out += "<code>\(escape(node.snippet))</code>" }
            if !node.selector.isEmpty { out += "<div class=\"node-selector\">\(escape(node.selector))</div>" }
            return out + "</td>"
        }
    }

    // MARK: Environment

    private static func environment(_ report: DeveloperLighthouseReport) -> String {
        let ff = report.formFactor
        let device = report.mode == .navigation
            ? "Emulated \(ff.rawValue.lowercased()) (\(ff.width)×\(ff.height) at \(ff.deviceScaleFactor.formatted())×)"
            : "The window's own viewport"
        let rows: [(String, String)] = [
            ("URL", report.finalURL),
            ("Requested URL", report.requestedURL),
            ("Captured at", report.fetchTime.formatted(date: .abbreviated, time: .standard)),
            ("Mode", report.mode.rawValue),
            ("Device", device),
            ("Emulation", report.emulation),
            ("Network throttling", networkThrottling(report)),
            ("CPU throttling", cpuThrottling(report)),
            ("User agent", report.userAgent),
            ("Total time", milliseconds(report.totalTime)),
            ("Generated by", "Search's implementation of Lighthouse audits (report format \(DeveloperLighthouseLHR.version))"),
        ]
        var out = "<footer class=\"environment\"><h2>Runtime settings</h2><table class=\"settings\"><tbody>"
        for (name, value) in rows where !value.isEmpty {
            out += "<tr><th>\(escape(name))</th><td>\(escape(value))</td></tr>"
        }
        return out + "</tbody></table></footer>\n"
    }

    static func networkThrottling(_ report: DeveloperLighthouseReport) -> String {
        let settings = DeveloperLighthouseLantern.Settings.lighthouse(report.formFactor)
        let mbps = (settings.throughputKbps / 1_024).formatted(.number.precision(.fractionLength(0...1)))
        switch report.throttling {
        case .simulated: return "\(settings.rttMs.formatted()) ms TCP RTT, \(mbps) Mbps throughput (Simulated)"
        case .devtools: return report.formFactor == .mobile ? "Slow 4G through the Network panel (DevTools)" : "None (DevTools, desktop)"
        case .none: return "None"
        }
    }

    static func cpuThrottling(_ report: DeveloperLighthouseReport) -> String {
        let settings = DeveloperLighthouseLantern.Settings.lighthouse(report.formFactor)
        switch report.throttling {
        case .simulated: return "\(settings.cpuSlowdownMultiplier.formatted())x slowdown (Simulated)"
        case .devtools, .none: return "None"
        }
    }

    // MARK: Text

    static func milliseconds(_ ms: Double) -> String {
        ms >= 1_000 ? String(format: "%.1f s", ms / 1_000) : "\(Int(ms.rounded())) ms"
    }

    static func kibibytes(_ bytes: Double) -> String {
        "\(Int((bytes / 1_024).rounded()).formatted()) KiB"
    }

    /// Text for HTML, attributes included.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Lighthouse's titles and descriptions: escaped, with their Markdown
    /// `code` spans and [links](https://…) made into HTML.
    static func inline(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let tick = rest.firstIndex(of: "`") {
            let after = rest.index(after: tick)
            guard let close = rest[after...].firstIndex(of: "`") else { break }
            out += links(String(rest[..<tick]))
            out += "<code>" + escape(String(rest[after..<close])) + "</code>"
            rest = rest[rest.index(after: close)...]
        }
        return out + links(String(rest))
    }

    private static func links(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            guard let closeLabel = rest[open...].range(of: "]("),
                  let closeURL = rest[closeLabel.upperBound...].firstIndex(of: ")") else { break }
            let label = rest[rest.index(after: open)..<closeLabel.lowerBound]
            let url = String(rest[closeLabel.upperBound..<closeURL])
            out += escape(String(rest[..<open]))
            if url.hasPrefix("https://") || url.hasPrefix("http://") {
                out += "<a href=\"\(escape(url))\">\(escape(String(label)))</a>"
            } else {
                out += escape(String(label))
            }
            rest = rest[rest.index(after: closeURL)...]
        }
        return out + escape(String(rest))
    }

    private static let style = """
        :root { --pass: #0c6; --pass-text: #080; --average: #fa3; --average-text: #c33300; --fail: #f33; --fail-text: #c00;
          --neutral: #777; --text: #212121; --muted: #616161; --line: #ebebeb; --bg: #fff; --raised: #f8f9fa; --link: #0b57d0; }
        @media (prefers-color-scheme: dark) {
          :root { --pass-text: #18d26e; --average-text: #ffb340; --fail-text: #ff6b6b; --text: #e8eaed; --muted: #9aa0a6;
            --line: #3c4043; --bg: #202124; --raised: #292a2d; --link: #8ab4f8; } }
        * { box-sizing: border-box; }
        body { margin: 0 auto; max-width: 960px; padding: 24px 16px 48px; background: var(--bg); color: var(--text);
          font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        a { color: var(--link); }
        code { font: 12px/1.4 ui-monospace, Menlo, Consolas, monospace; background: var(--raised); padding: 1px 4px; border-radius: 3px;
          overflow-wrap: anywhere; }
        header h1 { font-size: 20px; margin: 0 0 4px; }
        header .url { margin: 0; overflow-wrap: anywhere; }
        header .note, .legend, .group-description, .description { color: var(--muted); }
        header .note { font-size: 12px; }
        .gauges { display: flex; flex-wrap: wrap; justify-content: center; gap: 24px; margin: 24px 0 8px; }
        .gauge-link { display: flex; flex-direction: column; align-items: center; gap: 6px; text-decoration: none; color: var(--text); }
        .gauge .track { fill: none; stroke-width: 8; opacity: .15; }
        .gauge .arc { fill: none; stroke-width: 8; stroke-linecap: round; }
        .gauge text { font: 500 28px ui-monospace, Menlo, monospace; }
        .gauge.pass { color: var(--pass-text); } .gauge.pass .track, .gauge.pass .arc { stroke: var(--pass); } .gauge.pass circle.track { fill: var(--pass); fill-opacity: .1; }
        .gauge.average { color: var(--average-text); } .gauge.average .track, .gauge.average .arc { stroke: var(--average); }
        .gauge.fail { color: var(--fail-text); } .gauge.fail .track, .gauge.fail .arc { stroke: var(--fail); }
        .gauge.neutral { color: var(--neutral); } .gauge.neutral .track, .gauge.neutral .arc { stroke: var(--neutral); }
        .gauge text { fill: currentColor; }
        .legend { text-align: center; font-size: 12px; }
        .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin: 0 4px 0 12px; }
        .dot.pass, .pass > .marker, .pass > summary .marker { background: var(--pass); }
        .dot.average, .average > summary .marker, .metric.average .marker { background: var(--average); }
        .dot.fail, .fail > summary .marker, .metric.fail .marker { background: var(--fail); }
        .metric.pass .marker { background: var(--pass); }
        .warnings { background: #fff3cd33; border: 1px solid var(--average); border-radius: 6px; padding: 8px 16px; margin: 16px 0; }
        .warnings h2 { font-size: 14px; margin: 0; }
        .category { border-top: 1px solid var(--line); padding-top: 24px; margin-top: 24px; }
        .category-head { display: flex; gap: 20px; align-items: center; margin-bottom: 16px; }
        .category-head h2 { margin: 0; font-size: 22px; }
        .category-head p { margin: 4px 0 0; color: var(--muted); }
        h3 { font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 20px 0 6px; }
        .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 0 24px; }
        .metric { border-top: 1px solid var(--line); padding: 10px 0; }
        .metric-title { display: flex; align-items: center; gap: 8px; }
        .metric-value { font-size: 26px; }
        .metric.pass .metric-value { color: var(--pass-text); } .metric.average .metric-value { color: var(--average-text); }
        .metric.fail .metric-value { color: var(--fail-text); }
        .metric .description, .metric .explanation { font-size: 12px; margin: 2px 0 0; }
        .marker { display: inline-block; flex: none; width: 10px; height: 10px; border-radius: 50%; background: var(--neutral); }
        .average > summary .marker { border-radius: 0; }
        .fail > summary .marker, .metric.fail .marker { border-radius: 0; width: 0; height: 0; background: none !important;
          border-left: 6px solid transparent; border-right: 6px solid transparent; border-bottom: 10px solid var(--fail); }
        .na > summary .marker, .manual > summary .marker, .informative > summary .marker { background: transparent; border: 2px solid var(--neutral); }
        .opportunity-head { display: flex; justify-content: space-between; font-size: 12px; color: var(--muted); padding: 4px 0; }
        details.audit { border-top: 1px solid var(--line); }
        details.audit > summary { display: flex; align-items: center; gap: 10px; padding: 8px 0; cursor: pointer; list-style: none; }
        details.audit > summary::-webkit-details-marker { display: none; }
        .audit-title { flex: 1; }
        .savings, .display { color: var(--muted); font-size: 13px; white-space: nowrap; }
        .fail .savings { color: var(--fail-text); } .average .savings { color: var(--average-text); }
        .audit-body { padding: 0 0 12px 20px; }
        .audit-warnings { color: var(--average-text); }
        details.clump { margin-top: 16px; }
        details.clump > summary { cursor: pointer; font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); padding: 6px 0; }
        table { border-collapse: collapse; width: 100%; font-size: 12px; }
        table.details th, table.details td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
        table.details thead th { background: var(--raised); font-weight: 600; }
        table.details tbody tr:nth-child(even) { background: var(--raised); }
        .number { text-align: right !important; white-space: nowrap; }
        .url-cell { overflow-wrap: anywhere; }
        .node-label { font-weight: 500; }
        .node-selector { color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
        .environment { border-top: 1px solid var(--line); margin-top: 32px; padding-top: 16px; }
        .environment h2 { font-size: 16px; }
        table.settings th { text-align: left; width: 180px; padding: 4px 8px 4px 0; color: var(--muted); font-weight: 500; vertical-align: top; }
        table.settings td { padding: 4px 0; overflow-wrap: anywhere; }
        @media (max-width: 600px) { .category-head { flex-direction: column; align-items: flex-start; } }
        @media print { details { display: block; } details > * { display: block; } }
        """
}
