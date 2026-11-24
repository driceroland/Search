import Foundation

// Chrome's header overrides (Network ▸ Headers ▸ "Override headers"): a
// `.headers` file in a Local Overrides folder holds rules,
//
//     [{"applyTo": "app.js", "headers": [{"name": "cache-control", "value": "no-store"}]}]
//
// each `applyTo` relative to the file's own folder, `*` matching anything.
// A `.headers` file at the top of the overrides folder applies to every
// host. A response whose address matches gets the rule's headers: one
// replaces every header of its name, ignoring case, and the others stay;
// Set-Cookie headers replace the response's cookie of the same name and
// add the rest, as Chrome merges them. An empty value is sent empty, not
// removed, as in Chrome.
//
// This is the pure part: parsing, matching and merging. The folder lives in
// DeveloperLocalOverrides; the bridge (DeveloperNetworkBridgeScript) answers
// matching responses with the merged headers, using the rules compiled here.

enum DeveloperHeaderOverrides {
    static let fileName = ".headers"

    struct Header: Codable, Equatable, Hashable {
        var name: String
        var value: String
    }

    struct Rule: Codable, Equatable {
        var applyTo: String
        var headers: [Header]
    }

    /// One `.headers` file: the folder it sits in, as a page address
    /// without its scheme (`example.com/js`, or "" at the top), and its rules.
    struct File: Equatable {
        var directory: String
        var rules: [Rule]
    }

    struct ParseError: LocalizedError {
        let errorDescription: String?
    }

    // MARK: Reading and writing

