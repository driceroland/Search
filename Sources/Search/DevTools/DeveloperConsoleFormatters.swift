import Foundation
import SwiftUI

// Chrome DevTools' custom formatters (Settings › Preferences › Console ›
// "Enable custom formatters"): a page lists formatters in
// `window.devtoolsFormatters`, each with header(object, config),
// hasBody(object, config) and body(object, config) returning JsonML,
// `["div", {style}, "text", ["object", {object, config}]]`. With the
// setting on, each logged object is offered to the formatters in the
// page; a header found draws in place of the usual preview, and one with
// a body opens with its own triangle.

/// One JsonML node as the page's formatter returned it, its nested object
/// references numbered into the reply's object table.
indirect enum ConsoleJsonML: Equatable {
    case text(String)
    case element(tag: String, style: String, children: [ConsoleJsonML])
    /// `["object", {object, config}]`: indices into the reply's objects.
    case object(ref: Int, config: Int?)

    /// The tags Chrome's formatter renderer accepts.
    static let tags: Set<String> = ["div", "span", "ol", "li", "table", "tr", "td"]
    static let maximumDepth = 64

    /// Reads the page's encoded reply (strings, and arrays of tag, then
    /// attributes, then children). Anything Chrome would refuse (an
    /// unknown tag, a malformed node, too deep) makes the whole header nil,
    /// so the usual preview shows instead.
    static func parse(_ raw: Any?, depth: Int = 0) -> ConsoleJsonML? {
        guard depth <= maximumDepth else { return nil }
        if let text = raw as? String { return .text(text) }
        guard let list = raw as? [Any], let tag = list.first as? String else { return nil }
        let attributes = list.count > 1 ? list[1] as? [String: Any] : nil
        if tag == "object" {
            guard let ref = attributes?["ref"] as? Int else { return nil }
            return .object(ref: ref, config: attributes?["config"] as? Int)
        }
        guard tags.contains(tag) else { return nil }
        var children: [ConsoleJsonML] = []
        for child in list.dropFirst(attributes == nil ? 1 : 2) {
            guard let node = parse(child, depth: depth + 1) else { return nil }
            children.append(node)
        }
        return .element(tag: tag, style: ConsoleJsonMLStyle.sanitized(attributes?["style"] as? String ?? ""), children: children)
    }

    /// Parses the reply's `json` string.
    static func parse(json text: String) -> ConsoleJsonML? {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return parse(raw)
    }
}

/// The CSS a formatter's `style` may carry: Chrome's safe subset (colours,
/// fonts, text decoration, margins, padding, borders), with anything that
/// could load a resource dropped.
enum ConsoleJsonMLStyle {
    static let allowedProperties: Set<String> = [
        "color", "background", "background-color", "font", "font-weight", "font-style", "font-size", "font-family",
        "font-variant", "text-decoration", "text-decoration-line", "text-decoration-color", "text-transform",
        "text-align", "text-indent", "text-shadow", "letter-spacing", "word-spacing", "line-height", "white-space",
        "vertical-align", "display", "opacity", "border-radius", "box-shadow", "outline", "width", "height",
        "min-width", "min-height", "max-width", "max-height",
    ]
    static let allowedPrefixes = ["margin", "padding", "border"]

