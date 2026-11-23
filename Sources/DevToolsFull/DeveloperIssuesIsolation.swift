import Foundation

// The Issues tool's cross-origin isolation and ARIA rules, beside the rest
// of DeveloperIssueRules (DeveloperIssues.swift). Cross-origin isolation
// is judged from the response headers the frontend listener hears
// (DeveloperIssues-frontend.js) and the page's `crossOriginIsolated`;
// ARIA from the attributes the page scan reads (DeveloperIssues-collect.js).

/// An element the page scan found with a role or an aria-* attribute.
struct DeveloperAriaElement: Equatable {
    var index: Int
    var label: String
    /// The role attribute; nil when absent.
    var role: String?
    /// Its aria-* attributes, names lowercased, in document order.
    var attributes: [(name: String, value: String)] = []
    /// Whether it can take keyboard focus.
    var focusable = false
    /// Whether an element inside it can take keyboard focus.
    var containsFocusable = false
    /// A form field: its aria-labelledby is the form rules' to judge.
    var formField = false

    init(index: Int, label: String, role: String? = nil, attributes: [(name: String, value: String)] = [],
         focusable: Bool = false, containsFocusable: Bool = false, formField: Bool = false) {
        self.index = index
        self.label = label
        self.role = role
        self.attributes = attributes
        self.focusable = focusable
        self.containsFocusable = containsFocusable
        self.formField = formField
    }

    init(raw: [String: Any]) {
        let pairs = (raw["attributes"] as? [[String]] ?? []).compactMap { pair -> (name: String, value: String)? in
            guard let name = pair.first else { return nil }
            return (name.lowercased(), pair.count > 1 ? pair[1] : "")
        }
        self.init(index: (raw["i"] as? NSNumber)?.intValue ?? -1, label: raw["label"] as? String ?? "element",
                  role: raw["role"] as? String, attributes: pairs, focusable: raw["focusable"] as? Bool ?? false,
                  containsFocusable: raw["containsFocusable"] as? Bool ?? false, formField: raw["field"] as? Bool ?? false)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.label == rhs.label && lhs.role == rhs.role
            && lhs.attributes.map(\.name) == rhs.attributes.map(\.name)
            && lhs.attributes.map(\.value) == rhs.attributes.map(\.value)
            && lhs.focusable == rhs.focusable && lhs.containsFocusable == rhs.containsFocusable
            && lhs.formField == rhs.formField
    }
}

/// The isolation headers of one response, lowercased values, nil when the
/// header wasn't sent.
struct DeveloperIsolationResponse: Equatable {
    var requestID: String
    var url: String
    /// WebKit's resource type: "Document", "Script", "Image", …
    var type: String
    var coop: String?
    var coep: String?
    var corp: String?
    /// Access-Control-Allow-Origin, which loads the resource with CORS.
    var allowOrigin: String?
    var failed = false

    init(requestID: String, url: String, type: String, coop: String? = nil, coep: String? = nil, corp: String? = nil,
         allowOrigin: String? = nil, failed: Bool = false) {
        self.requestID = requestID
        self.url = url
        self.type = type
        self.coop = coop
        self.coep = coep
        self.corp = corp
        self.allowOrigin = allowOrigin
        self.failed = failed
    }
}

extension DeveloperIssueRules {
    // MARK: Cross-origin isolation

    /// The values each header takes; anything else is ignored by browsers.
    static let coopValues: Set<String> = ["same-origin", "same-origin-allow-popups", "unsafe-none", "noopener-allow-popups"]
    static let coepValues: Set<String> = ["require-corp", "credentialless", "unsafe-none"]

