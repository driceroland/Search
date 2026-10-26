import Foundation

// A filter list in Adblock Plus syntax — EasyList, EasyPrivacy, the ones
// people keep for themselves — turned into the JSON a WKContentRuleList
// compiles. WebKit has no hook for asking about each request as it goes, so a
// list can only be enforced by translating it ahead of time into WebKit's own
// rules.
//
// A port of adblock-rust's content-blocking converter, the one Brave's iOS
// app uses, checked filter by filter against it on EasyList + EasyPrivacy.
// Where it differs it is on purpose:
//   - `^` in the middle of a filter is a separator, not a literal caret that
//     no address ever contains, and `^` at the end still has to end the host
//     or the token: `||ad.example.com^` doesn't block ad.example.community.
//   - `site##.ad` covers www.site too; adblock-rust's bare `site` reaches
//     only the bare host in WebKit.
//   - `site#@#.ad` lifts `.ad` on that site, rather than hiding it on every
//     other one.
//   - `$important` blocks come after the exceptions, so they win over them.
//   - `$ping`, `$websocket` and `$other` block, since WebKit has those types.
//   - `@@||site^$generichide`, `$elemhide` and `$document` turn hiding, or
//     blocking, off there.
//
// Everything WebKit has no way to say — scriptlets, redirects, procedural
// selectors, `$csp`, `$removeparam` — is dropped and counted, never guessed
// at. One rule WebKit can't parse fails the whole list, so every rule here is
// built from pieces known to compile.
//
// It reads the list as bytes, never as Characters or Substrings: a list is
// ASCII to the last line, and Swift's grapheme-aware string handling made
// the first version of this eight times slower than adblock-rust. Now it's
// about as fast.

enum FilterList {
    struct Converted {
        /// What WKContentRuleListStore.compileContentRuleList takes.
        var json: String
        var rules: Int
        /// Filters that became at least one rule.
        var used: Int
        /// Filters left out, by why.
        var dropped: [String: Int]
    }

    /// WebKit refuses a list with more rules than this.
    static let limit = 150_000

    static func convert(_ text: String) -> Converted {
        let bytes = Array(text.utf8)
        var converter = ListConverter(text: bytes)
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            converter.read(bytes[start..<end].trimmed)
            start = end + 1
        }
        return converter.finish()
    }
}

private typealias Bytes = ArraySlice<UInt8>

private extension ArraySlice where Element == UInt8 {
    var trimmed: Bytes {
        guard let first = firstIndex(where: { $0 > 0x20 }), let last = lastIndex(where: { $0 > 0x20 })
        else { return self[endIndex...] }
        return self[first...last]
    }

    var string: String { String(decoding: self, as: UTF8.self) }