    /// Keeps only the allowed declarations, in their order.
    static func sanitized(_ css: String) -> String {
        var kept: [String] = []
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            let name = parts[0].lowercased()
            let value = parts[1]
            let lowered = value.lowercased()
            guard allowedProperties.contains(name) || allowedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard !lowered.contains("url("), !lowered.contains("expression("), !lowered.contains("image-set("),
                  !lowered.contains("javascript:"), !lowered.contains("@import"), !lowered.contains("\\") else { continue }
            kept.append(name + ": " + value)
        }
        return kept.joined(separator: "; ")
    }

    /// The left margin and padding a block's style adds, in points.
    static func indent(_ css: String) -> Double {
        var total = 0.0
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let values = parts[1].split(separator: " ").map(String.init)
            switch parts[0] {
            case "margin-left", "padding-left":
                total += pixels(values.first)
            case "margin", "padding":
                // One value: all sides; two or three: the second is left and right; four: the fourth.
                let left = values.count == 4 ? values[3] : values.count >= 2 ? values[1] : values.first
                total += pixels(left)
            default:
                continue
            }
        }
        return min(max(total, 0), 200)
    }

    private static func pixels(_ value: String?) -> Double {
        guard let value else { return 0 }
        if value.hasSuffix("px") { return Double(value.dropLast(2)) ?? 0 }
        if value.hasSuffix("em") { return (Double(value.dropLast(2)) ?? 0) * 11 }
        return Double(value) ?? 0
    }

    /// A child's style over its parent's: the declarations it sets win.
    static func text(_ css: String, over parent: ConsoleStyle) -> ConsoleStyle {
        guard !css.isEmpty else { return parent }
        let own = ConsoleStyle(css: css)
        var style = parent
        let names = Set(css.split(separator: ";").compactMap {
            $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        })
        if names.contains("color") { style.color = own.color }
        if names.contains("background") || names.contains("background-color") { style.background = own.background }
        if names.contains("font-weight") { style.bold = own.bold }
        if names.contains("font-style") { style.italic = own.italic }
        if names.contains("text-decoration") || names.contains("text-decoration-line") {
            style.underline = own.underline
            style.strikethrough = own.strikethrough
        }
        if names.contains("font-size") { style.fontSize = own.fontSize }
        if names.contains("font-family") { style.monospaced = own.monospaced }
        if names.contains(where: { $0.hasPrefix("padding") }) { style.padding = own.padding }
        return style
    }
}

/// A formatter's JsonML laid out as console lines: block tags (div, li,
/// tr, ol, table) start lines and indent by their left margin and padding;
/// spans and cells run inline.
enum ConsoleJsonMLLayout {
    enum Run: Equatable {
        case text(String, ConsoleStyle)
        case object(ref: Int, config: Int?)
    }

    struct Line: Equatable {
        var indent: Double
        var runs: [Run]
    }

    static let blockTags: Set<String> = ["div", "li", "tr", "ol", "table"]

    static func lines(_ root: ConsoleJsonML) -> [Line] {
        var output: [Line] = []
        var current = Line(indent: 0, runs: [])
        walk(root, style: .plain, indent: 0, output: &output, current: &current)
        if !current.runs.isEmpty { output.append(current) }
        return output
    }

    /// The header on one line, as Chrome draws a header inline.
    static func inline(_ root: ConsoleJsonML) -> [Run] {
        lines(root).flatMap(\.runs)
    }

    private static func walk(_ node: ConsoleJsonML, style: ConsoleStyle, indent: Double,
                             output: inout [Line], current: inout Line) {
        switch node {
        case .text(let text):
            guard !text.isEmpty else { return }
            if current.runs.isEmpty { current.indent = indent }
            current.runs.append(.text(text, style))
        case .object(let ref, let config):
            if current.runs.isEmpty { current.indent = indent }
            current.runs.append(.object(ref: ref, config: config))
        case .element(let tag, let css, let children):
            let own = ConsoleJsonMLStyle.text(css, over: style)
            let block = blockTags.contains(tag)
            var inner = indent
            if block {
                if !current.runs.isEmpty { output.append(current) }
                inner += ConsoleJsonMLStyle.indent(css) + (tag == "li" ? 14 : 0)
                current = Line(indent: inner, runs: [])
            }
            for child in children {
                walk(child, style: own, indent: inner, output: &output, current: &current)
            }
            if block {
                if !current.runs.isEmpty { output.append(current) }
                current = Line(indent: indent, runs: [])
            } else if tag == "td", !current.runs.isEmpty {
                current.runs.append(.text(" ", style))
            }
        }
    }

    /// The text runs as one attributed string, for plain lines and tests.
    static func plain(_ runs: [Run]) -> String {
        runs.map {
            switch $0 {
            case .text(let text, _): return text
            case .object(let ref, _): return "{object \(ref)}"
            }
        }.joined()
    }
}

/// A formatter's header for one object, with what's needed to ask for its body.
struct ConsoleCustomPreview: Equatable {
    let object: ConsoleRemoteObject
    let config: ConsoleRemoteObject?
    /// Which of `window.devtoolsFormatters` answered.
    let formatter: Int
    let header: ConsoleJsonML
    let hasBody: Bool
    /// The JsonML's nested objects and configs, by reference number.
    let objects: [Int: ConsoleRemoteObject]
}

