import Foundation
import WebKit

// Source maps in the Sources panel, as Chrome DevTools reads them: a
// compiled script (or stylesheet) names its map, the map names the authored
// files it came from and how each position in the compiled file lines up
// with one in them. The navigator lists the authored files beside the
// compiled ones, the debugger shows a paused frame where it is in them, and
// a breakpoint set in one goes where its line landed in the compiled file.

/// A Source Map v3 (sourcemaps.info/spec.html): `sources` resolved against
/// `sourceRoot` and the map's own address, `sourcesContent`, `names` and the
/// base64 VLQ `mappings`; an index map's `sections` are flattened into one.
struct DeveloperSourceMap: Equatable {
    /// One segment of `mappings`. Lines and columns are 0-based, as the
    /// protocol and the spec count them.
    struct Mapping: Equatable {
        var generatedLine: Int
        var generatedColumn: Int
        /// Index into `sources`; nil for a segment that maps to nothing.
        var source: Int?
        var originalLine = 0
        var originalColumn = 0
        var name: Int?
    }

    /// Where a compiled position came from.
    struct Original: Equatable {
        let url: String
        let line: Int
        let column: Int
        let name: String?
    }

    /// A position in the compiled file.
    struct Generated: Equatable, Hashable {
        let line: Int
        let column: Int
    }

    enum ParseError: LocalizedError {
        case notJSON
        case unsupportedVersion
        case badMappings

        var errorDescription: String? {
            switch self {
            case .notJSON: return "The source map isn’t JSON."
            case .unsupportedVersion: return "Only version 3 source maps are supported."
            case .badMappings: return "The source map’s mappings couldn’t be read."
            }
        }
    }

    private(set) var sources: [String] = []
    private(set) var sourcesContent: [String?] = []
    private(set) var names: [String] = []
    /// Indices into `sources` of the map's ignore list: known third-party
    /// code, which Chrome adds to the debugger's ignore list.
    private(set) var ignoredSources = Set<Int>()
    /// Ordered by generated line, then column.
    private(set) var mappings: [Mapping] = []
    /// Indices into `mappings`, ordered by source, original line and column.
    private var reverse: [Int] = []

    /// `mapURL` is where the map was read from (nil for a data: URL), which
    /// its relative `sources` resolve against; else the compiled file's.
    init(text: String, mapURL: String?, scriptURL: String?) throws {
        guard let json = Self.json(text) else { throw ParseError.notJSON }
        try self.init(json: json, base: mapURL ?? scriptURL)
    }

