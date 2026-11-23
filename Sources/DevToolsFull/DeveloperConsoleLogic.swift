import AppKit
import Foundation

// MARK: - Error stacks

/// As in Chrome DevTools: a logged Error prints its whole stack, each
/// frame a link to its file and line. WebKit describes an Error as just
/// `Name: message` and keeps the frames in `error.stack`, written
/// `name@url:line:column`; V8's `    at name (url:line:column)` is read
/// too, for stacks a page builds or copies itself.
enum ConsoleErrorStack {
    /// The text before the frames and the frames, from an error's
    /// description and, when the description has none, its `stack`.
    static func split(description: String, stack: String?) -> (header: String, frames: [ConsoleCallFrame]) {
        let lines = description.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { isV8Frame($0) }), first > 0 {
            let frames = parse(lines[first...].joined(separator: "\n"))
            if !frames.isEmpty {
                return (lines[..<first].joined(separator: "\n"), frames)
            }
        }
        return (description, stack.map(parse) ?? [])
    }

    /// Every frame line in a stack string; lines that are not frames, such
    /// as V8's leading `Error: message`, are left out.
    static func parse(_ stack: String) -> [ConsoleCallFrame] {
        var frames = [ConsoleCallFrame]()
        for raw in stack.components(separatedBy: "\n").prefix(200) {
            if let frame = frame(raw) { frames.append(frame) }
        }
        return frames
    }

    private static func isV8Frame(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("at ")
    }

    static func frame(_ raw: String) -> ConsoleCallFrame? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        var name = ""
        var place: String
        if line.hasPrefix("at ") {
            let rest = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
                name = String(rest[..<open.lowerBound])
                place = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
            } else {
                place = rest
            }
        } else if let at = line.firstIndex(of: "@") {
            name = String(line[..<at])
            place = String(line[line.index(after: at)...])
        } else {
            place = line
        }
        if place == "[native code]" || place == "native" {
            return ConsoleCallFrame(functionName: name.isEmpty ? "[native code]" : name, url: "", lineNumber: 0, columnNumber: 0)
        }
        guard let location = location(place) else { return nil }
        // JavaScriptCore names top-level code "global code" and module
        // bodies "module code"; Chrome shows both as (anonymous).
        if name == "global code" || name == "module code" || name == "eval code" { name = "" }
        if name.hasPrefix("async ") { name = String(name.dropFirst(6)) }
        return ConsoleCallFrame(functionName: name, url: location.url, lineNumber: location.line, columnNumber: location.column)
    }

    /// `url:line:column` or `url:line`; anything else is not a frame.
    private static func location(_ place: String) -> (url: String, line: Int, column: Int)? {
        var parts = place.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        var column = 0
        if parts.count >= 3, let last = Int(parts[parts.count - 1]), let line = Int(parts[parts.count - 2]) {
            column = last
            parts.removeLast(2)
            let url = parts.joined(separator: ":")
            return url.isEmpty ? nil : (url, line, column)
        }
        guard let line = Int(parts[parts.count - 1]) else { return nil }
        parts.removeLast()
        let url = parts.joined(separator: ":")
        guard !url.isEmpty, url.contains("/") || url.contains(".") || url.hasPrefix("<") else { return nil }
        return (url, line, column)
    }
}

// MARK: - Links in messages

/// A URL found in a logged string. Chrome links every URL in a message;
/// one that ends in `:line` or `:line:column` opens in Sources.
struct ConsoleLink: Equatable {
    let range: Range<String.Index>
    let url: String
    let line: Int?
    let column: Int?
}

