import Foundation

// More of the Lighthouse panel's audits (DeveloperLighthouseRules.swift has
// the first ones and the helpers): axe-core's remaining checks that the page
// script can answer, the byte-efficiency audits over the scripts' and
// stylesheets' text and coverage, the connection and redirect audits over the
// Network panel's requests, and Best practices' and SEO's audits of the
// page's CSP, paste handlers, permission requests, source maps and
// robots.txt. Each follows the Lighthouse audit of the same id: its
// thresholds, scoring mode and details table. Pure, for the tests.

extension DeveloperLighthouseRules {
    // MARK: Accessibility

    static func selectName(_ page: DeveloperLighthousePage) -> Audit {
        nameAudit("select-name", page.selects)
    }

    static func ariaHiddenBody(_ page: DeveloperLighthousePage) -> Audit {
        let id = "aria-hidden-body"
        guard page.bodyAriaHidden else { return binary(id, passed: true) }
        return binary(id, passed: false, details: page.bodyNode.map { DeveloperLighthouseDetails.nodes([$0]) })
    }

    /// axe's `bypass`: a page with links needs a heading, an internal
    /// (skip) link or a main landmark to let keyboard users past them.
    static func bypass(_ page: DeveloperLighthousePage) -> Audit {
        let id = "bypass"
        let links = page.links.filter { $0.tag == "a" && $0.rawHref != nil }
        guard !links.isEmpty else { return notApplicable(id) }
        // axe's internal-link-present: an href of "#" and a fragment.
        let skipLink = links.contains { link in
            guard let raw = link.rawHref, raw.hasPrefix("#"), raw.count > 1 else { return false }
            let next = raw[raw.index(after: raw.startIndex)]
            return next != "/" && next != "!"
        }
        return binary(id, passed: !page.headings.isEmpty || skipLink || page.mainLandmarks > 0)
    }

    static func landmarkOneMain(_ page: DeveloperLighthousePage) -> Audit {
        binary("landmark-one-main", passed: page.mainLandmarks > 0)
    }

