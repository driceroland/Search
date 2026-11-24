import Foundation

// Chrome DevTools' Recorder panel, its pure part: a recording (a user
// flow) in Chrome's Recorder JSON format, the steps as the panel edits
// them, the rules that fold what the page reports into steps (typing into
// one `change`, a double click's two clicks into one `doubleClick`, a
// navigation onto the step that caused it), the selector strings, and
// the exports: Chrome's JSON, a @puppeteer/replay script and a Puppeteer
// script. The page scripts are Resources/js/DeveloperRecorder-*.js; the
// recording and replay against a page is DeveloperRecorderModel.swift.

// MARK: JSON

/// A JSON value that keeps an object's keys in order, so a recording is
/// written exactly as Chrome writes one (JSON.stringify(flow, null, 2)).
indirect enum DeveloperRecorderJSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DeveloperRecorderJSON])
    case object([(String, DeveloperRecorderJSON)])

    static func == (a: DeveloperRecorderJSON, b: DeveloperRecorderJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            // Order doesn't make two objects different values.
            guard x.count == y.count else { return false }
            let other = Dictionary(y, uniquingKeysWith: { first, _ in first })
            return x.allSatisfy { other[$0.0] == $0.1 }
        default: return false
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [DeveloperRecorderJSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [(String, DeveloperRecorderJSON)]? { if case .object(let o) = self { return o }; return nil }

    subscript(key: String) -> DeveloperRecorderJSON? {
        object?.first { $0.0 == key }?.1
    }

    /// From what JSONSerialization (or a page's message) gives.
    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { DeveloperRecorderJSON($0) })
        case let object as [String: Any]:
            self = .object(object.keys.sorted().map { ($0, DeveloperRecorderJSON(object[$0])) })
        default: self = .null
        }
    }

    /// What JSONSerialization (and a page script's arguments) take.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o):
            var result: [String: Any] = [:]
            for (key, value) in o { result[key] = value.any }
            return result
        }
    }

    static func parse(_ data: Data) throws -> DeveloperRecorderJSON {
        DeveloperRecorderJSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// As JSON.stringify(value, null, indent) writes it.
    func stringified(indent: Int = 2) -> String {
        written(indent: String(repeating: " ", count: indent), level: 0, string: Self.quote, key: Self.quote)
    }

    /// Laid out as JSON.stringify lays it out, `indent` a level, with
    /// strings and keys as `string` and `key` write them.
    func written(indent: String, level: Int, string: (String) -> String, key: (String) -> String) -> String {
        let inner = String(repeating: indent, count: level + 1)
        let outer = String(repeating: indent, count: level)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return Self.format(n)
        case .string(let s): return string(s)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.written(indent: indent, level: level + 1, string: string, key: key) }
                .joined(separator: ",\n") + "\n" + outer + "]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            return "{\n" + fields.map { name, value in
                inner + key(name) + ": " + value.written(indent: indent, level: level + 1, string: string, key: key)
            }.joined(separator: ",\n") + "\n" + outer + "}"
        }
    }

    /// A number as JavaScript prints it: 12, not 12.0; NaN and infinity as null.
    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    /// A string as JSON.stringify quotes it.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: Selectors

/// The kinds of selector Chrome's Recorder records, in the order a step lists them.
enum DeveloperRecorderSelectorType: String, CaseIterable, Identifiable, Codable {
    case aria, css, xpath, pierce, text

    var id: Self { self }

    var title: String {
        switch self {
        case .css: "CSS"
        case .aria: "ARIA"
        case .text: "Text"
        case .xpath: "XPath"
        case .pierce: "Pierce"
        }
    }

    /// The prefix a selector of this kind starts with; CSS has none.
    var prefix: String {
        switch self {
        case .css: ""
        default: rawValue + "/"
        }
    }
}

/// Selector strings as Chrome writes them, and as Puppeteer reads them.
enum DeveloperRecorderSelector {
    /// A selector's kind, from its prefix.
    static func kind(of selector: String) -> DeveloperRecorderSelectorType {
        for type in DeveloperRecorderSelectorType.allCases where type != .css && selector.hasPrefix(type.prefix) {
            return type
        }
        return .css
    }

    /// A selector without its prefix.
    static func body(of selector: String) -> String {
        String(selector.dropFirst(kind(of: selector).prefix.count))
    }

    /// The selectors a step keeps: the kinds chosen, in Chrome's order.
    static func filter(_ selectors: [[String]], to types: Set<DeveloperRecorderSelectorType>) -> [[String]] {
        selectors.filter { parts in parts.first.map { types.contains(kind(of: $0)) } ?? false }
    }

