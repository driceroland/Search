import AppKit
import SwiftUI

/// A JSON value as JSON.parse leaves it, with each object's keys in the
/// order a JavaScript object keeps them: array-index keys first, in
/// numeric order, then the rest as they came, a repeated key keeping its
/// first place and its last value. The Preview and Payload trees, and
/// pretty-printed payloads, read JSON through this, never through
/// JSONSerialization, whose dictionaries lose the order.
enum DeveloperJSONValue: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        let key: String
        let value: DeveloperJSONValue
    }

    case object([Member])
    case array([DeveloperJSONValue])
    case string(String)
    /// The number as written; `display` gives what JavaScript would print.
    case number(String)
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self {
        case .object, .array: true
        default: false
        }
    }

    // MARK: Parsing

    static func parse(_ text: String?) -> DeveloperJSONValue? {
        guard let text else { return nil }
        var parser = Parser(bytes: Array(text.utf8))
        return parser.document()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // A byte-order mark, as JSON.parse of a decoded body never sees.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        mutating func document() -> DeveloperJSONValue? {
            skipSpace()
            guard let value = value() else { return nil }
            skipSpace()
            return index == bytes.count ? value : nil
        }

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func value() -> DeveloperJSONValue? {
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map(DeveloperJSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            default: return nil
            }
        }

        mutating func literal(_ word: StaticString, _ value: DeveloperJSONValue) -> DeveloperJSONValue? {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { return nil }
            let matches = word.withUTF8Buffer { buffer in
                (0..<count).allSatisfy { bytes[index + $0] == buffer[$0] }
            }
            guard matches else { return nil }
            index += count
            return value
        }

        mutating func object() -> DeveloperJSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 1_000 else { return nil }
            index += 1
            var members: [Member] = []
            var positions: [String: Int] = [:]
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object([])
            }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipSpace()
                guard let value = value() else { return nil }
                if let at = positions[key] {
                    members[at] = Member(key: key, value: value)
                } else {
                    positions[key] = members.count
                    members.append(Member(key: key, value: value))
                }
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                return nil
            }
            return .object(DeveloperJSONValue.javaScriptOrder(members))
        }

        mutating func array() -> DeveloperJSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 1_000 else { return nil }
            index += 1
            var items: [DeveloperJSONValue] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array([])
            }
            while true {
                skipSpace()
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                return nil
            }
            return .array(items)
        }

        mutating func string() -> String? {
            index += 1
            let start = index
            // Most strings have no escapes: one slice, decoded once.
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    defer { index += 1 }
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") { break }
                if byte < 0x20 { return nil }
                index += 1
            }
            var buffer = Array(bytes[start..<index])
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: buffer, as: UTF8.self)
                }
                if byte < 0x20 { return nil }
                guard byte == UInt8(ascii: "\\") else {
                    buffer.append(byte)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    guard var unit = hex4() else { return nil }
                    var scalar: Unicode.Scalar?
                    if (0xD800...0xDBFF).contains(unit), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                            scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                        } else {
                            index = save
                        }
                    }
                    if scalar == nil {
                        if (0xD800...0xDFFF).contains(unit) { unit = 0xFFFD }
                        scalar = Unicode.Scalar(unit)
                    }
                    buffer.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
                default:
                    return nil
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 {
                let byte = bytes[index + offset]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: return nil
                }
                value = value * 16 + digit
            }
            index += 4
            return value
        }

        mutating func number() -> DeveloperJSONValue? {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                return nil
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { return nil }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { return nil }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }

    /// A JavaScript object's own-key order: canonical array indices
    /// (0 to 2³² − 2) ascending, then the other keys as inserted.
    static func javaScriptOrder(_ members: [Member]) -> [Member] {
        let indexed = members.compactMap { member in arrayIndex(member.key).map { ($0, member) } }
        guard !indexed.isEmpty else { return members }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1) + members.filter { arrayIndex($0.key) == nil }
    }

    static func arrayIndex(_ key: String) -> UInt32? {
        guard let first = key.utf8.first, key.utf8.count <= 10,
              key.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              first != UInt8(ascii: "0") || key == "0",
              let value = UInt64(key), value < 4_294_967_295 else { return nil }
        return UInt32(value)
    }

    // MARK: Writing

    /// JSON.stringify(value, null, 2).
    func pretty(indent: Int = 0) -> String {
        switch self {
        case .string(let text): return DeveloperJSON.quote(text)
        case .number(let raw): return Self.display(number: raw)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let inner = String(repeating: " ", count: indent + 2)
            return "[\n" + items.map { inner + $0.pretty(indent: indent + 2) }.joined(separator: ",\n")
                + "\n" + String(repeating: " ", count: indent) + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let inner = String(repeating: " ", count: indent + 2)
            return "{\n" + members.map { inner + DeveloperJSON.quote($0.key) + ": " + $0.value.pretty(indent: indent + 2) }
                .joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent) + "}"
        }
    }

    /// A number as JavaScript's Number#toString writes the double it
    /// parses to: `1.0` is `1`, `1e3` is `1000`, `1e-7` stays `1e-7`.
    static func display(number raw: String) -> String {
        guard let value = Double(raw), value.isFinite else { return raw }
        if value == 0 { return "0" }
        // Swift's description holds the shortest digits that round-trip,
        // as JavaScript picks them; only the layout differs.
        var text = String(value.magnitude)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let point = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        var digits = Array(text.replacingOccurrences(of: ".", with: ""))
        var position = point + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            position -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count, n = position
        let sign = value < 0 ? "-" : ""
        let string = String(digits)
        if k <= n && n <= 21 { return sign + string + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 { return sign + String(digits[..<n]) + "." + String(digits[n...]) }
        if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + string }
        let power = n - 1
        let mantissa = k == 1 ? string : String(digits[0]) + "." + String(digits[1...])
        return sign + mantissa + "e" + (power >= 0 ? "+" : "-") + String(abs(power))
    }

    // MARK: Previews

    /// The one-line text Chrome's LocalJSONObject gives a value: strings
    /// in double quotes with ↵ for new lines, objects and arrays listed
    /// until the preview passes 100 characters, then `,…`.
    var summary: String { summary(limit: .max) ?? "" }

    /// The summary, or nil once it would pass `limit` UTF-16 units, so a
    /// large value is never written out just to be cut.
    func summary(limit: Int) -> String? {
        switch self {
        case .string(let text):
            guard text.utf16.count + 2 <= limit else { return nil }
            return "\"" + text.replacingOccurrences(of: "\n", with: "\u{21B5}") + "\""
        case .number(let raw):
            let text = Self.display(number: raw)
            return text.utf16.count <= limit ? text : nil
        case .bool(let flag): return (flag ? "true" : "false").utf16.count <= limit ? (flag ? "true" : "false") : nil
        case .null: return limit >= 4 ? "null" : nil
        case .array(let items):
            return Self.concatenate("[", "]", count: items.count, limit: limit) { index, room in items[index].summary(limit: room) }
        case .object(let members):
            return Self.concatenate("{", "}", count: members.count, limit: limit) { index, room in
                let name = Self.displayKey(members[index].key) + ": "
                guard room - name.utf16.count >= 0,
                      let value = members[index].value.summary(limit: room - name.utf16.count) else { return nil }
                return name + value
            }
        }
    }

    private static func concatenate(_ prefix: String, _ suffix: String, count: Int, limit: Int,
                                     item: (Int, Int) -> String?) -> String? {
        let previewCharacters = 100
        var buffer = prefix
        var length = prefix.utf16.count
        for index in 0..<count {
            // An item fits while the buffer stays within 100 characters.
            let room = previewCharacters - length
            guard room >= 0, let text = item(index, room) else {
                buffer += ",\u{2026}"
                length += 2
                break
            }
            if index > 0 {
                buffer += ", "
                length += 2
            }
            buffer += text
            length += text.utf16.count
            if length + suffix.utf16.count > limit { return nil }
        }
        buffer += suffix
        length += suffix.utf16.count
        return length <= limit ? buffer : nil
    }

    /// A key as Chrome writes it in a tree or preview: quoted when it is
    /// empty, starts or ends with white space, or holds a new line.
    static func displayKey(_ key: String) -> String {
        let edges = key.first.map(\.isWhitespace) == true || key.last.map(\.isWhitespace) == true
        guard key.isEmpty || edges || key.contains("\n") else { return key }
        return "\"" + key.replacingOccurrences(of: "\n", with: "\u{21B5}") + "\""
    }
}