struct ConsoleCustomBody: Equatable {
    let body: ConsoleJsonML
    let objects: [Int: ConsoleRemoteObject]
}

enum ConsoleCustomPreviewState: Equatable {
    case loading
    /// No formatter took it: the usual preview.
    case none
    case header(ConsoleCustomPreview)
}

enum ConsoleCustomFormatting {
    /// Longest a formatter may take before the usual preview is shown.
    static let timeout: Duration = .milliseconds(1_500)

    static func key(_ object: ConsoleRemoteObject, config: ConsoleRemoteObject?) -> String {
        (object.objectId ?? "") + "|" + (config.map { $0.objectId ?? ($0.type + ":" + ($0.value?.string ?? "")) } ?? "")
    }

    /// A remote object as a Runtime.callFunctionOn argument.
    static func argument(_ object: ConsoleRemoteObject?) -> [String: Any] {
        guard let object else { return [:] }
        if let id = object.objectId { return ["objectId": id] }
        switch object.value {
        case .string(let text)?: return ["value": text]
        case .number(let number)?: return ["value": number]
        case .bool(let flag)?: return ["value": flag]
        case .null?: return ["value": NSNull()]
        case nil: return [:]
        }
    }

    /// Runs in the page, on the object: asks each formatter for a header
    /// (or the given one for its body), every call guarded, and encodes the
    /// JsonML with its nested objects moved into the reply as `o0`, `o1`…
    static let function = """
        function(mode, formatterIndex, formatterConfig) {
            const formatters = window.devtoolsFormatters;
            if (!Array.isArray(formatters)) return null;
            const reply = {};
            let count = 0;
            const encode = (node, depth) => {
                if (depth > 64) throw new Error("JsonML is too deep");
                if (typeof node === "string") return node;
                if (typeof node === "number" || typeof node === "boolean") return String(node);
                if (!Array.isArray(node) || typeof node[0] !== "string") throw new Error("Not JsonML");
                const tag = node[0];
                const attributed = node.length > 1 && node[1] !== null && typeof node[1] === "object" && !Array.isArray(node[1]);
                const attributes = attributed ? node[1] : {};
                if (tag === "object") {
                    const ref = count++;
                    reply["o" + ref] = attributes.object;
                    let configRef = null;
                    if ("config" in attributes) {
                        configRef = count++;
                        reply["o" + configRef] = attributes.config;
                    }
                    return ["object", {ref: ref, config: configRef}];
                }
                const style = typeof attributes.style === "string" ? attributes.style : "";
                return [tag, {style: style}].concat(node.slice(attributed ? 2 : 1).map((child) => encode(child, depth + 1)));
            };
            const wantsBody = mode === "body";
            const start = wantsBody ? formatterIndex : 0;
            const end = wantsBody ? formatterIndex + 1 : formatters.length;
            for (let position = start; position < end; position++) {
                const formatter = formatters[position];
                try {
                    if (!formatter) continue;
                    const method = wantsBody ? formatter.body : formatter.header;
                    if (typeof method !== "function") continue;
                    const markup = method.call(formatter, this, formatterConfig);
                    if (markup === null || markup === undefined) continue;
                    let more = false;
                    if (!wantsBody && typeof formatter.hasBody === "function") {
                        try { more = !!formatter.hasBody.call(formatter, this, formatterConfig); } catch (error) {}
                    }
                    reply.json = JSON.stringify(encode(markup, 0));
                    reply.hasBody = more;
                    reply.formatter = position;
                    return reply;
                } catch (error) {
                    count = 0;
                }
            }
            return null;
        }
        """

    /// What the page function answered.
    struct Reply: Equatable {
        let json: String
        let hasBody: Bool
        let formatter: Int
        let objects: [Int: ConsoleRemoteObject]
    }

    /// Reads the page function's reply object: its JSON, flags and objects.
    static func reply(_ properties: [[String: Any]]) -> ConsoleCustomFormatting.Reply? {
        var json: String?
        var hasBody = false
        var formatter = 0
        var objects: [Int: ConsoleRemoteObject] = [:]
        for property in properties {
            guard let name = property["name"] as? String, let value = property["value"] as? [String: Any] else { continue }
            let object = ConsoleRemoteObject(value)
            switch name {
            case "json": json = object.value?.string
            case "hasBody": hasBody = object.value == .bool(true)
            case "formatter": formatter = Int(object.number ?? 0)
            default:
                if name.hasPrefix("o"), let index = Int(name.dropFirst()) { objects[index] = object }
            }
        }
        guard let json else { return nil }
        return Reply(json: json, hasBody: hasBody, formatter: formatter, objects: objects)
    }
}

