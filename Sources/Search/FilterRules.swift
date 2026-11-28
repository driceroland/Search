import Foundation

enum FilterRules {
    typealias Rule = [String: Any]
    private static let chunkLimit = 150_000
    private static let maxChunks = 8
    private static let selectorsPerRule = 1_000
    private static let resourceTypes = [
        "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"],
        "font": ["font"], "media": ["media"], "xmlhttprequest": ["raw", "fetch"],
        "xhr": ["raw", "fetch"], "subdocument": ["child-document"], "popup": ["popup"],
        "websocket": ["websocket"], "other": ["other"], "ping": ["ping"],
    ]

    // Order matters because an exception resets everything before it in the
    // custom list. Cosmetic exceptions run before network blocks.
    private enum Kind: Int, CaseIterable {
        case generic, genericException, site, cosmeticException, block, exception

        var isException: Bool {
            self == .genericException || self == .cosmeticException || self == .exception
        }
    }

    static func convert(_ text: String) -> (chunks: [[Rule]], count: Int, skipped: Int) {
        var groups = Array(repeating: [Rule](), count: Kind.allCases.count)
        var generic: [String] = []
        var count = 0
        var skipped = 0
        let lines = text.split(whereSeparator: \.isNewline)

        // Reserve room for every exception in each chunk before adding any
        // blocking rules. Keep at least one slot for a blocking rule.
        var exceptions = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("@@") else { continue }
            if !isUnsupportedCosmetic(line), !line.contains("##"),
               let (kind, rules) = network(line), rules.count < chunkLimit - exceptions {
                groups[kind.rawValue].append(contentsOf: rules)
                exceptions += rules.count
            } else {
                skipped += 1
            }
        }

        let capacity = chunkLimit - exceptions
        let limit = capacity * maxChunks
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("@@")
                || (line.hasPrefix("[") && line.lowercased().hasPrefix("[adblock")) { continue }
            guard count < limit || (!generic.isEmpty && generic.count < selectorsPerRule) else {
                skipped += 1
                continue
            }
            if isUnsupportedCosmetic(line) {
                skipped += 1
            } else if let separator = line.range(of: "##") {
                let sites = String(line[..<separator.lowerBound])
                let selector = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard supportedSelector(selector) else { skipped += 1; continue }
                if sites.isEmpty {
                    if generic.count == selectorsPerRule {
                        groups[Kind.generic.rawValue].append(cosmetic(generic.joined(separator: ", ")))
                        generic.removeAll(keepingCapacity: true)
                    }
                    if generic.isEmpty { count += 1 }
                    generic.append(selector)
                } else if count < limit, let domains = domains(sites, separator: ",") {
                    groups[Kind.site.rawValue].append(cosmetic(selector, domains: domains))
                    count += 1
                } else {
                    skipped += 1
                }
            } else if let (kind, rules) = network(line), rules.count <= limit - count {
                groups[kind.rawValue].append(contentsOf: rules)
                count += rules.count
            } else {
                skipped += 1
            }
        }
        if !generic.isEmpty {
            groups[Kind.generic.rawValue].append(cosmetic(generic.joined(separator: ", ")))
        }
        guard count + exceptions > 0 else { return ([], 0, skipped) }

        let chunkCount = max(1, (count + capacity - 1) / capacity)
        var offsets = Array(repeating: 0, count: groups.count)
        let chunks = (0..<chunkCount).map { _ in
            var available = capacity
            var chunk: [Rule] = []
            for kind in Kind.allCases {
                let index = kind.rawValue
                if kind.isException {
                    chunk.append(contentsOf: groups[index])
                } else {
                    let start = offsets[index]
                    let end = min(groups[index].count, start + available)
                    chunk.append(contentsOf: groups[index][start..<end])
                    offsets[index] = end
                    available -= end - start
                }
            }
            return chunk
        }
        return (chunks, count + exceptions, skipped)
    }

    private static func isUnsupportedCosmetic(_ line: String) -> Bool {
        line.contains("#@#") || line.contains("#?#") || line.contains("#$#")
            || line.contains("#%#") || line.contains("#@?#") || line.contains("#@$#") || line.contains("#@%#")
    }

    private static func supportedSelector(_ selector: String) -> Bool {
        let unsupported = [":has-text(", ":contains(", ":matches-", ":upward(", ":xpath(",
                           ":min-text-length(", ":watch-attr(", ":remove(", ":style(",
                           ":nth-ancestor(", ":contains-", ":-abp-"]
        return !selector.isEmpty && !selector.hasPrefix("+js") && !selector.hasPrefix("^")
            && !unsupported.contains(where: selector.lowercased().contains)
    }

    private static func cosmetic(_ selector: String, domains: Rule = [:]) -> Rule {
        var trigger = domains
        trigger["url-filter"] = ".*"
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    private static func domains(_ text: String, separator: Character) -> Rule? {
        var includes: [String] = []
        var excludes: [String] = []
        for item in text.lowercased().split(separator: separator, omittingEmptySubsequences: false) {
            let negated = item.hasPrefix("~")
            let host = negated ? item.dropFirst() : item[...]
            guard validDomain(host) else { return nil }
            if negated { excludes += [String(host), "*." + host] }
            else { includes += [String(host), "*." + host] }
        }
        guard includes.isEmpty || excludes.isEmpty else { return nil }
        return includes.isEmpty ? ["unless-domain": excludes] : ["if-domain": includes]
    }

    private static func validDomain(_ host: Substring) -> Bool {
        !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    private static func network(_ line: String) -> (Kind, [Rule])? {
        let exception = line.hasPrefix("@@")
        let filter = exception ? line.dropFirst(2) : line[...]
        let regexEnd = filter.hasPrefix("/") ? filter.lastIndex(of: "/") : nil
        let splitFrom = regexEnd.map { filter.index(after: $0) } ?? filter.startIndex
        let optionStart = filter[splitFrom...].firstIndex(of: "$")
        let pattern = filter[..<(optionStart ?? filter.endIndex)]
        let options = optionStart.map { filter[filter.index(after: $0)...].lowercased()
            .split(separator: ",", omittingEmptySubsequences: false) } ?? []
        guard let patterns = patterns(for: pattern) else { return nil }

        var trigger: Rule = [:]
        var types: Set<String> = []
        var scope: Kind?
        for option in options {
            switch option {
            case "third-party", "3p":
                guard trigger["load-type"] == nil else { return nil }
                trigger["load-type"] = ["third-party"]
            case "~third-party", "1p":
                guard trigger["load-type"] == nil else { return nil }
                trigger["load-type"] = ["first-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important":
                break
            case "document", "elemhide", "generichide":
                guard exception, scope == nil else { return nil }
                scope = option == "document" ? .exception
                    : (option == "elemhide" ? .cosmeticException : .genericException)
            case let value where value.hasPrefix("domain="):
                guard trigger["if-domain"] == nil, trigger["unless-domain"] == nil,
                      let domains = domains(String(value.dropFirst(7)), separator: "|") else { return nil }
                trigger.merge(domains) { current, _ in current }
            default:
                guard let mapped = resourceTypes[String(option)] else { return nil }
                types.formUnion(mapped)
            }
        }

        let action = ["type": exception ? "ignore-previous-rules" : "block"]
        if let scope {
            // WebKit accepts only one top-level URL/domain condition.
            guard types.isEmpty, trigger["if-domain"] == nil, trigger["unless-domain"] == nil,
                  trigger["load-type"] == nil else { return nil }
            if trigger.removeValue(forKey: "url-filter-is-case-sensitive") != nil {
                trigger["top-url-filter-is-case-sensitive"] = true
            }
            trigger["url-filter"] = ".*"
            trigger["if-top-url"] = patterns
            return (scope, [["trigger": trigger, "action": action]])
        }
        if !types.isEmpty { trigger["resource-type"] = types.sorted() }
        return (exception ? .exception : .block, patterns.map { pattern in
            var match = trigger
            match["url-filter"] = pattern
            return ["trigger": match, "action": action]
        })
    }

    private static func patterns(for filter: Substring) -> [String]? {
        guard !filter.isEmpty, filter.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        if filter.count > 2, filter.hasPrefix("/"), filter.hasSuffix("/") {
            let regex = String(filter.dropFirst().dropLast())
            return supportedRegex(regex) ? [regex] : nil
        }
        var rest = filter
        var prefix = ""
        var hostLength = 0
        var domainOnly = false
        if rest.hasPrefix("||") {
            rest = rest.dropFirst(2)
            let host = rest.prefix { $0.isLetter || $0.isNumber || ".-_*".contains($0) }
            guard host.contains(where: { $0.isLetter || $0.isNumber }),
                  validDomain(Substring(host.replacingOccurrences(of: "*", with: "x"))) else { return nil }
            hostLength = host.count
            domainOnly = rest.dropFirst(hostLength) == "^"
            prefix = "^[a-z][a-z0-9+.\\-]*://([^/?#@]+@)?([^/:?#@]+\\.)?"
        } else if rest.hasPrefix("|") {
            rest = rest.dropFirst()
            prefix = "^"
        }
        let anchoredEnd = rest.hasSuffix("|")
        if anchoredEnd { rest = rest.dropLast() }
        guard !rest.isEmpty, !rest.contains("|") else { return nil }
        let trailingSeparator = rest.hasSuffix("^")
        if trailingSeparator { rest = rest.dropLast() }
        guard rest.contains(where: { $0 != "*" && $0 != "^" }) else { return nil }
        let separator = "[^A-Za-z0-9_.%\\-]"
        var pattern = prefix
        var wildcard = false
        for (offset, character) in rest.enumerated() {
            switch character {
            case "*":
                if !wildcard { pattern += offset < hostLength ? "[^/:?#@]*" : ".*" }
            case "^":
                pattern += separator
            default:
                if "\\.[]{}()+?$".contains(character) { pattern += "\\" }
                pattern.append(character)
            }
            wildcard = character == "*"
        }
        let end = anchoredEnd ? "$" : ""
        if domainOnly {
            // WebKit supplies a canonical URL with a path boundary. Require
            // that boundary even after a port, so credentials cannot match.
            return [pattern + "(:[0-9]+)?[/?#]"]
        }
        // WebKit has no alternation. Other trailing separators match a
        // boundary character or the end of the URL.
        return trailingSeparator ? [pattern + separator + end, pattern + "$"] : [pattern + end]
    }

    private static func supportedRegex(_ regex: String) -> Bool {
        // Admit a conservative subset: literal escapes, simple character
        // classes and quantifiers, and anchors at the ends only.
        let atom = #"(?:\\[\\./\[\]{}()*+?$^\-|]|[^\[\]\\(){}|^$*+?]|\[\^?(?:[A-Za-z0-9_.:/?=&%#@]|-)+\])"#
        let subset = #"^\^?(?:"# + atom + #"[?+*]?)+\$?$"#
        guard regex.utf8.count <= 512, regex.range(of: subset, options: .regularExpression) != nil,
              let expression = try? NSRegularExpression(pattern: regex) else { return false }
        return expression.firstMatch(in: "", range: NSRange(location: 0, length: 0)) == nil
    }
}