    /// The rules in a `.headers` file. Chrome's format: an array of
    /// `{applyTo, headers: [{name, value}]}`.
    static func parse(_ text: String) throws -> [Rule] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ParseError(errorDescription: "The .headers file isn’t valid JSON.")
        }
        guard let list = json as? [Any] else {
            throw ParseError(errorDescription: "A .headers file holds an array of {applyTo, headers} rules.")
        }
        return try list.map { item in
            guard let rule = item as? [String: Any], let applyTo = rule["applyTo"] as? String,
                  let headers = rule["headers"] as? [Any] else {
                throw ParseError(errorDescription: "Each rule needs an “applyTo” string and a “headers” array.")
            }
            return Rule(applyTo: applyTo, headers: try headers.map { header in
                guard let header = header as? [String: Any], let name = header["name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ParseError(errorDescription: "Each header needs a “name” and a “value”.")
                }
                let value: String
                switch header["value"] {
                case let text as String: value = text
                case let number as NSNumber: value = number.stringValue
                default: throw ParseError(errorDescription: "Each header needs a “name” and a “value”.")
                }
                return Header(name: name, value: value)
            })
        }
    }

    /// The rules as Chrome writes them: indented JSON, keys in its order.
    static func encode(_ rules: [Rule]) -> String {
        func quote(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        if rules.isEmpty { return "[]\n" }
        let items = rules.map { rule in
            let headers = rule.headers.map { "      {\n        \"name\": \(quote($0.name)),\n        \"value\": \(quote($0.value))\n      }" }
            let list = headers.isEmpty ? "[]" : "[\n" + headers.joined(separator: ",\n") + "\n    ]"
            return "  {\n    \"applyTo\": \(quote(rule.applyTo)),\n    \"headers\": \(list)\n  }"
        }
        return "[\n" + items.joined(separator: ",\n") + "\n]\n"
    }

    // MARK: Matching

    /// What rules match: an http(s) address as host/path, a folder's own
    /// page as `index.html` (as Local Overrides keeps it), and its query.
    static func target(for url: String) -> (path: String, query: String?)? {
        guard let address = URLComponents(string: url), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = address.host?.lowercased(), !host.isEmpty
        else { return nil }
        if let port = address.port { host += ":\(port)" }
        var path = address.percentEncodedPath
        path = path.removingPercentEncoding ?? path
        if path.isEmpty || path.hasSuffix("/") { path += path.isEmpty ? "/index.html" : "index.html" }
        let query = address.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
        return (host + path, query)
    }

    /// The pattern a rule's `applyTo` makes, in its file's folder, as a
    /// regular expression both NSRegularExpression and JavaScript read.
    static func pattern(directory: String, applyTo: String) -> String {
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let full = trimmed.isEmpty ? applyTo : trimmed + "/" + applyTo
        return "^" + full.split(separator: "*", omittingEmptySubsequences: false).map { escape(String($0)) }
            .joined(separator: ".*") + "$"
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.|?*+()[]{}/".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    static func matches(_ url: String, directory: String, applyTo: String) -> Bool {
        guard let target = target(for: url) else { return false }
        return matches(target, pattern: pattern(directory: directory, applyTo: applyTo))
    }

    private static func matches(_ target: (path: String, query: String?), pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let test = { (text: String) in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if test(target.path) { return true }
        if let query = target.query { return test(target.path + "?" + query) }
        return false
    }

    /// The files in the order their rules apply: the top of the folder
    /// first, deeper folders after, so the nearer file wins.
    static func ordered(_ files: [File]) -> [File] {
        files.enumerated().sorted { a, b in
            let depthA = a.element.directory.split(separator: "/").count
            let depthB = b.element.directory.split(separator: "/").count
            if depthA != depthB { return depthA < depthB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Every rule as the bridge takes it, in the order they apply.
    static func compiled(_ files: [File]) -> [(pattern: String, headers: [Header])] {
        ordered(files).flatMap { file in
            file.rules.filter { !$0.headers.isEmpty }.map { (pattern(directory: file.directory, applyTo: $0.applyTo), $0.headers) }
        }
    }

    /// The headers every matching rule sets for an address, later rules
    /// over earlier ones. Empty when none matches.
    static func overrides(for url: String, in files: [File]) -> [Header] {
        guard let target = target(for: url) else { return [] }
        return overrides(for: target, in: files)
    }

    static func overrides(for target: (path: String, query: String?), in files: [File]) -> [Header] {
        var result: [Header] = []
        for rule in compiled(files) where matches(target, pattern: rule.pattern) {
            result = merge(result, rule.headers)
        }
        return result
    }

    /// The response's headers with the overrides applied.
    static func apply(to base: [Header], url: String, in files: [File]) -> [Header] {
        let headers = overrides(for: url, in: files)
        return headers.isEmpty ? base : merge(base, headers)
    }

    // MARK: Merging

    private static func isSetCookie(_ header: Header) -> Bool {
        header.name.caseInsensitiveCompare("set-cookie") == .orderedSame
    }

    /// Chrome's merge: a header named in the overrides replaces every one
    /// of that name in `base`, whatever the case, in the first one's place;
    /// new ones follow; Set-Cookie is merged by cookie name.
    static func merge(_ base: [Header], _ overrides: [Header]) -> [Header] {
        var replacements: [String: [Header]] = [:]
        var order: [String] = []
        for header in overrides where !isSetCookie(header) {
            let key = header.name.lowercased()
            if replacements[key] == nil { order.append(key) }
            replacements[key, default: []].append(header)
        }
        var result: [Header] = []
        var placed = Set<String>()
        for header in base where !isSetCookie(header) {
            let key = header.name.lowercased()
            if let replacement = replacements[key] {
                if placed.insert(key).inserted { result += replacement }
            } else {
                result.append(header)
            }
        }
        for key in order where !placed.contains(key) { result += replacements[key] ?? [] }
        return result + mergeSetCookies(base.filter(isSetCookie), overrides.filter(isSetCookie))
    }

    /// The key Chrome merges a Set-Cookie value by: `name=`, or the whole
    /// value when it isn't one.
    static func cookieKey(_ value: String) -> String {
        let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+.^_`|~-")
        guard let equals = value.firstIndex(of: "=") else { return value }
        let name = value[..<equals]
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains) else { return value }
        return String(name) + "="
    }

    /// An override's cookie replaces the response's cookies of its name;
    /// the rest are added after the response's own.
    static func mergeSetCookies(_ original: [Header], _ overrides: [Header]) -> [Header] {
        func grouped(_ headers: [Header]) -> (keys: [String], values: [String: [String]]) {
            var keys: [String] = []
            var values: [String: [String]] = [:]
            for header in headers {
                let key = cookieKey(header.value)
                if values[key] == nil { keys.append(key) }
                values[key, default: []].append(header.value)
            }
            return (keys, values)
        }
        let base = grouped(original)
        let added = grouped(overrides)
        let values = base.keys.flatMap { added.values[$0] ?? base.values[$0] ?? [] }
            + added.keys.filter { base.values[$0] == nil }.flatMap { added.values[$0] ?? [] }
        return values.map { Header(name: "set-cookie", value: $0) }
    }

    /// Headers as WebKit takes them: one value per name, Set-Cookie values
    /// on separate lines (as WebKit reports them), others joined by commas.
    static func object(_ headers: [Header]) -> [String: String] {
        var result: [String: String] = [:]
        var names: [String: String] = [:]
        for header in headers {
            let key = header.name.lowercased()
            let name = names[key] ?? header.name
            names[key] = name
            result[name] = result[name].map { $0 + (key == "set-cookie" ? "\n" : ", ") + header.value } ?? header.value
        }
        return result
    }

    /// Headers from WebKit's object form, Set-Cookie split back into lines.
    static func headers(from object: [String: String]) -> [Header] {
        object.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.flatMap { name, value in
            name.caseInsensitiveCompare("set-cookie") == .orderedSame
                ? value.split(separator: "\n").map { Header(name: name, value: String($0)) }
                : [Header(name: name, value: value)]
        }
    }

    // MARK: Editing

    /// Where "Override headers" keeps an address's rule: the `.headers`
    /// file in the folder its file is kept in, `applyTo` its file's name.
    static func location(for url: String) -> (directory: String, applyTo: String)? {
        guard let target = target(for: url), let slash = target.path.lastIndex(of: "/") else { return nil }
        let name = String(target.path[target.path.index(after: slash)...])
        return (String(target.path[..<slash]), name.isEmpty ? "index.html" : name)
    }

    /// The rules with `applyTo`'s headers replaced: the first rule for it
    /// changed, a new one added at the end, or removed when none is left.
    static func setting(_ headers: [Header], applyTo: String, in rules: [Rule]) -> [Rule] {
        var rules = rules
        let kept = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if let index = rules.firstIndex(where: { $0.applyTo == applyTo }) {
            if kept.isEmpty { rules.remove(at: index) } else { rules[index].headers = kept }
        } else if !kept.isEmpty {
            rules.append(Rule(applyTo: applyTo, headers: kept))
        }
        return rules
    }

    /// The headers a file's rule for exactly `applyTo` sets.
    static func headers(applyTo: String, in rules: [Rule]) -> [Header] {
        rules.first { $0.applyTo == applyTo }?.headers ?? []
    }
}