    /// One selector (its parts across shadow roots) as a Puppeteer
    /// locator's selector: `::-p-aria(…)`, `::-p-xpath(…)`, `:scope >>> …`,
    /// `::-p-text(…)` or the CSS itself, parts joined by ` >>>> `.
    static func puppeteer(_ parts: [String]) -> String {
        parts.map { part in
            let body = body(of: part)
            switch kind(of: part) {
            case .css: return part
            case .aria: return "::-p-aria(\(pseudoArgument(body)))"
            case .xpath: return "::-p-xpath(\(pseudoArgument(body)))"
            case .text: return "::-p-text(\(pseudoArgument(body)))"
            case .pierce: return ":scope >>> " + body
            }
        }.joined(separator: " >>>> ")
    }

    /// Quotes and backslashes in a P-selector's argument are escaped, as
    /// Chrome's export does.
    private static func pseudoArgument(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: Steps

/// A step's kind, as Chrome's Recorder and @puppeteer/replay name them.
enum DeveloperRecorderStepType: String, CaseIterable, Identifiable {
    case setViewport, navigate, click, doubleClick, change, keyDown, keyUp, scroll, hover
    case waitForElement, waitForExpression, close, customStep, emulateNetworkConditions

    var id: Self { self }

    /// Whether the step acts on an element (and so has selectors).
    var targetsElement: Bool {
        [.click, .doubleClick, .change, .hover, .waitForElement].contains(self)
    }

    /// The fields the panel offers for it, beyond the type.
    var editableFields: [String] {
        switch self {
        case .setViewport: ["width", "height", "deviceScaleFactor", "isMobile", "hasTouch", "isLandscape"]
        case .navigate: ["url", "timeout"]
        case .click, .doubleClick: ["target", "offsetX", "offsetY", "button", "deviceType", "duration", "timeout"]
        case .change: ["target", "value", "timeout"]
        case .keyDown, .keyUp: ["target", "key", "timeout"]
        case .scroll: ["target", "x", "y", "timeout"]
        case .hover: ["target", "timeout"]
        case .waitForElement: ["target", "count", "operator", "visible", "timeout"]
        case .waitForExpression: ["target", "expression", "timeout"]
        case .close: ["target"]
        case .customStep: ["name", "target"]
        case .emulateNetworkConditions: ["download", "upload", "latency"]
        }
    }

    /// A new step of this kind, as Chrome's Add step makes one.
    var template: [(String, DeveloperRecorderJSON)] {
        switch self {
        case .setViewport:
            [("width", .number(1280)), ("height", .number(720)), ("deviceScaleFactor", .number(1)),
             ("isMobile", .bool(false)), ("hasTouch", .bool(false)), ("isLandscape", .bool(false))]
        case .navigate: [("url", .string("https://example.com"))]
        case .click, .doubleClick: [("target", .string("main")), ("selectors", .array([.array([.string("body")])])),
                                    ("offsetY", .number(0)), ("offsetX", .number(0))]
        case .change: [("value", .string("")), ("selectors", .array([.array([.string("body")])])), ("target", .string("main"))]
        case .keyDown, .keyUp: [("target", .string("main")), ("key", .string("Enter"))]
        case .scroll: [("target", .string("main")), ("x", .number(0)), ("y", .number(0))]
        case .hover, .waitForElement: [("target", .string("main")), ("selectors", .array([.array([.string("body")])]))]
        case .waitForExpression: [("target", .string("main")), ("expression", .string("true"))]
        case .close: [("target", .string("main"))]
        case .customStep: [("name", .string("customParam")), ("parameters", .object([])), ("target", .string("main"))]
        case .emulateNetworkConditions: DeveloperRecorderNetwork.fields(.threeG)
        }
    }
}

/// An event a step waits for after it runs: the page it navigates to.
struct DeveloperRecorderAssertedEvent: Equatable {
    var type = "navigation"
    var url: String?
    var title: String?

    var json: DeveloperRecorderJSON {
        var fields: [(String, DeveloperRecorderJSON)] = [("type", .string(type))]
        if let url { fields.append(("url", .string(url))) }
        if let title { fields.append(("title", .string(title))) }
        return .object(fields)
    }
}

extension DeveloperRecorderAssertedEvent {
    init?(_ json: DeveloperRecorderJSON) {
        guard let type = json["type"]?.string else { return nil }
        self.init(type: type, url: json["url"]?.string, title: json["title"]?.string)
    }
}

/// One step of a recording. Its fields are kept as Chrome's JSON has
/// them, so a step imported with fields the panel doesn't know goes back
/// out with them; the typed properties read and write those fields.
struct DeveloperRecorderStep: Identifiable, Equatable {
    var id = UUID()
    /// Every field but `type`.
    var fields: [String: DeveloperRecorderJSON]
    var type: String
    /// The panel's breakpoint: replay stops before running the step.
    var breakpoint = false

    init(id: UUID = UUID(), type: String, fields: [String: DeveloperRecorderJSON] = [:], breakpoint: Bool = false) {
        self.id = id
        self.type = type
        self.fields = fields
        self.breakpoint = breakpoint
    }

    init(_ kind: DeveloperRecorderStepType) {
        self.init(type: kind.rawValue, fields: Dictionary(kind.template, uniquingKeysWith: { first, _ in first }))
    }

    var kind: DeveloperRecorderStepType? { DeveloperRecorderStepType(rawValue: type) }

    subscript(key: String) -> DeveloperRecorderJSON? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    private func number(_ key: String) -> Double? { fields[key]?.number }
    private mutating func setNumber(_ key: String, _ value: Double?) { fields[key] = value.map { .number($0) } }
    private func text(_ key: String) -> String? { fields[key]?.string }
    private mutating func setText(_ key: String, _ value: String?) { fields[key] = value.map { .string($0) } }

    var target: String? { get { text("target") } set { setText("target", newValue) } }
    var value: String? { get { text("value") } set { setText("value", newValue) } }
    var key: String? { get { text("key") } set { setText("key", newValue) } }
    var url: String? { get { text("url") } set { setText("url", newValue) } }
    var button: String? { get { text("button") } set { setText("button", newValue) } }
    var offsetX: Double? { get { number("offsetX") } set { setNumber("offsetX", newValue) } }
    var offsetY: Double? { get { number("offsetY") } set { setNumber("offsetY", newValue) } }
    var x: Double? { get { number("x") } set { setNumber("x", newValue) } }
    var y: Double? { get { number("y") } set { setNumber("y", newValue) } }
    var timeout: Double? { get { number("timeout") } set { setNumber("timeout", newValue) } }

    /// Each alternative, as the parts of a path through shadow roots and frames.
    var selectors: [[String]] {
        get {
            (fields["selectors"]?.array ?? []).compactMap { item in
                if let parts = item.array { return parts.compactMap(\.string) }
                if let single = item.string { return [single] }
                return nil
            }
        }
        set {
            fields["selectors"] = newValue.isEmpty ? nil : .array(newValue.map { .array($0.map { .string($0) }) })
        }
    }

    var assertedEvents: [DeveloperRecorderAssertedEvent] {
        get { (fields["assertedEvents"]?.array ?? []).compactMap(DeveloperRecorderAssertedEvent.init) }
        set { fields["assertedEvents"] = newValue.isEmpty ? nil : .array(newValue.map(\.json)) }
    }

    var assertsNavigation: Bool { assertedEvents.contains { $0.type == "navigation" } }

    /// The order Chrome's Recorder writes a step's fields in; any others follow, sorted.
    static func fieldOrder(for type: String) -> [String] {
        if type == DeveloperRecorderStepType.change.rawValue {
            return ["type", "value", "selectors", "target", "frame", "timeout", "assertedEvents"]
        }
        return ["type", "target", "frame", "selectors", "offsetY", "offsetX", "button", "deviceType", "duration",
                "value", "key", "url", "x", "y", "width", "height", "deviceScaleFactor", "isMobile", "hasTouch",
                "isLandscape", "count", "operator", "visible", "attributes", "properties", "expression", "name",
                "parameters", "download", "upload", "latency", "timeout", "assertedEvents"]
    }

    var json: DeveloperRecorderJSON {
        let order = Self.fieldOrder(for: type)
        var out: [(String, DeveloperRecorderJSON)] = [("type", .string(type))]
        for key in order.dropFirst() {
            guard let value = fields[key] else { continue }
            if key == "assertedEvents", let events = value.array {
                // An event's fields in Chrome's order too: type, url, title.
                out.append((key, .array(events.map { Self.ordered($0, first: ["type", "url", "title"]) })))
            } else {
                out.append((key, value))
            }
        }
        for key in fields.keys.sorted() where !order.contains(key) { out.append((key, fields[key]!)) }
        return .object(out)
    }

    private static func ordered(_ value: DeveloperRecorderJSON, first: [String]) -> DeveloperRecorderJSON {
        guard let object = value.object else { return value }
        let known = first.compactMap { key in object.first { $0.0 == key } }
        let rest = object.filter { !first.contains($0.0) }.sorted { $0.0 < $1.0 }
        return .object(known + rest)
    }

    init?(json: DeveloperRecorderJSON) {
        guard let object = json.object, let type = json["type"]?.string else { return nil }
        var fields: [String: DeveloperRecorderJSON] = [:]
        for (key, value) in object where key != "type" { fields[key] = value }
        self.init(type: type, fields: fields)
    }

    /// The row's title in the steps list, as Chrome words it.
    var title: String {
        switch kind {
        case .setViewport: "Set viewport"
        case .navigate: "Navigate"
        case .click: button == "secondary" ? "Right click" : "Click"
        case .doubleClick: "Double click"
        case .change: "Change"
        case .keyDown: "Key down"
        case .keyUp: "Key up"
        case .scroll: "Scroll"
        case .hover: "Hover"
        case .waitForElement: "Wait for element"
        case .waitForExpression: "Wait for expression"
        case .close: "Close"
        case .customStep: "Custom step"
        case .emulateNetworkConditions: "Emulate network conditions"
        case nil: type
        }
    }

    /// The row's subtitle: what it acts on.
    var subtitle: String {
        switch kind {
        case .setViewport:
            let width = fields["width"]?.number.map(DeveloperRecorderJSON.format) ?? "?"
            let height = fields["height"]?.number.map(DeveloperRecorderJSON.format) ?? "?"
            return "\(width)×\(height)"
        case .navigate: return url ?? ""
        case .keyDown, .keyUp: return key ?? ""
        case .change: return (selectors.first?.joined(separator: " ") ?? "") + (value.map { " · “\($0)”" } ?? "")
        case .scroll where selectors.isEmpty:
            return "window → \(DeveloperRecorderJSON.format(x ?? 0)), \(DeveloperRecorderJSON.format(y ?? 0))"
        case .waitForExpression: return fields["expression"]?.string ?? ""
        case .emulateNetworkConditions: return DeveloperRecorderNetwork.condition(of: self)?.rawValue ?? "Custom"
        default: return selectors.first?.joined(separator: " ") ?? ""
        }
    }
}

// MARK: Recordings

/// A recording: its title and steps, Chrome's top-level fields, and the
/// selector kinds it was recorded with.
struct DeveloperRecording: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var steps: [DeveloperRecorderStep] = []
    var selectorAttribute: String?
    var timeout: Double?
    /// Top-level fields beyond Chrome's three.
    var extra: [String: DeveloperRecorderJSON] = [:]
    var selectorTypes: Set<DeveloperRecorderSelectorType> = Set(DeveloperRecorderSelectorType.allCases)
    var created = Date()
}

extension DeveloperRecording {
    /// Chrome's default name for a new recording: "Recording 22/11/2026 at 10:04:31".
    static func defaultTitle(_ date: Date = Date(), locale: Locale = .current) -> String {
        func format(_ dateStyle: DateFormatter.Style, _ timeStyle: DateFormatter.Style) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            return formatter.string(from: date)
        }
        return "Recording \(format(.short, .none)) at \(format(.none, .medium))"
    }