// MARK: Tree model

/// The rows of Chrome's JSON object tree: the root open, everything else
/// shut until asked, arrays of more than 100 items in `[0 … 99]` ranges.
enum DeveloperJSONOutline {
    static let rootID = "$"

    enum Segment: Equatable {
        case key(String)
        case index(Int)
    }

    enum Content {
        case value(DeveloperJSONValue)
        /// Items lower...upper of an array too long to list whole.
        case range([DeveloperJSONValue], lower: Int, upper: Int)
    }

    struct Row: Identifiable {
        let id: String
        let depth: Int
        /// The key or index as the tree shows it; nil for the root and ranges.
        let name: String?
        let path: [Segment]
        let content: Content

        var expandable: Bool {
            switch content {
            case .range:
                return true
            case .value(.object(let members)):
                return !members.isEmpty
            case .value(.array(let items)):
                return !items.isEmpty
            case .value:
                return false
            }
        }

        var isString: Bool {
            if case .value(.string) = content { return true }
            return false
        }

        var value: DeveloperJSONValue? {
            if case .value(let value) = content { return value }
            return nil
        }
    }

    static func root(_ value: DeveloperJSONValue) -> Row {
        Row(id: rootID, depth: 0, name: nil, path: [], content: .value(value))
    }

    /// Chrome's ArrayGroupingTreeElement buckets: ranges of 100ⁿ, the
    /// largest that leaves at most 100 of them.
    static func ranges(lower: Int, upper: Int) -> [(lower: Int, upper: Int)]? {
        let count = upper - lower + 1
        guard count > 100 else { return nil }
        var size = 1
        while size * 100 < count { size *= 100 }
        return stride(from: lower, through: upper, by: size).map { ($0, min(upper, $0 + size - 1)) }
    }