extension DeveloperToolsSession {
    /// Offers a logged object to the page's formatters, once per object and config.
    func loadConsoleCustomHeader(_ object: ConsoleRemoteObject, config: ConsoleRemoteObject? = nil, targetID: String?) {
        guard consoleStore.settings.customFormatters, object.objectId != nil else { return }
        let key = ConsoleCustomFormatting.key(object, config: config)
        guard consoleStore.customHeaders[key] == nil else { return }
        consoleStore.customHeaders[key] = .loading
        Task { [weak self] in
            guard let self else { return }
            let found: ConsoleCustomFormatting.Reply? = await Self.withinTimeout {
                await self.consoleCustomFormat(object, mode: "header", formatter: 0, config: config, targetID: targetID)
            }
            guard self.consoleStore.customHeaders[key] == .loading else { return }
            if let found, let header = ConsoleJsonML.parse(json: found.json) {
                self.consoleStore.customHeaders[key] = .header(ConsoleCustomPreview(
                    object: object, config: config, formatter: found.formatter, header: header,
                    hasBody: found.hasBody, objects: found.objects))
            } else {
                self.consoleStore.customHeaders[key] = ConsoleCustomPreviewState.none
            }
        }
    }

    /// The body a formatter's header opens to.
    func loadConsoleCustomBody(_ preview: ConsoleCustomPreview, targetID: String?) {
        let key = ConsoleCustomFormatting.key(preview.object, config: preview.config)
        guard consoleStore.customBodies[key] == nil, consoleStore.loading.insert("custom:" + key).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let found: ConsoleCustomFormatting.Reply? = await Self.withinTimeout {
                await self.consoleCustomFormat(preview.object, mode: "body", formatter: preview.formatter,
                                               config: preview.config, targetID: targetID)
            }
            self.consoleStore.loading.remove("custom:" + key)
            let body = found.flatMap { ConsoleJsonML.parse(json: $0.json) } ?? .text("")
            self.consoleStore.customBodies[key] = ConsoleCustomBody(body: body, objects: found?.objects ?? [:])
        }
    }

    private func consoleCustomFormat(_ object: ConsoleRemoteObject, mode: String, formatter: Int,
                                     config: ConsoleRemoteObject?, targetID: String?) async
        -> ConsoleCustomFormatting.Reply? {
        guard let id = object.objectId else { return nil }
        let arguments: [[String: Any]] = [["value": mode], ["value": formatter], ConsoleCustomFormatting.argument(config)]
        guard let called = try? await command("Runtime.callFunctionOn", [
            "objectId": id,
            "functionDeclaration": ConsoleCustomFormatting.function,
            "arguments": arguments,
            "objectGroup": "console",
            "returnByValue": false,
            "doNotPauseOnExceptionsAndMuteConsole": true,
        ], targetID: targetID),
              called["wasThrown"] as? Bool != true,
              let result = called["result"] as? [String: Any],
              let replyID = result["objectId"] as? String else { return nil }
        guard let listed = try? await command("Runtime.getProperties", [
            "objectId": replyID, "ownProperties": true, "generatePreview": true,
        ], targetID: targetID) else { return nil }
        return ConsoleCustomFormatting.reply(listed["properties"] as? [[String: Any]] ?? [])
    }

    /// The work's answer, or nil once the formatter has taken too long; a
    /// late answer is dropped.
    static func withinTimeout<T>(_ work: @escaping @MainActor () async -> T?) async -> T? {
        let box = ConsoleCustomFormattingBox<T>()
        Task { @MainActor in
            box.value = await work()
            box.done = true
        }
        let deadline = ContinuousClock.now + ConsoleCustomFormatting.timeout
        while !box.done, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return box.done ? box.value : nil
    }
}

/// What withinTimeout's work answered, once it has.
@MainActor
private final class ConsoleCustomFormattingBox<T> {
    var done = false
    var value: T?
}
