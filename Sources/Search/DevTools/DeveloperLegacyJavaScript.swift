// Portions derived from Lighthouse's legacy-javascript.js, Copyright 2025 Google LLC.
// Apache-2.0. Adapted to Swift and Search's WebKit trace model.
// See Resources/THIRD-PARTY-NOTICES.md and Resources/LICENSE-Lighthouse.txt.

import Foundation

/// Lighthouse's legacy-javascript detection (core/lib/legacy-javascript,
/// Apache-2.0), which Chrome's Legacy JavaScript insight runs over each
/// script: polyfills for features modern browsers have, found by how
/// polyfill libraries install them (and by core-js's module names), and
/// Babel transforms found by the runtime helpers they bring; then from a
/// source map, the polyfill modules it names. The savings are the size of
/// the polyfills' modules (DeveloperLegacyJavaScriptData) plus an estimate
/// per transform.
enum DeveloperLegacyJavaScript {
    typealias Table = DeveloperLegacyJavaScriptData

    struct Result: Equatable {
        /// The polyfills and transforms found, by name, sorted.
        var matches: [String]
        /// In bytes of the script's text.
        var estimatedByteSavings: Int
    }

    static let classesTransform = "@babel/plugin-transform-classes"
    static let regeneratorTransform = "@babel/plugin-transform-regenerator"
    static let spreadTransform = "@babel/plugin-transform-spread"

    private struct Pattern {
        let expression: String
        /// The polyfill's or transform's name, from the text matched.
        let resolve: (String) -> String?
    }

    /// Every module name (core-js's "es.array.at", an npm package's) to the
    /// polyfill it provides.
    static let moduleToPolyfill: [String: String] = {
        var names: [String: String] = [:]
        for polyfill in Table.polyfills {
            for module in polyfill.modules { names[module] = polyfill.name }
        }
        return names
    }()

