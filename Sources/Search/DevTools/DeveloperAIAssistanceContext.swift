import Foundation

// What AI assistance tells the on-device model about the thing asked
// about, as Chrome DevTools' agents gather it: an element's outer HTML,
// computed style and matched rules (StylingAgent), a request's headers,
// status and timing (NetworkAgent), a Console message's text and stack
// (Console insights). Pure, so the tests can read it without a model.
//
// The model only ever reads this text. Chrome's styling agent can also run
// JavaScript in the inspected page to look things up; here that is left
// out on purpose: nothing the model answers is executed, and it gets no
// tools, so it can't change or probe the page.

/// What a chat is about: the context chip above the prompt.
enum DeveloperAISubject: Equatable {
    /// An element in Elements, by node id, with its tree label.
    case element(node: Int, label: String)
    /// A request in Network, by id, with its name.
    case request(id: String, label: String)
    /// A Console message, kept as it was when asked about.
    case console(DeveloperToolsSession.ConsoleLine)
    /// An entry of a Performance recording, by a key for it, with its
    /// name and its context written when asked about: the recording is
    /// the panel's, not the session's, so it is read then.
    case traceEvent(id: String, label: String, context: String)
    /// A Performance insight, by its kind, with its context as it was.
    case insight(id: String, label: String, context: String)
    /// A file open in Sources, by URL, with its context as it was.
    case file(url: String, label: String, context: String)

    var label: String {
        switch self {
        case .element(_, let label), .request(_, let label), .traceEvent(_, let label, _),
             .insight(_, let label, _), .file(_, let label, _): label
        case .console(let line): DeveloperAIContextText.oneLine(line.text, limit: 60)
        }
    }

    var icon: String {
        switch self {
        case .element: "chevron.left.forwardslash.chevron.right"
        case .request: "point.3.connected.trianglepath.dotted"
        case .console(let line): line.level == "warning" ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
        case .traceEvent: "chart.bar.xaxis"
        case .insight: "lightbulb"
        case .file: "doc.text"
        }
    }

    /// The prompt field's placeholder, in Chrome's words.
    var placeholder: String {
        switch self {
        case .element: "Ask a question about the selected element"
        case .request: "Ask a question about the selected network request"
        case .console: "Ask a question about this console message"
        case .traceEvent: "Ask a question about the selected item and its call tree"
        case .insight: "Ask a question about this performance insight"
        case .file: "Ask a question about the selected file"
        }
    }

    /// Chrome's suggested prompts for each kind of context.
    var examplePrompts: [String] {
        switch self {
        case .element:
            ["Why isn’t this element visible?", "How can I center this element?", "Why is this element overlapping others?"]
        case .request:
            ["Why is this network request taking so long?", "Are there any security headers present?",
             "Why is the request failing?", "Explain the purpose of this request"]
        case .console(let line):
            [line.level == "warning" ? "Explain this warning" : "Explain this error", "How can I fix this?"]
        case .traceEvent:
            ["What’s the purpose of this work?", "Where is most of the time being spent in this call tree?",
             "How can I reduce the time of this call tree?"]
        case .insight:
            ["Help me understand this insight", "How can I improve this?", "What should I look at first?"]
        case .file:
            ["What does this file do?", "Is this file optimized for performance?",
             "Does this file handle user input safely?"]
        }
    }

    /// Whether two subjects are about the same thing, so a chat keeps its
    /// context when the chip is set again to what it already shows.
    func same(as other: DeveloperAISubject?) -> Bool {
        switch (self, other) {
        case (.element(let a, _), .element(let b, _)?): a == b
        case (.request(let a, _), .request(let b, _)?): a == b
        case (.console(let a), .console(let b)?): a.id == b.id
        case (.traceEvent(let a, _, _), .traceEvent(let b, _, _)?): a == b
        case (.insight(let a, _, let x), .insight(let b, _, let y)?): a == b && x == y
        case (.file(let a, _, let x), .file(let b, _, let y)?): a == b && x == y
        default: false
        }
    }
}

/// The text of each context, and the prompt that carries it, trimmed to fit
/// the on-device model's context window.
enum DeveloperAIContextText {
    /// The on-device model reads about 4,096 tokens in all, instructions,
    /// history and answer included. Code runs at roughly three characters
    /// a token, so the context takes at most this many characters, leaving
    /// room for the question, earlier turns and the answer.
    static let contextBudget = 5_000
    static let questionBudget = 1_500
    static let outerHTMLBudget = 1_500
    static let rulesBudget = 2_000
    static let headersBudget = 1_400
    static let stackFrames = 10

