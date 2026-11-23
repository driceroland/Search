import AppKit
import Foundation

// The session's value types: the DOM mirror's nodes, styles, listeners,
// console lines, requests, resources and timeline records, and the
// highlight DevTools draws over the page.

extension DeveloperToolsSession {
    struct DOMNode: Identifiable, Equatable {
        let id: Int
        let parent: Int?
        let type: Int
        let name: String
        var text: String
        var attributes: [String]
        var children: [Int]
        var count: Int
        /// "before", "after" or "marker" for a pseudo-element.
        var pseudoType: String? = nil
        /// "open" or "closed" (or "user-agent") for a shadow root.
        var shadowRootType: String? = nil
        /// WebKit's layout flags: "scrollable", "event", "grid", "flex"…,
        /// for the tree's badges.
        var flags: [String] = []

        /// Text and comments by their node type, not their name: a payload
        /// without a nodeName must not turn a text node into a `<>` tag.
        var display: String {
            if let pseudoType { return "::" + pseudoType }
            if let shadowRootType { return "#shadow-root (\(shadowRootType))" }
            switch type {
            case 10: return "<!DOCTYPE \(name)>"
            case 3, 4: return Self.collapsed(text)
            case 8: return "<!--" + text + "-->"
            case 9, 11: return name.isEmpty ? Self.name(forType: type) : name
            default: break
            }
            if name == "#text" { return Self.collapsed(text) }
            if name.hasPrefix("#") { return name }
            if type != 1, name.isEmpty { return Self.name(forType: type) }
            let pairs = stride(from: 0, to: max(0, attributes.count - 1), by: 2).prefix(8).map {
                " \(attributes[$0])=\"\(attributes[$0 + 1])\""
            }
            return "<\(name)\(pairs.joined())>"
        }

        /// Text as the Elements tree shows it, as Chrome does: runs of
        /// whitespace become one space, and the ends are trimmed.
        static func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        static func name(forType type: Int) -> String {
            switch type {
            case 3: "#text"
            case 4: "#cdata-section"
            case 8: "#comment"
            case 9: "#document"
            case 11: "#document-fragment"
            default: ""
            }
        }

        /// Chrome's inline text: an element whose only child is a short
        /// text node shows it on its own row, `<li>text</li>`, with nothing
        /// to expand. Chrome's limit is 80 characters.
        static let inlineTextLimit = 80

        func inlineText(in nodes: [Int: DOMNode]) -> String? {
            guard type == 1, count <= 1, children.count == 1, let child = nodes[children[0]],
                  child.type == 3 else { return nil }
            let text = Self.collapsed(child.text)
            return !text.isEmpty && text.count <= Self.inlineTextLimit ? text : nil
        }

        /// Where this node sits among its parent's rows. As in Chrome
        /// DevTools: ::marker, ::before, the shadow root, a template's
        /// content, a frame's document, the children, then ::after (and
        /// any other pseudo-element after that).
        var childRank: Int {
            switch pseudoType {
            case "marker": return 0
            case "before": return 1
            case "after": return 6
            case .some: return 7
            case nil: break
            }
            if shadowRootType != nil { return 2 }
            switch type {
            case 11: return 3
            case 9: return 4
            default: return 5
            }
        }

        /// Not one of the parent's own DOM children but shown beside them.
        var isExtraChild: Bool { childRank != 5 }

        /// Rows under a node in Chrome's order, each once; nodes of the
        /// same kind keep the order they came in.
        static func treeOrder(_ ids: [Int], in tree: [Int: DOMNode]) -> [Int] {
            var seen = Set<Int>()
            let unique = ids.filter { seen.insert($0).inserted }
            return unique.enumerated().sorted { left, right in
                let a = tree[left.element]?.childRank ?? 5, b = tree[right.element]?.childRank ?? 5
                return a != b ? a < b : left.offset < right.offset
            }.map(\.element)
        }

        /// The rows beside the DOM children that a node's count leaves out
        /// (a frame's document is already in WebKit's count).
        static func extraCount(_ ids: [Int], in tree: [Int: DOMNode]) -> Int {
            ids.filter { tree[$0].map { $0.isExtraChild && $0.type != 9 } ?? false }.count
        }
    }

    struct Detail: Identifiable, Equatable {
        var name: String
        var value: String
        var enabled = true
        var important = false
        var parsed = true
        /// Struck through: a later or more specific declaration wins.
        var overridden = false
        /// Whether an inherited section shows it (inherited properties only).
        var inheritable = true
        /// A shorthand's longhands, shown when it is expanded.
        var longhands: [Detail] = []
        var id: String { name }

        /// The declaration as a rule's text holds it; switched off, inside
        /// a comment, as Web Inspector keeps it.
        var text: String {
            let line = "\(name): \(value)\(important ? " !important" : "");"
            return enabled ? line : "/* \(line) */"
        }
    }

    struct StyleID: Equatable {
        let sheet: String
        let ordinal: Int
        var protocolValue: [String: Any] { ["styleSheetId": sheet, "ordinal": ordinal] }
    }