    /// A map's text as JSON, past Chrome's XSSI guard, )]}' on its own
    /// line, that a map may start with.
    static func json(_ text: String) -> [String: Any]? {
        var body = Substring(text)
        if body.hasPrefix(")]}") { body = body.drop { $0 != "\n" } }
        return body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    init(json: [String: Any], base: String?) throws {
        try add(json, base: base, line: 0, column: 0, depth: 0)
        // Stable: segments out of order on a line keep their order among equals.
        mappings = mappings.enumerated().sorted {
            ($0.element.generatedLine, $0.element.generatedColumn, $0.offset)
                < ($1.element.generatedLine, $1.element.generatedColumn, $1.offset)
        }.map(\.element)
        let all = mappings
        reverse = all.indices.filter { all[$0].source != nil }.sorted {
            let left = all[$0], right = all[$1]
            return (left.source!, left.originalLine, left.originalColumn, left.generatedLine, left.generatedColumn)
                < (right.source!, right.originalLine, right.originalColumn, right.generatedLine, right.generatedColumn)
        }
    }

    private mutating func add(_ json: [String: Any], base: String?, line: Int, column: Int, depth: Int) throws {
        if let version = json["version"] as? Int, version != 3 { throw ParseError.unsupportedVersion }
        if let sections = json["sections"] as? [[String: Any]] {
            // An index map: each section a map of its own, placed at an
            // offset in the compiled file. Sections by url are not fetched
            // (Chrome doesn't either).
            guard depth < 4 else { return }
            for section in sections {
                guard let map = section["map"] as? [String: Any] else { continue }
                let offset = section["offset"] as? [String: Any] ?? [:]
                try add(map, base: base, line: line + (offset["line"] as? Int ?? 0),
                        column: (offset["line"] as? Int ?? 0) == 0 ? column + (offset["column"] as? Int ?? 0)
                                                                   : offset["column"] as? Int ?? 0,
                        depth: depth + 1)
            }
            return
        }
        let root = json["sourceRoot"] as? String
        let listed = json["sources"] as? [Any] ?? []
        let content = json["sourcesContent"] as? [Any] ?? []
        // Sources already named by an earlier section keep their index.
        var indices: [Int] = []
        for (index, item) in listed.enumerated() {
            let url = DeveloperSourceMapURL.source(item as? String ?? "", root: root, base: base)
            let text = content.indices.contains(index) ? content[index] as? String : nil
            if let existing = sources.firstIndex(of: url) {
                if sourcesContent[existing] == nil { sourcesContent[existing] = text }
                indices.append(existing)
            } else {
                indices.append(sources.count)
                sources.append(url)
                sourcesContent.append(text)
            }
        }
        // The sources the map marks as third-party (`ignoreList`, or
        // Chrome's older `x_google_ignoreList`), by index into `sources`.
        let ignoreList = (json["ignoreList"] ?? json["x_google_ignoreList"]) as? [Any] ?? []
        for item in ignoreList {
            guard let index = (item as? NSNumber)?.intValue, indices.indices.contains(index) else { continue }
            ignoredSources.insert(indices[index])
        }
        let nameOffset = names.count
        names += (json["names"] as? [Any] ?? []).map { $0 as? String ?? "" }
        guard let text = json["mappings"] as? String else { return }
        guard let decoded = Self.decodeMappings(text) else { throw ParseError.badMappings }
        for var mapping in decoded {
            if let source = mapping.source {
                guard indices.indices.contains(source) else { continue }
                mapping.source = indices[source]
            }
            if let name = mapping.name {
                mapping.name = name >= 0 && nameOffset + name < names.count ? nameOffset + name : nil
            }
            if mapping.generatedLine == 0 { mapping.generatedColumn += column }
            mapping.generatedLine += line
            mappings.append(mapping)
        }
    }

    // MARK: VLQ

    private static let digits: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(byte)] = Int8(index)
        }
        return table
    }()

    /// The numbers one base64 VLQ segment holds, or nil if it is not one.
    static func decodeVLQ(_ text: String) -> [Int]? {
        var values: [Int] = []
        var value = 0
        var shift = 0
        for byte in text.utf8 {
            let digit = Int(digits[Int(byte)])
            guard digit >= 0, shift <= 55 else { return nil }
            value += (digit & 31) << shift
            if digit & 32 != 0 {
                shift += 5
                continue
            }
            values.append(value & 1 == 1 ? -(value >> 1) : value >> 1)
            value = 0
            shift = 0
        }
        return shift == 0 ? values : nil
    }

    /// `mappings` into segments with absolute positions: the generated
    /// column restarts each line, the other fields run on from the last.
    static func decodeMappings(_ text: String) -> [Mapping]? {
        var result: [Mapping] = []
        var line = 0, column = 0, source = 0, originalLine = 0, originalColumn = 0, name = 0
        var fields: [Int] = []
        fields.reserveCapacity(5)
        var value = 0
        var shift = 0

        func flush() -> Bool {
            guard shift == 0 else { return false }
            switch fields.count {
            case 0: return true
            case 1:
                column += fields[0]
                result.append(Mapping(generatedLine: line, generatedColumn: column))
            case 4, 5:
                column += fields[0]
                source += fields[1]
                originalLine += fields[2]
                originalColumn += fields[3]
                var mapping = Mapping(generatedLine: line, generatedColumn: column, source: source,
                                      originalLine: originalLine, originalColumn: originalColumn)
                if fields.count == 5 {
                    name += fields[4]
                    mapping.name = name
                }
                if source >= 0, originalLine >= 0, originalColumn >= 0, column >= 0 { result.append(mapping) }
            default:
                // Two or three fields: not a segment the spec has; skipped,
                // as Chrome skips it, rather than losing the whole map.
                break
            }
            fields.removeAll(keepingCapacity: true)
            return true
        }

        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: ","):
                guard flush() else { return nil }
            case UInt8(ascii: ";"):
                guard flush() else { return nil }
                line += 1
                column = 0
            default:
                let digit = Int(digits[Int(byte)])
                guard digit >= 0, shift <= 55 else { return nil }
                value += (digit & 31) << shift
                if digit & 32 != 0 {
                    shift += 5
                } else {
                    fields.append(value & 1 == 1 ? -(value >> 1) : value >> 1)
                    value = 0
                    shift = 0
                }
            }
        }
        return flush() ? result : nil
    }

    // MARK: Lookups

    /// The authored place of a compiled position: the last segment on the
    /// line at or before the column, or the line's first when the column is
    /// before them all (a breakpoint at a line's start).
    func original(line: Int, column: Int) -> Original? {
        var low = 0, high = mappings.count
        while low < high {
            let middle = (low + high) / 2
            let item = mappings[middle]
            if (item.generatedLine, item.generatedColumn) <= (line, column) { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        if index < 0 || mappings[index].generatedLine != line {
            guard low < mappings.count, mappings[low].generatedLine == line else { return nil }
            index = low
        }
        let item = mappings[index]
        guard let source = item.source, sources.indices.contains(source) else { return nil }
        return Original(url: sources[source], line: item.originalLine, column: item.originalColumn,
                        name: item.name.flatMap { names.indices.contains($0) ? names[$0] : nil })
    }

    /// Where an authored line went in the compiled file: one position per
    /// compiled line it landed on, at the first column there, in order. A
    /// line with no code moves on to the next one that has some, as
    /// Chrome's breakpoints do. A `column` keeps segments at or after it.
    func generated(source url: String, line: Int, column: Int? = nil) -> [Generated] {
        guard let source = sources.firstIndex(of: url) else { return [] }
        // The first segment of this source at or after the line.
        var low = 0, high = reverse.count
        while low < high {
            let middle = (low + high) / 2
            let item = mappings[reverse[middle]]
            if (item.source!, item.originalLine) < (source, line) { low = middle + 1 } else { high = middle }
        }
        guard low < reverse.count, mappings[reverse[low]].source == source else { return [] }
        let found = mappings[reverse[low]].originalLine
        var segments: [Mapping] = []
        for index in reverse[low...] {
            let item = mappings[index]
            guard item.source == source, item.originalLine == found else { break }
            segments.append(item)
        }
        if let column, found == line {
            let after = segments.filter { $0.originalColumn >= column }
            if !after.isEmpty { segments = after }
        }
        var first: [Int: Int] = [:]
        for item in segments { first[item.generatedLine] = min(first[item.generatedLine] ?? .max, item.generatedColumn) }
        return first.keys.sorted().map { Generated(line: $0, column: first[$0]!) }
    }

    /// The authored file's text, when the map carries it.
    func content(of url: String) -> String? {
        sources.firstIndex(of: url).flatMap { sourcesContent[$0] }
    }

    /// The addresses of the map's ignore list.
    var ignoredSourceURLs: [String] { ignoredSources.sorted().map { sources[$0] } }

    /// The stretches of the compiled file that came from the given sources,
    /// as WebKit's Debugger.setShouldBlackboxURL takes them: each
    /// [startLine, startColumn, endLine, endColumn], 0-based, the end where
    /// the next segment from another source (or from none) starts. `line`
    /// and `column` move them to where the file starts in its document.
    func generatedRanges(of ignored: Set<Int>, line: Int = 0, column: Int = 0) -> [[Int]] {
        var ranges: [[Int]] = []
        var start: (line: Int, column: Int)?
        func place(_ item: Mapping) -> (line: Int, column: Int) {
            (item.generatedLine + line, item.generatedLine == 0 ? item.generatedColumn + column : item.generatedColumn)
        }
        for item in mappings {
            if item.source.map(ignored.contains) == true {
                if start == nil { start = place(item) }
            } else if let from = start {
                let to = place(item)
                if (to.line, to.column) > (from.line, from.column) { ranges.append([from.line, from.column, to.line, to.column]) }
                start = nil
            }
        }
        if let from = start { ranges.append([from.line, from.column, Int(Int32.max), Int(Int32.max)]) }
        return ranges
    }
}

// MARK: - Addresses

/// The addresses around a source map: the comment that names it, data:
/// URLs, and how its `sources` resolve.
enum DeveloperSourceMapURL {
    /// The map a compiled file names in its last `//# sourceMappingURL=`
    /// (or a stylesheet's `/*# sourceMappingURL= */`), as Chrome reads it.
    static func comment(in text: String) -> String? {
        var searchEnd = text.endIndex
        while let found = text.range(of: "sourceMappingURL=", options: .backwards, range: text.startIndex..<searchEnd) {
            searchEnd = found.lowerBound
            // Preceded by //# or /*# (or the older @), and a space or so.
            var cursor = found.lowerBound
            while cursor > text.startIndex, [" ", "\t"].contains(text[text.index(before: cursor)]) {
                cursor = text.index(before: cursor)
            }
            guard let start = text.index(cursor, offsetBy: -3, limitedBy: text.startIndex),
                  ["//#", "//@", "/*#", "/*@"].contains(String(text[start..<cursor])) else { continue }
            var value = text[found.upperBound...].prefix { !$0.isWhitespace && !$0.isNewline }
            if let close = value.range(of: "*/") { value = value[..<close.lowerBound] }
            let address = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return address.isEmpty ? nil : address
        }
        return nil
    }

    /// A data: URL's text: base64 or percent-encoded.
    static func decodeData(_ url: String) -> String? {
        guard url.lowercased().hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(url[url.index(after: comma)...])
        if header.split(separator: ";").contains("base64") {
            var encoded = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        return payload.removingPercentEncoding ?? payload
    }

    /// Whether an address names its scheme (https:, webpack:, data:).
    static func hasScheme(_ address: String) -> Bool {
        guard let colon = address.firstIndex(of: ":"), colon != address.startIndex else { return false }
        let scheme = address[..<colon]
        return scheme.first!.isLetter && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+.-".contains($0) }
    }

    /// `reference` resolved against `base`, as a browser resolves a link.
    static func resolve(_ reference: String, against base: String?) -> String {
        if hasScheme(reference) { return normalize(reference) }
        guard let base, let baseURL = URL(string: base) else { return normalize(reference) }
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "#%"))
        let escaped = reference.addingPercentEncoding(withAllowedCharacters: allowed) ?? reference
        guard let url = URL(string: URL(string: reference) == nil ? escaped : reference, relativeTo: baseURL) else {
            return normalize(reference)
        }
        return normalize(url.absoluteString)
    }

    /// A map's `sources` entry as an address: after `sourceRoot`, then
    /// against the map's address, with ./ and ../ taken out.
    static func source(_ source: String, root: String?, base: String?) -> String {
        var path = source
        if let root, !root.isEmpty, !hasScheme(source) {
            if root.hasSuffix("/") && path.hasPrefix("/") { path.removeFirst() }
            path = root + (root.hasSuffix("/") || path.hasPrefix("/") ? "" : "/") + path
        }
        return resolve(path, against: base)
    }

    /// Takes ./ and ../ out of an address's path (webpack:///./src/a.ts
    /// to webpack:///src/a.ts), leaving its scheme, host and query.
    static func normalize(_ address: String) -> String {
        var prefix = ""
        var rest = Substring(address)
        if let scheme = address.range(of: "://") {
            let afterScheme = address[scheme.upperBound...]
            let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
            prefix = String(address[..<slash])
            rest = address[slash...]
        } else if hasScheme(address) {
            return address
        }
        let queryStart = rest.firstIndex { $0 == "?" || $0 == "#" } ?? rest.endIndex
        let path = rest[..<queryStart]
        let tail = rest[queryStart...]
        guard path.contains(".") else { return address }
        let absolute = path.hasPrefix("/")
        var output: [Substring] = []
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            switch part {
            case ".":
                if last { output.append("") }
            case "..":
                // An absolute path keeps its leading "" and can't climb above it.
                if output.count > (absolute ? 1 : 0), output.last != ".." { output.removeLast() }
                else if !absolute { output.append(part) }
                if last { output.append("") }
            default:
                output.append(part)
            }
        }
        return prefix + output.joined(separator: "/") + tail
    }

    /// The navigator's group for an authored file: "webpack://app" for a
    /// bundler's scheme, the host for one on the web.
    static func origin(of address: String) -> String {
        guard let scheme = address.range(of: "://") else { return "(no domain)" }
        let name = address[..<scheme.lowerBound].lowercased()
        let afterScheme = address[scheme.upperBound...]
        let host = afterScheme.prefix { $0 != "/" }
        if name == "http" || name == "https" { return host.isEmpty ? "(no domain)" : String(host) }
        return name + "://" + host
    }

    /// The folders an authored file sits in, under its origin.
    static func folders(of address: String) -> [String] {
        path(of: address).split(separator: "/").dropLast().filter { $0 != "." }.map(String.init)
    }

    /// An address's path after its scheme and host, without query or fragment.
    static func path(of address: String) -> Substring {
        var path = Substring(address)
        if let scheme = address.range(of: "://") {
            let afterScheme = address[scheme.upperBound...]
            path = afterScheme[(afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex)...]
        }
        return path.prefix { $0 != "?" && $0 != "#" }
    }
}