    // MARK: Chrome's JSON

    var json: DeveloperRecorderJSON {
        var fields: [(String, DeveloperRecorderJSON)] = [("title", .string(title))]
        if let selectorAttribute { fields.append(("selectorAttribute", .string(selectorAttribute))) }
        if let timeout { fields.append(("timeout", .number(timeout))) }
        for key in extra.keys.sorted() { fields.append((key, extra[key]!)) }
        fields.append(("steps", .array(steps.map(\.json))))
        return .object(fields)
    }

    /// What Chrome's Export › JSON writes.
    var exportedJSON: String { json.stringified(indent: 2) + "\n" }

    init(json: DeveloperRecorderJSON) throws {
        guard let object = json.object else { throw DeveloperPanelError("A recording is a JSON object.") }
        guard let steps = json["steps"]?.array else { throw DeveloperPanelError("The recording has no steps.") }
        var parsed: [DeveloperRecorderStep] = []
        for (index, raw) in steps.enumerated() {
            guard let step = DeveloperRecorderStep(json: raw) else {
                throw DeveloperPanelError("Step \(index + 1) has no type.")
            }
            parsed.append(step)
        }
        self.init(title: json["title"]?.string ?? "Imported recording", steps: parsed,
                  selectorAttribute: json["selectorAttribute"]?.string, timeout: json["timeout"]?.number)
        for (key, value) in object where !["title", "steps", "selectorAttribute", "timeout"].contains(key) {
            extra[key] = value
        }
        // The kinds a recording was made with are the ones its steps use.
        let used = Set(parsed.flatMap(\.selectors).compactMap(\.first).map(DeveloperRecorderSelector.kind(of:)))
        if !used.isEmpty { selectorTypes = used }
    }