    /// Lighthouse's patterns, factored as it factors them: by the object a
    /// polyfill is installed on, core-js's target, and its module prefix.
    /// ICU, unlike JavaScript, wants a literal brace escaped, in a set too.
    private static let patterns: [Pattern] = {
        var objects: [(key: String, values: [String])] = []
        var targets: [(key: String, values: [String])] = []
        var prefixes: [(key: String, values: [String])] = []
        var targetToName: [String: String] = [:]
        var coreJSModuleToName: [String: String] = [:]
        func add(_ list: inout [(key: String, values: [String])], _ key: String, _ value: String) {
            if let index = list.firstIndex(where: { $0.key == key }) {
                list[index].values.append(value)
            } else {
                list.append((key: key, values: [value]))
            }
        }
        for polyfill in Table.polyfills where polyfill.coreJS {
            guard let module = polyfill.modules.first else { continue }
            let parts = polyfill.name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let object = parts.dropLast().joined(separator: ".")
            let property = parts.last ?? ""
            add(&objects, object, property)
            let target = replacingFirst(".prototype", in: object)
            add(&targets, target, property)
            targetToName["\(target).\(property)"] = polyfill.name
            coreJSModuleToName[module] = polyfill.name
            let moduleParts = module.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            add(&prefixes, moduleParts.prefix(2).joined(separator: "."), moduleParts.dropFirst(2).joined(separator: "."))
        }
        func escape(_ text: String) -> String { text.replacingOccurrences(of: ".", with: "\\.") }

        // 1. Direct property assignment: `String.prototype.startsWith =`
        let direct = objects.map { "\(escape($0.key))\\.(?:\($0.values.joined(separator: "|")))\\s?=[^=]" }
        // 2. Bracket property assignment: `String.prototype['startsWith'] =`
        let bracket = objects.map { "\(escape($0.key))\\[['\"](?:\($0.values.joined(separator: "|")))['\"]\\]\\s?=[^=]" }
        // 3. Object.defineProperty: `Object.defineProperty(String.prototype, 'startsWith'`
        let define = objects.map { "\(escape($0.key)),\\s?['\"](?:\($0.values.joined(separator: "|")))['\"]" }
        // 4. es-shims: `no(Object,{entries:r},{entries:function`
        let shims = objects.map { entry in
            let properties = entry.values.map { "\($0):[^\\};]*\\},\\s*\\{\($0)\\b" }.joined(separator: "|")
            return "\(escape(entry.key)),\\s*\\{(?:\(properties))"
        }
        // 5. core-js@3 minified: `{target:"Array",proto:true},{fill:fill`
        let target = targets.map { "['\"]\(escape($0.key))['\"][^;]*?\\},\\{(?:\($0.values.joined(separator: "|"))):" }
        // 6. Un-minified core-js module names: `core-js/modules/es.object.is-frozen`
        let modules = prefixes.map { "\(escape($0.key))\\.(?:\($0.values.map(escape).joined(separator: "|")))" }

        let polyfills: [Pattern] = [
            Pattern(expression: direct.joined(separator: "|")) { match in
                guard let equals = match.firstIndex(of: "=") else { return nil }
                return trimmingTrailingWhitespace(match[..<equals])
            },
            Pattern(expression: bracket.joined(separator: "|")) { match in
                let characters = Array(match)
                guard let open = characters.firstIndex(of: "["),
                      let close = characters[open...].firstIndex(of: "]"), close - 1 >= open + 2 else { return nil }
                return String(characters[..<open]) + "." + String(characters[(open + 2)..<(close - 1)])
            },
            Pattern(expression: "defineProperty\\((?:\(define.joined(separator: "|")))") { match in
                let characters = Array(match)
                guard let open = characters.firstIndex(of: "("),
                      let comma = characters[open...].firstIndex(of: ",") else { return nil }
                let object = String(characters[(open + 1)..<comma])
                let rest = Array(characters[(comma + 1)...].drop { $0.isWhitespace })
                guard rest.count >= 2 else { return nil }
                return object + "." + String(rest[1..<(rest.count - 1)])
            },
            Pattern(expression: "\\((?:\(shims.joined(separator: "|")))") { match in
                let characters = Array(match)
                guard let comma = characters.firstIndex(of: ","), comma >= 1,
                      let brace = characters[comma...].firstIndex(of: "{"),
                      let colon = characters[brace...].firstIndex(of: ":") else { return nil }
                return String(characters[1..<comma]) + "." + String(characters[(brace + 1)..<colon])
            },
            Pattern(expression: "\\{target:(?:\(target.joined(separator: "|")))") { match in
                // `{target:` is 8 characters, then the target's quote.
                let characters = Array(match)
                guard characters.count > 9, let end = characters[9...].firstIndex(of: characters[8]),
                      let brace = characters.lastIndex(of: "{"), brace + 1 <= characters.count - 1 else { return nil }
                let name = String(characters[9..<end]) + "." + String(characters[(brace + 1)..<(characters.count - 1)])
                return targetToName[name]
            },
            Pattern(expression: "(?:\(modules.joined(separator: "|")))(?:\\.js)?\"") { match in
                let module = match.hasSuffix(".js\"") ? String(match.dropLast(4)) : String(match.dropLast())
                return coreJSModuleToName[module]
            },
        ]
        return polyfills + transformPatterns
    }()

    /// The Babel transforms, each found by a string its runtime helpers
    /// carry (those are never minified).
    private static let transformPatterns: [Pattern] = [
        Pattern(expression: "Cannot call a class as a function") { _ in classesTransform },
        Pattern(expression: "Generator is already running|regeneratorRuntime") { _ in regeneratorTransform },
        Pattern(expression: "Invalid attempt to spread non-iterable instance") { _ in spreadTransform },
    ]

    /// All the patterns in one expression, each its own group, as
    /// Lighthouse's CodePatternMatcher runs them.
    private static let matcher: NSRegularExpression? = {
        let expression = patterns.map { "(\($0.expression))" }.joined(separator: "|")
        return try? NSRegularExpression(pattern: expression)
    }()

    private static func replacingFirst(_ target: String, in text: String) -> String {
        guard let range = text.range(of: target) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return String(text[..<end])
    }