// MARK: - The session's maps

/// The maps of the page's scripts and stylesheets, for one DevTools
/// session: found as scripts parse (Debugger.scriptParsed's sourceMapURL),
/// from the hidden frontend for scripts already there, and from the comment
/// at the end of a file opened in the editor. Read through the same
/// protocol load WebKit's own frontend uses (Network.loadResource), else
/// fetched with the page's cookies.
@MainActor
final class DeveloperSourceMaps {
    /// Settings › Preferences › Sources, both on by default as in Chrome.
    nonisolated static let javaScriptKey = "DeveloperJavaScriptSourceMaps"
    nonisolated static let cssKey = "DeveloperCSSSourceMaps"
    static var javaScriptEnabled: Bool { UserDefaults.standard.object(forKey: javaScriptKey) as? Bool ?? true }
    static var cssEnabled: Bool { UserDefaults.standard.object(forKey: cssKey) as? Bool ?? true }

    /// The editor and navigator's type for an authored file.
    nonisolated static let authoredType = "Authored"
    /// The most a map (or an authored file fetched on its own) may be.
    nonisolated static let byteLimit = 64 << 20

    /// The navigator's and tab's symbol for an authored file.
    nonisolated static func icon(for url: String) -> String {
        let path = key(url).lowercased()
        let style = [".css", ".scss", ".sass", ".less", ".styl"].contains { path.hasSuffix($0) }
        return style ? "paintbrush" : "curlybraces"
    }