    init(data: Data) throws {
        try self.init(json: DeveloperRecorderJSON.parse(data))
    }

    // MARK: Saved

    /// How the panel keeps it between launches: Chrome's JSON plus what
    /// the panel adds (its id, breakpoints, selector kinds, when it was made).
    var saved: [String: Any] {
        [
            "id": id.uuidString,
            "created": created.timeIntervalSince1970,
            "selectorTypes": selectorTypes.map(\.rawValue).sorted(),
            "breakpoints": steps.indices.filter { steps[$0].breakpoint },
            "flow": json.any,
        ]
    }

    init?(saved: [String: Any]) {
        guard let flow = saved["flow"], var recording = try? DeveloperRecording(json: DeveloperRecorderJSON(flow)) else { return nil }
        if let id = (saved["id"] as? String).flatMap(UUID.init) { recording.id = id }
        if let created = saved["created"] as? Double { recording.created = Date(timeIntervalSince1970: created) }
        let types = Set((saved["selectorTypes"] as? [String] ?? []).compactMap(DeveloperRecorderSelectorType.init))
        if !types.isEmpty { recording.selectorTypes = types }
        for index in saved["breakpoints"] as? [Int] ?? [] where recording.steps.indices.contains(index) {
            recording.steps[index].breakpoint = true
        }
        self = recording
    }
}