    /// Headers whose values are credentials: named but never shown, as
    /// Chrome's network agent leaves them out.
    static let redactedHeaders: Set<String> = ["cookie", "set-cookie", "authorization", "proxy-authorization",
                                               "x-api-key", "x-auth-token", "x-csrf-token"]

    /// Computed properties that say most about layout and visibility, in
    /// the order Chrome's styling agent asks for them first.
    static let computedProperties = [
        "display", "position", "top", "right", "bottom", "left", "z-index", "float",
        "width", "height", "min-width", "min-height", "max-width", "max-height", "box-sizing",
        "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding-top", "padding-right", "padding-bottom", "padding-left",
        "flex-direction", "flex-wrap", "justify-content", "align-items", "align-self", "flex-grow", "flex-shrink",
        "flex-basis", "grid-template-columns", "grid-template-rows", "gap",
        "overflow-x", "overflow-y", "visibility", "opacity", "transform", "clip-path",
        "color", "background-color", "font-family", "font-size", "font-weight", "line-height", "text-align",
        "white-space", "pointer-events",
    ]

    // MARK: Trimming

    /// The text cut to `limit` characters, marked where it was cut, as
    /// Chrome marks the HTML it shortens.
    static func trim(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n… (trimmed \(text.count - limit) characters)"
        let keep = max(0, limit - marker.count)
        return String(text.prefix(keep)) + marker
    }