enum ConsoleLinks {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:https?|file|wss?|ftp|chrome-extension|safari-web-extension|webkit-masked-url)://[^\s"'<>`{}|\\^]+"#,
        options: [.caseInsensitive])

    static func find(in text: String) -> [ConsoleLink] {
        guard text.contains("://") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var links = [ConsoleLink]()
        for match in pattern.matches(in: text, range: whole).prefix(200) {
            guard let range = Range(match.range, in: text) else { continue }
            var candidate = String(text[range])
            // Trailing punctuation belongs to the sentence, and a closing
            // bracket only to the URL when it opened one.
            while let last = candidate.last, ".,;:!?'\")]}".contains(last) {
                if last == ")", candidate.filter({ $0 == "(" }).count >= candidate.filter({ $0 == ")" }).count { break }
                if last == "]", candidate.filter({ $0 == "[" }).count >= candidate.filter({ $0 == "]" }).count { break }
                candidate.removeLast()
            }
            guard candidate.count > 8 else { continue }
            let end = text.index(range.lowerBound, offsetBy: candidate.count)
            let (url, line, column) = splitLocation(candidate)
            links.append(ConsoleLink(range: range.lowerBound..<end, url: url, line: line, column: column))
        }
        return links
    }

    /// `https://a.com/app.js:12:5` is the file at line 12, column 5; a
    /// port such as `http://localhost:8080` stays part of the address.
    static func splitLocation(_ address: String) -> (url: String, line: Int?, column: Int?) {
        guard let scheme = address.range(of: "://") else { return (address, nil, nil) }
        let afterScheme = address[scheme.upperBound...]
        guard let pathStart = afterScheme.firstIndex(of: "/") else { return (address, nil, nil) }
        let path = address[pathStart...]
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let last = Int(parts[parts.count - 1]) else { return (address, nil, nil) }
        if parts.count >= 3, let line = Int(parts[parts.count - 2]) {
            let suffix = ":\(parts[parts.count - 2]):\(parts[parts.count - 1])"
            return (String(address.dropLast(suffix.count)), line, last)
        }
        let suffix = ":\(parts[parts.count - 1])"
        return (String(address.dropLast(suffix.count)), last, nil)
    }

    /// The link a console message carries for a found URL: the address
    /// itself, or a Search link that opens Sources at the line.
    static func target(_ link: ConsoleLink) -> URL? {
        if let line = link.line {
            var components = URLComponents()
            components.scheme = "search-console"
            components.host = "source"
            components.queryItems = [URLQueryItem(name: "url", value: link.url), URLQueryItem(name: "line", value: String(line)),
                                     URLQueryItem(name: "column", value: link.column.map(String.init))]
            return components.url
        }
        return URL(string: link.url)
    }

    /// The file and line of a `search-console://source` link.
    static func source(_ url: URL) -> (url: String, line: Int)? {
        guard url.scheme == "search-console", url.host() == "source",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "url" })?.value,
              let line = items.first(where: { $0.name == "line" })?.value.flatMap({ Int($0) }) else { return nil }
        return (address, line)
    }
}

// MARK: - Prompt history

/// The prompt's history: up to 300 entries, without repeating the last
/// one. Unlike Chrome's it is never written down: what was typed at a
/// page's console lasts while Search runs, and a private tab's not even
/// that long (DeveloperConsoleStore).
enum ConsoleHistory {
    static let limit = 300

    /// This run's, shared by the sessions of tabs that aren't private.
    nonisolated(unsafe) private static var kept: [String] = []

    static func load() -> [String] { kept }

    static func save(_ history: [String]) { kept = Array(history.suffix(limit)) }

    static func appending(_ expression: String, to history: [String]) -> [String] {
        let entry = String(expression.prefix(20_000))
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, history.last != entry else { return history }
        return Array((history + [entry]).suffix(limit))
    }
}

// MARK: - Scrolling

/// As in Chrome DevTools: new messages keep the list at the bottom only
/// while it is already there, or right after the prompt ran something.
enum ConsoleScrollPin {
    static let tolerance: CGFloat = 16

    static func isAtBottom(visibleMaxY: CGFloat, contentHeight: CGFloat, tolerance: CGFloat = tolerance) -> Bool {
        contentHeight - visibleMaxY <= tolerance
    }

    static func shouldFollow(pinned: Bool, ranCommand: Bool) -> Bool { pinned || ranCommand }
}

// MARK: - Find