    private weak var session: DeveloperToolsSession?

    /// A map attached to a compiled file.
    struct Attached {
        let url: String
        let css: Bool
        /// Where the file starts in its document (an inline script), 0-based.
        let startLine: Int
        let startColumn: Int
        let map: DeveloperSourceMap
        /// The map as read, and where from (nil for a data: URL), for a
        /// Performance trace saved with its scripts.
        let text: String
        let mapURL: String?
    }

    private struct Script {
        let id: String
        let url: String
        let targetID: String?
        let mapURL: String
        let startLine: Int
        let startColumn: Int
    }

    /// By compiled address without query or fragment.
    private(set) var attached: [String: Attached] = [:]
    private var scripts: [String: Script] = [:]
    private var loading = Set<String>()
    private var seeded = Set<String>()
    private var fetched: [String: String] = [:]
    /// Bumped when the page navigates, so a map read for the old page is dropped.
    private var generation = 0
    /// Every load made, for the Developer resources drawer tool.
    let resourceLog = DeveloperResourceLog()

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    /// An address without query or fragment.
    nonisolated static func key(_ url: String) -> String { String(url.prefix { $0 != "?" && $0 != "#" }) }

    private func enabled(_ entry: Attached) -> Bool { entry.css ? Self.cssEnabled : Self.javaScriptEnabled }