    static func children(of row: Row) -> [Row] {
        switch row.content {
        case .value(.object(let members)):
            return members.map { member in
                Row(id: row.id + "\u{1}k" + member.key, depth: row.depth + 1, name: DeveloperJSONValue.displayKey(member.key),
                    path: row.path + [.key(member.key)], content: .value(member.value))
            }
        case .value(.array(let items)):
            return elements(items, lower: 0, upper: items.count - 1, parent: row)
        case .range(let items, let lower, let upper):
            return elements(items, lower: lower, upper: upper, parent: row)
        default:
            return []
        }
    }

    private static func elements(_ items: [DeveloperJSONValue], lower: Int, upper: Int, parent: Row) -> [Row] {
        guard upper >= lower else { return [] }
        if let ranges = ranges(lower: lower, upper: upper) {
            return ranges.map { range in
                Row(id: parent.id + "\u{1}r\(range.lower)-\(range.upper)", depth: parent.depth + 1, name: nil,
                    path: parent.path, content: .range(items, lower: range.lower, upper: range.upper))
            }
        }
        return (lower...upper).map { index in
            Row(id: parent.id + "\u{1}i\(index)", depth: parent.depth + 1, name: String(index),
                path: parent.path + [.index(index)], content: .value(items[index]))
        }
    }

    /// The rows on show: each open row followed by its children.
    static func visibleRows(_ value: DeveloperJSONValue, expanded: Set<String>) -> [Row] {
        var output: [Row] = []
        var stack = [root(value)]
        while let row = stack.popLast() {
            output.append(row)
            if row.expandable, expanded.contains(row.id) {
                stack.append(contentsOf: children(of: row).reversed())
            }
        }
        return output
    }

    /// A row and every openable row under it, for Alt-click and "Expand
    /// recursively"; capped so a huge document stays responsive.
    static func expandableIDs(under row: Row, limit: Int = 10_000) -> [String] {
        var ids: [String] = []
        var stack = [row]
        while let next = stack.popLast(), ids.count < limit {
            guard next.expandable else { continue }
            ids.append(next.id)
            stack.append(contentsOf: children(of: next).reversed())
        }
        return ids
    }

    /// Chrome's "Copy property path": `data.items[0].name`, with keys that
    /// aren't identifiers as `["a-b"]`.
    static func propertyPath(_ path: [Segment]) -> String {
        var result = ""
        for segment in path {
            switch segment {
            case .index(let index):
                result += "[\(index)]"
            case .key(let key):
                if isCanonicalInteger(key) {
                    result += "[\(key)]"
                } else if isIdentifier(key) {
                    result += result.isEmpty ? key : "." + key
                } else {
                    result += "[" + DeveloperJSON.quote(key) + "]"
                }
            }
        }
        return result
    }

    private static func isCanonicalInteger(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        return key.allSatisfy(\.isASCII) && key.allSatisfy(\.isNumber) && (first != "0" || key == "0")
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let start = CharacterSet.letters.union(CharacterSet(charactersIn: "$_"))
        let rest = start.union(.decimalDigits).union(.nonBaseCharacters).union(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
        return start.contains(first) && key.unicodeScalars.dropFirst().allSatisfy { rest.contains($0) }
    }

    /// "Copy value": a string as it is, anything else as JSON.
    static func copyValue(_ value: DeveloperJSONValue) -> String {
        if case .string(let text) = value { return text }
        return value.pretty()
    }
}

// MARK: Tree view

/// Chrome's JSON object tree, as the Preview tab shows a JSON response and
/// the Payload tab a JSON request body: keys in the order JSON.parse keeps
/// them, the root open and everything under it shut, each shut object
/// showing its preview. Click a row to open it, Alt-click to open or shut
/// everything under it; right-click to copy.
struct DeveloperJSONTree: View {
    let root: DeveloperJSONValue
    @State private var expanded: Set<String> = [DeveloperJSONOutline.rootID]
    @State private var selected: String? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(DeveloperJSONOutline.visibleRows(root, expanded: expanded)) { row in
                line(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityIdentifier("developer-json-tree")
    }

    private func line(_ row: DeveloperJSONOutline.Row) -> some View {
        let open = expanded.contains(row.id)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if row.expandable {
                Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary)
                    .frame(width: 11, height: 13)
            } else {
                Color.clear.frame(width: 11, height: 1)
            }
            Text(label(row, open: open))
                .font(DeveloperToolsStyle.code)
                .lineLimit(row.isString ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(row.depth) * 12)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, 1)
        .background(selected == row.id ? DeveloperToolsStyle.selected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = row.id
            guard row.expandable else { return }
            toggle(row, recursive: NSEvent.modifierFlags.contains(.option))
        }
        .contextMenu { menu(row) }
    }

