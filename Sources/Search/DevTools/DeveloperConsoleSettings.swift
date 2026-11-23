import AppKit
import Foundation

// MARK: - Settings

/// The Console settings pane behind Chrome's gear (ConsoleView.ts,
/// renderSettingsPane), with Chrome's defaults. "Keep log" lives on the
/// session as `preserveConsoleLog`.
struct ConsoleSettings: Codable, Equatable {
    var networkMessages = true
    var logXMLHttpRequests = false
    var eagerEvaluation = true
    var historyAutocomplete = true
    var groupSimilar = true
    var userActivation = true
    var corsErrors = true
    /// Chrome's "Show timestamps" (Settings › Preferences › Console).
    var showTimestamps = false
    /// Chrome's "Enable custom formatters" (Settings › Preferences ›
    /// Console): the page's window.devtoolsFormatters draw its objects.
    var customFormatters = false

    init() {}

    /// Settings saved before a setting existed keep the rest, and the new
    /// one starts at Chrome's default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConsoleSettings()
        networkMessages = try container.decodeIfPresent(Bool.self, forKey: .networkMessages) ?? defaults.networkMessages
        logXMLHttpRequests = try container.decodeIfPresent(Bool.self, forKey: .logXMLHttpRequests) ?? defaults.logXMLHttpRequests
        eagerEvaluation = try container.decodeIfPresent(Bool.self, forKey: .eagerEvaluation) ?? defaults.eagerEvaluation
        historyAutocomplete = try container.decodeIfPresent(Bool.self, forKey: .historyAutocomplete) ?? defaults.historyAutocomplete
        groupSimilar = try container.decodeIfPresent(Bool.self, forKey: .groupSimilar) ?? defaults.groupSimilar
        userActivation = try container.decodeIfPresent(Bool.self, forKey: .userActivation) ?? defaults.userActivation
        corsErrors = try container.decodeIfPresent(Bool.self, forKey: .corsErrors) ?? defaults.corsErrors
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? defaults.showTimestamps
        customFormatters = try container.decodeIfPresent(Bool.self, forKey: .customFormatters) ?? defaults.customFormatters
    }

    private static let key = "DeveloperConsoleSettings"

    static var saved: ConsoleSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ConsoleSettings.self, from: data) else { return ConsoleSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// WebKit words its CORS failures differently from Chrome; these are
    /// the messages Chrome's "CORS errors in console" setting hides.
    static func isCORSError(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        guard line.level == "error", ["network", "security", "javascript", nil].contains(line.details?.source) else { return false }
        let text = line.text
        return text.contains("Access-Control-Allow") || text.contains("due to access control checks")
            || text.contains("CORS") || text.contains("Cross-Origin")
    }
}

// MARK: - Filter text

/// Chrome's console filter syntax: words that must all match, `-word` to
/// exclude, `/regex/`, and `url:` / `-url:` for the message's source.
struct ConsoleFilter {
    private enum Term {
        case text(String, negated: Bool)
        case regex(NSRegularExpression, negated: Bool)
        case url(String, negated: Bool)
    }

    private let terms: [Term]
    var isEmpty: Bool { terms.isEmpty }

    init(_ query: String) {
        var terms = [Term]()
        for raw in query.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            let negated = raw.hasPrefix("-") && raw.count > 1
            let token = negated ? String(raw.dropFirst()) : raw
            if token.lowercased().hasPrefix("url:"), token.count > 4 {
                terms.append(.url(String(token.dropFirst(4)), negated: negated))
            } else if token.count > 2, token.hasPrefix("/"), token.hasSuffix("/"),
                      let regex = try? NSRegularExpression(pattern: String(token.dropFirst().dropLast()), options: [.caseInsensitive]) {
                terms.append(.regex(regex, negated: negated))
            } else if !token.isEmpty, token != "-" {
                terms.append(.text(token, negated: negated))
            }
        }
        self.terms = terms
    }

    func accepts(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = ConsoleLayout.searchableText(line)
        let url = line.url ?? line.details?.stackTrace.first?.url ?? ""
        for term in terms {
            switch term {
            case .text(let needle, let negated):
                if text.localizedCaseInsensitiveContains(needle) == negated { return false }
            case .regex(let regex, let negated):
                let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                if found == negated { return false }
            case .url(let needle, let negated):
                if url.localizedCaseInsensitiveContains(needle) == negated { return false }
            }
        }
        return true
    }
}