    struct StyleRule: Identifiable {
        let id: Int
        let selector: String
        let origin: String
        var properties: [Detail]
        /// Nil for the browser's own rules, which can't be edited.
        var style: StyleID? = nil
        /// The rule itself, for its selector to be edited.
        var rule: StyleID? = nil
        /// "Inherited from …" or "Pseudo ::before element" above the rule.
        var section: String? = nil
        var sectionNode: Int? = nil
        var inherited = false
        var pseudo: String? = nil
        /// @media, @supports, @layer, @container: outermost first.
        var groupings: [String] = []
        var sourceURL: String? = nil
        var sourceLine: Int? = nil
        /// The selector's column on `sourceLine`, 0-based, for a source map
        /// of a sheet minified onto few lines.
        var sourceColumn: Int? = nil
        var editable: Bool { style != nil }
        var inline: Bool { id == 0 }
    }

    struct EventListener: Identifiable, Equatable {
        let id: Int
        let type: String
        let target: String
        let handler: String
        let framework: String?
        let useCapture: Bool
        let passive: Bool
        let once: Bool
        let isAttribute: Bool
        var disabled: Bool
        let url: String
        /// The handler's place, 0-based as the debugger gives it.
        let line: Int?
        let column: Int?

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? Int, let type = raw["type"] as? String else { return nil }
            self.id = id
            self.type = type
            target = raw["target"] as? String ?? ""
            handler = raw["handler"] as? String ?? ""
            framework = raw["framework"] as? String
            useCapture = raw["useCapture"] as? Bool == true
            passive = raw["passive"] as? Bool == true
            once = raw["once"] as? Bool == true
            isAttribute = raw["isAttribute"] as? Bool == true
            disabled = raw["disabled"] as? Bool == true
            url = raw["url"] as? String ?? ""
            line = raw["line"] as? Int
            column = raw["column"] as? Int
        }