    var lowercased: String {
        String(decoding: map { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") ? $0 + 32 : $0 }, as: UTF8.self)
    }

    var isASCII: Bool { allSatisfy { $0 < 0x80 } }

    func starts(_ prefix: String) -> Bool { starts(with: prefix.utf8) }

    func ends(_ suffix: String) -> Bool {
        count >= suffix.utf8.count && self[(endIndex - suffix.utf8.count)...].elementsEqual(suffix.utf8)
    }

    func has(_ needle: [UInt8]) -> Bool {
        guard let head = needle.first, needle.count <= count else { return false }
        var i = startIndex
        while i <= endIndex - needle.count {
            if self[i] == head, self[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }
}

private struct BlockRule {
    var action: String
    var selector: String? = nil
    var urlFilter = ".*"
    var ifDomain: [String]? = nil
    var unlessDomain: [String]? = nil
    var types: [String]? = nil
    var load: String? = nil

    func write(to out: inout [UInt8]) {
        out += BlockRule.openAction
        out.appendRaw(action)
        out.append(UInt8(ascii: "\""))
        if let selector {
            out += BlockRule.selectorKey
            out.appendJSON(selector)
        }
        out += BlockRule.urlFilterKey
        out.appendJSON(urlFilter)
        if let ifDomain { out += BlockRule.ifDomainKey; out.appendJSON(ifDomain) }
        if let unlessDomain { out += BlockRule.unlessDomainKey; out.appendJSON(unlessDomain) }
        if let types { out += BlockRule.typesKey; out.appendJSON(types) }
        if let load { out += BlockRule.loadKey; out.appendRaw(load); out += BlockRule.closeLoad }
        out += BlockRule.close
    }

    static let openAction = Array(#"{"action":{"type":""#.utf8)
    static let selectorKey = Array(#","selector":"#.utf8)
    static let urlFilterKey = Array(#"},"trigger":{"url-filter":"#.utf8)
    static let ifDomainKey = Array(#","if-domain":"#.utf8)
    static let unlessDomainKey = Array(#","unless-domain":"#.utf8)
    static let typesKey = Array(#","resource-type":"#.utf8)
    static let loadKey = Array(#","load-type":[""#.utf8)
    static let closeLoad = Array(#""]"#.utf8)
    static let close = Array("}}".utf8)
}

private extension Array where Element == UInt8 {
    /// A string's bytes in one copy, where `+= s.utf8` goes a byte at a time.
    mutating func appendRaw(_ s: String) {
        var s = s
        s.withUTF8 { self.append(contentsOf: $0) }
    }

    mutating func appendJSON(_ s: String) {
        append(UInt8(ascii: "\""))
        var s = s
        let plain = s.withUTF8 { buffer in
            guard !buffer.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") })
            else { return false }
            self.append(contentsOf: buffer)
            return true
        }
        if plain {
            append(UInt8(ascii: "\""))
            return
        }
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                append(UInt8(ascii: "\\"))
                append(b)
            case 0..<0x20:
                self += String(format: "\\u%04x", b).utf8
            default:
                append(b)
            }
        }
        append(UInt8(ascii: "\""))
    }

    mutating func appendJSON(_ list: [String]) {
        append(UInt8(ascii: "["))
        for (i, s) in list.enumerated() {
            if i > 0 { append(UInt8(ascii: ",")) }
            appendJSON(s)
        }
        append(UInt8(ascii: "]"))
    }
}

private struct ListConverter {
    // Network rules, held until the end so `$badfilter` can strike one out
    // wherever in the list it appears.
    // Each is written out as JSON the moment it's read: a struct and a
    // String per rule, only to be serialised at the end, was most of what
    // kept this slower than adblock-rust.
    var blocks = Written()
    var exceptions = Written()
    var important = Written()
    var badfilters: Set<String> = []
    /// The whole list, which `Written.lines` point into.
    let text: [UInt8]

    /// Rules as JSON, each followed by a comma, with where each came from.
    struct Written {
        var json: [UInt8] = []
        var spans: [(line: Range<Int>, bytes: Range<Int>)] = []

        mutating func add(from line: Range<Int>, _ write: (inout [UInt8]) -> Void) {
            let start = json.count
            write(&json)
            json.append(UInt8(ascii: ","))
            spans.append((line, start..<json.count))
        }
    }

    // Element hiding, gathered by selector so an exception can find the rule
    // it lifts.
    var everywhere: [String: Hide] = [:]
    var bySite: [String: Set<String>] = [:]
    var lifted: [String: Set<String>] = [:]
    var order: [String] = []
    var noGeneric: [String] = []
    var noHiding: [String] = []

    var used = 0
    var dropped: [String: Int] = [:]

    struct Hide {
        var plain = false
        var unless: Set<String> = []
    }

    mutating func drop(_ why: String) {
        dropped[why, default: 0] += 1
    }

    static let sharpByte = UInt8(ascii: "#"), pipe = UInt8(ascii: "|"), tilde = UInt8(ascii: "~")

    mutating func read(_ line: Bytes) {
        guard line.count > 1, let first = line.first, first != UInt8(ascii: "!") else { return }
        if first == UInt8(ascii: "["), line.starts("[Adblock") { return }
        // `# comment`
        if first == ListConverter.sharpByte, line[line.startIndex + 1] == UInt8(ascii: " ") || line[line.startIndex + 1] == UInt8(ascii: "\t") {
            return
        }

        // One pass for everything the line's kind turns on.
        var spaced = false
        var sharp: Int?
        var elementHiding = false
        var dollars = false
        var previous: UInt8 = 0
        for i in line.indices {
            let b = line[i]
            if b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") { spaced = true }
            if b == UInt8(ascii: "$"), previous == b { dollars = true }
            if b == ListConverter.sharpByte {
                if let sharp {
                    if !elementHiding, i - sharp <= 4 { elementHiding = true }
                } else {
                    sharp = i
                }
            }
            previous = b
        }

        let networkSyntax = first == ListConverter.pipe || line.starts("@@|")
        if elementHiding, let sharp, !networkSyntax {
            cosmetic(line, sharp: sharp)
        } else if spaced {
            // A selector can have spaces and a hosts file always does;
            // nothing else in a list should.
            if let field = line.split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }).first,
               ["0.0.0.0", "127.0.0.1", "::1", "::"].contains(where: { field.elementsEqual($0.utf8) }) {
                // `127.0.0.1 localhost` and the like just go.
                if let host = hostsEntry(line) { network(Array("||\(host)^".utf8)[...], from: line.indices) }
            } else {
                drop("space in a filter")
            }
        } else if dollars, !networkSyntax {
            drop("HTML filtering")
        } else {
            network(line)
        }
    }

    /// A hosts file's `0.0.0.0 tracker.example` blocks the host, the way the
    /// file would have.
    func hostsEntry(_ line: Bytes) -> String? {
        let body = line.firstIndex(of: ListConverter.sharpByte).map { line[..<$0] } ?? line
        let fields = body.split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
        guard fields.count == 2 else { return nil }
        let host = fields[1].lowercased
        guard host != "localhost", host != "0.0.0.0", host.contains("."),
              host.utf8.allSatisfy({ ListConverter.hostByte[Int($0)] || $0 == UInt8(ascii: "_") })
        else { return nil }
        return host
    }

    /// Lowercase letters, digits, `.` and `-`, indexed by byte.
    static let hostByte: [Bool] = (0..<256).map {
        let b = UInt8($0)
        return (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: ".") || b == UInt8(ascii: "-")
    }

    // MARK: Network filters

    mutating func network(_ line: Bytes, from source: Range<Int>? = nil) {
        let span = source ?? line.indices
        var pattern = line
        let exception = pattern.starts("@@")
        if exception { pattern = pattern.dropFirst(2) }

        var options = pattern[pattern.endIndex...]
        if let dollar = pattern.lastIndex(of: UInt8(ascii: "$")) {
            options = pattern[(dollar + 1)...]
            pattern = pattern[..<dollar]
        }

        var party: String?
        var wanted: UInt16 = 0
        var unwanted: UInt16 = 0
        // `$object` alone names a type WebKit lacks; that mustn't read as
        // "every type".
        var named = false
        var domains: Bytes?
        var isImportant = false
        var isBadfilter = false
        var hiding: String?
        var page = false

        var next = options.startIndex
        while !options.isEmpty {
            let end = options[next...].firstIndex(of: UInt8(ascii: ",")) ?? options.endIndex
            var option = options[next..<end]
            let negated = option.first == ListConverter.tilde
            while option.first == ListConverter.tilde { option = option.dropFirst() }
            var name = option
            var value = option[option.endIndex...]
            if let equals = option.firstIndex(of: UInt8(ascii: "=")) {
                name = option[..<equals]
                value = option[(equals + 1)...]
            }
            // Option names fit in Swift's inline small strings, so this
            // doesn't allocate.
            let key = name.string
            switch key {
            case "domain", "from":
                domains = value
            case "third-party", "3p":
                party = negated ? "first-party" : "third-party"
            case "first-party", "1p":
                party = negated ? "third-party" : "first-party"
            case "important":
                if negated { return drop("~important") }
                isImportant = true
            case "badfilter":
                if negated { return drop("~badfilter") }
                isBadfilter = true
            case "generichide", "ghide":
                if negated || !exception { return drop("$generichide outside an exception") }
                hiding = "generic"
            case "elemhide", "ehide":
                if negated || !exception { return drop("$elemhide outside an exception") }
                hiding = "all"
            case "document", "doc":
                if negated { return drop("~document") }
                named = true
                wanted |= ListConverter.documentType
                page = true
            case "all":
                if negated { return drop("~all") }
                named = true
                wanted |= ListConverter.everyType
            default:
                if let bits = ListConverter.typeBits[key] {
                    if negated {
                        unwanted |= bits
                    } else {
                        named = true
                        wanted |= bits
                    }
                } else if let why = ListConverter.unsupported[key] {
                    return drop(why)
                } else {
                    return drop("unknown option $\(key)")
                }
            }
            if end == options.endIndex { break }
            next = end + 1
        }

        if isBadfilter {
            badfilters.insert(ListConverter.key(text[span]))
            used += 1
            return
        }

        // Where it applies: `$domain=a.com|~b.a.com`.
        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        if let domains {
            for raw in domains.split(separator: ListConverter.pipe) {
                var domain = raw
                let negated = domain.first == ListConverter.tilde
                if negated { domain = domain.dropFirst() }
                // `$domain=/regex/` and `google.*` have no WebKit equivalent.
                if domain.first == UInt8(ascii: "/") || domain.ends(".*") || domain.isEmpty { continue }
                guard let normal = ListConverter.domain(domain) else { return drop("non-ASCII domain") }
                if negated { unlessDomain.append(normal) } else { ifDomain.append(normal) }
            }
            if ifDomain.isEmpty && unlessDomain.isEmpty { return drop("$domain WebKit can't express") }
            if !ifDomain.isEmpty && !unlessDomain.isEmpty { return drop("$domain both including and excluding") }
        }

        // `@@||site^$document` turns blocking off on the site's pages, not
        // just for the page's own request.
        if page, exception, ifDomain.isEmpty, unlessDomain.isEmpty, let host = ListConverter.bareHost(pattern) {
            exceptions.add(from: span, BlockRule(action: "ignore-previous-rules", ifDomain: [host]).write)
            used += 1
            return
        }

        if let hiding {
            guard let host = ListConverter.bareHost(pattern) else { return drop("$\(hiding == "all" ? "elem" : "generic")hide on more than a host") }
            if hiding == "all" { noHiding.append(host) } else { noGeneric.append(host) }
            used += 1
            return
        }

        guard let urlFilter = urlFilter(pattern) else { return }

        // Which kinds of request: none named means every one.
        var kinds: UInt16?
        if named && wanted == 0 { return drop("only types WebKit can't block") }
        if wanted != 0 || unwanted != 0 {
            let left = (wanted == 0 ? ListConverter.everyType : wanted) & ~unwanted
            if left == 0 { return drop("only types WebKit can't block") }
            kinds = left
        }

        // A frame filter with other kinds and no party is split, as
        // adblock-rust does: the frame half only for third-party frames, so
        // it never stops a page someone typed in.
        var halves: [(kinds: UInt16?, load: String?)] = [(kinds, party)]
        let document = ListConverter.documentType
        if let kinds, kinds != document, kinds & document != 0, party == nil {
            halves = [(kinds & ~document, nil), (document, "third-party")]
        }
        for half in halves {
            let write = { (out: inout [UInt8]) in
                ListConverter.writeNetwork(&out, exception: exception, urlFilter: urlFilter,
                                           ifDomain: ifDomain, unlessDomain: unlessDomain,
                                           kinds: half.kinds, load: half.load)
            }
            if exception {
                exceptions.add(from: span, write)
            } else if isImportant {
                important.add(from: span, write)
            } else {
                blocks.add(from: span, write)
            }
        }
        used += 1
    }

    /// One network rule as JSON, the same as BlockRule.write would make it.
    static func writeNetwork(_ out: inout [UInt8], exception: Bool, urlFilter: [UInt8],
                             ifDomain: [String], unlessDomain: [String], kinds: UInt16?, load: String?) {
        out += BlockRule.openAction
        out += exception ? ListConverter.ignoreBytes : ListConverter.blockBytes
        out.append(UInt8(ascii: "\""))
        out += BlockRule.urlFilterKey
        out.append(UInt8(ascii: "\""))
        for b in urlFilter {
            // A url-filter has backslashes and maybe quotes, and no control
            // characters: the line it came from had none.
            if b == UInt8(ascii: "\\") || b == UInt8(ascii: "\"") { out.append(UInt8(ascii: "\\")) }
            out.append(b)
        }
        out.append(UInt8(ascii: "\""))
        if !ifDomain.isEmpty { out += BlockRule.ifDomainKey; out.appendJSON(ifDomain) }
        if !unlessDomain.isEmpty { out += BlockRule.unlessDomainKey; out.appendJSON(unlessDomain) }
        if let kinds {
            out += BlockRule.typesKey
            out.append(UInt8(ascii: "["))
            var first = true
            for (i, name) in typeJSON.enumerated() where kinds & (1 << i) != 0 {
                if !first { out.append(UInt8(ascii: ",")) }
                out += name
                first = false
            }
            out.append(UInt8(ascii: "]"))
        }
        if let load { out += BlockRule.loadKey; out.appendRaw(load); out += BlockRule.closeLoad }
        out += BlockRule.close
    }

    static let blockBytes = Array("block".utf8)
    static let ignoreBytes = Array("ignore-previous-rules".utf8)
    static let typeJSON = typeNames.map { Array("\"\($0)\"".utf8) }

    /// The url-filter for a filter's address part, or nil after counting why
    /// there isn't one.
    mutating func urlFilter(_ raw: Bytes) -> [UInt8]? {
        let star = UInt8(ascii: "*"), caret = UInt8(ascii: "^"), pipe = ListConverter.pipe, slash = UInt8(ascii: "/")
        var pattern = raw
        var hostAnchor = false
        var leftAnchor = false
        var rightAnchor = false

        if pattern.starts("||") {
            hostAnchor = true
            pattern = pattern.dropFirst(2)
        } else if pattern.first == pipe {
            leftAnchor = true
            pattern = pattern.dropFirst()
        }
        if pattern.last == pipe {
            rightAnchor = true
            pattern = pattern.dropLast()
        }
        if pattern.count > 1, pattern.first == slash, pattern.last == slash {
            drop("regular expression")
            return nil
        }
        guard pattern.isASCII else {
            drop("non-ASCII address")
            return nil
        }

        var host: Bytes?
        var part = pattern
        var hostWildcard = false
        var hostEnds = false
        if hostAnchor {
            if let cut = pattern.firstIndex(where: { $0 == slash || $0 == caret || $0 == star }) {
                host = pattern[..<cut]
                part = pattern[cut...]
                if pattern[cut] == star { hostWildcard = true }
                if part.count == 1, part.first == caret {
                    part = part.dropFirst()
                    hostEnds = true
                } else if part.first != star {
                    leftAnchor = true
                }
            } else {
                host = pattern
                part = pattern[pattern.endIndex...]
            }
        }
        if part.last == star { part = part.dropLast() }
        if part.first == star {
            leftAnchor = false
            part = part.dropFirst()
        }

        var out: [UInt8] = []
        out.reserveCapacity(part.count + (host?.count ?? 0) + 40)
        if let host {
            if host.isEmpty {
                drop("empty host")
                return nil
            }
            out += ListConverter.hostPrefix
            ListConverter.append(host, escaping: true, to: &out)
            if hostWildcard { out += ".*".utf8 }
            if hostEnds {
                // After a host, WebKit's addresses always go on with a port
                // or a path.
                out += "[:/]".utf8
            }
        } else if leftAnchor {
            if let scheme = ListConverter.schemes.first(where: { part.elementsEqual($0.pattern) }) {
                out += scheme.filter
                part = part[part.endIndex...]
            } else {
                out.append(caret)
            }
        }

        var tail: [UInt8] = []
        if part.last == caret {
            part = part.dropLast()
            tail = rightAnchor ? ListConverter.separator + Array("?$".utf8)
                               : Array("(".utf8) + ListConverter.separator + Array(".*)?$".utf8)
        } else if rightAnchor {
            tail = Array("$".utf8)
        }
        ListConverter.append(part, escaping: false, to: &out)
        out += tail
        // No address at all, as in `$third-party,xhr,domain=site.example`:
        // every request its options pick out.
        if out.isEmpty || out == [caret] { return Array("^https?://".utf8) }
        return out
    }

    static let hostPrefix = Array(#"^[^:]+:(//)?([^/]+\.)?"#.utf8)

    /// ABP's separator: anything but a letter, digit, or `_ - . %`.
    static let separator = Array("[^a-zA-Z0-9_.%-]".utf8)

    static let schemes: [(pattern: [UInt8], filter: [UInt8])] = [
        ("http://", "^http://"), ("https://", "^https://"), ("http*://", "^https?://"), ("ws://", "^wss?://"),
    ].map { (Array($0.0.utf8), Array($0.1.utf8)) }

    /// A host or a path, lowercased, as regex: wildcards and separators
    /// become their patterns in a path, and are escaped in a host.
    static func append(_ bytes: Bytes, escaping: Bool, to out: inout [UInt8]) {
        for var b in bytes {
            if b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") { b += 32 }
            if !escaping && b == UInt8(ascii: "*") {
                out += [UInt8(ascii: "."), b]
            } else if !escaping && b == UInt8(ascii: "^") {
                out += separator
            } else {
                if special[Int(b)] { out.append(UInt8(ascii: "\\")) }
                out.append(b)
            }
        }
    }

    /// The bytes a regex needs escaped, indexed by byte.
    static let special: [Bool] = (0..<256).map { #".+?${}()|[]\^*"#.utf8.contains(UInt8($0)) }

    /// `example.com` as WebKit's domain lists want it: lowercase, ASCII, and
    /// `*` in front so subdomains count too.
    static func domain(_ raw: Bytes) -> String? {
        guard raw.isASCII else { return nil }
        return "*" + raw.lowercased
    }

    /// The host in `||host^`, and nothing else.
    static func bareHost(_ pattern: Bytes) -> String? {
        guard pattern.starts("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.last == UInt8(ascii: "^") { host = host.dropLast() }
        let lower = host.lowercased
        guard !lower.isEmpty, lower.utf8.allSatisfy({ hostByte[Int($0)] }) else { return nil }
        return "*" + lower
    }

    /// What a filter and its `$badfilter` have in common: the filter, with its
    /// options in any order. Worked out only for lists that have a badfilter.
    static func key(_ bytes: Bytes) -> String {
        let line = bytes.string
        guard let dollar = line.lastIndex(of: "$") else { return line }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        return line[..<dollar] + "$" + options.sorted().joined(separator: ",")
    }

    /// WebKit's request types, one bit each, in the order they're written out.
    static let typeNames = ["document", "fetch", "font", "image", "media", "other",
                            "ping", "raw", "script", "style-sheet", "websocket"]
    static let everyType: UInt16 = (1 << typeNames.count) - 1
    static let documentType: UInt16 = bit("document")

    static func bit(_ webkit: String) -> UInt16 { 1 << typeNames.firstIndex(of: webkit)! }

    /// ABP's request types, as WebKit's bits.
    static let typeBits: [String: UInt16] = [
        "image": bit("image"), "media": bit("media"), "script": bit("script"),
        "stylesheet": bit("style-sheet"), "css": bit("style-sheet"),
        "subdocument": documentType, "frame": documentType,
        "xmlhttprequest": bit("raw") | bit("fetch"), "xhr": bit("raw") | bit("fetch"),
        "font": bit("font"), "ping": bit("ping"), "beacon": bit("ping"),
        "websocket": bit("websocket"), "other": bit("other"),
        "object": 0, "object-subrequest": 0,
    ]

    /// Options that mean something WebKit can't do, so the filter goes.
    static let unsupported: [String: String] = [
        "redirect": "$redirect", "redirect-rule": "$redirect", "rewrite": "$redirect",
        "csp": "$csp", "removeparam": "$removeparam", "popup": "$popup",
        "popunder": "$popup",
        "match-case": "$match-case", "method": "$method", "to": "$to",
        "denyallow": "$denyallow", "header": "$header", "permissions": "$permissions",
        "specifichide": "$specifichide", "shide": "$specifichide", "tag": "$tag",
        "empty": "$redirect", "mp4": "$redirect", "inline-script": "$csp",
        "inline-font": "$csp", "cname": "$cname", "strict1p": "$strict1p",
        "strict3p": "$strict3p", "replace": "$replace", "urltransform": "$urltransform",
        "reason": "$reason", "ipaddress": "$ipaddress", "urlskip": "$urlskip",
    ]

    // MARK: Element hiding

    mutating func cosmetic(_ line: Bytes, sharp: Int) {
        guard let second = line[(sharp + 1)...].firstIndex(of: ListConverter.sharpByte) else { return drop("cosmetic syntax") }
        var between = line[(sharp + 1)..<second]
        let unhide = between.first == UInt8(ascii: "@")
        if unhide { between = between.dropFirst() }
        if between.first == UInt8(ascii: "%") { return drop("AdGuard scriptlet") }
        if between.first == UInt8(ascii: "$") { return drop("AdGuard CSS injection") }
        if between.first == UInt8(ascii: "?") { between = between.dropFirst() }
        if !between.isEmpty { return drop("cosmetic syntax") }

        let raw = line[(second + 1)...].trimmed
        if raw.isEmpty { return drop("empty selector") }
        if raw.starts("+js(") { return drop("scriptlet") }
        if raw.first == UInt8(ascii: "^") { return drop("HTML filtering") }
        if raw.contains(UInt8(ascii: "(")), ListConverter.procedural.contains(where: { raw.has($0) }) {
            return drop("procedural selector")
        }
        if !raw.isASCII { return drop("non-ASCII selector") }
        let selector = raw.string

        let locations = line[..<sharp]
        if locations.first == UInt8(ascii: "[") { return drop("cosmetic modifier") }
        var hosts: Set<String> = []
        var notHosts: Set<String> = []
        var skipped = false
        for raw in locations.split(separator: UInt8(ascii: ",")) {
            var location = raw
            let negated = location.first == ListConverter.tilde
            if negated { location = location.dropFirst() }
            if location.ends(".*") || location.first == UInt8(ascii: "/") || location.isEmpty {
                skipped = true
                continue
            }
            guard let domain = ListConverter.domain(location) else {
                skipped = true
                continue
            }
            if negated { notHosts.insert(domain) } else { hosts.insert(domain) }
        }
        if skipped && hosts.isEmpty && notHosts.isEmpty { return drop("site.* or regex location") }
        if !hosts.isEmpty && !notHosts.isEmpty { return drop("location both including and excluding") }

        if unhide {
            if hosts.isEmpty { return drop(notHosts.isEmpty ? "exception everywhere" : "~site#@#") }
            lifted[selector, default: []].formUnion(hosts)
        } else if !hosts.isEmpty {
            if bySite[selector] == nil, everywhere[selector] == nil { order.append(selector) }
            bySite[selector, default: []].formUnion(hosts)
        } else {
            if bySite[selector] == nil, everywhere[selector] == nil { order.append(selector) }
            var hide = everywhere[selector] ?? Hide()
            if notHosts.isEmpty { hide.plain = true } else { hide.unless.formUnion(notHosts) }
            everywhere[selector] = hide
        }
        used += 1
    }

    /// Extended-CSS operators only a script running in the page can do.
    static let procedural: [[UInt8]] = [
        ":has-text(", ":-abp-has(", ":-abp-contains(", ":-abp-properties(", ":contains(",
        ":xpath(", ":upward(", ":nth-ancestor(", ":matches-css", ":matches-attr(",
        ":matches-path(", ":matches-prop(", ":matches-media(", ":min-text-length(",
        ":watch-attr(", ":others(", ":if(", ":if-not(", ":remove()", ":remove-attr(",
        ":remove-class(", ":style(",
    ].map { Array($0.utf8) }

    // MARK: Putting it together

    func finish() -> FilterList.Converted {
        var generic: [BlockRule] = []
        var specific: [BlockRule] = []
        for selector in order {
            let lift = lifted[selector] ?? []
            if let hide = everywhere[selector] {
                let unless = (hide.plain ? [] : hide.unless).union(lift)
                generic.append(BlockRule(action: "css-display-none", selector: selector,
                                         unlessDomain: unless.isEmpty ? nil : unless.sorted()))
            }
            if let sites = bySite[selector] {
                let left = sites.subtracting(lift)
                if !left.isEmpty {
                    specific.append(BlockRule(action: "css-display-none", selector: selector, ifDomain: left.sorted()))
                }
            }
        }

        // Order matters to WebKit: ignore-previous-rules undoes only what came
        // before it.
        var rules = generic
        if !noGeneric.isEmpty {
            rules.append(BlockRule(action: "ignore-previous-rules", ifDomain: noGeneric))
        }
        rules += specific
        if !noHiding.isEmpty {
            rules.append(BlockRule(action: "ignore-previous-rules", ifDomain: noHiding))
        }
        var json: [UInt8] = [UInt8(ascii: "[")]
        json.reserveCapacity(rules.count * 80 + blocks.json.count + exceptions.json.count + important.json.count + 200)
        for rule in rules {
            rule.write(to: &json)
            json.append(UInt8(ascii: ","))
        }
        var count = rules.count
        for written in [blocks, exceptions, important] {
            if badfilters.isEmpty {
                json += written.json
                count += written.spans.count
            } else {
                for span in written.spans where !badfilters.contains(ListConverter.key(text[span.line])) {
                    json += written.json[span.bytes]
                    count += 1
                }
            }
        }
        if count > 0 {
            // A page someone opens is never blocked outright, as in adblock-rust:
            // a filter that matches it is almost always meant for its frames.
            BlockRule(action: "ignore-previous-rules", types: ["document"], load: "first-party").write(to: &json)
            count += 1
        }
        json.append(UInt8(ascii: "]"))
        return .init(json: String(decoding: json, as: UTF8.self), rules: count, used: used, dropped: dropped)
    }
}