// MARK: - Sidebar

/// The Console sidebar's groups (ConsoleSidebar.ts): every message, the
/// page's own console calls, and one per level, each split by source file.
enum ConsoleSidebarGroup: String, CaseIterable, Identifiable {
    case messages, user, errors, warnings, info, verbose

    var id: String { rawValue }

    var levels: Set<ConsoleLevel>? {
        switch self {
        case .messages, .user: return nil
        case .errors: return [.errors]
        case .warnings: return [.warnings]
        case .info: return [.info]
        case .verbose: return [.verbose]
        }
    }

    var symbol: String {
        switch self {
        case .messages: return "list.bullet"
        case .user: return "person.circle"
        case .errors: return "xmark.circle.fill"
        case .warnings: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .verbose: return "ladybug"
        }
    }

    /// Chrome's plural strings: "3 messages", "No errors", "1 info".
    func title(_ count: Int) -> String {
        let (none, one, many): (String, String, String)
        switch self {
        case .messages: (none, one, many) = ("No messages", "message", "messages")
        case .user: (none, one, many) = ("No user messages", "user message", "user messages")
        case .errors: (none, one, many) = ("No errors", "error", "errors")
        case .warnings: (none, one, many) = ("No warnings", "warning", "warnings")
        case .info: (none, one, many) = ("No info", "info", "info")
        case .verbose: (none, one, many) = ("No verbose", "verbose", "verbose")
        }
        return count == 0 ? none : "\(count) " + (count == 1 ? one : many)
    }

    func contains(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        guard ConsoleSidebarFilter.counted(line) else { return false }
        switch self {
        case .messages: return true
        case .user: return line.details?.source == "console-api"
        default: return levels?.contains(ConsoleLevel(line.level)) == true
        }
    }
}

struct ConsoleSidebarFilter: Equatable {
    var group = ConsoleSidebarGroup.messages
    /// A source file under the group; "" is Chrome's `<other>`.
    var url: String?

    var isEmpty: Bool { group == .messages && url == nil }

    static func counted(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        line.level != "command" && line.level != "result" && line.details?.type != "endGroup"
            && line.details?.type != "clear" && line.details?.type != "navigation"
    }

    static func source(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        line.url ?? line.details?.stackTrace.first?.url ?? ""
    }

    func accepts(_ line: DeveloperToolsSession.ConsoleLine) -> Bool {
        guard !isEmpty else { return true }
        // Commands and results stay, as Chrome keeps them under any group.
        guard Self.counted(line) else { return line.level == "command" || line.level == "result" }
        guard group.contains(line) else { return false }
        return url.map { Self.source(line) == $0 } ?? true
    }

    /// Counts for each group, and per source file within it.
    static func tally(_ lines: [DeveloperToolsSession.ConsoleLine]) -> [ConsoleSidebarGroup: (count: Int, files: [(url: String, count: Int)])] {
        var output = [ConsoleSidebarGroup: (count: Int, files: [(url: String, count: Int)])]()
        for group in ConsoleSidebarGroup.allCases {
            var files = [String: Int]()
            var order = [String]()
            var count = 0
            for line in lines where group.contains(line) {
                count += line.repeatCount
                let url = source(line)
                if files[url] == nil { order.append(url) }
                files[url, default: 0] += line.repeatCount
            }
            output[group] = (count, order.map { ($0, files[$0] ?? 0) })
        }
        return output
    }
}

// MARK: - Live expressions

/// One of Chrome's pinned "live expressions" (ConsolePinPane.ts).
struct ConsoleLiveExpression: Identifiable, Equatable {
    let id = UUID()
    var expression: String
    var result: String?
    var failed = false
}

// MARK: - Session commands

