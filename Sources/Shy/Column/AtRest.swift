import Foundation

/// Where the page on the tab you're on comes from, said at rest — without
/// clicking the tab to see its address (Settings › Tabs › Show the address on
/// the tab you're on).
///
/// The site is its registrable domain, the part nobody else can register
/// under: "github.com" in gist.github.com, "bbc.co.uk" in www.bbc.co.uk. That
/// part is what a look-alike can't fake, so it is drawn in ink and never cut;
/// the subdomain before it is dim and gives way first. A name in another
/// alphabet is shown as itself only when it can't pass for a Latin one, as
/// Safari does; otherwise as the punycode it really is (xn--80ak6aa92e.com,
/// not "аррӏе.com" in Cyrillic letters). A page over plain http says it isn't
/// secure, and a file on this Mac is named by its file name.
struct AtRest: Equatable {
    enum Kind: Equatable {
        case secure
        /// Plain http, somewhere other than this Mac.
        case notSecure
        /// A file on this Mac: `name` is its file name.
        case file
        /// Not a website at all: an extension's page, data:, blob:.
        case other
    }

    let kind: Kind
    /// Before the registrable domain, dim: "gist." Never "www.".
    let lead: String
    /// The registrable domain; a file's name; what the page is.
    let name: String
    /// A port that isn't the scheme's own, dim: ":3000".
    let tail: String

    /// Worth saying even with the setting off: a page over plain http, or a
    /// name shown as the punycode it is because it could pass for another
    /// (Hosts.display). With Settings › Tabs › Show the address on the tab
    /// you're on, every page is said; without it, only these.
    var warns: Bool {
        kind == .notSecure || ((kind == .secure) && (lead + name).split(separator: ".").contains { $0.hasPrefix("xn--") })
    }

    /// What the tab you're on says at rest: everything with the setting on,
    /// only a warning with it off.
    static func said(_ url: URL?, always: Bool) -> AtRest? {
        guard let rest = of(url), always || rest.warns else { return nil }
        return rest
    }

    /// All of it as one line, as read aloud and as the bench reports it.
    var text: String {
        (kind == .notSecure ? "Not secure — " : "") + lead + name + tail
    }

    /// The page on screen (`Tab.pageAddress`), at rest. Nil for a tab with
    /// nowhere to say: a new tab, about:blank.
    static func of(_ url: URL?) -> AtRest? {
        guard let url else { return nil }
        let key = url.absoluteString as NSString
        if let kept = cache.object(forKey: key) { return kept.value }
        let made = make(url)
        cache.setObject(Box(made), forKey: key)
        return made
    }

    private final class Box {
        let value: AtRest?
        init(_ value: AtRest?) { self.value = value }
    }
    /// Worked out once per address: a row asks on every update it gets.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 256
        return cache
    }()

    static func make(_ url: URL, isSuffix: ((String) -> Bool)? = AtRest.systemSuffix) -> AtRest? {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https":
            guard let raw = url.host(percentEncoded: false), !raw.isEmpty else { return nil }
            let ascii = Hosts.ascii(raw)
            let ip = Hosts.isAddress(ascii)
            let bare = !ip && ascii.hasPrefix("www.") && ascii.split(separator: ".").count > 2 ? String(ascii.dropFirst(4)) : ascii
            let domain = ip ? bare : Registrable.domain(of: bare, isSuffix: isSuffix)
            let shown = Hosts.display(bare)
            // The same labels, as shown: the registrable part is the last
            // few, whatever alphabet they are drawn in.
            let count = domain.split(separator: ".").count
            let labels = shown.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let name: String
            let lead: String
            if ip {
                name = ascii.contains(":") ? "[" + ascii + "]" : ascii
                lead = ""
            } else if labels.count > count {
                name = labels.suffix(count).joined(separator: ".")
                lead = labels.dropLast(count).joined(separator: ".") + "."
            } else {
                name = shown
                lead = ""
            }
            let standard = scheme == "https" ? 443 : 80
            let tail = url.port.map { $0 == standard ? "" : ":\($0)" } ?? ""
            let local = Hosts.isLoopback(ascii)
            return AtRest(kind: scheme == "https" || local ? .secure : .notSecure, lead: lead, name: name, tail: tail)
        case "file":
            let file = url.lastPathComponent
            return AtRest(kind: .file, lead: "", name: file.isEmpty || file == "/" ? "File" : file, tail: "")
        case "about", "":
            return nil
        case "chrome-extension", "webkit-extension":
            return AtRest(kind: .other, lead: "", name: "Extension page", tail: "")
        default:
            return AtRest(kind: .other, lead: "", name: "Not a website", tail: "")
        }
    }

    /// The Mac's own list of public suffixes (see Passkeys.publicSuffix).
    static let systemSuffix: ((String) -> Bool)? = Passkeys.publicSuffix.map { test in { test($0 as CFString) } }
}