/// One occurrence of the Find bar's text: which row, and which match in it.
struct ConsoleFindMatch: Equatable, Hashable {
    let row: String
    let occurrence: Int
}

/// As in Chrome DevTools: ⌘F searches the messages as shown, ignoring
/// case, and Return / ⇧Return step through the matches, wrapping.
enum ConsoleFind {
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var output = [Range<String.Index>]()
        var start = text.startIndex
        while start < text.endIndex, output.count < 1000,
              let found = text.range(of: query, options: [.caseInsensitive], range: start..<text.endIndex) {
            output.append(found)
            start = found.isEmpty ? text.index(after: found.lowerBound) : found.upperBound
        }
        return output
    }

    static func matches(_ rows: [(id: String, text: String)], query: String) -> [ConsoleFindMatch] {
        guard !query.isEmpty else { return [] }
        var output = [ConsoleFindMatch]()
        for row in rows {
            for index in ranges(of: query, in: row.text).indices { output.append(ConsoleFindMatch(row: row.id, occurrence: index)) }
            if output.count >= 10_000 { break }
        }
        return output
    }

    static func step(_ current: Int?, count: Int, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return backwards ? count - 1 : 0 }
        return ((backwards ? current - 1 : current + 1) % count + count) % count
    }
}

// MARK: - Property paths

/// Chrome's "Copy property path": `items[0].name`, `map["a b"]`, with the
/// internal `[[…]]` slots left out.
enum ConsolePropertyPath {
    static func format(_ names: [String]) -> String {
        var output = ""
        for name in names where !(name.hasPrefix("[[") && name.hasSuffix("]]")) {
            if let index = Int(name), index >= 0, String(index) == name {
                output += "[\(index)]"
            } else if isIdentifier(name) {
                output += output.isEmpty ? name : "." + name
            } else {
                let data = (try? JSONSerialization.data(withJSONObject: [name], options: [.withoutEscapingSlashes])) ?? Data()
                let quoted = String(data: data, encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "\"\(name)\""
                output += "[" + quoted + "]"
            }
        }
        return output
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" || first == "$" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }
}

// MARK: - Timestamps

extension ConsoleFormat {
    /// Chrome's "Show timestamps": `HH:mm:ss.SSS`, local time. WebKit
    /// stamps messages in seconds; a millisecond stamp is read too.
    static func timestamp(_ value: Double, timeZone: TimeZone = .current) -> String {
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let whole = seconds.rounded(.down)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: whole))
        let milliseconds = min(999, max(0, Int(((seconds - whole) * 1000).rounded())))
        return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, milliseconds)
    }
}

// MARK: - Execution contexts

/// A JavaScript context the Console can evaluate in, as Chrome's context
/// selector lists them: the page, its frames, and extensions' content
/// scripts (WebKit's "user" worlds).
struct ConsoleExecutionContext: Identifiable, Equatable, Hashable {
    var id: String { "\(targetID ?? "")#\(contextID)" }
    let contextID: Int
    let targetID: String?
    let name: String
    let frameName: String
    let isTop: Bool
    let isContentScript: Bool
    let depth: Int
    /// A dedicated worker: its own thread, evaluated in through its target.
    var isWorker = false
    /// The worker's script address.
    var url = ""

    init(contextID: Int, targetID: String?, name: String, frameName: String, isTop: Bool, isContentScript: Bool, depth: Int,
         isWorker: Bool = false, url: String = "") {
        self.contextID = contextID
        self.targetID = targetID
        self.name = name
        self.frameName = frameName
        self.isTop = isTop
        self.isContentScript = isContentScript
        self.depth = depth
        self.isWorker = isWorker
        self.url = url
    }

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? Int else { return nil }
        contextID = id
        targetID = raw["targetId"] as? String
        frameName = raw["frame"] as? String ?? ""
        isTop = raw["top"] as? Bool ?? false
        isContentScript = raw["contentScript"] as? Bool ?? false
        depth = raw["depth"] as? Int ?? 0
        name = raw["name"] as? String ?? ""
        isWorker = raw["worker"] as? Bool ?? false
        url = raw["url"] as? String ?? ""
    }

    /// Chrome's label: `top`, a frame by its name or address, and an
    /// extension's content script by the extension's name.
    var title: String {
        if isContentScript { return name.isEmpty ? "Content script" : name }
        if isWorker { return name.isEmpty ? "worker" : name }
        if isTop { return "top" }
        return frameName.isEmpty ? (name.isEmpty ? "iframe" : name) : frameName
    }
}

