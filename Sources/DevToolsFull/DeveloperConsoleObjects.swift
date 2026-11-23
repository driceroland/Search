import Foundation
import SwiftUI

// MARK: - Remote objects

/// A `Runtime.RemoteObject` as the console shows it: a primitive, or an
/// object with its preview and an id to ask for its properties.
struct ConsoleRemoteObject: Equatable, Hashable {
    var type: String
    var subtype: String?
    var className: String?
    var description: String?
    var value: ConsoleValue?
    var objectId: String?
    var size: Int?
    var preview: ConsoleObjectPreview?

    init(type: String, subtype: String? = nil, className: String? = nil, description: String? = nil,
         value: ConsoleValue? = nil, objectId: String? = nil, size: Int? = nil, preview: ConsoleObjectPreview? = nil) {
        self.type = type
        self.subtype = subtype
        self.className = className
        self.description = description
        self.value = value
        self.objectId = objectId
        self.size = size
        self.preview = preview
    }

    init(_ raw: [String: Any]) {
        type = raw["type"] as? String ?? "undefined"
        subtype = raw["subtype"] as? String
        className = raw["className"] as? String
        description = raw["description"] as? String
        value = ConsoleValue(raw["value"])
        objectId = raw["objectId"] as? String
        size = raw["size"] as? Int
        preview = (raw["preview"] as? [String: Any]).map(ConsoleObjectPreview.init)
    }

    /// Objects, functions and arrays that can be opened.
    var expandable: Bool { objectId != nil && (type == "object" || type == "function") && subtype != "null" }
    var isNode: Bool { subtype == "node" }

    /// The string a `%s` or a plain top-level argument shows.
    var plainText: String {
        switch type {
        case "string": return value?.string ?? description ?? ""
        case "undefined": return "undefined"
        default: return value?.string ?? description ?? ""
        }
    }

    /// The number a `%d`, `%i` or `%f` substitution reads.
    var number: Double? {
        switch value {
        case .number(let number): return number
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        case .bool(let flag): return flag ? 1 : 0
        default: return description.flatMap { Double($0) }
        }
    }
}

enum ConsoleValue: Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(_ raw: Any?) {
        switch raw {
        case nil: return nil
        case is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .string(text)
        default: return nil
        }
    }

    var string: String {
        switch self {
        case .string(let text): return text
        case .number(let number): return ConsoleFormat.number(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }
}

struct ConsoleObjectPreview: Equatable, Hashable {
    struct Property: Equatable, Hashable {
        var name: String
        var type: String
        var subtype: String?
        var value: String?
        var isInternal = false
        var valuePreview: ConsoleObjectPreview?
    }

    struct Entry: Equatable, Hashable {
        var key: ConsoleObjectPreview?
        var value: ConsoleObjectPreview?
    }

    var type: String
    var subtype: String?
    var description: String?
    var lossless: Bool
    var overflow: Bool
    var size: Int?
    var properties: [Property]
    var entries: [Entry]

    init(_ raw: [String: Any]) {
        type = raw["type"] as? String ?? "object"
        subtype = raw["subtype"] as? String
        description = raw["description"] as? String
        lossless = raw["lossless"] as? Bool ?? false
        overflow = raw["overflow"] as? Bool ?? false
        size = raw["size"] as? Int
        properties = (raw["properties"] as? [[String: Any]] ?? []).map {
            Property(name: $0["name"] as? String ?? "", type: $0["type"] as? String ?? "undefined",
                     subtype: $0["subtype"] as? String, value: $0["value"] as? String,
                     isInternal: $0["internal"] as? Bool ?? false,
                     valuePreview: ($0["valuePreview"] as? [String: Any]).map(ConsoleObjectPreview.init))
        }
        entries = (raw["entries"] as? [[String: Any]] ?? []).map {
            Entry(key: ($0["key"] as? [String: Any]).map(ConsoleObjectPreview.init),
                  value: ($0["value"] as? [String: Any]).map(ConsoleObjectPreview.init))
        }
    }

    init(type: String, subtype: String? = nil, description: String? = nil, lossless: Bool = true, overflow: Bool = false,
         size: Int? = nil, properties: [Property] = [], entries: [Entry] = []) {
        self.type = type
        self.subtype = subtype
        self.description = description
        self.lossless = lossless
        self.overflow = overflow
        self.size = size
        self.properties = properties
        self.entries = entries
    }
}

/// One row of an expanded object.
struct ConsoleProperty: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var value: ConsoleRemoteObject?
    var getter = false
    var enumerable = true
    var isInternal = false
    var wasThrown = false
    var entries: [ConsoleEntry]?

    init(name: String, value: ConsoleRemoteObject? = nil, getter: Bool = false, enumerable: Bool = true,
         isInternal: Bool = false, wasThrown: Bool = false, entries: [ConsoleEntry]? = nil) {
        self.name = name
        self.value = value
        self.getter = getter
        self.enumerable = enumerable
        self.isInternal = isInternal
        self.wasThrown = wasThrown
        self.entries = entries
    }

    init(_ raw: [String: Any]) {
        name = raw["name"] as? String ?? ""
        value = (raw["value"] as? [String: Any]).map(ConsoleRemoteObject.init)
        getter = raw["getter"] as? Bool ?? false
        enumerable = raw["enumerable"] as? Bool ?? true
        isInternal = raw["internal"] as? Bool ?? false
        wasThrown = raw["wasThrown"] as? Bool ?? false
        entries = (raw["entries"] as? [[String: Any]]).map { list in
            list.map { ConsoleEntry(key: ($0["key"] as? [String: Any]).map(ConsoleRemoteObject.init),
                                    value: ConsoleRemoteObject($0["value"] as? [String: Any] ?? [:])) }
        }
    }
}

struct ConsoleEntry: Equatable {
    var key: ConsoleRemoteObject?
    var value: ConsoleRemoteObject
}

struct ConsoleCallFrame: Equatable, Hashable {
    var functionName: String
    var url: String
    var lineNumber: Int
    var columnNumber: Int
    var asyncBoundary = false
    /// The script, for one with no address (eval, console), which Chrome
    /// links as VM<id>.
    var scriptID: String?

    init(functionName: String, url: String, lineNumber: Int, columnNumber: Int, asyncBoundary: Bool = false) {
        self.functionName = functionName
        self.url = url
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.asyncBoundary = asyncBoundary
    }

    init(_ raw: [String: Any]) {
        functionName = raw["functionName"] as? String ?? ""
        url = raw["url"] as? String ?? ""
        lineNumber = raw["lineNumber"] as? Int ?? 0
        columnNumber = raw["columnNumber"] as? Int ?? 0
        asyncBoundary = raw["asyncBoundary"] as? Bool ?? false
        scriptID = raw["scriptId"] as? String
    }

    var name: String { functionName.isEmpty ? "(anonymous)" : functionName }
    var location: String { ConsoleFormat.location(url, line: lineNumber) }
}