    @ViewBuilder
    private func menu(_ row: DeveloperJSONOutline.Row) -> some View {
        if let value = row.value {
            Button("Copy value") { Self.copy(DeveloperJSONOutline.copyValue(value)) }
            if !row.path.isEmpty {
                Button("Copy property path") { Self.copy(DeveloperJSONOutline.propertyPath(row.path)) }
            }
            if value.isContainer {
                Button("Copy object") { Self.copy(value.pretty()) }
            }
        }
        if row.expandable {
            Divider()
            Button("Expand recursively") { expanded.formUnion(DeveloperJSONOutline.expandableIDs(under: row)) }
            Button("Collapse children") { expanded.subtract(DeveloperJSONOutline.expandableIDs(under: row).filter { $0 != row.id }) }
        }
    }

    private func toggle(_ row: DeveloperJSONOutline.Row, recursive: Bool) {
        let open = expanded.contains(row.id)
        if recursive {
            let ids = DeveloperJSONOutline.expandableIDs(under: row)
            if open { expanded.subtract(ids) } else { expanded.formUnion(ids) }
        } else if open {
            expanded.remove(row.id)
        } else {
            expanded.insert(row.id)
        }
    }

    /// Strings longer than this show cut, as Chrome cuts them before its
    /// "Show more".
    private static let longestString = 10_000

    private func label(_ row: DeveloperJSONOutline.Row, open: Bool) -> AttributedString {
        var output = AttributedString()
        if let name = row.name {
            var key = AttributedString(name)
            key.foregroundColor = ConsoleTheme.property
            output += key
            output += AttributedString(": ")
        }
        switch row.content {
        case .range(_, let lower, let upper):
            output += AttributedString("[\(lower) \u{2026} \(upper)]")
        case .value(let value):
            var text: AttributedString
            switch value {
            case .string(let string):
                let shown = string.utf16.count > Self.longestString ? String(string.prefix(Self.longestString)) + "\u{2026}" : string
                text = AttributedString("\"" + shown.replacingOccurrences(of: "\n", with: "\u{21B5}") + "\"")
                text.foregroundColor = ConsoleTheme.string
            case .number(let raw):
                text = AttributedString(DeveloperJSONValue.display(number: raw))
                text.foregroundColor = ConsoleTheme.number
            case .bool(let flag):
                text = AttributedString(flag ? "true" : "false")
                text.foregroundColor = ConsoleTheme.keyword
            case .null:
                text = AttributedString("null")
                text.foregroundColor = ConsoleTheme.null
            case .object, .array:
                text = AttributedString(value.summary)
                if open, row.name != nil { text.foregroundColor = Color.secondary }
            }
            output += text
        }
        return output
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A JSON body parsed off the main thread, then drawn as the tree; while
/// it parses, nothing, and if it isn't JSON after all, `fallback`.
struct DeveloperJSONPreview<Fallback: View>: View {
    let text: String
    let scrolls: Bool
    @ViewBuilder let fallback: () -> Fallback
    @State private var parsed: DeveloperJSONValue?? = nil

    var body: some View {
        Group {
            switch parsed {
            case .none:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil)
            case .some(.none):
                fallback()
            case .some(.some(let root)):
                if scrolls {
                    ScrollView { DeveloperJSONTree(root: root) }
                } else {
                    DeveloperJSONTree(root: root)
                }
            }
        }
        .task(id: text) {
            let text = text
            let result = await Task.detached(priority: .userInitiated) { DeveloperJSONValue.parse(text) }.value
            parsed = .some(result)
        }
    }

    /// Whether a body is worth trying as JSON: a JSON MIME type, or text
    /// that opens like an object or array.
    static func looksLikeJSON(_ text: String, mimeType: String?) -> Bool {
        if let mime = mimeType?.lowercased(), mime.contains("json") { return true }
        let head = text.utf8.first { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        return head == UInt8(ascii: "{") || head == UInt8(ascii: "[")
    }
}