    // MARK: Events

    func handle(_ method: String, params: [String: Any], targetID: String?) {
        switch method {
        case "Debugger.scriptParsed":
            guard let id = params["scriptId"] as? String,
                  let url = [params["url"], params["sourceURL"]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }),
                  let map = params["sourceMapURL"] as? String, !map.isEmpty else { return }
            let script = Script(id: id, url: url, targetID: targetID, mapURL: map,
                                startLine: params["startLine"] as? Int ?? 0, startColumn: params["startColumn"] as? Int ?? 0)
            scripts[(targetID ?? "") + "\n" + id] = script
            if Self.javaScriptEnabled { load(script) }
        case "Page.frameNavigated":
            guard let frame = params["frame"] as? [String: Any], (frame["parentId"] as? String)?.isEmpty != false else { return }
            // A new document: its scripts parse again and bring their maps.
            generation += 1
            attached = [:]
            scripts = [:]
            loading = []
            seeded = []
            fetched = [:]
            resourceLog.removeAll()
            changed()
        default:
            break
        }
    }

    /// A setting turned on: the maps already named load now.
    func settingsChanged() {
        if Self.javaScriptEnabled { for script in scripts.values { load(script) } }
        changed()
    }

    /// Scripts that parsed before DevTools listened: the hidden frontend
    /// keeps each one's sourceMapURL.
    func noteResources(_ resources: [SourceResource]) {
        guard Self.javaScriptEnabled, let session else { return }
        let urls = resources.filter { $0.type == "Script" && seeded.insert($0.url).inserted }.map(\.url).prefix(300)
        guard !urls.isEmpty else { return }
        let generation = generation
        Task { [weak self] in
            let found = try? await session.evaluateInFrontend("""
                const out = [];
                for (const url of urls) {
                    let scripts = [];
                    try { scripts = WI.debuggerManager?.scriptsForURL?.(url, WI.mainTarget) ?? []; } catch {}
                    for (const script of scripts.slice(0, 8)) {
                        // WI.Script keeps the comment's address as sourceMappingURL.
                        const map = script?.sourceMappingURL ?? script?.sourceMapURL;
                        if (typeof map === "string" && map && map.length <= 67108864)
                            out.push({scriptId: String(script.id), url, sourceMapURL: map,
                                      startLine: script.range?.startLine ?? 0, startColumn: script.range?.startColumn ?? 0});
                    }
                }
                return out;
                """, ["urls": Array(urls)]) as? [[String: Any]]
            guard let self, self.generation == generation else { return }
            for item in found ?? [] {
                guard let id = item["scriptId"] as? String, let url = item["url"] as? String,
                      let map = item["sourceMapURL"] as? String else { continue }
                let script = Script(id: id, url: url, targetID: nil, mapURL: map,
                                    startLine: item["startLine"] as? Int ?? 0, startColumn: item["startColumn"] as? Int ?? 0)
                if self.scripts.values.contains(where: { $0.url == url }) { continue }
                self.scripts["\n" + id] = script
                self.load(script)
            }
        }
    }

    /// A compiled file opened in the editor: the map its last comment
    /// names, for one the debugger didn't report (a stylesheet).
    func noteSource(_ resource: SourceResource, text: String) {
        let css = resource.type == "Stylesheet"
        guard css ? Self.cssEnabled : (resource.type == "Script" && Self.javaScriptEnabled),
              attached[Self.key(resource.url)] == nil, !loading.contains(Self.key(resource.url)),
              let reference = DeveloperSourceMapURL.comment(in: String(text.suffix(4_000_000))) else { return }
        load(url: resource.url, reference: reference, css: css, startLine: 0, startColumn: 0)
    }

    /// The editor's Add source map…: the map at an address the user gave
    /// (resolved against the file's), attached to the file in place of any
    /// it had. A failure is said in the status line, as for a map the
    /// file names itself.
    func addSourceMap(_ reference: String, to url: String, css: Bool) {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !url.isEmpty else { return }
        let key = Self.key(url)
        let script = scripts.values.first { Self.key($0.url) == key }
        if attached.removeValue(forKey: key) != nil { changed() }
        loading.remove(key)
        load(url: url, reference: reference, css: css, startLine: script?.startLine ?? 0,
             startColumn: script?.startColumn ?? 0)
    }

    private func load(_ script: Script) {
        if script.mapURL.lowercased() == "data:" {
            // The event stream keeps no data: URL's body; the script's own
            // last comment has it.
            let key = Self.key(script.url)
            guard attached[key] == nil, !loading.contains(key), let session else { return }
            let generation = generation
            Task { [weak self] in
                let reply = try? await session.command("Debugger.getScriptSource", ["scriptId": script.id],
                                                       targetID: script.targetID)
                guard let self, self.generation == generation,
                      let text = reply?["scriptSource"] as? String,
                      let reference = DeveloperSourceMapURL.comment(in: String(text.suffix(64 << 20))) else { return }
                self.load(url: script.url, reference: reference, css: false,
                          startLine: script.startLine, startColumn: script.startColumn)
            }
            return
        }
        load(url: script.url, reference: script.mapURL, css: false, startLine: script.startLine, startColumn: script.startColumn)
    }

    private func load(url: String, reference: String, css: Bool, startLine: Int, startColumn: Int) {
        let key = Self.key(url)
        guard attached[key] == nil, loading.insert(key).inserted else { return }
        let generation = generation
        let isData = reference.lowercased().hasPrefix("data:")
        let record = resourceLog.begin(url: isData ? reference : DeveloperSourceMapURL.resolve(reference, against: url),
                                       initiator: url, kind: .sourceMap)
        Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.loading.remove(key) } }
            var read: Int?
            do {
                let text: String
                let mapURL: String?
                if isData {
                    guard let decoded = DeveloperSourceMapURL.decodeData(reference) else {
                        self.resourceLog.fail(record, error: "The data: URL couldn’t be decoded.")
                        return
                    }
                    text = decoded
                    mapURL = nil
                } else {
                    let address = DeveloperSourceMapURL.resolve(reference, against: url)
                    text = try await self.fetch(address)
                    mapURL = address
                }
                read = text.utf8.count
                guard self.generation == generation else { return }
                let map = try DeveloperSourceMap(text: text, mapURL: mapURL, scriptURL: url)
                self.resourceLog.finish(record, bytes: text.utf8.count)
                guard !map.sources.isEmpty else { return }
                self.attached[key] = Attached(url: url, css: css, startLine: startLine, startColumn: startColumn, map: map,
                                              text: text, mapURL: mapURL)
                self.changed()
                self.session?.debugger.sourceMapLoaded(Set(map.sources))
                // Its third-party and ignore-listed sources are stepped over.
                if !css { self.session?.debugger.scriptMapLoaded(url: url, map: map, startLine: startLine, startColumn: startColumn) }
            } catch {
                self.resourceLog.fail(record, error: error.localizedDescription, bytes: read)
                // A map that won't load leaves the compiled file as it is;
                // Chrome says so in Console, Search in the status line.
                if self.generation == generation, self.session?.panel == .sources {
                    self.session?.message = "Could not load the source map for \(SourceTree.fileName(url)): \(error.localizedDescription)"
                }
            }
        }
    }

    private func changed() { session?.objectWillChange.send() }

    // MARK: Fetching

    private func fetch(_ address: String) async throws -> String {
        guard let session else { throw DeveloperDebugger.DebuggerError("DevTools closed.") }
        // Developer resources' "Load through website" off: DevTools loads
        // the file itself, without the page's network stack or cookies.
        guard resourceLog.loadThroughWebsite else { return try await download(address) }
        let siteOrigin = Tab.origin(of: session.address)
        var frame = session.resourceFrames.first?.id ?? session.resources.first?.frame
        if frame == nil {
            let tree = try? await session.command("Page.getResourceTree")
            frame = ((tree?["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
        }
        if let frame, let reply = try? await session.command("Network.loadResource", ["frameId": frame, "url": address]),
           let content = reply["content"] as? String, (reply["status"] as? Int).map({ $0 < 400 }) ?? true {
            guard content.utf8.count <= Self.byteLimit else { throw DeveloperDebugger.DebuggerError("The file is too large.") }
            return content
        }
        return try await download(address, siteOrigin: siteOrigin)
    }

    /// The fallback, or the only way with "Load through website" off: an
    /// ordinary request, with the page's cookies for that address when
    /// loading through the website.
    private func download(_ address: String, siteOrigin: String? = nil) async throws -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else {
            throw DeveloperDebugger.DebuggerError("\(address) can’t be loaded.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let siteOrigin, let web = session?.web, Tab.origin(of: web.url) == siteOrigin, Tab.origin(of: url) == siteOrigin {
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            if session?.web === web, Tab.origin(of: web.url) == siteOrigin {
                for (field, value) in DeveloperResourceLoading.headers(for: url, cookies: cookies, throughWebsite: true) {
                    request.setValue(value, forHTTPHeaderField: field)
                }
            }
        }
        try Task.checkCancellation()
        let (data, response) = try await DeveloperResourceRequest.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw DeveloperDebugger.DebuggerError("The server answered \(status).")
        }
        guard data.count <= Self.byteLimit else { throw DeveloperDebugger.DebuggerError("The file is too large.") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Lookups

    /// The authored files, as the navigator and ⌘P list them.
    var authoredResources: [SourceResource] {
        var seen = Set<String>()
        return attached.values.filter { enabled($0) }.flatMap(\.map.sources)
            .filter { seen.insert($0).inserted }
            .sorted()
            .map { SourceResource(frame: "authored", url: $0, type: Self.authoredType) }
    }

    private func entry(forGenerated url: String) -> Attached? {
        guard !url.isEmpty, let entry = attached[Self.key(url)], enabled(entry) else { return nil }
        return entry
    }

    /// The compiled files an authored one came from.
    private func entries(forOriginal url: String) -> [Attached] {
        attached.values.filter { enabled($0) && $0.map.sources.contains(url) }.sorted { $0.url < $1.url }
    }

    func isAuthored(_ url: String) -> Bool { !entries(forOriginal: url).isEmpty }

    /// Whether an authored file is a script's, so breakpoints can go in it.
    func isAuthoredScript(_ url: String) -> Bool { entries(forOriginal: url).contains { !$0.css } }

    /// A compiled position (0-based, in the document's lines) where the
    /// authored file has it.
    func original(url: String, line: Int, column: Int) -> DeveloperSourceMap.Original? {
        guard let entry = entry(forGenerated: url) else { return nil }
        let inLine = line - entry.startLine
        guard inLine >= 0 else { return nil }
        return entry.map.original(line: inLine, column: inLine == 0 ? max(0, column - entry.startColumn) : column)
    }

    /// A Console link (1-based line and column, as WebKit's messages and
    /// stack traces give them) moved to its authored file, as Chrome's
    /// links read; unchanged when the script has no map.
    func linked(url: String, line: Int?, column: Int?) -> (url: String, line: Int?) {
        guard let line, line > 0,
              let original = original(url: url, line: line - 1, column: max(0, (column ?? 1) - 1)) else { return (url, line) }
        return (original.url, original.line + 1)
    }

    /// Where an authored line (0-based) runs in a compiled script: the
    /// first place it landed. Nil when no script's map has it.
    func generated(url: String, line: Int, column: Int? = nil) -> (url: String, line: Int, column: Int)? {
        for entry in entries(forOriginal: url) where !entry.css {
            guard let first = entry.map.generated(source: url, line: line, column: column).first else { continue }
            return (entry.url, first.line + entry.startLine, first.line == 0 ? first.column + entry.startColumn : first.column)
        }
        return nil
    }

    /// The compiled file an authored one came from, for the editor's
    /// "From bundle.js" link back to it.
    func compiledFile(for url: String) -> String? { entries(forOriginal: url).first?.url }

    /// The map a script file names, for Performance's Duplicated and Legacy
    /// JavaScript insights: none for a stylesheet's, or an inline script's,
    /// whose lines aren't the file's.
    func scriptMap(for url: String) -> DeveloperSourceMap? { scriptEntry(for: url)?.map }

    func scriptEntry(for url: String) -> Attached? {
        guard let entry = entry(forGenerated: url), !entry.css, entry.startLine == 0, entry.startColumn == 0 else { return nil }
        return entry
    }

    /// How many authored files a compiled one has, for its status line.
    func authoredCount(for url: String) -> Int { entry(forGenerated: url)?.map.sources.count ?? 0 }

    /// An authored file's text: from the map's sourcesContent, else read
    /// from its address when that is on the web.
    func content(of url: String) async -> String {
        switch await text(of: url) {
        case let .success(text): return text
        case let .failure(missing): return missing.note
        }
    }

    /// An authored file's text for Sources › Search: nil when there is
    /// none to read, rather than the editor's note saying so.
    func searchableContent(of url: String) async -> String? {
        try? await text(of: url).get()
    }

    private struct Missing: Error {
        let note: String
    }

    private func text(of url: String) async -> Result<String, Missing> {
        for entry in entries(forOriginal: url) {
            if let text = entry.map.content(of: url) { return .success(text) }
        }
        if let text = fetched[url] { return .success(text) }
        guard url.lowercased().hasPrefix("http") || url.lowercased().hasPrefix("file:") else {
            return .failure(Missing(note: "// The source map has no content for \(url)."))
        }
        let generation = generation
        let record = resourceLog.begin(url: url, initiator: compiledFile(for: url) ?? "", kind: .authored)
        do {
            let text = try await fetch(url)
            resourceLog.finish(record, bytes: text.utf8.count)
            if self.generation == generation { fetched[url] = text }
            return .success(text)
        } catch {
            resourceLog.fail(record, error: error.localizedDescription)
            return .failure(Missing(note: "// Could not load \(url): \(error.localizedDescription)"))
        }
    }
}