// MARK: - Logged nodes

/// What the console needs to draw one DOM node as Chrome's element tree
/// does: its kind, tag or text, attributes and how many children open.
struct ConsoleNodeSummary: Equatable, Hashable {
    var type: Int
    var name: String
    var attributes: [[String]] = []
    var text: String?
    var children = 0

    init(type: Int, name: String, attributes: [[String]] = [], text: String? = nil, children: Int = 0) {
        self.type = type
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    init?(_ raw: [String: Any]?) {
        guard let raw, let type = raw["type"] as? Int else { return nil }
        self.type = type
        name = raw["name"] as? String ?? ""
        attributes = (raw["attributes"] as? [[String]] ?? []).filter { $0.count == 2 }
        text = raw["text"] as? String
        children = raw["children"] as? Int ?? 0
    }

    var isElement: Bool { type == 1 }
}

struct ConsoleNodeTree: Equatable {
    struct Child: Equatable {
        let summary: ConsoleNodeSummary
        let object: ConsoleRemoteObject?
    }

    let summary: ConsoleNodeSummary?
    let children: [Child]

    init(summary: ConsoleNodeSummary?, children: [Child]) {
        self.summary = summary
        self.children = children
    }

    init(_ raw: [String: Any]) {
        summary = ConsoleNodeSummary(raw["summary"] as? [String: Any])
        children = (raw["children"] as? [[String: Any]] ?? []).compactMap { item in
            guard let summary = ConsoleNodeSummary(item["summary"] as? [String: Any]) else { return nil }
            return Child(summary: summary, object: (item["object"] as? [String: Any]).map(ConsoleRemoteObject.init))
        }
    }
}

/// The markup Chrome's console tree shows for a node, in pieces that are
/// coloured by kind: `<div class="a">…</div>`, `"text"`, `<!--note-->`.
enum ConsoleNodeMarkup {
    enum Kind: Equatable { case punctuation, tag, attribute, value, text, comment }

    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                            "param", "source", "track", "wbr"]

    static func opening(_ node: ConsoleNodeSummary, open: Bool) -> [(String, Kind)] {
        switch node.type {
        case 1:
            var pieces: [(String, Kind)] = [("<", .punctuation), (node.name, .tag)]
            for pair in node.attributes {
                pieces.append((" ", .punctuation))
                pieces.append((pair[0], .attribute))
                if !pair[1].isEmpty {
                    pieces += [("=\"", .punctuation), (pair[1], .value), ("\"", .punctuation)]
                }
            }
            pieces.append((">", .punctuation))
            if voidElements.contains(node.name.lowercased()) { return pieces }
            if node.children == 0 {
                if let text = node.text { pieces.append((text, .text)) }
                pieces += closing(node)
            } else if !open {
                pieces.append(("…", .punctuation))
                pieces += closing(node)
            }
            return pieces
        case 3: return [("\"", .punctuation), (node.text ?? "", .text), ("\"", .punctuation)]
        case 8: return [("<!--" + (node.text ?? "") + "-->", .comment)]
        case 10: return [("<!DOCTYPE " + node.name + ">", .comment)]
        default: return [(node.name, .tag)]
        }
    }

    static func closing(_ node: ConsoleNodeSummary) -> [(String, Kind)] {
        guard node.isElement, !voidElements.contains(node.name.lowercased()) else { return [] }
        return [("</", .punctuation), (node.name, .tag), (">", .punctuation)]
    }

    static func text(_ pieces: [(String, Kind)]) -> String { pieces.map(\.0).joined() }
}