// MARK: Folding what the page reports

/// How a recording grows as the page reports what was done.
enum DeveloperRecorderFlow {
    /// How long after an action a page load still counts as its doing.
    static let navigationWindow: TimeInterval = 5

    /// The steps a recording starts with, as Chrome's: the viewport, then the page.
    static func opening(width: Double, height: Double, scale: Double, url: String, title: String?) -> [DeveloperRecorderStep] {
        let viewport = DeveloperRecorderStep(type: "setViewport", fields: [
            "width": .number(width.rounded()), "height": .number(height.rounded()), "deviceScaleFactor": .number(scale),
            "isMobile": .bool(false), "hasTouch": .bool(false), "isLandscape": .bool(false),
        ])
        var navigate = DeveloperRecorderStep(type: "navigate", fields: ["url": .string(url)])
        navigate.assertedEvents = [DeveloperRecorderAssertedEvent(url: url, title: title ?? "")]
        return [viewport, navigate]
    }

    /// A step the page reported, folded into the steps: typing into the
    /// same field is one `change` with the final value; a double click
    /// replaces the clicks it began with; scrolling the same thing again
    /// is one `scroll` at where it ended.
    static func append(_ step: DeveloperRecorderStep, to steps: inout [DeveloperRecorderStep]) {
        let last = steps.last
        switch step.kind {
        case .change:
            if let last, last.kind == .change, last.selectors == step.selectors, !last.assertsNavigation {
                steps[steps.count - 1].value = step.value
                return
            }
        case .doubleClick:
            var removed = 0
            while removed < 2, let tail = steps.last, tail.kind == .click, tail.selectors == step.selectors,
                  tail.button == step.button, !tail.assertsNavigation {
                steps.removeLast()
                removed += 1
            }
        case .scroll:
            if let last, last.kind == .scroll, last.selectors == step.selectors {
                steps[steps.count - 1].x = step.x
                steps[steps.count - 1].y = step.y
                return
            }
        default:
            break
        }
        steps.append(step)
    }

    /// The page reported that it loaded. The recording's first page fills
    /// in the opening navigate step's title; a load soon after a click, a
    /// key or a change is that step's doing and is asserted on it, as
    /// Chrome records it; any other is a `navigate` step of its own (an
    /// address typed, a reload).
    static func loaded(url: String, title: String, into steps: inout [DeveloperRecorderStep],
                       lastAction: Date?, now: Date = Date(), first: Bool) {
        let event = DeveloperRecorderAssertedEvent(url: url, title: title)
        if first, let index = steps.lastIndex(where: { $0.kind == .navigate }) {
            steps[index].assertedEvents = [event]
            return
        }
        let causes: Set<DeveloperRecorderStepType> = [.click, .doubleClick, .keyDown, .keyUp, .change]
        if let lastAction, now.timeIntervalSince(lastAction) <= navigationWindow,
           var index = steps.indices.last, let kind = steps[index].kind, causes.contains(kind) {
            // Enter's navigation is the key going down, not up.
            if kind == .keyUp, index > 0, steps[index - 1].kind == .keyDown, steps[index - 1].key == steps[index].key {
                index -= 1
            }
            if !steps[index].assertsNavigation {
                steps[index].assertedEvents.append(event)
                return
            }
        }
        var navigate = DeveloperRecorderStep(type: "navigate", fields: ["url": .string(url)])
        navigate.assertedEvents = [event]
        steps.append(navigate)
    }