    /// One line, whitespace collapsed, ending in an ellipsis past `limit`.
    static func oneLine(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))) + "…"
    }

    /// Lines kept whole, in order, until the next would pass `limit`; the
    /// rest counted, so the model knows there were more.
    static func lines(_ lines: [String], within limit: Int) -> String {
        var kept: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            guard used + cost <= limit else { break }
            kept.append(line)
            used += cost
        }
        let left = lines.count - kept.count
        if left > 0 { kept.append("… (\(left) more not shown)") }
        return kept.joined(separator: "\n")
    }

    // MARK: Element

    /// An element as the tree and the chip name it: `div#main.card`.
    static func elementLabel(name: String, attributes: [String]) -> String {
        var label = name.lowercased()
        var index = 0
        var id: String?
        var classes: [String] = []
        while index + 1 < attributes.count {
            switch attributes[index] {
            case "id": id = attributes[index + 1]
            case "class": classes = attributes[index + 1].split(whereSeparator: \.isWhitespace).map(String.init)
            default: break
            }
            index += 2
        }
        if let id, !id.isEmpty { label += "#" + id }
        for name in classes.prefix(3) { label += "." + name }
        return label.isEmpty ? "element" : label
    }

    /// Outer HTML with long attribute values and text shortened, then cut
    /// to its budget: the opening tag matters most, so it comes first.
    static func outerHTML(_ html: String, limit: Int = outerHTMLBudget) -> String {
        let compact = html.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return trim(compact.trimmingCharacters(in: .whitespacesAndNewlines), to: limit)
    }

    static func computed(_ styles: [DeveloperToolsSession.Detail]) -> String {
        var values: [String: String] = [:]
        for style in styles { values[style.name] = style.value }
        return computedProperties.compactMap { name in values[name].map { "\(name): \($0);" } }.joined(separator: "\n")
    }

    /// The rules that apply, most specific first as Styles lists them;
    /// overridden and disabled declarations left out, since they don't apply.
    static func rules(_ rules: [DeveloperToolsSession.StyleRule], limit: Int = rulesBudget) -> String {
        var blocks: [String] = []
        for rule in rules {
            let declarations = rule.properties.filter { $0.enabled && $0.parsed && !$0.overridden }
            guard !declarations.isEmpty else { continue }
            var head = rule.inline ? "element.style" : rule.selector
            if !rule.groupings.isEmpty { head = rule.groupings.joined(separator: " ") + " " + head }
            var block = head + " {"
            if let section = rule.section { block = "/* " + section + " */\n" + block }
            if !rule.origin.isEmpty, !rule.inline { block += " /* " + rule.origin + " */" }
            for declaration in declarations {
                block += "\n  " + declaration.name + ": " + declaration.value + (declaration.important ? " !important" : "") + ";"
            }
            blocks.append(block + "\n}")
        }
        return lines(blocks, within: limit)
    }

    static func element(label: String, outerHTML html: String, computed styles: [DeveloperToolsSession.Detail],
                        rules matched: [DeveloperToolsSession.StyleRule]) -> String {
        var parts = ["The selected element: " + label]
        if !html.isEmpty { parts.append("Its outer HTML:\n```html\n" + outerHTML(html) + "\n```") }
        let computedText = computed(styles)
        if !computedText.isEmpty { parts.append("Its computed style:\n```css\n" + computedText + "\n```") }
        let rulesText = rules(matched)
        if !rulesText.isEmpty { parts.append("The CSS rules that apply to it:\n```css\n" + rulesText + "\n```") }
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    // MARK: Network

    static func headers(_ headers: [DeveloperRequestDetails.Header], limit: Int = headersBudget) -> String {
        lines(headers.map { header in
            let value = redactedHeaders.contains(header.name.lowercased()) ? "<redacted>" : oneLine(header.value, limit: 200)
            return header.name + ": " + value
        }, within: limit)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        let ms = seconds * 1_000
        return ms < 1 ? String(format: "%.2f ms", ms) : String(format: "%.0f ms", ms)
    }

    /// Chrome's Timing tab, as far as WebKit's events give it: waiting for
    /// the server's first byte, then the download.
    static func timing(_ request: DeveloperToolsSession.Request) -> String {
        var lines: [String] = []
        if let started = request.started, let sent = request.sent, sent >= started {
            lines.append("Queueing and connection: " + milliseconds(sent - started))
        }
        if let sent = request.sent ?? request.started, let received = request.received, received >= sent {
            lines.append("Waiting for server response: " + milliseconds(received - sent))
        }
        if let received = request.received, let ended = request.ended, ended >= received {
            lines.append("Content download: " + milliseconds(ended - received))
        }
        if let total = request.time { lines.append("Total: " + milliseconds(total / 1_000)) }
        return lines.joined(separator: "\n")
    }

    static func request(_ request: DeveloperToolsSession.Request, details: DeveloperRequestDetails?) -> String {
        var general = ["Request URL: " + oneLine(details?.url ?? request.url, limit: 500),
                       "Request method: " + (details?.method ?? request.method)]
        let status = details?.status ?? request.status
        let statusText = details?.statusText ?? request.statusText
        if let failure = request.failure ?? details?.failure {
            general.append("Status: failed (" + failure + ")")
        } else if let status {
            general.append("Status code: \(status)" + (statusText.map { $0.isEmpty ? "" : " " + $0 } ?? ""))
        } else {
            general.append("Status: pending")
        }
        general.append("Resource type: " + request.type)
        if let mime = details?.mimeType ?? request.mimeType { general.append("MIME type: " + mime) }
        if let address = details?.remoteAddress { general.append("Remote address: " + address) }
        if let proto = details?.networkProtocol { general.append("Protocol: " + proto) }
        if request.cached { general.append("Served from cache") }
        if let bytes = request.bytes { general.append("Size: \(bytes) bytes") }
        if let initiator = details?.initiatorURL ?? request.initiatorURL {
            general.append("Initiator: " + oneLine(initiator, limit: 300) + (details?.initiatorLine.map { ":\($0)" } ?? ""))
        }
        var parts = ["The selected network request:\n" + general.joined(separator: "\n")]
        if let details, !details.requestHeaders.isEmpty {
            parts.append("Request headers:\n" + headers(details.requestHeaders))
        }
        if let details, !details.responseHeaders.isEmpty {
            parts.append("Response headers:\n" + headers(details.responseHeaders))
        }
        let timingText = timing(request)
        if !timingText.isEmpty { parts.append("Timing:\n" + timingText) }
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    // MARK: Console

    static func frame(_ frame: ConsoleCallFrame) -> String {
        guard !frame.url.isEmpty else { return frame.name }
        return "\(frame.name) @ \(frame.url):\(frame.lineNumber):\(frame.columnNumber)"
    }

    static func console(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        let kind = line.level == "warning" ? "warning" : line.level == "error" ? "error" : "message"
        var parts = ["The Console " + kind + ":\n" + trim(line.text, to: 2_000)]
        if let url = line.url, !url.isEmpty {
            parts.append("Logged from: " + url + (line.line.map { ":\($0)" } ?? ""))
        }
        let frames = line.details?.stackTrace ?? []
        if !frames.isEmpty {
            parts.append("Stack trace:\n" + lines(frames.prefix(stackFrames).map(frame), within: 1_500))
        }
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    // MARK: Performance

    /// How much of an entry's call tree goes with it, as Chrome's
    /// performance agent sends the selected node with its parents and
    /// heaviest children.
    static let callTreeAncestors = 6
    static let callTreeChildren = 8
    static let fileBudget = 3_600

    private static func time(_ milliseconds: Double) -> String { DeveloperPerformanceRuler.label(milliseconds) }

    /// The data keys that say what an entry was about, in the order worth reading.
    private static let traceDataKeys = ["url", "scriptName", "scriptLine", "lineNumber", "functionName", "name",
                                        "type", "message", "nodes", "score"]

    /// A Performance entry and its place in the call tree: its name, when
    /// and how long it ran and on its own, what it was about, its stack, the
    /// entries it ran inside, and the children that took longest.
    static func traceEvent(_ event: DeveloperPerformanceEvent, in profile: DeveloperPerformanceProfile) -> String {
        var general: [String] = ["Name: " + event.title, "Record type: " + event.type,
                                 "Category: " + event.category.rawValue, "Start: " + time(event.start) + " into the recording",
                                 "Duration: " + time(event.duration), "Self time: " + time(event.selfTime)]
        if let detail = event.detail, !detail.isEmpty { general.append("Details: " + oneLine(detail, limit: 300)) }
        for key in traceDataKeys {
            if let value = event.data[key], !value.isEmpty { general.append(key + ": " + oneLine(value, limit: 300)) }
        }
        if event.parent == nil, event.duration > DeveloperPerformanceProfile.longTask {
            general.append("This is a long task: it ran " + time(event.duration - DeveloperPerformanceProfile.longTask)
                           + " past the 50 ms budget.")
        }
        var parts = ["The selected item in the Performance recording's Main track:\n" + general.joined(separator: "\n")]
        if !event.stack.isEmpty {
            parts.append("Its JavaScript stack:\n" + lines(Array(event.stack.prefix(stackFrames)), within: 800))
        }
        var ancestors: [String] = []
        var parent = event.parent
        while let id = parent, profile.events.indices.contains(id), ancestors.count < callTreeAncestors {
            let item = profile.events[id]
            ancestors.append(callTreeLine(item, withSelfTime: false))
            parent = item.parent
        }
        if !ancestors.isEmpty {
            parts.append("It ran inside (innermost first):\n" + ancestors.joined(separator: "\n"))
        }
        let children = event.children.filter { profile.events.indices.contains($0) }
            .map { profile.events[$0] }
            .sorted { $0.duration > $1.duration }
        if !children.isEmpty {
            var list = children.prefix(callTreeChildren).map { callTreeLine($0, withSelfTime: true) }
            if children.count > callTreeChildren { list.append("… and \(children.count - callTreeChildren) more") }
            parts.append("Its children, longest first:\n" + list.joined(separator: "\n"))
        }
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    /// One entry of the call tree: its name, what it was about, and its time.
    private static func callTreeLine(_ event: DeveloperPerformanceEvent, withSelfTime: Bool) -> String {
        var line = event.title
        if let detail = event.detail, !detail.isEmpty { line += " (" + oneLine(detail, limit: 80) + ")" }
        line += " — " + time(event.duration)
        if withSelfTime { line += ", self " + time(event.selfTime) }
        return line
    }

    /// A Performance insight as its card shows it: whether it passed, what
    /// it checks, and what it found.
    static func insight(_ insight: DeveloperPerformanceInsight) -> String {
        let verdict: String
        switch insight.verdict {
        case .fail: verdict = "failed"
        case .pass: verdict = "passed"
        case .info: verdict = "for information"
        }
        var heading = "The Performance insight “" + insight.title + "” (" + verdict + ")"
        if let headline = insight.headline { heading += ": " + headline }
        var parts: [String] = [heading, "What it checks:\n" + insight.explanation]
        if !insight.rows.isEmpty {
            let rows = insight.rows.map { row -> String in
                var text = (row.failing ? "[problem] " : "") + row.label + ": " + row.value
                if let detail = row.detail, !detail.isEmpty { text += " (" + oneLine(detail, limit: 200) + ")" }
                return text
            }
            parts.append("What it found:\n" + lines(rows, within: 2_500))
        }
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    // MARK: Sources

    /// The lines of `text` that fit `limit`, centred on `line` (1-based)
    /// when the whole file doesn't fit, each numbered as Sources numbers it.
    static func excerpt(_ text: String, around line: Int?, limit: Int = fileBudget) -> String {
        let all = text.components(separatedBy: "\n")
        func numbered(_ index: Int) -> String { "\(index + 1): " + all[index] }
        let whole = all.indices.map(numbered)
        if whole.reduce(0, { $0 + $1.count + 1 }) <= limit { return whole.joined(separator: "\n") }
        let centre = min(max(0, (line ?? 1) - 1), max(0, all.count - 1))
        var lower = centre, upper = centre
        var used = numbered(centre).count
        // Grow both ways from the caret's line until the budget is spent.
        while true {
            var grew = false
            if upper + 1 < all.count, used + numbered(upper + 1).count + 1 <= limit {
                upper += 1
                used += numbered(upper).count + 1
                grew = true
            }
            if lower > 0, used + numbered(lower - 1).count + 1 <= limit {
                lower -= 1
                used += numbered(lower).count + 1
                grew = true
            }
            if !grew { break }
        }
        var shown = (lower...upper).map { numbered($0) }
        // A single line past the budget (minified code): cut it.
        if shown.count == 1 { shown[0] = String(shown[0].prefix(limit)) + "…" }
        if lower > 0 { shown.insert("… (lines 1–\(lower) not shown)", at: 0) }
        if upper < all.count - 1 { shown.append("… (lines \(upper + 2)–\(all.count) not shown)") }
        return shown.joined(separator: "\n")
    }

    /// A Sources language as the context names it.
    static func languageName(_ language: SourceLanguage) -> String {
        switch language {
        case .javascript(let typescript, let jsx):
            (typescript ? "TypeScript" : "JavaScript") + (jsx ? " (JSX)" : "")
        case .css: "CSS"
        case .html: "HTML"
        case .json: "JSON"
        case .plain: "Plain text"
        }
    }

    /// A file open in Sources, as Chrome's file agent sends it: its name,
    /// address and kind, the caret's line and any selection, and its text,
    /// around the caret when the whole file is too long.
    static func file(url: String, language: String, text: String, line: Int?, selection: String?) -> String {
        var general = ["File name: " + SourceTree.fileName(url), "URL: " + oneLine(url, limit: 500),
                       "Language: " + language, "Lines: \(text.components(separatedBy: "\n").count)"]
        if let line { general.append("The caret is on line \(line).") }
        var parts = ["The file open in Sources:\n" + general.joined(separator: "\n")]
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("The selected text:\n```\n" + trim(selection, to: 800) + "\n```")
        }
        let budget = max(800, fileBudget - (selection.map { min($0.count, 800) } ?? 0))
        parts.append("Its contents (line numbers added):\n```\n" + excerpt(text, around: line, limit: budget) + "\n```")
        return trim(parts.joined(separator: "\n\n"), to: contextBudget)
    }

    // MARK: Prompt

    /// What the model is told once per chat.
    static let instructions = """
        You are AI assistance in a web browser's developer tools. You help web developers understand and fix \
        the page they are inspecting. Answer concisely, in short paragraphs or lists, and use Markdown code \
        blocks for code. Base your answer on the context you are given; if it isn't enough, say what to check \
        next. When the context isn't enough, or the user asks about the page's live state, call the \
        runJavaScript tool with the code; don't write the code in your answer or ask for permission, because \
        the user approves each script first in the app. Keep scripts short and read-only, ending with the value \
        you need, unless the user asks you to change the page. Then answer from the result.
        """

    /// Characters a chat's model session may read and write before it is
    /// started afresh: about 3,000 tokens, under the 4,096 window with room
    /// for the instructions and the next answer.
    static let sessionBudget = 9_000

    /// Whether the conversation so far and the next prompt would outgrow
    /// the window, so the next turn starts a fresh session.
    static func needsFreshSession(spent: Int, next: Int) -> Bool {
        spent + next + instructions.count > sessionBudget
    }

    /// One turn's prompt: the context (on the first turn, or when it
    /// changed) and the question, each trimmed to its budget.
    static func prompt(question: String, context: String?) -> String {
        let asked = trim(question.trimmingCharacters(in: .whitespacesAndNewlines), to: questionBudget)
        guard let context, !context.isEmpty else { return asked }
        return "# Context\n\n" + trim(context, to: contextBudget) + "\n\n# Question\n\n" + asked
    }
}