    /// A header's value without report-to parameters ("same-origin; report-to=x").
    static func policyValue(_ header: String?) -> String? {
        guard let header else { return nil }
        let value = header.split(separator: ";").first.map(String.init) ?? header
        return value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))).lowercased()
    }

    /// What's wrong with the page's isolation: header values browsers
    /// ignore, COEP without the isolation it asks for, and cross-origin
    /// resources a require-corp page loads without CORS or a
    /// Cross-Origin-Resource-Policy.
    static func isolation(document: DeveloperIsolationResponse?, responses: [DeveloperIsolationResponse],
                          crossOriginIsolated: Bool?) -> [DeveloperIssue] {
        guard let document else { return [] }
        var issues: [DeveloperIssue] = []
        let coop = policyValue(document.coop)
        let coep = policyValue(document.coep)
        func request(_ response: DeveloperIsolationResponse, _ detail: String) -> DeveloperAffectedResource {
            DeveloperAffectedResource(kind: .request, label: response.url, detail: detail, url: response.url,
                                      requestID: response.requestID.isEmpty ? nil : response.requestID)
        }
        if let coop, !coop.isEmpty, !coopValues.contains(coop) {
            issues.append(DeveloperIssue(code: .coopCoepInvalid, key: "isolation|coop|" + coop + "|" + document.url,
                                         resources: [request(document, "Cross-Origin-Opener-Policy: " + coop)]))
        }
        if let coep, !coep.isEmpty, !coepValues.contains(coep) {
            issues.append(DeveloperIssue(code: .coopCoepInvalid, key: "isolation|coep|" + coep + "|" + document.url,
                                         resources: [request(document, "Cross-Origin-Embedder-Policy: " + coep)]))
        }
        let wantsIsolation = coep == "require-corp" || coep == "credentialless"
        if wantsIsolation, crossOriginIsolated == false {
            let missing = coop == "same-origin" ? "COOP and COEP are sent; the document isn’t isolated"
                : "Cross-Origin-Opener-Policy: " + (coop ?? "missing")
            issues.append(DeveloperIssue(code: .crossOriginIsolationIncomplete, key: "isolation|incomplete|" + document.url,
                                         resources: [request(document, missing)]))
        }
        guard coep == "require-corp", let page = URL(string: document.url) else { return issues }
        for response in responses where response.requestID != document.requestID {
            guard let address = URL(string: response.url), let scheme = address.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", !sameOrigin(page, address),
                  response.allowOrigin == nil else { continue }
            if let corp = policyValue(response.corp), !corp.isEmpty {
                // same-site is enough when the sites match; same-origin never is here.
                let allowed = corp == "cross-origin" || corp == "same-site" && sameSite(page, address)
                if allowed { continue }
                issues.append(DeveloperIssue(code: .coepCorpMissing, key: "isolation|corp|" + response.url,
                                             resources: [request(response, "Cross-Origin-Resource-Policy: " + corp)]))
            } else {
                issues.append(DeveloperIssue(code: .coepCorpMissing, key: "isolation|corp|" + response.url,
                                             resources: [request(response, response.failed ? "Blocked: no Cross-Origin-Resource-Policy"
                                                                    : "No Cross-Origin-Resource-Policy")]))
            }
        }
        return issues
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased() && left.host()?.lowercased() == right.host()?.lowercased()
            && (left.port ?? defaultPort(left)) == (right.port ?? defaultPort(right))
    }

    private static func sameSite(_ left: URL, _ right: URL) -> Bool {
        guard let first = left.host()?.lowercased(), let second = right.host()?.lowercased() else { return false }
        return left.scheme?.lowercased() == right.scheme?.lowercased() && site(of: first) == site(of: second)
    }

    private static func defaultPort(_ url: URL) -> Int {
        url.scheme?.lowercased() == "http" ? 80 : 443
    }

    /// Console messages about isolation: SharedArrayBuffer used where it
    /// isn't available (WebKit leaves it undefined on a page that isn't
    /// cross-origin isolated, so its use is a ReferenceError), and loads
    /// WebKit refused under COEP or CORP.
    static func isolation(_ message: DeveloperIssueMessage) -> DeveloperIssue? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = message.url.flatMap { url -> DeveloperAffectedResource? in
            guard !url.isEmpty, let line = message.line, line > 0 else { return nil }
            return DeveloperAffectedResource(kind: .source, label: ConsoleFormat.location(url, line: line), url: url,
                                             line: line, column: message.column)
        }
        let place = (message.url ?? "") + "|" + (message.line.map(String.init) ?? "")
        if text.contains("SharedArrayBuffer"), message.level == "error" || text.contains("isolat") {
            var resources: [DeveloperAffectedResource] = []
            if var source {
                source.detail = String(text.prefix(300))
                resources.append(source)
            }
            return DeveloperIssue(code: .sharedArrayBuffer, key: "sab|" + place, resources: resources)
        }
        guard text.contains("Cross-Origin-Embedder-Policy") || text.contains("Cross-Origin-Resource-Policy") else { return nil }
        let url = first(#"(?:load(?: to)?|display) ['"]?((?:https?):[^\s'"]+)"#, in: text).map(trimmedURL)
        var resources: [DeveloperAffectedResource] = []
        if let url {
            resources.append(DeveloperAffectedResource(kind: .request, label: url, detail: "Blocked", url: url))
        } else {
            resources.append(DeveloperAffectedResource(kind: .request, label: String(text.prefix(300)), detail: "Blocked"))
        }
        if let source { resources.append(source) }
        return DeveloperIssue(code: .coepCorpMissing, key: "isolation|corp|" + (url ?? text), resources: resources)
    }

    // MARK: ARIA

    /// WAI-ARIA 1.2 roles, the DPub and Graphics modules, and the abstract
    /// roles left out (authors mustn't use them).
    static let ariaRoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "blockquote", "button", "caption", "cell",
        "checkbox", "code", "columnheader", "combobox", "comment", "complementary", "contentinfo", "definition",
        "deletion", "dialog", "directory", "document", "emphasis", "feed", "figure", "form", "generic", "grid",
        "gridcell", "group", "heading", "img", "image", "insertion", "link", "list", "listbox", "listitem", "log", "main",
        "mark", "marquee", "math", "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio", "meter",
        "navigation", "none", "note", "option", "paragraph", "presentation", "progressbar", "radio", "radiogroup",
        "region", "row", "rowgroup", "rowheader", "scrollbar", "search", "searchbox", "separator", "slider",
        "spinbutton", "status", "strong", "subscript", "suggestion", "superscript", "switch", "tab", "table",
        "tablist", "tabpanel", "term", "textbox", "time", "timer", "toolbar", "tooltip", "tree", "treegrid", "treeitem",
        "doc-abstract", "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-backlink", "doc-biblioentry",
        "doc-bibliography", "doc-biblioref", "doc-chapter", "doc-colophon", "doc-conclusion", "doc-cover",
        "doc-credit", "doc-credits", "doc-dedication", "doc-endnote", "doc-endnotes", "doc-epigraph", "doc-epilogue",
        "doc-errata", "doc-example", "doc-footnote", "doc-foreword", "doc-glossary", "doc-glossref", "doc-index",
        "doc-introduction", "doc-noteref", "doc-notice", "doc-pagebreak", "doc-pagefooter", "doc-pageheader",
        "doc-pagelist", "doc-part", "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna", "doc-subtitle",
        "doc-tip", "doc-toc", "graphics-document", "graphics-object", "graphics-symbol",
    ]

    /// Every aria-* attribute WAI-ARIA 1.2 and 1.3 define.
    static let ariaAttributes: Set<String> = [
        "aria-activedescendant", "aria-atomic", "aria-autocomplete", "aria-braillelabel", "aria-brailleroledescription",
        "aria-busy", "aria-checked", "aria-colcount", "aria-colindex", "aria-colindextext", "aria-colspan",
        "aria-controls", "aria-current", "aria-describedby", "aria-description", "aria-details", "aria-disabled",
        "aria-dropeffect", "aria-errormessage", "aria-expanded", "aria-flowto", "aria-grabbed", "aria-haspopup",
        "aria-hidden", "aria-invalid", "aria-keyshortcuts", "aria-label", "aria-labelledby", "aria-level", "aria-live",
        "aria-modal", "aria-multiline", "aria-multiselectable", "aria-orientation", "aria-owns", "aria-placeholder",
        "aria-posinset", "aria-pressed", "aria-readonly", "aria-relevant", "aria-required", "aria-roledescription",
        "aria-rowcount", "aria-rowindex", "aria-rowindextext", "aria-rowspan", "aria-selected", "aria-setsize",
        "aria-sort", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext", "aria-actions",
    ]

    /// Attributes whose value is a list of ids (or one id).
    static let ariaReferences: Set<String> = [
        "aria-activedescendant", "aria-controls", "aria-describedby", "aria-details", "aria-errormessage",
        "aria-flowto", "aria-labelledby", "aria-owns", "aria-actions",
    ]

    /// The values token attributes allow; true/false ones take "undefined"
    /// too where the spec lets them.
    static let ariaTokens: [String: Set<String>] = [
        "aria-atomic": ["true", "false"], "aria-busy": ["true", "false"], "aria-disabled": ["true", "false"],
        "aria-modal": ["true", "false"], "aria-multiline": ["true", "false"], "aria-multiselectable": ["true", "false"],
        "aria-readonly": ["true", "false"], "aria-required": ["true", "false"],
        "aria-hidden": ["true", "false", "undefined"], "aria-expanded": ["true", "false", "undefined"],
        "aria-selected": ["true", "false", "undefined"], "aria-grabbed": ["true", "false", "undefined"],
        "aria-checked": ["true", "false", "mixed", "undefined"], "aria-pressed": ["true", "false", "mixed", "undefined"],
        "aria-autocomplete": ["inline", "list", "both", "none"],
        "aria-current": ["page", "step", "location", "date", "time", "true", "false"],
        "aria-haspopup": ["false", "true", "menu", "listbox", "tree", "grid", "dialog"],
        "aria-invalid": ["grammar", "false", "spelling", "true"],
        "aria-live": ["assertive", "off", "polite"], "aria-orientation": ["horizontal", "vertical", "undefined"],
        "aria-sort": ["ascending", "descending", "none", "other"],
    ]

    /// Chrome's accessibility checks, as issues: each element on its own,
    /// as the form issues are.
    static func aria(_ snapshot: DeveloperFormSnapshot, scan: String) -> [DeveloperIssue] {
        var issues: [DeveloperIssue] = []
        for element in snapshot.aria {
            func add(_ code: DeveloperIssueCode, _ detail: String, _ part: String) {
                issues.append(DeveloperIssue(code: code, key: ["aria", code.rawValue, String(element.index), element.label, part]
                    .joined(separator: "|"), resources: [
                        DeveloperAffectedResource(kind: .element, label: element.label.isEmpty ? "element" : element.label,
                                                  detail: detail,
                                                  element: element.index >= 0 ? DeveloperIssueElement(scan: scan, index: element.index) : nil),
                    ]))
            }
            if let role = element.role {
                let tokens = role.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                if !tokens.isEmpty, !tokens.contains(where: { ariaRoles.contains($0) }) {
                    add(.ariaInvalidRole, "role=\"" + String(role.prefix(80)) + "\"", "role")
                }
            }
            for attribute in element.attributes {
                let name = attribute.name
                let value = attribute.value.trimmingCharacters(in: .whitespaces)
                guard ariaAttributes.contains(name) else {
                    add(.ariaUnknownAttribute, name, name)
                    continue
                }
                if let allowed = ariaTokens[name], !value.isEmpty, !allowed.contains(value.lowercased()) {
                    add(.ariaInvalidValue, name + "=\"" + String(value.prefix(80)) + "\"", name)
                }
                if ariaReferences.contains(name), !(element.formField && name == "aria-labelledby") {
                    let missing = value.split(whereSeparator: \.isWhitespace).map(String.init).filter { !snapshot.ids.contains($0) }
                    if !missing.isEmpty { add(.ariaMissingReference, name + "=" + missing.joined(separator: " "), name) }
                }
                if name == "aria-hidden", value.lowercased() == "true", element.focusable || element.containsFocusable {
                    add(.ariaHiddenFocusable, element.focusable ? "aria-hidden=\"true\" on a focusable element"
                        : "aria-hidden=\"true\" around a focusable element", name)
                }
            }
        }
        return issues
    }
}