    /// A step from a page message: `{type, selectors, offsetX, …}`, the
    /// selectors kept to the kinds chosen.
    static func step(from message: [String: Any], types: Set<DeveloperRecorderSelectorType>) -> DeveloperRecorderStep? {
        guard let step = DeveloperRecorderStep(json: DeveloperRecorderJSON(message)), step.kind != nil else { return nil }
        var result = step
        if step.fields["selectors"] != nil {
            result.selectors = DeveloperRecorderSelector.filter(step.selectors, to: types)
            if result.selectors.isEmpty, step.kind?.targetsElement == true { return nil }
        }
        if result.target == nil, result.kind != .navigate, result.kind != .setViewport { result.target = "main" }
        return result
    }
}

// MARK: Replay settings

/// Replay settings › Network, kept as Chrome keeps it: an
/// `emulateNetworkConditions` step after the viewport, in bytes a second
/// and milliseconds as Chromium's presets give them. Replay applies it
/// with the Network conditions tool's throttling.
enum DeveloperRecorderNetwork {
    typealias Condition = DeveloperToolsSession.NetworkCondition

    static func fields(_ condition: Condition) -> [(String, DeveloperRecorderJSON)] {
        let speeds: (download: Double, upload: Double)
        switch condition {
        case .fast4G: speeds = (9 * 1_000 * 1_000 / 8 * 0.9, 1.5 * 1_000 * 1_000 / 8 * 0.9)
        case .slow4G: speeds = (1.6 * 1_000 * 1_000 / 8 * 0.9, 750 * 1_000 / 8 * 0.9)
        case .threeG: speeds = (500 * 1_000 / 8 * 0.8, 500 * 1_000 / 8 * 0.8)
        case .offline, .unrestricted: speeds = (0, 0)
        }
        return [("download", .number(speeds.download)), ("upload", .number(speeds.upload)),
                ("latency", .number(condition.latency))]
    }

    /// The preset a step names: offline when nothing gets through, else
    /// the preset with the nearest latency.
    static func condition(of step: DeveloperRecorderStep) -> Condition? {
        guard step.kind == .emulateNetworkConditions else { return nil }
        if step["download"]?.number == 0, step["upload"]?.number == 0 { return .offline }
        guard let latency = step["latency"]?.number else { return nil }
        let presets: [Condition] = [.fast4G, .slow4G, .threeG]
        return presets.min { abs($0.latency - latency) < abs($1.latency - latency) }
    }

    /// The network a replay runs under: the recording's first
    /// `emulateNetworkConditions` step, or none.
    static func condition(of recording: DeveloperRecording) -> Condition {
        for step in recording.steps {
            if let condition = condition(of: step) { return condition }
        }
        return .unrestricted
    }

    /// Sets Replay settings › Network: updates the first
    /// `emulateNetworkConditions` step, adds one after the viewport, or
    /// takes it out for No throttling.
    static func set(_ condition: Condition, in recording: inout DeveloperRecording) {
        let existing = recording.steps.firstIndex { $0.kind == .emulateNetworkConditions }
        if condition == .unrestricted {
            if let existing { recording.steps.remove(at: existing) }
            return
        }
        let values = Dictionary(fields(condition), uniquingKeysWith: { first, _ in first })
        if let existing {
            for (key, value) in values { recording.steps[existing][key] = value }
            return
        }
        let step = DeveloperRecorderStep(type: DeveloperRecorderStepType.emulateNetworkConditions.rawValue, fields: values)
        let after = recording.steps.firstIndex { $0.kind == .setViewport }.map { $0 + 1 } ?? 0
        recording.steps.insert(step, at: after)
    }
}

extension DeveloperRecorderFlow {
    /// Chrome's Add assertion while recording: a `waitForElement` for the
    /// element the last step acted on, or for the page's body when no step
    /// has acted on one yet.
    static func assertion(after steps: [DeveloperRecorderStep]) -> DeveloperRecorderStep {
        var step = DeveloperRecorderStep(.waitForElement)
        guard let last = steps.last(where: { !$0.selectors.isEmpty }) else { return step }
        step.selectors = last.selectors
        step.target = last.target ?? "main"
        if let frame = last["frame"] { step["frame"] = frame }
        return step
    }
}

// MARK: Replay speed

/// Replay's speeds, as Chrome offers them: a pause between steps.
enum DeveloperRecorderSpeed: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case slow = "Slow"
    case verySlow = "Very slow"
    case extremelySlow = "Extremely slow"

    var id: Self { self }

    var delay: Duration {
        switch self {
        case .normal: .zero
        case .slow: .milliseconds(500)
        case .verySlow: .milliseconds(1000)
        case .extremelySlow: .milliseconds(2000)
        }
    }
}

// MARK: Exports

enum DeveloperRecorderExport {
    /// Puppeteer's default wait, and Chrome's.
    static let defaultTimeout = 5000.0