/// Host names as they are, and as they are safe to show.
enum Hosts {
    /// An IPv4 or IPv6 address rather than a name.
    static func isAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// This Mac, where plain http is the rule rather than a risk.
    static func isLoopback(_ host: String) -> Bool {
        // 127.x written as an address only: 127.0.0.1.example.com is a
        // website like any other (see Dialogs.isLoopback).
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || (isAddress(host) && host.hasPrefix("127."))
    }

    /// The host in ASCII: each label written in another alphabet turned to
    /// its punycode, as WebKit hands it on. Lower case, no trailing dot.
    static func ascii(_ host: String) -> String {
        let trimmed = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.allSatisfy(\.isASCII) else { return trimmed }
        return trimmed.precomposedStringWithCompatibilityMapping
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { label in
                let label = String(label)
                guard !label.allSatisfy(\.isASCII), let encoded = Punycode.encode(label) else { return label }
                return "xn--" + encoded
            }
            .joined(separator: ".")
    }

    /// The host as shown: in its own alphabet when every label is safe to
    /// read that way, otherwise all of it as punycode. One unsafe label is
    /// enough to show the lot as it is.
    static func display(_ ascii: String) -> String {
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.contains(where: { $0.hasPrefix("xn--") }) else { return ascii }
        var shown: [String] = []
        for label in labels {
            guard label.hasPrefix("xn--") else { shown.append(label); continue }
            guard let decoded = Punycode.decode(String(label.dropFirst(4))), !decoded.isEmpty,
                  // A label that comes back plain ASCII was never a real
                  // international one: it stays as it was written.
                  !decoded.allSatisfy(\.isASCII),
                  safe(decoded)
            else { return ascii }
            shown.append(decoded)
        }
        return shown.joined(separator: ".")
    }

    private enum Script: Hashable { case latin, latinExtra, cjk, hangul, arabic, hebrew, thai, devanagari }