/// What the event stream carries for a message beyond its text.
struct ConsoleMessageDetails: Equatable {
    var source: String?
    var type: String?
    var column: Int?
    var timestamp: Double?
    var targetID: String?
    var parameters: [ConsoleRemoteObject] = []
    var stackTrace: [ConsoleCallFrame] = []

    init(source: String? = nil, type: String? = nil, column: Int? = nil, timestamp: Double? = nil, targetID: String? = nil,
         parameters: [ConsoleRemoteObject] = [], stackTrace: [ConsoleCallFrame] = []) {
        self.source = source
        self.type = type
        self.column = column
        self.timestamp = timestamp
        self.targetID = targetID
        self.parameters = parameters
        self.stackTrace = stackTrace
    }

    init(message raw: [String: Any], targetID: String?) {
        source = raw["source"] as? String
        type = raw["type"] as? String
        column = raw["column"] as? Int
        timestamp = raw["timestamp"] as? Double
        self.targetID = targetID
        parameters = (raw["parameters"] as? [[String: Any]] ?? []).map(ConsoleRemoteObject.init)
        stackTrace = (raw["stackTrace"] as? [[String: Any]] ?? []).map(ConsoleCallFrame.init)
    }
}

// MARK: - Formatting

/// A piece of one console line: text in a `%c` style, or an argument.
enum ConsoleSegment: Equatable {
    case text(String, ConsoleStyle)
    case object(ConsoleRemoteObject, ConsoleStyle)
}

/// The CSS a `%c` directive may set, as far as the console can draw it.
struct ConsoleStyle: Equatable, Hashable {
    var color: ConsoleColor?
    var background: ConsoleColor?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var fontSize: Double?
    var padding = false
    var monospaced = true

    static let plain = ConsoleStyle()
    var isPlain: Bool { self == .plain }

    /// Chrome reads a `%c` argument as CSS for a span; this keeps the
    /// properties a native text run can show.
    init(css: String) {
        self.init()
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].lowercased().replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "color": color = ConsoleColor(css: value) ?? color
            case "background", "background-color":
                background = ConsoleColor(css: value) ?? value.split(separator: " ").lazy.compactMap { ConsoleColor(css: String($0)) }.first ?? background
            case "font-weight": bold = value == "bold" || value == "bolder" || (Int(value) ?? 400) >= 600
            case "font-style": italic = value == "italic" || value == "oblique"
            case "text-decoration", "text-decoration-line":
                underline = value.contains("underline")
                strikethrough = value.contains("line-through")
            case "font-size":
                if value.hasSuffix("px"), let size = Double(value.dropLast(2)) { fontSize = min(max(size, 6), 48) }
                else if value.hasSuffix("em"), let size = Double(value.dropLast(2)) { fontSize = min(max(size * 11, 6), 48) }
            case "font-family":
                monospaced = value.contains("mono") || value.contains("courier") || value.contains("menlo")
            case "padding", "padding-left", "padding-right": padding = !value.hasPrefix("0")
            default: continue
            }
        }
    }

    init() {}
}

struct ConsoleColor: Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    private static let named: [String: (Double, Double, Double)] = [
        "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0), "green": (0, 128, 0), "blue": (0, 0, 255),
        "yellow": (255, 255, 0), "orange": (255, 165, 0), "purple": (128, 0, 128), "gray": (128, 128, 128),
        "grey": (128, 128, 128), "pink": (255, 192, 203), "brown": (165, 42, 42), "cyan": (0, 255, 255),
        "aqua": (0, 255, 255), "magenta": (255, 0, 255), "fuchsia": (255, 0, 255), "lime": (0, 255, 0),
        "navy": (0, 0, 128), "teal": (0, 128, 128), "maroon": (128, 0, 0), "olive": (128, 128, 0),
        "silver": (192, 192, 192), "gold": (255, 215, 0), "indigo": (75, 0, 130), "violet": (238, 130, 238),
        "crimson": (220, 20, 60), "coral": (255, 127, 80), "salmon": (250, 128, 114), "tomato": (255, 99, 71),
        "orangered": (255, 69, 0), "darkred": (139, 0, 0), "darkgreen": (0, 100, 0), "darkblue": (0, 0, 139),
        "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211), "darkgray": (169, 169, 169),
        "darkgrey": (169, 169, 169), "lightblue": (173, 216, 230), "lightgreen": (144, 238, 144),
        "hotpink": (255, 105, 180), "deeppink": (255, 20, 147), "skyblue": (135, 206, 235),
        "steelblue": (70, 130, 180), "royalblue": (65, 105, 225), "dodgerblue": (30, 144, 255),
        "rebeccapurple": (102, 51, 153), "limegreen": (50, 205, 50), "seagreen": (46, 139, 87),
        "chocolate": (210, 105, 30), "tan": (210, 180, 140), "khaki": (240, 230, 140), "beige": (245, 245, 220),
        "ivory": (255, 255, 240), "lavender": (230, 230, 250), "turquoise": (64, 224, 208),
    ]

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(css raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "transparent" { self.init(red: 0, green: 0, blue: 0, alpha: 0); return }
        if let rgb = Self.named[value] { self.init(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255); return }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            let alpha = hex.count == 8 ? Double(number & 0xff) / 255 : 1
            let rgb = hex.count == 8 ? number >> 8 : number
            self.init(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                      blue: Double(rgb & 0xff) / 255, alpha: alpha)
            return
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let numbers = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard numbers.count >= 3 else { return nil }
            func channel(_ text: String) -> Double? {
                text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text).map { $0 / 255 }
            }
            guard let red = channel(numbers[0]), let green = channel(numbers[1]), let blue = channel(numbers[2]) else { return nil }
            let alpha = numbers.count > 3 ? (numbers[3].hasSuffix("%") ? Double(numbers[3].dropLast()).map { $0 / 100 } : Double(numbers[3])) ?? 1 : 1
            self.init(red: red, green: green, blue: blue, alpha: alpha)
            return
        }
        return nil
    }
}

enum ConsoleFormat {
    static func number(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e21 { return value == 0 && value.sign == .minus ? "-0" : String(Int64(value)) }
        return String(value)
    }

    static func location(_ url: String, line: Int?) -> String {
        let name = URL(string: url).map { $0.lastPathComponent.isEmpty ? ($0.host() ?? url) : $0.lastPathComponent } ?? url
        return name + (line.map { ":\($0)" } ?? "")
    }