    /// WAI-ARIA 1.2's roles an author may use (with DPUB-ARIA's and the
    /// Graphics module's, which axe accepts), and the abstract ones.
    static let ariaRoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "blockquote", "button", "caption", "cell", "checkbox",
        "code", "columnheader", "combobox", "comment", "complementary", "contentinfo", "definition", "deletion", "dialog",
        "directory", "document", "emphasis", "feed", "figure", "form", "generic", "grid", "gridcell", "group", "heading",
        "img", "insertion", "link", "list", "listbox", "listitem", "log", "main", "mark", "marquee", "math", "menu", "menubar",
        "menuitem", "menuitemcheckbox", "menuitemradio", "meter", "navigation", "none", "note", "option", "paragraph",
        "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup", "rowheader", "scrollbar", "search",
        "searchbox", "separator", "slider", "spinbutton", "status", "strong", "subscript", "suggestion", "superscript",
        "switch", "tab", "table", "tablist", "tabpanel", "term", "textbox", "time", "timer", "toolbar", "tooltip", "tree",
        "treegrid", "treeitem",
        "doc-abstract", "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-backlink", "doc-biblioentry",
        "doc-bibliography", "doc-biblioref", "doc-chapter", "doc-colophon", "doc-conclusion", "doc-cover", "doc-credit",
        "doc-credits", "doc-dedication", "doc-endnote", "doc-endnotes", "doc-epigraph", "doc-epilogue", "doc-errata",
        "doc-example", "doc-footnote", "doc-foreword", "doc-glossary", "doc-glossref", "doc-index", "doc-introduction",
        "doc-noteref", "doc-notice", "doc-pagebreak", "doc-pagefooter", "doc-pageheader", "doc-pagelist", "doc-part",
        "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna", "doc-subtitle", "doc-tip", "doc-toc",
        "graphics-document", "graphics-object", "graphics-symbol",
    ]
    static let abstractRoles: Set<String> = [
        "command", "composite", "input", "landmark", "range", "roletype", "section", "sectionhead", "select", "structure",
        "widget", "window",
    ]

    static func roleTokens(_ role: String?) -> [String] {
        (role ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// axe's `aria-roles`: fails when none of the role's tokens is a role,
    /// or one is abstract.
    static func ariaRolesAudit(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.aria.filter { !roleTokens($0.role).isEmpty }
        var failing: [DeveloperLighthouseNode] = []
        var values: [Value] = []
        for element in checked {
            let tokens = roleTokens(element.role)
            let abstract = tokens.filter { abstractRoles.contains($0) }
            if !abstract.isEmpty || !tokens.contains(where: { ariaRoles.contains($0) }) {
                failing.append(element.node)
                values.append(.code("role=\"\(element.role ?? "")\""))
            }
        }
        return elements("aria-roles", checked: checked.count, failing: failing, extra: [("role", "Role", values)])
    }

    /// ARIA 1.2's global states and properties, with those 1.2 deprecated
    /// as global that axe still allows everywhere.
    static let globalAriaAttributes: Set<String> = [
        "aria-atomic", "aria-braillelabel", "aria-brailleroledescription", "aria-busy", "aria-controls", "aria-current",
        "aria-describedby", "aria-description", "aria-details", "aria-disabled", "aria-dropeffect", "aria-errormessage",
        "aria-flowto", "aria-grabbed", "aria-haspopup", "aria-hidden", "aria-invalid", "aria-keyshortcuts", "aria-label",
        "aria-labelledby", "aria-live", "aria-owns", "aria-relevant", "aria-roledescription",
    ]

    /// The roles that support each attribute that isn't global (ARIA 1.2's
    /// characteristics tables, as axe's standards object has them).
    static let attributeRoles: [String: Set<String>] = {
        let range: Set<String> = ["meter", "progressbar", "scrollbar", "separator", "slider", "spinbutton"]
        let cells: Set<String> = ["cell", "columnheader", "gridcell", "rowheader"]
        let indexed: Set<String> = cells.union(["row"])
        let set: Set<String> = ["article", "comment", "listitem", "menuitem", "menuitemcheckbox", "menuitemradio", "option",
                                "radio", "row", "tab", "treeitem"]
        let tables: Set<String> = ["grid", "table", "treegrid"]
        return [
            "aria-activedescendant": ["application", "combobox", "grid", "group", "listbox", "menu", "menubar", "radiogroup",
                                      "row", "searchbox", "spinbutton", "tablist", "textbox", "toolbar", "tree", "treegrid"],
            "aria-autocomplete": ["combobox", "searchbox", "textbox"],
            "aria-checked": ["checkbox", "menuitemcheckbox", "menuitemradio", "option", "radio", "switch", "treeitem"],
            "aria-colcount": tables,
            "aria-colindex": indexed,
            "aria-colindextext": indexed,
            "aria-colspan": cells,
            "aria-expanded": ["application", "button", "checkbox", "columnheader", "combobox", "gridcell", "link", "listbox",
                              "menuitem", "menuitemcheckbox", "menuitemradio", "row", "rowheader", "switch", "tab", "treeitem"],
            "aria-level": ["comment", "heading", "listitem", "row", "treeitem"],
            "aria-modal": ["alertdialog", "dialog"],
            "aria-multiline": ["searchbox", "textbox"],
            "aria-multiselectable": ["grid", "listbox", "tablist", "tree", "treegrid"],
            "aria-orientation": ["listbox", "menu", "menubar", "radiogroup", "scrollbar", "separator", "slider", "tablist",
                                 "toolbar", "tree", "treegrid"],
            "aria-placeholder": ["searchbox", "textbox"],
            "aria-posinset": set,
            "aria-setsize": set,
            "aria-pressed": ["button"],
            "aria-readonly": ["checkbox", "columnheader", "combobox", "grid", "gridcell", "listbox", "menuitemcheckbox",
                              "menuitemradio", "radiogroup", "rowheader", "searchbox", "slider", "spinbutton", "switch",
                              "textbox", "treegrid"],
            "aria-required": ["checkbox", "columnheader", "combobox", "gridcell", "listbox", "radiogroup", "rowheader",
                              "searchbox", "spinbutton", "switch", "textbox", "tree", "treegrid"],
            "aria-rowcount": tables,
            "aria-rowindex": indexed,
            "aria-rowindextext": indexed,
            "aria-rowspan": cells,
            "aria-selected": ["columnheader", "gridcell", "option", "row", "rowheader", "tab", "treeitem"],
            "aria-sort": ["columnheader", "rowheader"],
            "aria-valuemax": range,
            "aria-valuemin": range,
            "aria-valuenow": range,
            "aria-valuetext": range,
        ]
    }()

    /// An element's role as axe's getRole has it: the first explicit token
    /// that's a role, else the implicit one; nil when it can't be told.
    static func effectiveRole(_ element: DeveloperLighthousePage.Aria) -> String? {
        let tokens = roleTokens(element.role)
        if let explicit = tokens.first(where: { ariaRoles.contains($0) }) { return explicit }
        return tokens.isEmpty ? element.implicitRole?.lowercased() : nil
    }

    /// axe's `aria-allowed-attr`: each valid `aria-*` attribute is global or
    /// supported by the element's role.
    static func ariaAllowedAttributes(_ page: DeveloperLighthousePage) -> Audit {
        var checked = 0
        var failing: [DeveloperLighthouseNode] = []
        var values: [Value] = []
        for element in page.aria {
            let attributes = element.attributes.map { $0.lowercased() }
                .filter { ariaAttributes.contains($0) && !globalAriaAttributes.contains($0) }
            guard !attributes.isEmpty, let role = effectiveRole(element) else { continue }
            checked += 1
            let bad = attributes.filter { attributeRoles[$0]?.contains(role) != true }
            guard !bad.isEmpty else { continue }
            failing.append(element.node)
            values.append(.code(bad.joined(separator: ", ") + " on role=\"\(role)\""))
        }
        return elements("aria-allowed-attr", checked: checked, failing: failing,
                        extra: [("attributes", "Attributes not allowed", values)])
    }

    /// axe's target-size (WCAG 2.2's 24 by 24 CSS pixels): a smaller target
    /// passes when a 24 px circle on its centre stays clear of every other
    /// target (and of an undersized neighbour's own circle).
    static func targetSizeFailures(_ targets: [DeveloperLighthousePage.Target], minimum: Double = 24)
        -> [(target: DeveloperLighthousePage.Target, reason: String)] {
        func small(_ t: DeveloperLighthousePage.Target) -> Bool { t.width < minimum || t.height < minimum }
        func contains(_ a: DeveloperLighthousePage.Target, _ b: DeveloperLighthousePage.Target) -> Bool {
            b.x >= a.x - 0.5 && b.y >= a.y - 0.5 && b.x + b.width <= a.x + a.width + 0.5 && b.y + b.height <= a.y + a.height + 0.5
        }
        var out: [(target: DeveloperLighthousePage.Target, reason: String)] = []
        for target in targets where small(target) && target.width > 0 && target.height > 0 {
            let cx = target.x + target.width / 2, cy = target.y + target.height / 2
            var closest = Double.infinity
            for other in targets where other.node != target.node && other.width > 0 && other.height > 0 {
                // A target inside another (a link in a button) isn't its neighbour.
                if contains(other, target) || contains(target, other) { continue }
                let distance: Double
                if small(other) {
                    let ox = other.x + other.width / 2, oy = other.y + other.height / 2
                    distance = ((cx - ox) * (cx - ox) + (cy - oy) * (cy - oy)).squareRoot() / 2
                } else {
                    let dx = max(other.x - cx, 0, cx - (other.x + other.width))
                    let dy = max(other.y - cy, 0, cy - (other.y + other.height))
                    distance = (dx * dx + dy * dy).squareRoot()
                }
                closest = min(closest, distance)
            }
            if closest < minimum / 2 {
                let size = "\(Int(target.width.rounded()))px by \(Int(target.height.rounded()))px"
                out.append((target, "Target has insufficient size (\(size), should be at least \(Int(minimum))px by \(Int(minimum))px) and insufficient space to its closest neighbors (\(String(format: "%.1f", closest * 2))px)"))
            }
        }
        return out
    }

    static func targetSize(_ page: DeveloperLighthousePage) -> Audit {
        let failures = targetSizeFailures(page.targets)
        return elements("target-size", checked: page.targets.count, failing: failures.map { $0.target.node },
                        extra: [("reason", "Reason", failures.map { Value.text($0.reason) })])
    }

    static func tdHeadersAttribute(_ page: DeveloperLighthousePage) -> Audit {
        var failing: [DeveloperLighthouseNode] = []
        var values: [Value] = []
        for cell in page.headersCells {
            let found = Set(cell.found)
            let bad = cell.headers.filter { !found.contains($0) || (!cell.id.isEmpty && $0 == cell.id) }
            guard !bad.isEmpty else { continue }
            failing.append(cell.node)
            values.append(.code("headers=\"" + cell.headers.joined(separator: " ") + "\""))
        }
        return elements("td-headers-attr", checked: page.headersCells.count, failing: failing,
                        extra: [("headers", "Headers", values)])
    }

    /// axe's meta-refresh check: the delay before a refresh, nil when the
    /// content doesn't start with one.
    static func refreshDelay(_ content: String) -> Double? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == ";" || $0 == "," || $0.isWhitespace }
            .first.map(String.init) ?? ""
        guard !first.isEmpty, first.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return Double(first)
    }

    /// Fails a timed refresh or redirect: more than 0 s, up to 20 hours
    /// (axe's minDelay 0 and maxDelay 72000).
    static func metaRefresh(_ page: DeveloperLighthousePage) -> Audit {
        let failing = page.metaRefreshes.filter { meta in
            guard let delay = refreshDelay(meta.content) else { return false }
            return delay > 0 && delay <= 72_000
        }
        return elements("meta-refresh", checked: page.metaRefreshes.count, failing: failing.map(\.node),
                        extra: [("content", "Content", failing.map { Value.code($0.content) })])
    }

    static func validLang(_ page: DeveloperLighthousePage) -> Audit {
        let checked = page.langs.filter { !$0.lang.trimmingCharacters(in: .whitespaces).isEmpty }
        let failing = checked.filter { !validLanguage($0.lang) }
        return elements("valid-lang", checked: checked.count, failing: failing.map(\.node),
                        extra: [("lang", "Language", failing.map { Value.code("lang=\"\($0.lang)\"") })])
    }

    // MARK: Byte efficiency

    /// What `length` characters of a file cost over the wire: its own
    /// transfer size for a script or stylesheet; for inline code, its share
    /// of the document at the document's compression ratio.
    static func transferEstimate(_ url: String, length: Double, _ input: DeveloperLighthouseInput) -> Double {
        if let found = request(url, in: input.requests) {
            let transfer = found.transferSize ?? 0, resource = found.resourceSize ?? 0
            if found.type.lowercased() == "document" || url == input.page.url {
                return transfer > 0 && resource > 0 ? length * min(1, transfer / resource) : length
            }
            if transfer > 0 { return transfer }
            if resource > 0 { return resource }
        }
        return bytes(of: url, input) ?? length
    }

    /// A coverage-based opportunity: each file's unused share of its transfer size.
    static func unusedBytes(_ id: String, _ entries: [DeveloperCoverageMath.Entry], threshold: Double,
                            _ input: DeveloperLighthouseInput) -> Audit {
        var items: [[String: Value]] = []
        for entry in entries where entry.total > 0 {
            let size = transferEstimate(entry.url, length: Double(entry.total), input)
            let wasted = size * Double(entry.unused) / Double(entry.total)
            guard wasted >= threshold else { continue }
            items.append(["url": .url(entry.url), "totalBytes": .bytes(size), "wastedBytes": .bytes(wasted)])
        }
        return byteOpportunity(id, items, input)
    }

    static func unusedJavaScript(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "unused-javascript"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard let entries = input.scriptCoverage else {
            return notApplicable(id, "JavaScriptCore's control flow profiler couldn't be turned on for the load.")
        }
        // unused-javascript.js IGNORE_THRESHOLD_IN_BYTES.
        return unusedBytes(id, entries.filter { $0.kind == .javaScript }, threshold: 20 * 1_024, input)
    }

    static func unusedCSS(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "unused-css-rules"
        guard input.mode != .timespan else { return notApplicable(id) }
        guard let entries = input.styleCoverage else { return notApplicable(id, "The page's stylesheets couldn't be read.") }
        // unused-css-rules.js IGNORE_THRESHOLD_IN_BYTES.
        var audit = unusedBytes(id, entries.filter { $0.kind == .css }, threshold: 10 * 1_024, input)
        if input.page.unreadableStyleSheets > 0 {
            audit.warnings = ["\(input.page.unreadableStyleSheets) stylesheet(s) from other origins couldn't be read and weren't checked."]
        }
        return audit
    }

    /// minification-estimator.js computeTokenLength: the characters left
    /// once comments and whitespace outside strings (and, for JavaScript,
    /// regular expressions and template literals) are taken out. Unbalanced
    /// strings or comments give the whole length, as there.
    static func tokenLength(_ content: String, javaScript: Bool) -> Int {
        let chars = Array(content.utf16)
        let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*")), backslash = UInt16(UInt8(ascii: "\\"))
        let newline = UInt16(UInt8(ascii: "\n")), space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
        let carriage = UInt16(UInt8(ascii: "\r"))
        let quotes: Set<UInt16> = [UInt16(UInt8(ascii: "'")), UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "`"))]
        let openBracket = UInt16(UInt8(ascii: "[")), closeBracket = UInt16(UInt8(ascii: "]"))
        let bang = UInt16(UInt8(ascii: "!"))
        // A / after one of these starts a regular expression.
        let beforeRegex = Set("(,=:[!&|?{};+-*%<>~^".utf16)
        var total = 0
        var stringQuote: UInt16?
        var inBlockComment = false, inLicenseComment = false, inLineComment = false
        var inRegex = false, inRegexClass = false
        var lastNonWhitespace: UInt16?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: UInt16? = i + 1 < chars.count ? chars[i + 1] : nil
            let whitespace = c == space || c == newline || c == tab || c == carriage
            if let quote = stringQuote {
                total += 1
                if c == backslash {
                    total += 1
                    i += 1
                } else if c == quote {
                    stringQuote = nil
                }
            } else if inBlockComment {
                if inLicenseComment { total += 1 }
                if c == star, next == slash {
                    if inLicenseComment { total += 1 }
                    inBlockComment = false
                    inLicenseComment = false
                    i += 1
                }
            } else if inLineComment {
                if c == newline { inLineComment = false }
            } else if inRegex {
                total += 1
                if c == backslash {
                    total += 1
                    i += 1
                } else if c == openBracket {
                    inRegexClass = true
                } else if c == closeBracket, inRegexClass {
                    inRegexClass = false
                } else if c == slash, !inRegexClass {
                    inRegex = false
                    lastNonWhitespace = c
                }
            } else if c == slash, next == star {
                inBlockComment = true
                inLicenseComment = i + 2 < chars.count && chars[i + 2] == bang
                if inLicenseComment { total += 2 }
                i += 1
            } else if javaScript, c == slash, next == slash {
                inLineComment = true
                i += 1
            } else if javaScript, c == slash, lastNonWhitespace.map({ beforeRegex.contains($0) }) ?? true {
                inRegex = true
                total += 1
            } else if quotes.contains(c), javaScript || c != UInt16(UInt8(ascii: "`")) {
                stringQuote = c
                total += 1
                lastNonWhitespace = c
            } else if !whitespace {
                total += 1
                lastNonWhitespace = c
            }
            i += 1
        }
        if stringQuote != nil || inBlockComment || inRegex { return chars.count }
        return total
    }

    static func unminified(_ id: String, kind: DeveloperLighthouseContent.Kind, minPercent: Double,
                           _ input: DeveloperLighthouseInput) -> Audit {
        guard input.mode != .timespan else { return notApplicable(id) }
        guard let contents = input.contents else { return notApplicable(id, "The page's files couldn't be read.") }
        var items: [[String: Value]] = []
        var seen = Set<String>()
        for content in contents where content.kind == kind && seen.insert(content.url).inserted {
            let length = content.text.utf16.count
            guard length > 0 else { continue }
            let ratio = 1 - Double(tokenLength(content.text, javaScript: kind == .script)) / Double(length)
            let size = transferEstimate(content.url, length: Double(length), input)
            let wasted = size * ratio
            // unminified-*.js IGNORE_THRESHOLD_IN_PERCENT and IGNORE_THRESHOLD_IN_BYTES.
            guard ratio * 100 >= minPercent, wasted >= 2_048 else { continue }
            items.append(["url": .url(content.url), "totalBytes": .bytes(size), "wastedBytes": .bytes(wasted)])
        }
        return byteOpportunity(id, items, input)
    }

    /// offscreen-images.js computeVisiblePixels: the image's area within
    /// the viewport, 100 px either side and three viewports below.
    static func visiblePixels(_ rect: [Double], width: Double, height: Double) -> Double {
        guard rect.count == 4 else { return 0 }
        let top = max(rect[0], -100), left = max(rect[1], -100)
        let bottom = min(rect[2], height + 3 * height), right = min(rect[3], width + 100)
        return max(right - left, 0) * max(bottom - top, 0)
    }

    static func offscreenImages(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "offscreen-images"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        let page = input.page
        guard page.viewportWidth > 0, page.viewportHeight > 0 else { return notApplicable(id, "The viewport's size wasn't read.") }
        // Only images asked for during the load (Lighthouse: before the page was interactive).
        let until = input.metrics?.load
        var best: [String: (image: DeveloperLighthousePage.Image, size: Double, wasted: Double)] = [:]
        var order: [String] = []
        for image in page.images where !image.lazy && !image.src.isEmpty && !image.src.hasPrefix("data:") {
            guard let rect = image.documentRect, image.displayedWidth > 0, image.displayedHeight > 0,
                  let size = bytes(of: image.src, input) else { continue }
            if let until, let timing = page.timings.first(where: { $0.url == image.src }), timing.startTime > until { continue }
            let area = image.displayedWidth * image.displayedHeight
            let ratio = max(0, 1 - visiblePixels(rect, width: page.viewportWidth, height: page.viewportHeight) / area)
            let wasted = size * ratio
            if let found = best[image.src] {
                if wasted < found.wasted { best[image.src] = (image, size, wasted) }
            } else {
                best[image.src] = (image, size, wasted)
                order.append(image.src)
            }
        }
        var items: [[String: Value]] = []
        for src in order {
            guard let entry = best[src], entry.size > 0 else { continue }
            // IGNORE_THRESHOLD_IN_BYTES and IGNORE_THRESHOLD_IN_PERCENT.
            guard entry.wasted > 2_048, entry.wasted / entry.size * 100 >= 75 else { continue }
            items.append(["node": .node(entry.image.node), "url": .url(src), "totalBytes": .bytes(entry.size),
                          "wastedBytes": .bytes(entry.wasted)])
        }
        return byteOpportunity(id, items, sizeLabel: "Resource Size", nodes: true, input)
    }

    // MARK: Network

    static func origin(_ url: String) -> String? {
        guard let address = URL(string: url), let scheme = address.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = address.host()?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (address.port.map { ":\($0)" } ?? "")
    }

    /// uses-rel-preconnect.js over the observed load: the first request to
    /// each other origin that opened a connection before LCP, and the
    /// connection time a preconnect could have overlapped with the document.
    static func preconnect(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "uses-rel-preconnect"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard let document = mainDocument(input), let main = origin(document.url), let docStart = document.startedAt else {
            return notApplicable(id, "The page's document request wasn't recorded.")
        }
        let docEnd = document.endedAt ?? docStart
        let preconnected = Set(input.page.preconnects.compactMap(origin))
        let deadline = input.metrics?.lcp ?? input.metrics?.fcp
        var first: [String: DeveloperLighthouseRequest] = [:]
        for request in input.requests {
            guard let host = origin(request.url), host != main, let start = request.startedAt else { continue }
            if let found = first[host], let other = found.startedAt, other <= start { continue }
            first[host] = request
        }
        var items: [[String: Value]] = []
        var maxWasted = 0.0
        for (host, request) in first.sorted(by: { $0.key < $1.key }) {
            guard let start = request.startedAt, let connect = request.connectMs, connect > 0,
                  !preconnected.contains(host) else { continue }
            // PRECONNECT_SOCKET_MAX_IDLE_IN_MS: a preconnect this early would have closed.
            if (start - docEnd) * 1_000 > 15_000 { continue }
            if let deadline, (start - docStart) * 1_000 > deadline { continue }
            let wasted = max(connect - max(0, (start - docEnd) * 1_000), 0)
            // IGNORE_THRESHOLD_IN_MS.
            guard wasted >= 50 else { continue }
            maxWasted = max(maxWasted, wasted)
            items.append(["url": .url(host), "wastedMs": .ms(wasted)])
        }
        items.sort { (number($0["wastedMs"]) ?? 0) > (number($1["wastedMs"]) ?? 0) }
        return opportunity(id, items: items, headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "wastedMs", label: "Est Savings", valueType: "ms"),
        ], savingsBytes: 0, savingsMs: maxWasted, input.formFactor)
    }

    /// redirects.js over what WebKit reports: the document's first URL
    /// when it was redirected, with the time Navigation Timing gives the
    /// redirects, and the final URL. Search reloads the page's current
    /// address, so only redirects made on every load show.
    static func redirects(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "redirects"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        let document = mainDocument(input)
        let original = document?.originalURL.flatMap { $0 != document?.url ? $0 : nil }
        let count = max(input.metrics?.redirects ?? 0, original == nil ? 0 : 1)
        guard count > 0 else {
            return opportunity(id, items: [], headings: [], savingsBytes: 0, savingsMs: 0, input.formFactor)
        }
        let final = document?.url ?? input.page.url
        let wasted = input.metrics?.redirectMs ?? 0
        let items: [[String: Value]] = [
            ["url": .url(original ?? input.requestedURL), "wastedMs": .ms(wasted)],
            ["url": .url(final), "wastedMs": .ms(0)],
        ]
        var audit = opportunity(id, items: items, headings: [
            Heading(key: "url", label: "URL", valueType: "url"),
            Heading(key: "wastedMs", label: "Time Spent", valueType: "ms"),
        ], savingsBytes: 0, savingsMs: wasted, input.formFactor)
        if input.metrics?.redirectMs == nil {
            audit.warnings = ["WebKit didn't time the redirects (Navigation Timing leaves out cross-origin ones)."]
        }
        return audit
    }

    /// font-display.js: font-display values that keep text visible.
    static func fontDisplayPasses(_ display: String) -> Bool {
        ["block", "fallback", "optional", "swap"].contains(display.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func fontDisplay(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "font-display"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        var failingURLs = Set<String>()
        for face in input.page.fontFaces where !fontDisplayPasses(face.display) {
            for url in face.urls { failingURLs.insert(withoutFragment(url)) }
        }
        var items: [[String: Value]] = []
        var seen = Set<String>()
        for request in input.requests where failingURLs.contains(withoutFragment(request.url))
            && seen.insert(withoutFragment(request.url)).inserted {
            // The text stays invisible for up to 3 s while the font loads.
            items.append(["url": .url(request.url), "wastedMs": .ms(min(request.durationMs ?? 0, 3_000))])
        }
        var audit = items.isEmpty ? binary(id, passed: true)
            : binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
                Heading(key: "url", label: "URL", valueType: "url"),
                Heading(key: "wastedMs", label: "Est Savings", valueType: "ms"),
            ], items: items))
        if input.page.unreadableStyleSheets > 0 {
            audit.warnings = ["Fonts declared in \(input.page.unreadableStyleSheets) stylesheet(s) from other origins couldn't be checked: the page can't read their rules."]
        }
        return audit
    }

    static func lcpLazyLoaded(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "lcp-lazy-loaded"
        guard input.mode == .navigation else { return notApplicable(id, "Needs a page load: run in Navigation mode.") }
        guard let metrics = input.metrics, metrics.lcpSupported else {
            return notApplicable(id, "This WebKit doesn't report largest-contentful-paint entries.")
        }
        guard metrics.lcpImage, let element = metrics.lcpElement else {
            return notApplicable(id, "The Largest Contentful Paint element was not an image.")
        }
        return binary(id, passed: !metrics.lcpLazy, details: DeveloperLighthouseDetails(
            headings: [Heading(key: "element", label: "Element", valueType: "code")], items: [["element": .code(element)]]))
    }

    // MARK: Best practices

    static func pastePreventing(_ page: DeveloperLighthousePage) -> Audit {
        let id = "paste-preventing-inputs"
        guard !page.pasteBlocked.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: .nodes(page.pasteBlocked))
    }

    static func permissionOnStart(_ id: String, api: DeveloperLighthousePage.PermissionCall.API,
                                  _ input: DeveloperLighthouseInput) -> Audit {
        guard input.mode == .navigation, let calls = input.page.permissionCalls else {
            return notApplicable(id, "Needs a page load: run in Navigation mode.")
        }
        let found = calls.filter { $0.api == api && !$0.gesture }
        guard !found.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(
            headings: [Heading(key: "source", label: "Source", valueType: "code")],
            items: found.map { call in
                ["source": .code(call.url.isEmpty ? "(unknown)" : "\(call.url):\(call.line):\(call.column)")]
            }))
    }

    /// The page's own site, for telling first-party scripts.
    static func site(_ url: String) -> String? {
        guard let host = URL(string: url)?.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else { return host }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        return labels.suffix(last.count == 2 && second.count <= 3 ? 3 : 2).joined(separator: ".")
    }

    /// valid-source-maps.js LARGE_JS_BYTE_THRESHOLD.
    static let largeScript = 500 * 1_024

    static func validSourceMaps(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "valid-source-maps"
        guard let maps = input.sourceMaps else { return notApplicable(id, "JavaScript source maps are turned off in Settings.") }
        func key(_ url: String) -> String { String(url.prefix { $0 != "#" }) }
        let own = site(input.page.url)
        var scripts: [(url: String, length: Int, named: Bool)] = []
        var seen = Set<String>()
        for content in input.contents ?? [] where content.kind == .script && seen.insert(key(content.url)).inserted {
            scripts.append((content.url, content.text.utf16.count, DeveloperSourceMapURL.comment(in: String(content.text.suffix(4_000))) != nil))
        }
        for request in input.requests where request.type.lowercased() == "script" && seen.insert(key(request.url)).inserted {
            scripts.append((request.url, Int(request.resourceSize ?? 0), false))
        }
        var missingLarge = false
        var items: [[String: Value]] = []
        for script in scripts {
            let header = request(script.url, in: input.requests).map {
                $0.headers["sourcemap"] != nil || $0.headers["x-sourcemap"] != nil
            } ?? false
            let map = maps.first { key($0.scriptURL) == key(script.url) }
            var errors: [String] = []
            if map == nil, !script.named, !header, script.length >= largeScript, own != nil, site(script.url) == own {
                missingLarge = true
                errors.append("Large JavaScript file is missing a source map")
            }
            if let error = map?.error { errors.append(error) }
            guard map != nil || !errors.isEmpty else { continue }
            items.append(["scriptUrl": .url(script.url), "sourceMapUrl": .url(map?.mapURL ?? ""),
                          "error": .text(errors.joined(separator: "; "))])
        }
        guard !items.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: !missingLarge, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "scriptUrl", label: "URL", valueType: "url"),
            Heading(key: "sourceMapUrl", label: "Map URL", valueType: "url"),
            Heading(key: "error", label: "Error", valueType: "text"),
        ], items: items))
    }

    // MARK: CSP

    struct CSPFinding: Equatable {
        enum Severity: String { case high = "High", medium = "Medium", syntax = "Syntax" }
        var description: String
        var directive: String
        var severity: Severity
    }

    /// A policy's directives, by lowercased name, with their values.
    static func parseCSP(_ policy: String) -> [(name: String, values: [String])] {
        policy.split(separator: ";").compactMap { part in
            let tokens = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first?.lowercased() else { return nil }
            return (name, Array(tokens.dropFirst()))
        }
    }

    static let cspDirectives: Set<String> = [
        "child-src", "connect-src", "default-src", "font-src", "frame-src", "img-src", "manifest-src", "media-src",
        "object-src", "prefetch-src", "script-src", "script-src-attr", "script-src-elem", "style-src", "style-src-attr",
        "style-src-elem", "worker-src", "base-uri", "plugin-types", "sandbox", "form-action", "frame-ancestors",
        "navigate-to", "report-uri", "report-to", "block-all-mixed-content", "upgrade-insecure-requests",
        "require-sri-for", "require-trusted-types-for", "trusted-types", "webrtc", "fenced-frame-src", "treat-as-public-address",
    ]

    /// The csp_evaluator checks Lighthouse's csp-xss runs, for one policy.
    static func cspFindings(_ policy: String) -> [CSPFinding] {
        let directives = parseCSP(policy)
        var byName: [String: [String]] = [:]
        for directive in directives where byName[directive.name] == nil { byName[directive.name] = directive.values }
        var findings: [CSPFinding] = []
        for directive in directives where !cspDirectives.contains(directive.name) {
            findings.append(CSPFinding(description: "Unknown CSP directive.", directive: directive.name, severity: .syntax))
        }
        let scriptName = byName["script-src"] != nil ? "script-src" : "default-src"
        let script = (byName["script-src"] ?? byName["default-src"])?.map { $0.lowercased() }
        let nonces = script?.contains { $0.hasPrefix("'nonce-") } ?? false
        let hashes = script?.contains { $0.hasPrefix("'sha256-") || $0.hasPrefix("'sha384-") || $0.hasPrefix("'sha512-") } ?? false
        let strictDynamic = script?.contains("'strict-dynamic'") ?? false
        if let script {
            if script.contains("'unsafe-inline'"), !nonces, !hashes {
                findings.append(CSPFinding(description: "`'unsafe-inline'` allows the execution of unsafe in-page scripts and event handlers. Consider using CSP nonces or hashes to allow scripts individually.",
                                           directive: scriptName, severity: .high))
            }
            let hosts = script.filter { !$0.hasPrefix("'") }
            if !strictDynamic {
                if hosts.contains("*") {
                    findings.append(CSPFinding(description: "Avoid using plain wildcard (*) in this directive. Plain wildcards allow scripts to be sourced from an unsafe domain.",
                                               directive: scriptName, severity: .high))
                }
                for scheme in hosts where ["http:", "https:", "data:"].contains(scheme) {
                    findings.append(CSPFinding(description: "Avoid using plain URL schemes (\(scheme)) in this directive. Plain URL schemes allow scripts to be sourced from an unsafe domain.",
                                               directive: scriptName, severity: .high))
                }
                if hosts.contains(where: { !["*", "http:", "https:", "data:"].contains($0) }) || script.contains("'self'") {
                    findings.append(CSPFinding(description: "Host allowlists can frequently be bypassed. Consider using CSP nonces or hashes instead, along with `'strict-dynamic'` if necessary.",
                                               directive: scriptName, severity: .high))
                }
            } else if !(script.contains("https:") || script.contains("http:")) {
                findings.append(CSPFinding(description: "Consider adding `https:` and `http:` URL schemes (ignored by browsers supporting `'strict-dynamic'`) to be backward compatible with older browsers.",
                                           directive: scriptName, severity: .medium))
            }
            if (nonces || hashes), !script.contains("'unsafe-inline'") {
                findings.append(CSPFinding(description: "Consider adding `'unsafe-inline'` (ignored by browsers supporting nonces/hashes) to be backward compatible with older browsers.",
                                           directive: scriptName, severity: .medium))
            }
        } else {
            findings.append(CSPFinding(description: "`script-src` directive is missing. This can allow the execution of unsafe scripts.",
                                       directive: "script-src", severity: .high))
        }
        if (byName["object-src"] ?? byName["default-src"] ?? []).isEmpty {
            findings.append(CSPFinding(description: "Missing `object-src` allows the injection of plugins that execute unsafe scripts. Consider setting `object-src` to `'none'` if you can.",
                                       directive: "object-src", severity: .high))
        }
        if nonces || hashes, byName["base-uri"] == nil {
            findings.append(CSPFinding(description: "Missing `base-uri` allows injected `<base>` tags to set the base URL for all relative URLs (e.g. scripts) to an attacker controlled domain. Consider setting `base-uri` to `'none'` or `'self'`.",
                                       directive: "base-uri", severity: .high))
        }
        if byName["report-uri"] == nil, byName["report-to"] == nil {
            findings.append(CSPFinding(description: "No CSP configures a reporting destination. This makes it difficult to maintain the CSP over time and monitor for any breakages.",
                                       directive: "report-uri", severity: .medium))
        }
        return findings
    }

    /// csp-xss.js: informative. A bypass is reported only when every
    /// enforced policy has it, as one strict policy is enough.
    static func cspXSS(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "csp-xss"
        let header = mainDocument(input)?.headers["content-security-policy"]
        // Several policies in one header are separated by commas.
        let headerPolicies = (header ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let metaPolicies = input.page.metaCSPs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let policies = headerPolicies + metaPolicies
        let headings = [
            Heading(key: "description", label: "Description", valueType: "text"),
            Heading(key: "directive", label: "Directive", valueType: "code"),
            Heading(key: "severity", label: "Severity", valueType: "text"),
        ]
        func row(_ finding: CSPFinding) -> [String: Value] {
            ["description": .text(finding.description), "directive": .code(finding.directive), "severity": .text(finding.severity.rawValue)]
        }
        guard !policies.isEmpty else {
            return informative(id, details: DeveloperLighthouseDetails(headings: headings, items: [
                row(CSPFinding(description: "No CSP found in enforcement mode", directive: "", severity: .high)),
            ]))
        }
        let each = policies.map(cspFindings)
        var findings: [CSPFinding] = []
        for finding in each[0] where finding.severity != .syntax {
            if each.dropFirst().allSatisfy({ $0.contains { $0.description == finding.description } }) { findings.append(finding) }
        }
        findings += each.flatMap { $0.filter { $0.severity == .syntax } }
        if !metaPolicies.isEmpty {
            findings.append(CSPFinding(description: "The page contains a CSP defined in a `<meta>` tag. Consider moving the CSP to an HTTP header or defining another strict CSP in an HTTP header.",
                                       directive: "", severity: .medium))
        }
        guard !findings.isEmpty else { return informative(id) }
        return informative(id, details: DeveloperLighthouseDetails(headings: headings, items: findings.map(row)))
    }

    // MARK: SEO

    struct RobotsError: Equatable {
        var line: Int
        var content: String
        var message: String
    }

    /// robots-txt.js validateRobots.
    static func validateRobots(_ content: String) -> [RobotsError] {
        let supported: Set<String> = ["user-agent", "disallow", "allow", "sitemap", "crawl-delay", "clean-param", "host",
                                      "request-rate", "visit-time", "noindex"]
        var errors: [RobotsError] = []
        var inGroup = false
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, original) in lines.enumerated() {
            var line = original
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            func fail(_ message: String) { errors.append(RobotsError(line: index + 1, content: original, message: message)) }
            guard let colon = line.firstIndex(of: ":") else { fail("Syntax not understood"); continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !supported.contains(name) { fail("Unknown directive"); continue }
            if name == "user-agent", value.isEmpty { fail("No user-agent specified"); continue }
            if name == "allow" || name == "disallow" {
                if !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("*") {
                    fail("Pattern should either be empty, start with \"/\" or \"*\""); continue
                }
                if let dollar = value.firstIndex(of: "$"), value.index(after: dollar) != value.endIndex {
                    fail("\"$\" should only be used at the end of the pattern"); continue
                }
            }
            if name == "sitemap" {
                guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host() != nil else {
                    fail("Invalid sitemap URL"); continue
                }
                if !["https", "http", "ftp"].contains(scheme) { fail("Invalid URL protocol"); continue }
            }
            if name == "user-agent" {
                inGroup = true
            } else if !inGroup, name == "allow" || name == "disallow" {
                fail("No user-agent specified")
            }
        }
        return errors
    }

    static func robotsTxt(_ input: DeveloperLighthouseInput) -> Audit {
        let id = "robots-txt"
        guard let robots = input.robots else { return notApplicable(id, "robots.txt is only fetched for http and https pages.") }
        guard let status = robots.status else {
            return binary(id, passed: false, explanation: "Search was unable to download a robots.txt file")
        }
        if status >= 500 { return binary(id, passed: false, displayValue: "Request for robots.txt returned HTTP status: \(status)") }
        guard status < 400, let content = robots.content, !content.isEmpty else { return notApplicable(id) }
        let errors = validateRobots(content)
        guard !errors.isEmpty else { return binary(id, passed: true) }
        return binary(id, passed: false, details: DeveloperLighthouseDetails(headings: [
            Heading(key: "index", label: "Line #", valueType: "text"),
            Heading(key: "line", label: "Content", valueType: "code"),
            Heading(key: "message", label: "Error", valueType: "code"),
        ], items: errors.map { ["index": .text("\($0.line)"), "line": .code($0.content), "message": .code($0.message)] }),
        displayValue: found(errors.count, "error"))
    }
}