        var location: String {
            guard !url.isEmpty else { return line.map { "line \($0 + 1)" } ?? "" }
            let name = URL(string: url)?.lastPathComponent ?? url
            return name + (line.map { ":\($0 + 1)" } ?? "")
        }
    }

    struct ConsoleLine: Identifiable, Equatable {
        let id = UUID()
        let level: String
        let text: String
        var url: String?
        var line: Int?
        var repeatCount = 1
        var details: ConsoleMessageDetails?
    }

    struct Request: Identifiable, Equatable {
        let id: String
        let url: String
        let method: String
        var type: String
        let loader: String?
        var started: Double?
        var sent: Double?
        var received: Double?
        var ended: Double?
        var status: Int?
        var statusText: String?
        var mimeType: String?
        var bytes: Int?
        var initiatorURL: String?
        var initiatorType: String?
        var wallStarted: Double?
        var documentURL: String?
        /// The frame that made the request, for Group by frame.
        var frameId: String?
        var originalURL: String?
        var isEventSource: Bool {
            type == "EventSource" || mimeType?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
        }
        var failed: Bool { failure != nil || (status ?? 0) >= 400 }
        var failure: String?
        var cached = false
        /// The connection and certificate WebKit reported with the response,
        /// for the Security panel (DeveloperSecurity.swift).
        var security: DeveloperSecurity.ResponseSecurity?
        var time: Double? {
            guard let started, let ended else { return nil }
            return max(0, (ended - started) * 1_000)
        }
        var name: String {
            guard let address = URL(string: url) else { return url }
            return address.path.isEmpty || address.path == "/" ? address.host() ?? url : address.lastPathComponent
        }

        var initiator: String {
            if let initiatorURL, let address = URL(string: initiatorURL) {
                return address.path.isEmpty || address.path == "/" ? address.host() ?? initiatorURL : address.lastPathComponent
            }
            return initiatorType ?? "—"
        }

        mutating func applyResponse(_ response: [String: Any]?, received at: Double?) {
            received = at
            guard let response else { return }
            status = response["status"] as? Int
            statusText = response["statusText"] as? String
            mimeType = response["mimeType"] as? String
            cached = response["fromDiskCache"] as? Bool == true
                || (response["source"] as? String ?? "").localizedCaseInsensitiveContains("cache")
            security = DeveloperSecurity.ResponseSecurity(response["security"] as? [String: Any])
            if let timing = response["timing"] as? [String: Any],
               let fetch = timing["fetchStart"] as? Double, fetch.isFinite {
                if let request = timing["requestStart"] as? Double, request.isFinite, request >= 0 {
                    sent = fetch + request / 1_000
                }
                if let reply = timing["responseStart"] as? Double, reply.isFinite, reply >= 0 {
                    let firstByte = fetch + reply / 1_000
                    if let started, firstByte >= started { received = firstByte }
                }
            }
        }
    }

    struct ResourceFrame: Hashable {
        let id: String
        let parent: String?
        let url: String
        let name: String
    }

    struct Resource: Identifiable, Hashable {
        let frame: String
        let url: String
        let type: String
        var id: String { frame + "\n" + url }
        var name: String {
            guard let address = URL(string: url) else { return url }
            return address.lastPathComponent.isEmpty ? address.host() ?? url : address.lastPathComponent
        }
    }

    /// One record of a Performance recording. `start` and `end` are
    /// WebKit's timeline timestamps, in seconds; `depth` is how deeply the
    /// record is nested in the one WebKit sent; `stack` is the call stack
    /// that caused it, innermost first, as "function — file:line".
    struct Timing: Identifiable, Equatable {
        let id = UUID()
        let type: String
        let start: Double
        let end: Double
        var depth = 0
        var data: [String: String] = [:]
        var stack: [String] = []
        /// The same frames with their full addresses (1-based, as WebKit's
        /// Console.CallFrame numbers them), for the Summary's source links.
        var frames: [ConsoleCallFrame] = []

        var milliseconds: Double { (end - start) * 1_000 }

        /// A record's stackTrace as the Summary links it: the first five
        /// frames, as `stack` keeps.
        static func frames(_ raw: Any?) -> [ConsoleCallFrame] {
            (raw as? [[String: Any]] ?? []).prefix(5).map(ConsoleCallFrame.init)
        }

        static func frame(_ raw: [String: Any]) -> String {
            let name = (raw["functionName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)"
            guard let url = raw["url"] as? String, !url.isEmpty else { return name }
            let file = URL(string: url)?.lastPathComponent ?? url
            let line = (raw["lineNumber"] as? NSNumber).map { ":\($0.intValue)" } ?? ""  // 1-based already (Console.CallFrame)
            return "\(name) — \(file.isEmpty ? url : file)\(line)"
        }
    }

    /// Chromium's presets (Network conditions › Throttling), with the
    /// latency it adds for each. WebKit can hold a page's requests but not
    /// pace their bytes per page, so the download and upload limits shown in
    /// the help are approximated by the delay alone.
    enum NetworkCondition: String, CaseIterable, Identifiable {
        case unrestricted = "No throttling"
        case fast4G = "Fast 4G"
        case slow4G = "Slow 4G"
        case threeG = "3G"
        case offline = "Offline"

        var id: Self { self }
        /// Milliseconds, as Chromium's NetworkManager defines each preset.
        var latency: Double {
            switch self {
            case .fast4G: return 60 * 2.75
            case .slow4G: return 150 * 3.75
            case .threeG: return 400 * 5
            default: return 0
            }
        }

        var detail: String {
            switch self {
            case .unrestricted: return "No throttling"
            case .fast4G: return "Fast 4G: 165 ms latency, 8.1 Mbps down, 1.35 Mbps up"
            case .slow4G: return "Slow 4G: 562.5 ms latency, 1.44 Mbps down, 675 kbps up"
            case .threeG: return "3G: 2,000 ms latency, 400 kbps down, 400 kbps up"
            case .offline: return "Offline: every request fails"
            }
        }
    }
}

/// What DevTools last drew over the page: nothing, a node, every node a
/// selector matches, or not known (the picker drew, the document changed).
enum ShownHighlight: Equatable {
    case unknown
    case hidden
    case node(Int, DeveloperHighlight)
    case selector(String, DeveloperHighlight)
}

/// The highlight DevTools draws over a node on the page. As in Chrome
/// DevTools: the content, padding, border and margin boxes each in their
/// own colour, and the tag.class W×H label beside it.
struct DeveloperHighlight: Equatable {
    struct RGBA: Equatable {
        var r: Int, g: Int, b: Int
        var a: Double
        var protocolValue: [String: Any] { ["r": r, "g": g, "b": b, "a": a] }
    }

    var content: RGBA?
    var padding: RGBA?
    var border: RGBA?
    var margin: RGBA?
    /// The tag.class W×H label.
    var showInfo = true

    /// Chrome's colours (front_end/core/common/Color.ts, PageHighlight).
    static let contentColor = RGBA(r: 111, g: 168, b: 220, a: 0.66)
    static let paddingColor = RGBA(r: 147, g: 196, b: 125, a: 0.55)
    static let borderColor = RGBA(r: 255, g: 229, b: 153, a: 0.66)
    static let marginColor = RGBA(r: 246, g: 178, b: 107, a: 0.66)

    /// All four boxes and the label: a hover in the tree, a pick.
    static let chrome = DeveloperHighlight(content: contentColor, padding: paddingColor,
                                           border: borderColor, margin: marginColor)

    enum Layer: CaseIterable { case content, padding, border, margin }

    /// One box alone, as hovering that box in the box model shows it.
    static func only(_ layer: Layer) -> DeveloperHighlight {
        switch layer {
        case .content: DeveloperHighlight(content: contentColor)
        case .padding: DeveloperHighlight(padding: paddingColor)
        case .border: DeveloperHighlight(border: borderColor)
        case .margin: DeveloperHighlight(margin: marginColor)
        }
    }

    /// DOM.HighlightConfig.
    var protocolValue: [String: Any] {
        var config: [String: Any] = ["showInfo": showInfo && DeveloperElementsSettings.detailedInspectTooltip]
        if let content { config["contentColor"] = content.protocolValue }
        if let padding { config["paddingColor"] = padding.protocolValue }
        if let border { config["borderColor"] = border.protocolValue }
        if let margin { config["marginColor"] = margin.protocolValue }
        return config
    }
}