    /// Chrome's format-string substitution (`%s %d %i %f %o %O %c %%`),
    /// applied when the first argument is a string; the rest follow it,
    /// separated by spaces.
    static func segments(_ parameters: [ConsoleRemoteObject]) -> [ConsoleSegment] {
        guard let first = parameters.first else { return [] }
        var output = [ConsoleSegment]()
        var rest = parameters.dropFirst()
        if first.type == "string", let format = first.value?.string {
            var style = ConsoleStyle.plain
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { output.append(.text(buffer, style)) }
                buffer = ""
            }
            var index = format.startIndex
            while index < format.endIndex {
                let character = format[index]
                let next = format.index(after: index)
                guard character == "%", next < format.endIndex else {
                    buffer.append(character)
                    index = next
                    continue
                }
                // Chrome also accepts a precision such as %.2f.
                var cursor = next
                var precision: Int?
                if format[cursor] == ".", format.index(after: cursor) < format.endIndex {
                    var digits = ""
                    var probe = format.index(after: cursor)
                    while probe < format.endIndex, format[probe].isNumber { digits.append(format[probe]); probe = format.index(after: probe) }
                    if !digits.isEmpty, probe < format.endIndex { precision = Int(digits); cursor = probe }
                }
                let specifier = format[cursor]
                let after = format.index(after: cursor)
                if specifier == "%" {
                    buffer.append("%")
                    index = after
                    continue
                }
                guard "sdifoOc".contains(specifier) else {
                    buffer.append(character)
                    index = next
                    continue
                }
                guard let argument = rest.first else {
                    // A directive without an argument stays in the text.
                    buffer += String(format[index..<after])
                    index = after
                    continue
                }
                rest = rest.dropFirst()
                switch specifier {
                case "c":
                    flush()
                    style = ConsoleStyle(css: argument.plainText)
                case "s":
                    if argument.type == "string" || !argument.expandable { buffer += argument.type == "string" ? argument.plainText : inline(argument) }
                    else { flush(); output.append(.object(argument, style)) }
                case "d", "i":
                    let value = argument.number.map { $0.rounded(.towardZero) }
                    buffer += value.map(number) ?? "NaN"
                case "f":
                    if let value = argument.number {
                        buffer += precision.map { String(format: "%.\($0)f", value) } ?? number(value)
                    } else {
                        buffer += "NaN"
                    }
                default:
                    flush()
                    output.append(.object(argument, style))
                }
                index = after
            }
            flush()
        } else {
            output.append(first.type == "string" ? .text(first.plainText, .plain) : .object(first, .plain))
        }
        for argument in rest {
            output.append(.text(" ", .plain))
            output.append(argument.type == "string" ? .text(argument.plainText, .plain) : .object(argument, .plain))
        }
        return output
    }

    /// The one-line preview Chrome shows for an argument: `(3) [1, 2, 3]`,
    /// `{a: 1, b: 'x'}`, `Map(1) {'k' => 1}`, `ƒ name()`.
    static func inline(_ object: ConsoleRemoteObject, nested: Bool = false) -> String {
        switch object.type {
        case "string":
            let text = object.plainText
            return nested ? "'" + text + "'" : text
        case "undefined": return "undefined"
        case "number", "boolean": return object.value?.string ?? object.description ?? ""
        case "bigint": return (object.description ?? "") + (object.description?.hasSuffix("n") == true ? "" : "n")
        case "symbol": return object.description ?? "Symbol()"
        case "function": return function(object.description ?? "", className: object.className)
        default: break
        }
        switch object.subtype {
        case "null": return "null"
        case "node": return object.description ?? "node"
        case "regexp", "date", "error": return firstLine(object.description ?? "")
        default: break
        }
        if let preview = object.preview { return inline(preview, className: object.className, size: object.size) }
        return object.description ?? object.className ?? "Object"
    }

    static func inline(_ preview: ConsoleObjectPreview, className: String? = nil, size: Int? = nil) -> String {
        let size = preview.size ?? size
        let more = preview.overflow ? ", …" : ""
        switch preview.subtype {
        case "array":
            var items = [String]()
            var nextIndex = 0
            var named = [String]()
            for property in preview.properties {
                if let index = Int(property.name) {
                    if index > nextIndex { items.append("empty × \(index - nextIndex)") }
                    items.append(value(property))
                    nextIndex = index + 1
                } else if property.name != "length" {
                    named.append(property.name + ": " + value(property))
                }
            }
            let prefix = (className.map { $0 == "Array" ? "" : $0 } ?? "") + (size.map { "(\($0)) " } ?? "")
            return prefix + "[" + (items + named).joined(separator: ", ") + more + "]"
        case "map", "set", "weakmap", "weakset":
            let name = className ?? preview.description?.components(separatedBy: " ").first ?? "Map"
            let entries = preview.entries.map { entry in
                let value = entry.value.map { inline($0, nested: true) } ?? "undefined"
                return entry.key.map { inline($0, nested: true) + " => " + value } ?? value
            }
            return name + (size.map { "(\($0))" } ?? "") + " {" + entries.joined(separator: ", ") + more + "}"
        case "null": return "null"
        case "node", "regexp", "date", "error": return firstLine(preview.description ?? "")
        default:
            let name = className ?? preview.description ?? "Object"
            // A promise as Chrome shows it: its state in angle brackets and,
            // once settled, its value. WebKit lists these as status and result.
            if name == "Promise", let status = preview.properties.first(where: { $0.name == "status" })?.value {
                let state = "<" + status + ">"
                guard let result = preview.properties.first(where: { $0.name == "result" }) else { return "Promise {" + state + "}" }
                return "Promise {" + state + ": " + value(result) + "}"
            }
            let body = preview.properties.map { $0.name + ": " + value($0) }.joined(separator: ", ")
            let prefix = name == "Object" ? "" : name + " "
            return prefix + "{" + body + more + "}"
        }
    }

    private static func inline(_ preview: ConsoleObjectPreview, nested: Bool) -> String {
        switch preview.type {
        case "string": return "'" + (preview.description ?? "") + "'"
        case "object" where preview.subtype != "null" && (!preview.properties.isEmpty || !preview.entries.isEmpty):
            return inline(preview)
        case "function": return "ƒ"
        default: return preview.description ?? preview.type
        }
    }

    private static func value(_ property: ConsoleObjectPreview.Property) -> String {
        switch property.type {
        case "string": return "'" + (property.value ?? "") + "'"
        case "function": return "ƒ"
        case "accessor": return "(...)"
        case "object":
            if property.subtype == "null" { return "null" }
            if property.subtype == "array" {
                return property.value ?? "Array" + ((property.valuePreview?.size).map { "(\($0))" } ?? "")
            }
            if let nested = property.valuePreview, property.subtype == nil,
               nested.properties.count <= 3, !nested.properties.isEmpty {
                return "{" + nested.properties.map { $0.name + ": " + ($0.type == "string" ? "'\($0.value ?? "")'" : $0.value ?? "…") }
                    .joined(separator: ", ") + (nested.overflow ? ", …" : "") + "}"
            }
            return property.value ?? "{…}"
        default: return property.value ?? property.type
        }
    }

    static func function(_ source: String, className: String? = nil) -> String {
        var head = source.prefix(while: { $0 != "{" && $0 != "\n" }).trimmingCharacters(in: .whitespaces)
        if let arrow = head.range(of: "=>") { head = String(head[..<arrow.lowerBound]) + "=>" }
        if head.hasPrefix("class") { return head }
        var signature = head
        if signature.hasPrefix("function") { signature = String(signature.dropFirst("function".count)).trimmingCharacters(in: .whitespaces) }
        if signature.hasPrefix("async function") { signature = "async " + signature.dropFirst("async function".count).trimmingCharacters(in: .whitespaces) }
        if signature.hasSuffix("=>") { signature = String(signature.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        return "ƒ " + (signature.isEmpty ? "()" : signature)
    }

    static func firstLine(_ text: String) -> String {
        String(text.prefix(while: { $0 != "\n" }))
    }

    /// The message's whole text, as filtering and copying read it.
    static func plain(_ segments: [ConsoleSegment]) -> String {
        segments.map {
            switch $0 {
            case .text(let text, _): return text
            case .object(let object, _): return inline(object)
            }
        }.joined()
    }
}

// MARK: - console.table

struct ConsoleTable: Equatable {
    var columns: [String]
    var rows: [(index: String, cells: [String: ConsoleTableCell])]

    static func == (lhs: ConsoleTable, rhs: ConsoleTable) -> Bool {
        lhs.columns == rhs.columns && lhs.rows.map(\.index) == rhs.rows.map(\.index)
            && lhs.rows.map(\.cells) == rhs.rows.map(\.cells)
    }

    /// Rows and columns from the table argument's preview, as Chrome lays
    /// them out: `(index)`, then each row's keys in the order first seen,
    /// then `Value` for rows that are not objects.
    init?(_ object: ConsoleRemoteObject, columns filter: [String]? = nil) {
        guard let preview = object.preview, object.type == "object" else { return nil }
        var columns = [String]()
        var hasValue = false
        var rows = [(index: String, cells: [String: ConsoleTableCell])]()
        let sources: [(String, ConsoleObjectPreview.Property?, ConsoleObjectPreview?)] = preview.entries.isEmpty
            ? preview.properties.map { ($0.name, $0, $0.valuePreview) }
            : preview.entries.enumerated().map { index, entry in
                (entry.key.map { ConsoleFormat.inline($0, className: nil) } ?? String(index), nil, entry.value) }
        for (index, property, nested) in sources.prefix(1000) {
            var cells = [String: ConsoleTableCell]()
            if let nested, nested.type == "object", nested.subtype != "null", !nested.properties.isEmpty || nested.entries.isEmpty {
                for item in nested.properties {
                    if filter?.contains(item.name) == false { continue }
                    if !columns.contains(item.name) { columns.append(item.name) }
                    cells[item.name] = ConsoleTableCell(item)
                }
            } else if let property {
                hasValue = true
                cells["Value"] = ConsoleTableCell(property)
            } else if let nested {
                hasValue = true
                cells["Value"] = ConsoleTableCell(text: nested.description ?? "", type: nested.type)
            }
            rows.append((index, cells))
        }
        if let filter { columns = filter.filter { columns.contains($0) } }
        if hasValue { columns.append("Value") }
        self.columns = columns
        self.rows = rows
    }
}

struct ConsoleTableCell: Equatable, Hashable {
    var text: String
    var type: String

    init(text: String, type: String) {
        self.text = text
        self.type = type
    }

    init(_ property: ConsoleObjectPreview.Property) {
        type = property.subtype == "null" ? "null" : property.type
        switch property.type {
        case "string": text = "'" + (property.value ?? "") + "'"
        case "function": text = "ƒ"
        case "object" where property.valuePreview != nil && property.subtype == nil:
            text = property.valuePreview.map { ConsoleFormat.inline($0) } ?? property.value ?? "{…}"
        default: text = property.value ?? property.type
        }
    }
}

// MARK: - Levels and groups

/// Chrome's "Default levels" menu: Verbose, Info, Warnings, Errors.
enum ConsoleLevel: String, CaseIterable, Identifiable, Hashable {
    case verbose = "Verbose"
    case info = "Info"
    case warnings = "Warnings"
    case errors = "Errors"

    var id: String { rawValue }
    static let defaults: Set<ConsoleLevel> = [.info, .warnings, .errors]

    init(_ level: String) {
        switch level {
        case "error": self = .errors
        case "warning": self = .warnings
        case "debug": self = .verbose
        default: self = .info
        }
    }

    static func label(_ levels: Set<ConsoleLevel>) -> String {
        if levels == defaults { return "Default levels" }
        if levels.count == allCases.count { return "All levels" }
        if levels.isEmpty { return "Hide all" }
        if levels.count == 1, let only = levels.first { return only.rawValue + " only" }
        return "Custom levels"
    }
}

/// A message as the list lays it out: how deep in `console.group` it is,
/// and which group it opens.
struct ConsoleRow: Identifiable, Equatable {
    var id: String { copy == 0 ? line.id.uuidString : line.id.uuidString + "#\(copy)" }
    let line: DeveloperToolsSession.ConsoleLine
    let depth: Int
    let opensGroup: Bool
    let collapsed: Bool
    /// The badge: WebKit's repeats plus similar messages grouped in.
    var count = 1
    /// Which repeat this is when "Group similar messages" is off.
    var copy = 0
}

enum ConsoleLayout {
    static func isGroupStart(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        line.details?.type == "startGroup" || line.details?.type == "startGroupCollapsed"
    }

    /// Indents grouped messages, hides the ones inside a collapsed group
    /// and leaves out messages the level and text filters exclude. A
    /// group's header stays while anything inside it is shown.
    static func rows(_ lines: [DeveloperToolsSession.ConsoleLine], levels: Set<ConsoleLevel>, filter: String,
                     toggled: Set<UUID>, settings: ConsoleSettings = ConsoleSettings(),
                     sidebar: ConsoleSidebarFilter = ConsoleSidebarFilter()) -> [ConsoleRow] {
        var output = [ConsoleRow]()
        var stack = [Bool]()  // whether each open group hides what it holds
        let query = ConsoleFilter(filter)
        // The sidebar's level groups take over from the levels menu.
        let levels = sidebar.group.levels ?? levels
        func passes(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
            let entered = line.level == "command" || line.level == "result"
            if !entered && !levels.contains(ConsoleLevel(line.level)) { return false }
            if !settings.networkMessages && line.details?.source == "network" { return false }
            if !settings.corsErrors && ConsoleSettings.isCORSError(line) { return false }
            if !sidebar.accepts(line) { return false }
            return query.accepts(line)
        }
        var counts = [UUID: Int]()
        var similar = [String: Int]()
        for line in lines {
            let hiddenByParent = stack.last ?? false
            if line.details?.type == "endGroup" {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if isGroupStart(line) {
                let startsCollapsed = line.details?.type == "startGroupCollapsed"
                let collapsed = startsCollapsed != toggled.contains(line.id)
                if !hiddenByParent {
                    output.append(ConsoleRow(line: line, depth: stack.count, opensGroup: true, collapsed: collapsed))
                }
                stack.append(hiddenByParent || collapsed)
                continue
            }
            guard !hiddenByParent, passes(line) else { continue }
            // "Group similar messages": a message like an earlier one adds
            // to that one's count. Off, each repeat gets its own row.
            if settings.groupSimilar, let key = similarKey(line) {
                if let index = similar[key] {
                    let first = output[index]
                    counts[first.line.id, default: first.count] += line.repeatCount
                    continue
                }
                similar[key] = output.count
                output.append(ConsoleRow(line: line, depth: stack.count, opensGroup: false, collapsed: false, count: line.repeatCount))
            } else if settings.groupSimilar {
                output.append(ConsoleRow(line: line, depth: stack.count, opensGroup: false, collapsed: false, count: line.repeatCount))
            } else {
                for copy in 0..<max(1, min(line.repeatCount, 500)) {
                    output.append(ConsoleRow(line: line, depth: stack.count, opensGroup: false, collapsed: false, copy: copy))
                }
            }
        }
        if !counts.isEmpty {
            output = output.map { row in
                guard let count = counts[row.line.id] else { return row }
                var row = row
                row.count = count
                return row
            }
        }
        // Drop the headers of open groups whose messages were all filtered
        // out, unless the header itself matches.
        if !query.isEmpty || levels != Set(ConsoleLevel.allCases) || !sidebar.isEmpty
            || !settings.networkMessages || !settings.corsErrors {
            output = pruneEmptyGroups(output, passes: passes)
        }
        return output
    }

    private static func pruneEmptyGroups(_ rows: [ConsoleRow], passes: (DeveloperToolsSession.ConsoleLine) -> Bool) -> [ConsoleRow] {
        // From the end, so an outer group sees whether its inner ones stayed.
        var kept = [ConsoleRow]()
        for row in rows.reversed() {
            if row.opensGroup, !row.collapsed, !passes(row.line), (kept.last?.depth ?? -1) <= row.depth { continue }
            kept.append(row)
        }
        return kept.reversed()
    }

    /// Chrome groups messages with the same level, source, text and
    /// location; ones that carry objects or stacks stay apart.
    static func similarKey(_ line: DeveloperToolsSession.ConsoleLine) -> String? {
        ConsoleLineCache.shared.similarKey(line) {
            guard let details = line.details, details.source != nil, details.type == nil || details.type == "log",
                  details.parameters.allSatisfy({ !$0.expandable }) else { return nil }
            return [line.level, details.source ?? "", argumentText(line), line.url ?? "",
                    line.line.map(String.init) ?? ""].joined(separator: "\u{1}")
        }
    }

    static func searchableText(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        ConsoleLineCache.shared.searchableText(line) { argumentText(line) + " " + (line.url ?? "") }
    }

    /// The message's arguments as plain text, or its text when it has none.
    private static func argumentText(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        ConsoleLineCache.shared.argumentText(line) {
            guard let details = line.details, !details.parameters.isEmpty else { return line.text }
            return ConsoleFormat.plain(ConsoleFormat.segments(details.parameters))
        }
    }
}

/// What the list derives from each message's text and arguments, worked
/// out once per message rather than on every pass over up to 10,000 of
/// them. Keyed by the message's id: a message's level, text, location and
/// arguments never change once logged, only its repeat count, which none
/// of these depend on. Ids are unique across sessions, so one cache serves
/// every Console; a table that grows past its limit starts over.
final class ConsoleLineCache: @unchecked Sendable {
    static let shared = ConsoleLineCache()

    private let lock = NSLock()
    private var arguments: [UUID: String] = [:]
    private var similar: [UUID: String?] = [:]
    private var searchable: [UUID: String] = [:]
    private var rowSegments: [UUID: [ConsoleSegment]] = [:]
    private var display: [UUID: String] = [:]
    private static let limit = 60_000

    func argumentText(_ line: DeveloperToolsSession.ConsoleLine, _ make: () -> String) -> String {
        value(\.arguments, line.id, make)
    }

    func similarKey(_ line: DeveloperToolsSession.ConsoleLine, _ make: () -> String?) -> String? {
        value(\.similar, line.id, make)
    }

    func searchableText(_ line: DeveloperToolsSession.ConsoleLine, _ make: () -> String) -> String {
        value(\.searchable, line.id, make)
    }

    func segments(_ line: DeveloperToolsSession.ConsoleLine, _ make: () -> [ConsoleSegment]) -> [ConsoleSegment] {
        value(\.rowSegments, line.id, make)
    }

    func displayText(_ line: DeveloperToolsSession.ConsoleLine, _ make: () -> String) -> String {
        value(\.display, line.id, make)
    }

    /// The lock is not held while `make` runs, as one value may be built
    /// from another.
    private func value<T>(_ table: ReferenceWritableKeyPath<ConsoleLineCache, [UUID: T]>, _ id: UUID, _ make: () -> T) -> T {
        lock.lock()
        if let cached = self[keyPath: table][id] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let made = make()
        lock.lock()
        if self[keyPath: table].count >= Self.limit { self[keyPath: table].removeAll(keepingCapacity: true) }
        self[keyPath: table][id] = made
        lock.unlock()
        return made
    }
}

/// Tells one version of the message list from the next without walking
/// it: messages are only appended, trimmed from the front, cleared, or
/// have the repeat count of the newest message with a source raised
/// (`Console.messageRepeatCountUpdated`).
struct ConsoleMarker: Equatable {
    let count: Int
    let first: UUID?
    let last: UUID?
    let repeated: UUID?
    let repeats: Int

    init(_ lines: [DeveloperToolsSession.ConsoleLine]) {
        count = lines.count
        first = lines.first?.id
        last = lines.last?.id
        let sourced = lines.last(where: { $0.details?.source != nil })
        repeated = sourced?.id
        repeats = sourced?.repeatCount ?? 0
    }
}

typealias ConsoleTally = [ConsoleSidebarGroup: (count: Int, files: [(url: String, count: Int)])]

/// The Console's laid-out rows, the count the filters hide, the Find
/// bar's matches, the sidebar's tally and the toolbar's error and warning
/// counts, worked out again only when the messages or a filter change
/// rather than on every publish of the session.
@MainActor
final class ConsoleLayoutMemo {
    private struct Key: Equatable {
        let marker: ConsoleMarker
        let levels: Set<ConsoleLevel>
        let filter: String
        let toggled: Set<UUID>
        let settings: ConsoleSettings
        let sidebar: ConsoleSidebarFilter
    }

    private var key: Key?
    /// The rows last laid out, which Copy all messages and Save as… use.
    private(set) var rows: [ConsoleRow] = []
    private(set) var hidden = 0
    private var revision = 0
    private var findRevision = -1
    private var findQuery = ""
    private var found: [ConsoleFindMatch] = []
    private var tallyMarker: ConsoleMarker?
    private var tallied: ConsoleTally = [:]
    private var issueMarker: ConsoleMarker?
    private var issues: (errors: Int, warnings: Int) = (0, 0)

    func layout(_ lines: [DeveloperToolsSession.ConsoleLine], levels: Set<ConsoleLevel>, filter: String, toggled: Set<UUID>,
                settings: ConsoleSettings, sidebar: ConsoleSidebarFilter) -> (rows: [ConsoleRow], hidden: Int) {
        let key = Key(marker: ConsoleMarker(lines), levels: levels, filter: filter, toggled: toggled,
                      settings: settings, sidebar: sidebar)
        if key != self.key {
            self.key = key
            rows = ConsoleLayout.rows(lines, levels: levels, filter: filter, toggled: toggled, settings: settings, sidebar: sidebar)
            let shown = Set(rows.map(\.line.id))
            var hidden = 0
            for line in lines where ConsoleSidebarFilter.counted(line) && !shown.contains(line.id) && !ConsoleLayout.isGroupStart(line) {
                hidden += 1
            }
            self.hidden = hidden
            revision &+= 1
        }
        return (rows, hidden)
    }

    /// The Find bar's matches over the rows last laid out.
    func matches(_ query: String) -> [ConsoleFindMatch] {
        guard !query.isEmpty else { return [] }
        if findRevision == revision, findQuery == query { return found }
        found = ConsoleFind.matches(rows.map { (id: $0.id, text: ConsoleRowContent.displayText($0.line)) }, query: query)
        findRevision = revision
        findQuery = query
        return found
    }

    func tally(_ lines: [DeveloperToolsSession.ConsoleLine]) -> ConsoleTally {
        let marker = ConsoleMarker(lines)
        if marker != tallyMarker {
            tallyMarker = marker
            tallied = ConsoleSidebarFilter.tally(lines)
        }
        return tallied
    }

    func issueCounts(_ lines: [DeveloperToolsSession.ConsoleLine]) -> (errors: Int, warnings: Int) {
        let marker = ConsoleMarker(lines)
        if marker != issueMarker {
            issueMarker = marker
            issues = DeveloperIssueCounts.count(lines)
        }
        return issues
    }
}

enum ConsoleInput {
    /// Chrome keeps editing on Return while a bracket, brace or string is
    /// still open.
    static func isIncomplete(_ source: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        var lineComment = false
        var blockComment = false
        var previous: Character = " "
        for character in source {
            defer { previous = character }
            if lineComment { if character == "\n" { lineComment = false }; continue }
            if blockComment { if previous == "*" && character == "/" { blockComment = false }; continue }
            if let open = quote {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'", "`": quote = character
            case "/" where previous == "/": lineComment = true
            case "*" where previous == "/": blockComment = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
        }
        return depth > 0 || quote == "`"
    }
}

// MARK: - Session state

/// Console state that outlives the panel's views: expanded objects and
/// their properties, groups the user opened or closed, prompt history and
/// the file a console link asked Sources to show.
@MainActor
final class DeveloperConsoleStore: ObservableObject {
    @Published var expanded = Set<String>()
    @Published private(set) var properties: [String: [ConsoleProperty]] = [:]
    @Published private(set) var truncated = Set<String>()
    @Published var toggledGroups = Set<UUID>()
    @Published var expandedStacks = Set<UUID>()
    @Published var levels = ConsoleLevel.defaults
    @Published var filter = ""
    /// The prompt's history: this run's (ConsoleHistory), never a private
    /// tab's, which keeps its own for the session only.
    @Published var history: [String] = [] { didSet { if keepsHistory { ConsoleHistory.save(history) } } }
    var keepsHistory = false {
        didSet { if keepsHistory, !oldValue, history.isEmpty { history = ConsoleHistory.load() } }
    }
    /// The JavaScript context chosen in the selector; nil is `top`.
    @Published var context: ConsoleExecutionContext?
    /// The contexts the selector lists, read again each time it opens.
    @Published var contexts: [ConsoleExecutionContext] = []
    /// Logged errors' `stack` strings, by object id.
    @Published private(set) var errorStacks: [String: String] = [:]
    /// Logged nodes' element trees, by object id.
    @Published private(set) var nodeTrees: [String: ConsoleNodeTree] = [:]
    /// Custom formatter headers and opened bodies, by object and config
    /// (ConsoleCustomFormatting.key).
    @Published var customHeaders: [String: ConsoleCustomPreviewState] = [:]
    @Published var customBodies: [String: ConsoleCustomBody] = [:]
    /// Keys opened with ⌥-click and how many levels below them still open.
    var deepExpansion: [String: Int] = [:]
    /// The Find bar (⌘F) over the messages.
    @Published var findShown = false
    /// Counts that ask the Find bar's field (⌘F) and the prompt (⌃`) for
    /// the keyboard, from DevTools' keys.
    @Published var findFocus = 0
    @Published var promptFocus = 0
    @Published var findQuery = ""
    @Published var findIndex: Int?
    /// ⌘A in the message list: every shown message is selected for ⌘C.
    @Published var allSelected = false
    /// Bumped when the prompt runs something, so the list follows it to
    /// the bottom even when the user had scrolled up.
    @Published var followRequest = 0
    /// Whether the list was at its bottom when last scrolled.
    var pinnedToBottom = true
    /// Whether the last click landed in the message list, so ⌘A and ⌘C
    /// act on messages rather than on a field elsewhere.
    var listActive = false
    var highlight: Task<Void, Never>?
    /// The gear's settings, kept across sessions as Chrome keeps them.
    @Published var settings = ConsoleSettings.saved { didSet { settings.save() } }
    @Published var showsSettings = false
    @Published var showsSidebar = false
    @Published var sidebar = ConsoleSidebarFilter()
    @Published var liveExpressions: [ConsoleLiveExpression] = []
    /// The live expression being typed, which only gets safe previews.
    var editingLive: UUID?
    /// Nodes picked in Elements, newest first: $0 to $4.
    private(set) var inspectedNodes: [Int] = []
    var loading = Set<String>()
    /// Rows, counts and matches, kept until the messages or a filter change.
    let layout = ConsoleLayoutMemo()

    func noteInspected(_ node: Int) {
        guard inspectedNodes.first != node else { return }
        inspectedNodes = Array(([node] + inspectedNodes.filter { $0 != node }).prefix(5))
    }

    func setProperties(_ list: [ConsoleProperty], for key: String, more: Bool) {
        properties[key] = list
        if more { truncated.insert(key) }
        loading.remove(key)
    }

    func replaceProperty(_ property: ConsoleProperty, in key: String) {
        guard var list = properties[key], let index = list.firstIndex(where: { $0.name == property.name }) else { return }
        list[index] = property
        properties[key] = list
    }

    func setErrorStack(_ stack: String?, for key: String) {
        errorStacks[key] = stack ?? ""
        loading.remove("stack:" + key)
    }

    /// The formatter's header for a logged object, while custom formatters are on.
    func customHeader(_ object: ConsoleRemoteObject, config: ConsoleRemoteObject? = nil) -> ConsoleCustomPreview? {
        guard settings.customFormatters, object.objectId != nil,
              case .header(let preview)? = customHeaders[ConsoleCustomFormatting.key(object, config: config)] else { return nil }
        return preview
    }

    func setNodeTree(_ tree: ConsoleNodeTree, for key: String) {
        nodeTrees[key] = tree
        loading.remove("node:" + key)
    }

    /// ⌥-click on a triangle, as in Chrome: open this and everything
    /// below it, a few levels deep.
    func expandRecursively(_ key: String, depth: Int = 4) {
        expanded.insert(key)
        deepExpansion[key] = depth
    }

    /// Closes one tree; ⌥-click closes everything beneath it too.
    func collapse(_ key: String, recursively: Bool = false) {
        expanded = recursively ? expanded.filter { $0 != key && !$0.hasPrefix(key + "/") } : expanded.subtracting([key])
        deepExpansion = deepExpansion.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
    }

    /// Opens or closes a tree from its triangle or its text, as Chrome
    /// does; with ⌥ held, the whole tree below it.
    func toggle(_ key: String, recursively: Bool) {
        if expanded.contains(key) { collapse(key, recursively: recursively) }
        else if recursively { expandRecursively(key) }
        else { expanded.insert(key) }
    }

    func reset() {
        inspectedNodes = []
        expanded = []
        properties = [:]
        truncated = []
        toggledGroups = []
        expandedStacks = []
        loading = []
        errorStacks = [:]
        nodeTrees = [:]
        customHeaders = [:]
        customBodies = [:]
        deepExpansion = [:]
        allSelected = false
        findIndex = nil
    }

    func remember(_ expression: String) {
        let updated = ConsoleHistory.appending(expression, to: history)
        if updated != history { history = updated }
    }
}

// MARK: - Session commands

extension DeveloperToolsSession {
    /// As in Chrome DevTools, the most messages the Console keeps.
    static let consoleLimit = 10_000

    /// Where the prompt, its completions and its eager preview run: the
    /// selected call frame while the debugger is paused, as in Chrome
    /// DevTools, else the context chosen in the selector, else the page.
    func consolePlace(completing: Bool = false, force: Bool = false) -> [String: Any] {
        var place: [String: Any] = [:]
        if let frame = debugger.frame, !frame.id.hasPrefix("frame-") {
            place["callFrameId"] = frame.id
            if let target = debugger.pause?.targetID { place["targetId"] = target }
            if completing {
                place["scopes"] = Array(frame.scopes.filter { $0.kind != .global }.flatMap(\.objects).compactMap(\.objectID).prefix(12))
            }
        } else if let context = consoleStore.context, !context.isTop {
            place["contextId"] = context.contextID
            if let target = context.targetID { place["targetId"] = target }
        }
        if force { place["force"] = true }
        return place
    }

    /// Evaluates from the prompt like Chrome's console: in the "console"
    /// object group so the result stays expandable and `$_` follows it,
    /// with `$0` set to the node selected in Elements.
    func evaluateInConsole(_ expression: String) {
        guard ready, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        consoleStore.remember(expression)
        consoleStore.followRequest += 1
        let now = Date().timeIntervalSince1970
        appendConsoleLine(ConsoleLine(level: "command", text: String(expression.prefix(8_192)),
                                      details: ConsoleMessageDetails(timestamp: now)))
        if let node = selectedNode { consoleStore.noteInspected(node) }
        let nodes = consoleStore.inspectedNodes
        let gesture = consoleStore.settings.userActivation
        let place = consolePlace()
        let target = place["targetId"] as? String
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = UUID().uuidString
                let reply = try await self.bridge("""
                    const reply = await searchConsole.evaluate(expression, nodes, gesture, null, place);
                    searchInspector.mark?.(token);
                    return reply;
                    """, [
                    "expression": expression, "nodes": nodes, "gesture": gesture, "place": place, "token": token,
                ]) as? [String: Any]
                if reply?["contextReset"] as? Bool == true { self.consoleStore.context = nil }
                guard let raw = reply?["value"] as? [String: Any] else { return }
                let object = ConsoleRemoteObject(raw)
                let thrown = reply?["wasThrown"] as? Bool == true
                // Chrome quotes a string result, unlike a logged string.
                var text = ConsoleFormat.inline(object, nested: true)
                if thrown { text = "Uncaught " + (object.description ?? text) }
                var line = ConsoleLine(level: thrown ? "error" : "result", text: String(text.prefix(8_192)))
                line.details = ConsoleMessageDetails(type: "result", timestamp: Date().timeIntervalSince1970,
                                                     targetID: target, parameters: [object])
                self.consoleStore.followRequest += 1
                // The result goes where the reply came among the events (see
                // searchInspector.mark), or last if that mark was missed.
                self.awaitingConsoleResults[token] = line
                _ = try? await self.drain()
                if let line = self.awaitingConsoleResults.removeValue(forKey: token) { self.appendConsoleLine(line) }
            } catch is CancellationError {
            } catch {
                if self.ready { self.appendConsoleLine(ConsoleLine(level: "error", text: error.localizedDescription)) }
            }
        }
    }

    /// Reads the contexts for the selector, as it opens. A chosen context
    /// that is gone falls back to `top`, as in Chrome.
    func refreshConsoleContexts() {
        guard ready else { return }
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.bridge("return searchConsole.contexts();") as? [[String: Any]]
            let list = (reply ?? []).compactMap(ConsoleExecutionContext.init)
            guard reply != nil else { return }
            if self.consoleStore.contexts != list { self.consoleStore.contexts = list }
            if let chosen = self.consoleStore.context, !list.contains(where: { $0.id == chosen.id }) {
                self.consoleStore.context = nil
            }
        }
    }

    /// A logged Error's `stack`, which WebKit keeps out of its description.
    func loadConsoleErrorStack(_ object: ConsoleRemoteObject, targetID: String?) {
        guard let id = object.objectId, consoleStore.errorStacks[id] == nil, !consoleStore.loading.contains("stack:" + id) else { return }
        consoleStore.loading.insert("stack:" + id)
        Task { [weak self] in
            guard let self else { return }
            let stack = try? await self.bridge("return await searchConsole.errorStack(objectId, target);", [
                "objectId": id, "target": targetID as Any? ?? NSNull(),
            ]) as? String
            self.consoleStore.setErrorStack(stack, for: id)
        }
    }

    /// A logged node's element and its children, for the console's tree.
    func loadConsoleNodeTree(_ object: ConsoleRemoteObject, targetID: String?) {
        guard let id = object.objectId, consoleStore.nodeTrees[id] == nil, !consoleStore.loading.contains("node:" + id) else { return }
        consoleStore.loading.insert("node:" + id)
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.bridge("return await searchConsole.nodeTree(objectId, target);", [
                "objectId": id, "target": targetID as Any? ?? NSNull(),
            ]) as? [String: Any]
            self.consoleStore.setNodeTree(ConsoleNodeTree(reply ?? [:]), for: id)
        }
    }

    /// As in Chrome DevTools: hovering a logged node highlights it on the
    /// page; WebKit highlights straight from the node's object id.
    func highlightConsoleNode(_ object: ConsoleRemoteObject?, targetID: String?) {
        consoleStore.highlight?.cancel()
        guard ready else { return }
        guard let id = object?.objectId, object?.isNode == true else {
            consoleStore.highlight = Task { [weak self] in _ = try? await self?.command("DOM.hideHighlight") }
            return
        }
        consoleStore.highlight = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            _ = try? await self.command("DOM.highlightNode", [
                "objectId": id, "highlightConfig": ["contentColor": ["r": 70, "g": 160, "b": 150, "a": 0.27]],
            ], targetID: targetID ?? self.domTargetID)
        }
    }

    /// "Store as global variable" on a nested property: its own object
    /// when it has one, else the parent's property by name.
    func storeConsolePropertyAsGlobal(_ value: ConsoleRemoteObject, name: String, parent: ConsoleRemoteObject?, targetID: String?) {
        if value.objectId != nil { storeConsoleObjectAsGlobal(value, targetID: targetID); return }
        guard let parentID = parent?.objectId else { return }
        Task { [weak self] in
            guard let self else { return }
            let stored = try? await self.bridge("return await searchConsole.storePropertyAsGlobal(objectId, name, target);", [
                "objectId": parentID, "name": name, "target": targetID as Any? ?? NSNull(),
            ]) as? String
            if let stored { self.evaluateInConsole(stored) }
        }
    }

    /// A link in a message: a script location opens in Sources, as in
    /// Chrome; any other address opens in a new tab.
    func openConsoleLink(_ url: URL) {
        if let source = ConsoleLinks.source(url) {
            revealConsoleSource(url: source.url, line: source.line)
        } else if let scheme = url.scheme?.lowercased(), scheme != "search-console", scheme != "javascript" {
            DevHost.open(url)
        }
    }

    /// Loads an object's properties for its disclosure triangle.
    func loadConsoleProperties(_ object: ConsoleRemoteObject, targetID: String?) {
        guard let id = object.objectId, consoleStore.properties[id] == nil, !consoleStore.loading.contains(id) else { return }
        consoleStore.loading.insert(id)
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.bridge("return await searchConsole.properties(objectId, subtype, target);", [
                "objectId": id, "subtype": object.subtype as Any? ?? NSNull(), "target": targetID as Any? ?? NSNull(),
            ]) as? [String: Any]
            let list = (reply?["properties"] as? [[String: Any]] ?? []).map(ConsoleProperty.init)
            self.consoleStore.setProperties(Self.ordered(list), for: id, more: reply?["more"] as? Bool == true)
        }
    }

    /// Chrome lists an object's properties in insertion order for arrays and
    /// sorted otherwise, with non-enumerable ones after, then the internal
    /// slots and [[Prototype]] last.
    nonisolated static func ordered(_ list: [ConsoleProperty]) -> [ConsoleProperty] {
        func rank(_ property: ConsoleProperty) -> Int {
            if property.name == "[[Entries]]" { return 2 }
            if property.name == "[[Prototype]]" { return 5 }
            if property.isInternal || property.name.hasPrefix("[[") { return 4 }
            if Int(property.name) != nil { return 0 }
            if property.name == "length" { return 3 }
            return property.enumerable ? 1 : 3
        }
        return list.enumerated().sorted { left, right in
            let (a, b) = (rank(left.element), rank(right.element))
            if a != b { return a < b }
            if let x = Int(left.element.name), let y = Int(right.element.name) { return x < y }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Calls a user getter when its "(...)" is clicked, as Chrome does.
    func invokeConsoleGetter(_ property: ConsoleProperty, of object: ConsoleRemoteObject, targetID: String?) {
        guard let id = object.objectId else { return }
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.bridge("return await searchConsole.invokeGetter(objectId, name, target);", [
                "objectId": id, "name": property.name, "target": targetID as Any? ?? NSNull(),
            ]) as? [String: Any]
            guard let raw = reply?["value"] as? [String: Any] else { return }
            var updated = property
            updated.getter = false
            updated.value = ConsoleRemoteObject(raw)
            updated.wasThrown = reply?["wasThrown"] as? Bool == true
            self.consoleStore.replaceProperty(updated, in: id)
        }
    }

    /// Shows a logged node in the Elements panel. Entering Elements reads
    /// the document afresh, which renumbers WebKit's nodes, so the node is
    /// asked for once that is done.
    @discardableResult
    func revealConsoleNode(_ object: ConsoleRemoteObject, targetID: String?) -> Task<Bool, Never>? {
        guard let id = object.objectId else { return nil }
        let switching = panel != .elements
        let before = root
        select(.elements)
        return Task { [weak self] in
            for _ in 0..<40 where switching {
                guard let self, self.root == before || self.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return false }
            let node = try? await self.bridge("return await searchConsole.nodeId(objectId, null);", ["objectId": id]) as? Int
            guard let node, node > 0 else { return false }
            for _ in 0..<40 where self.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.selectNode(node)
            return true
        }
    }

    /// Opens a console link's file in Sources at its line (1-based, as
    /// the console shows it).
    func revealConsoleSource(url: String, line: Int?) {
        revealSource(url: url, line: line ?? 1)
    }

    /// The eager preview under the prompt, for reads that cannot run page code.
    func consoleEagerPreview(_ expression: String) async -> ConsoleRemoteObject? {
        guard ready else { return nil }
        let reply = try? await bridge("return await searchConsole.eager(expression, node, null, place);", [
            "expression": expression, "node": selectedNode as Any? ?? NSNull(), "place": consolePlace(),
        ]) as? [String: Any]
        return (reply?["value"] as? [String: Any]).map(ConsoleRemoteObject.init)
    }

    /// Property and global names for the word before the caret; while
    /// paused, also the selected frame's variables. `force` is ⌃Space,
    /// which lists names with nothing typed yet.
    func consoleCompletions(_ text: String, force: Bool = false) async -> (prefix: String, names: [String]) {
        guard ready else { return ("", []) }
        let reply = try? await bridge("return await searchConsole.completions(text, null, place);", [
            "text": text, "place": consolePlace(completing: true, force: force),
        ]) as? [String: Any]
        return (reply?["prefix"] as? String ?? "", reply?["names"] as? [String] ?? [])
    }
}