    /// A label is safe to show in its own letters when every one of them is
    /// from a script that can't pass for Latin — Chinese, Japanese, Korean,
    /// Arabic, Hebrew, Thai, Devanagari — or Latin with its common accents,
    /// and the scripts aren't mixed beyond Latin with Chinese, Japanese or
    /// Korean. Cyrillic, Greek, Armenian, Cherokee, IPA and the Latin
    /// letters with dots below are all left out: whole words of them can be
    /// made to look like Latin ones.
    static func safe(_ label: String) -> Bool {
        var scripts = Set<Script>()
        var strokes = false
        for scalar in label.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x30...0x39, 0x2D: continue                  // digits, hyphen
            case 0x61...0x7A: scripts.insert(.latin)          // a–z
            // Latin letters that pass for plain ones are left out, as Chrome
            // leaves them out: dotless ı, kra ĸ (k), thorn þ (p), eth ð (d),
            // ŀ, ŉ and long ſ.
            case 0xF0, 0xFE, 0x131, 0x138, 0x13F, 0x140, 0x149, 0x17F: return false
            case 0xDF...0xF6, 0xF8...0xFF, 0x100...0x17F: scripts.insert(.latinExtra)
            // Kana and ideographs that are a stroke, a slash or a ring, which
            // beside Latin letters read as -, /, l or o (ー ノ 一 丨 丶 ヽ ヾ).
            case 0x30FC, 0x30CE, 0x4E00, 0x4E28, 0x4E36, 0x30FD, 0x30FE:
                strokes = true
                scripts.insert(.cjk)
            case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF:
                scripts.insert(.cjk)
            // Hangul syllables only: a lone jamo such as ᅵ reads as l or I.
            case 0xAC00...0xD7A3: scripts.insert(.hangul)
            case 0x0620...0x064A, 0x0660...0x0669, 0x0671...0x06D3, 0x06F0...0x06FF: scripts.insert(.arabic)
            case 0x05D0...0x05EA: scripts.insert(.hebrew)
            case 0x0E01...0x0E3A, 0x0E40...0x0E4E, 0x0E50...0x0E59: scripts.insert(.thai)
            case 0x0901...0x0939, 0x093C...0x094D, 0x0950, 0x0966...0x096F: scripts.insert(.devanagari)
            default: return false
            }
        }
        let latin = scripts.intersection([.latin, .latinExtra])
        let others = scripts.subtracting([.latin, .latinExtra])
        if others.count > 1 { return false }
        if strokes && !latin.isEmpty { return false }
        if others.isEmpty { return true }
        // Latin beside one other script: only beside the ones written with
        // Latin letters in everyday names (as in 東京tokyo.jp).
        return latin.isEmpty || others == [.cjk] || others == [.hangul]
    }
}

/// RFC 3492, for the labels of internationalised names (xn--…).
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    private static func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c) - 22         // 0–9 → 26–35
        case 0x41...0x5A: return Int(c) - 0x41       // A–Z
        case 0x61...0x7A: return Int(c) - 0x61       // a–z
        default: return nil
        }
    }

    private static func character(_ d: Int) -> Character {
        Character(UnicodeScalar(UInt8(d < 26 ? d + 0x61 : d + 22)))
    }

    static func decode(_ input: String) -> String? {
        let bytes = Array(input.utf8)
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        var output: [UInt32] = []
        var start = 0
        if let dash = bytes.lastIndex(of: 0x2D) {
            output = bytes[..<dash].map(UInt32.init)
            start = dash + 1
        }
        var n = initialN, i = 0, bias = initialBias
        var index = start
        while index < bytes.count {
            let old = i
            var w = 1
            var k = base
            while true {
                guard index < bytes.count, let d = digit(bytes[index]) else { return nil }
                index += 1
                let (product, o1) = d.multipliedReportingOverflow(by: w)
                let (sum, o2) = i.addingReportingOverflow(product)
                guard !o1, !o2, sum < Int(Int32.max) else { return nil }
                i = sum
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if d < t { break }
                let (next, o3) = w.multipliedReportingOverflow(by: base - t)
                guard !o3 else { return nil }
                w = next
                k += base
            }
            let length = output.count + 1
            bias = adapt(i - old, length, old == 0)
            n += i / length
            guard n < 0x110000 else { return nil }
            i %= length
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var text = ""
        for value in output {
            guard let scalar = UnicodeScalar(value) else { return nil }
            text.unicodeScalars.append(scalar)
        }
        return text
    }

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map(\.value)
        var output = scalars.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) }
        let basic = output.count
        var handled = basic
        if basic > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ Int($0) >= n }).min().map(Int.init) else { return nil }
            let (step, o1) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !o1 else { return nil }
            delta += step
            n = m
            for value in scalars {
                if Int(value) < n { delta += 1 }
                if Int(value) == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                        if q < t { break }
                        output.append(character(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(character(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }
}