extension DeveloperToolsSession {
    /// Re-evaluates the live expressions, as Chrome does while they show.
    /// Like Chrome, a committed expression runs with side effects allowed.
    func refreshLiveExpressions() async {
        guard ready else { return }
        for item in consoleStore.liveExpressions {
            let text = item.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            var shown: String?
            var failed = false
            if !text.isEmpty, consoleStore.editingLive == item.id {
                let preview = await consoleEagerPreview(text)
                shown = preview.map { ConsoleFormat.inline($0, nested: true) }
                failed = preview == nil
            } else if !text.isEmpty {
                let reply = try? await bridge("return await perchConsole.live(expression);", ["expression": text]) as? [String: Any]
                if let raw = reply?["value"] as? [String: Any], reply?["wasThrown"] as? Bool != true {
                    shown = ConsoleFormat.inline(ConsoleRemoteObject(raw), nested: true)
                } else {
                    failed = true
                }
            }
            guard let index = consoleStore.liveExpressions.firstIndex(where: { $0.id == item.id }),
                  consoleStore.liveExpressions[index].expression == item.expression else { continue }
            if consoleStore.liveExpressions[index].result != shown || consoleStore.liveExpressions[index].failed != failed {
                consoleStore.liveExpressions[index].result = shown
                consoleStore.liveExpressions[index].failed = failed
            }
        }
    }

    /// "Store as global variable": the object becomes `temp1`, `temp2`…,
    /// then Chrome evaluates that name so it shows in the log.
    @discardableResult
    func storeConsoleObjectAsGlobal(_ object: ConsoleRemoteObject, targetID: String?) -> Task<String?, Never>? {
        guard let id = object.objectId else { return nil }
        return Task { [weak self] in
            guard let self else { return nil }
            let name = try? await self.bridge("return await perchConsole.storeAsGlobal(objectId, target);", [
                "objectId": id, "target": targetID as Any? ?? NSNull(),
            ]) as? String
            if let name { self.evaluateInConsole(name) }
            return name
        }
    }

    /// "Copy object": the value as JSON, as Chrome's copy() writes it.
    func copyConsoleObject(_ object: ConsoleRemoteObject, targetID: String?) {
        guard let id = object.objectId else {
            Self.copyToPasteboard(object.type == "string" ? object.plainText : ConsoleFormat.inline(object, nested: true))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let text = try? await self.bridge("return await perchConsole.copyText(objectId, target);", [
                "objectId": id, "target": targetID as Any? ?? NSNull(),
            ]) as? String
            Self.copyToPasteboard(text ?? ConsoleFormat.inline(object))
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The log as text, one message per line with its source, the way
    /// "Copy all messages" and "Save as…" write it.
    func consoleText(_ rows: [ConsoleRow]) -> String {
        rows.map { row in
            let line = row.line
            let indent = String(repeating: "    ", count: row.depth)
            var text = ConsoleLayout.searchableText(line).trimmingCharacters(in: .whitespaces)
            if let url = line.url, !url.isEmpty, text.hasSuffix(url) { text = String(text.dropLast(url.count)).trimmingCharacters(in: .whitespaces) }
            let location = line.url.flatMap { $0.isEmpty ? nil : ConsoleFormat.location($0, line: line.line) + " " } ?? ""
            let prefix = line.level == "command" ? "> " : line.level == "result" ? "< " : ""
            return indent + location + prefix + text + (row.count > 1 ? " (\(row.count))" : "")
        }.joined(separator: "\n")
    }

    /// Chrome's "Save as…": `host-timestamp.log`.
    func saveConsole(_ rows: [ConsoleRow]) {
        let text = consoleText(rows)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(host)-\(Int(Date().timeIntervalSince1970 * 1000)).log"
        panel.allowedContentTypes = [.log, .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// "Log XMLHttpRequests": Chrome's verbose "XHR finished loading" line.
    func logConsoleRequest(_ params: [String: Any], in network: [Request], to logs: inout [ConsoleLine]) {
        guard consoleStore.settings.logXMLHttpRequests, let id = params["requestId"] as? String,
              let request = network.last(where: { $0.id == id }) else { return }
        let kind = request.type.lowercased()
        guard kind == "xhr" || kind == "fetch" else { return }
        let label = kind == "xhr" ? "XHR" : "Fetch"
        logs.append(ConsoleLine(level: "debug", text: "\(label) finished loading: \(request.method) \"\(request.url)\".",
                                url: request.initiatorURL, details: ConsoleMessageDetails(source: "network")))
    }
}