    /// The names the patterns find in a script's text, each once, in the
    /// order first found.
    static func matches(in content: String) -> [String] {
        guard let matcher, !content.isEmpty else { return [] }
        let text = content as NSString
        var seen = Set<String>()
        var names: [String] = []
        matcher.enumerateMatches(in: content, options: [], range: NSRange(location: 0, length: text.length)) { result, _, _ in
            guard let result else { return }
            for group in 1..<result.numberOfRanges where result.range(at: group).location != NSNotFound {
                if patterns.indices.contains(group - 1),
                   let name = patterns[group - 1].resolve(text.substring(with: result.range)),
                   seen.insert(name).inserted {
                    names.append(name)
                }
                break
            }
        }
        return names
    }

    /// The polyfills a source map's `sources` name: a file named for a
    /// polyfill module ("…/es.array.at.js"), or a package in node_modules
    /// named for one ("node_modules/focus-visible/…").
    static func matches(inSources sources: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for source in sources {
            if source.hasSuffix(".js"), let slash = source.lastIndex(of: "/") {
                let file = source[source.index(after: slash)...].dropLast(3)
                if let name = moduleToPolyfill[String(file)], seen.insert(name).inserted { names.append(name) }
            }
            var from = source.startIndex
            while let found = source.range(of: "node_modules/", range: from..<source.endIndex) {
                let start = found.upperBound
                if let slash = source[start...].firstIndex(of: "/"),
                   let name = moduleToPolyfill[String(source[start..<slash])], seen.insert(name).inserted {
                    names.append(name)
                }
                from = start
            }
        }
        return names
    }

    /// What a script's polyfills and transforms cost: the modules the
    /// polyfills pull in, each counted once and at most Lighthouse's
    /// maximum, and each transform's estimate.
    static func estimatedWastedBytes(_ content: String, matches: [String]) -> Int {
        var modules = Set<Int>()
        for name in matches where !name.hasPrefix("@") {
            for module in Table.dependencies[name] ?? [] { modules.insert(module) }
        }
        let polyfills = min(Table.maxSize, modules.reduce(0) { total, module in
            total + (Table.moduleSizes.indices.contains(module) ? Table.moduleSizes[module] : 0)
        })
        guard !content.isEmpty else { return polyfills }
        let text = content as NSString
        var transforms = 0
        for name in matches where name.hasPrefix("@") {
            switch name {
            case classesTransform:
                transforms += 1_000 + (occurrences(of: "_classCallCheck", in: text) - 1) * "_classCallCheck()".count
            case regeneratorTransform:
                // `regeneratorRuntime.awrap` is generated for every `await`, ~80 bytes each.
                transforms += occurrences(matching: "regeneratorRuntime\\(?\\)?\\.a?wrap", in: text) * 80
            case spreadTransform:
                transforms += 1_169 + occurrences(matching: "\\.apply\\(void 0,\\s?_toConsumableArray", in: text)
                    * "_toConsumableArray()".count
            default:
                break
            }
        }
        return polyfills + transforms
    }

    private static func occurrences(of needle: String, in text: NSString) -> Int {
        var count = 0
        var location = 0
        while location < text.length {
            let found = text.range(of: needle, options: .literal,
                                   range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            count += 1
            location = found.location + max(1, found.length)
        }
        return count
    }

    private static func occurrences(matching expression: String, in text: NSString) -> Int {
        guard let regex = try? NSRegularExpression(pattern: expression) else { return 0 }
        return regex.numberOfMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length))
    }

    /// detectLegacyJavaScript: the script's text matched, then the polyfill
    /// modules its source map names that the text didn't show.
    static func detect(_ content: String, sources: [String]? = nil) -> Result {
        guard !content.isEmpty else { return Result(matches: [], estimatedByteSavings: 0) }
        var names = matches(in: content)
        if let sources {
            var seen = Set(names)
            for name in matches(inSources: sources) where seen.insert(name).inserted { names.append(name) }
        }
        // As JavaScript sorts strings: by UTF-16 code unit.
        names.sort { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        return Result(matches: names, estimatedByteSavings: estimatedWastedBytes(content, matches: names))
    }
}