    /// A JavaScript string literal, single-quoted.
    static func jsString(_ text: String) -> String {
        var out = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "'": out += "\\'"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\x%02x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "'"
    }

    /// A JSON value as a JavaScript literal, as @puppeteer/replay writes a
    /// step: unquoted keys where they can be, single-quoted strings.
    static func jsLiteral(_ value: DeveloperRecorderJSON, indent: String = "  ", level: Int = 0) -> String {
        value.written(indent: indent, level: level, string: jsString, key: jsKey)
    }

    private static func jsKey(_ key: String) -> String {
        let identifier = key.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        return identifier ? key : jsString(key)
    }

    /// Export › @puppeteer/replay: a script that runs the flow with
    /// @puppeteer/replay's runner, as Chrome writes it.
    static func puppeteerReplay(_ recording: DeveloperRecording) -> String {
        var lines = [
            "import url from 'url';",
            "import { createRunner } from '@puppeteer/replay';",
            "",
            "export async function run(extension) {",
            "  const runner = await createRunner(extension);",
            "",
            "  await runner.runBeforeAllSteps();",
            "",
        ]
        for step in recording.steps {
            lines.append("  await runner.runStep(" + jsLiteral(step.json, indent: "  ", level: 1) + ");")
        }
        lines += [
            "",
            "  await runner.runAfterAllSteps();",
            "}",
            "",
            "if (process && import.meta.url === url.pathToFileURL(process.argv[1]).href) {",
            "  run()",
            "}",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Export › Puppeteer: a script of Puppeteer calls, step by step, as
    /// Chrome's Puppeteer export writes it. Export › Puppeteer (for Firefox)
    /// is the same script launching Firefox.
    static func puppeteer(_ recording: DeveloperRecording, firefox: Bool = false) -> String {
        var out = puppeteerHead(recording, firefox: firefox)
        for step in recording.steps {
            out += puppeteerStep(step).map { "    " + $0 }
        }
        out += puppeteerTail
        return out.joined(separator: "\n")
    }

    private static func puppeteerHead(_ recording: DeveloperRecording, firefox: Bool) -> [String] {
        let timeout = recording.timeout ?? defaultTimeout
        let launch = firefox
            ? ["    const browser = await puppeteer.launch({", "        browser: 'firefox'", "    });"]
            : ["    const browser = await puppeteer.launch();"]
        return [
            "const puppeteer = require('puppeteer'); // v23.0.0 or later",
            "",
            "(async () => {",
        ] + launch + [
            "    const page = await browser.newPage();",
            "    const timeout = \(DeveloperRecorderJSON.format(timeout));",
            "    page.setDefaultTimeout(timeout);",
            "",
        ]
    }

    private static let puppeteerTail = [
        "",
        "    await browser.close();",
        "",
        "})().catch(err => {",
        "    console.error(err);",
        "    process.exit(1);",
        "});",
        "",
    ]

    /// Export › Puppeteer (including Lighthouse analysis): the Puppeteer
    /// script run as a Lighthouse user flow, as Chrome writes it. Each
    /// navigation is a navigation of the flow; the steps between are
    /// timespans; the flow's HTML report is written beside the script.
    static func puppeteerLighthouse(_ recording: DeveloperRecording) -> String {
        var head = puppeteerHead(recording, firefox: false)
        head[0] = "const fs = require('fs');"
        head.insert("const puppeteer = require('puppeteer'); // v23.0.0 or later", at: 1)
        let mobile = recording.steps.first { $0.kind == .setViewport }?["isMobile"]?.bool ?? false
        var out = head + [
            "    const lhApi = await import('lighthouse'); // v10.0.0 or later",
            "    const flags = {",
            "        screenEmulation: {",
            "            disabled: true",
            "        }",
            "    }",
            mobile ? "    const config = undefined;" : "    const config = lhApi.desktopConfig;",
            "    const lhFlow = await lhApi.startFlow(page, {name: \(jsString(recording.title)), config, flags});",
        ]
        var inTimespan = false
        var navigated = false
        for step in recording.steps {
            if step.kind == .setViewport, !navigated {
                // The viewport is set before the flow measures anything.
                out += puppeteerStep(step).map { "    " + $0 }
                continue
            }
            if step.kind == .navigate || step.assertsNavigation {
                if inTimespan {
                    out.append("    await lhFlow.endTimespan();")
                    inTimespan = false
                }
                out.append("    await lhFlow.startNavigation();")
                out += puppeteerStep(step).map { "    " + $0 }
                out.append("    await lhFlow.endNavigation();")
                navigated = true
            } else {
                if !inTimespan {
                    out.append("    await lhFlow.startTimespan();")
                    inTimespan = true
                }
                out += puppeteerStep(step).map { "    " + $0 }
            }
        }
        if inTimespan { out.append("    await lhFlow.endTimespan();") }
        out += [
            "    const lhFlowReport = await lhFlow.generateReport();",
            "    fs.writeFileSync(__dirname + '/flow.report.html', lhFlowReport)",
        ]
        out += puppeteerTail
        return out.joined(separator: "\n")
    }

    /// One step's block, unindented.
    static func puppeteerStep(_ step: DeveloperRecorderStep) -> [String] {
        let navigation = step.assertsNavigation
        var body: [String] = ["const targetPage = page;"]
        if navigation {
            body += [
                "const promises = [];",
                "const startWaitingForEvents = () => {",
                "    promises.push(targetPage.waitForNavigation());",
                "}",
            ]
        }
        let stepTimeout = step.timeout.map { DeveloperRecorderJSON.format($0) } ?? "timeout"
        let on = navigation ? ["    .on('action', () => startWaitingForEvents())"] : []
        func locator(_ action: [String]) -> [String] {
            var lines = ["await puppeteer.Locator.race(["]
            let selectors = step.selectors
            for (index, parts) in selectors.enumerated() {
                let line = "    targetPage.locator(" + jsString(DeveloperRecorderSelector.puppeteer(parts)) + ")"
                lines.append(index == selectors.count - 1 ? line : line + ",")
            }
            lines.append("])")
            lines.append("    .setTimeout(\(stepTimeout))")
            lines += on
            lines += action
            return lines
        }
        func clickOptions(count: Int?) -> [String] {
            var options: [String] = []
            if let count { options.append("  count: \(count),") }
            if let button = step.button, let name = ["auxiliary": "middle", "secondary": "right", "back": "back", "forward": "forward"][button] {
                options.append("  button: \(jsString(name)),")
            }
            if let duration = step["duration"]?.number { options.append("  delay: \(DeveloperRecorderJSON.format(duration)),") }
            options += [
                "  offset: {",
                "    x: \(DeveloperRecorderJSON.format(step.offsetX ?? 0)),",
                "    y: \(DeveloperRecorderJSON.format(step.offsetY ?? 0)),",
                "  },",
            ]
            return ["    .click({"] + options.map { "    " + $0 } + ["    });"]
        }
        switch step.kind {
        case .setViewport:
            let width = DeveloperRecorderJSON.format(step["width"]?.number ?? 0)
            let height = DeveloperRecorderJSON.format(step["height"]?.number ?? 0)
            body += ["await targetPage.setViewport({", "    width: \(width),", "    height: \(height)", "})"]
        case .navigate:
            if navigation { body.append("startWaitingForEvents();") }
            body.append("await targetPage.goto(\(jsString(step.url ?? "")));")
        case .click:
            body += locator(clickOptions(count: nil))
        case .doubleClick:
            body += locator(clickOptions(count: 2))
        case .change:
            body += locator(["    .fill(\(jsString(step.value ?? "")));"])
        case .hover:
            body += locator(["    .hover();"])
        case .keyDown, .keyUp:
            if navigation { body.append("startWaitingForEvents();") }
            body.append("await targetPage.keyboard.\(step.kind == .keyDown ? "down" : "up")(\(jsString(step.key ?? "")));")
        case .scroll:
            let x = DeveloperRecorderJSON.format(step.x ?? 0), y = DeveloperRecorderJSON.format(step.y ?? 0)
            if step.selectors.isEmpty {
                body.append("await targetPage.evaluate((x, y) => { window.scroll(x, y); }, \(x), \(y))")
            } else {
                body += locator(["    .scroll({", "      scrollTop: \(y),", "      scrollLeft: \(x),", "    });"])
            }
        case .waitForElement:
            body += locator(["    .wait();"])
        case .waitForExpression:
            body.append("await targetPage.waitForFunction(\(jsString(step["expression"]?.string ?? "true")), { timeout });")
        case .close:
            body.append("await targetPage.close()")
        case .emulateNetworkConditions:
            let number = { (key: String) in DeveloperRecorderJSON.format(step[key]?.number ?? 0) }
            let offline = step["download"]?.number == 0 && step["upload"]?.number == 0
            body += ["await targetPage.emulateNetworkConditions({",
                     "    offline: \(offline),",
                     "    downloadThroughput: \(number("download")),",
                     "    uploadThroughput: \(number("upload")),",
                     "    latency: \(number("latency")),",
                     "});"]
        case .customStep, nil:
            body.append("// Not exported: \(step.type)")
        }
        if navigation { body.append("await Promise.all(promises);") }
        return ["{"] + body.map { "    " + $0 } + ["}"]
    }
}
