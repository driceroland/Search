import AppKit
import Foundation
import UniformTypeIdentifiers

// Chrome's Coverage drawer tool (More tools › Coverage) on WebKit's
// inspector protocol. JavaScript comes from JavaScriptCore's control flow
// profiler (Runtime.enableControlFlowProfiler, Runtime.getBasicBlocks),
// which only instruments code compiled after it is turned on: so, as with
// Chrome's "Start instrumenting coverage and reload page", recording
// reloads the page. WebKit has no rule-usage tracking for CSS, so a rule
// counts as used when its selector matches something in the document now,
// which is close to Chrome's answer but not the same.

/// Coverage's arithmetic, apart from the protocol: basic blocks into used
/// and unused ranges, ranges into lines for the Sources gutter, CSS rules
/// into used bytes, and the table's filtering and footer.
enum DeveloperCoverageMath {
    /// One of `Runtime.getBasicBlocks`' blocks. `end` is the offset of the
    /// block's last character, as JavaScriptCore counts it.
    struct Block: Equatable {
        var start: Int
        var end: Int
        var executed: Bool
    }

    /// A stretch of a script, `start..<end` in UTF-16 offsets.
    struct Range: Equatable {
        var start: Int
        var end: Int
        var used: Bool
        var length: Int { end - start }
    }

    static func blocks(_ raw: [[String: Any]]) -> [Block] {
        raw.compactMap { item in
            guard let start = item["startOffset"] as? Int, let end = item["endOffset"] as? Int else { return nil }
            let executed = item["hasExecuted"] as? Bool ?? ((item["executionCount"] as? Int ?? 0) > 0)
            return Block(start: start, end: end, executed: executed)
        }
    }

    /// The script's text as used and unused ranges, in order, touching,
    /// with neighbours of the same kind merged. Blocks nest (a function, the
    /// branches inside it), so the innermost block decides its own text;
    /// text no block covers ran with the code around it and counts as used.
    /// No blocks means the script wasn't instrumented: no ranges at all.
    static func ranges(_ blocks: [Block], length: Int) -> [Range] {
        guard length > 0 else { return [] }
        let spans: [(start: Int, end: Int, executed: Bool)] = blocks.compactMap { block in
            let start = max(0, block.start), end = min(length, block.end + 1)
            return start < end ? (start, end, block.executed) : nil
        }
        guard !spans.isEmpty else { return [] }
        var cuts = Set([0, length])
        for span in spans {
            cuts.insert(span.start)
            cuts.insert(span.end)
        }
        let edges = cuts.sorted()
        let index = Dictionary(uniqueKeysWithValues: edges.enumerated().map { ($1, $0) })
        var used = Array(repeating: true, count: edges.count - 1)
        // Outermost first, so a block inside another paints over it; of two
        // blocks over the same text, the executed one goes last and wins.
        let ordered = spans.sorted {
            let left = $0.end - $0.start, right = $1.end - $1.start
            return left != right ? left > right : (!$0.executed && $1.executed)
        }
        for span in ordered {
            guard let from = index[span.start], let to = index[span.end] else { continue }
            for segment in from..<to { used[segment] = span.executed }
        }
        var result: [Range] = []
        for segment in used.indices {
            let start = edges[segment], end = edges[segment + 1]
            if let last = result.last, last.used == used[segment], last.end == start {
                result[result.count - 1].end = end
            } else {
                result.append(Range(start: start, end: end, used: used[segment]))
            }
        }
        return result
    }

    // MARK: Per function

    /// Chrome's coverage type: "Per function" counts a function as used
    /// once it has been called, all of it; "Per block" goes by each block.
    enum Granularity: String, CaseIterable, Identifiable {
        case perFunction = "Per function"
        case perBlock = "Per block"
        var id: Self { self }

        var help: String {
            switch self {
            case .perFunction: "Per function coverage reports whether each function was called."
            case .perBlock: "Per block coverage reports whether each block of code ran."
            }
        }
    }

    /// A function's text, `start..<end` in UTF-16 offsets: from its
    /// `function` keyword, name or parameters to its closing brace.
    struct Function: Equatable {
        var start: Int
        var end: Int
    }

    /// The functions in a script with a braced body, found with Sources'
    /// lexer: declarations and expressions, methods, getters, setters and
    /// arrow functions with braces. An arrow with an expression body counts
    /// as part of the function around it.
    static func functions(_ source: String) -> [Function] {
        let units = Array(source.utf16)
        guard !units.isEmpty else { return [] }
        return units.withUnsafeBufferPointer { u -> [Function] in
            let lexemes = JSLexer.lex(u).filter { !$0.isComment }
            func punctuator(_ lexeme: JSLexeme, _ text: String) -> Bool {
                guard lexeme.kind == .punctuator, lexeme.end - lexeme.start == text.utf16.count else { return false }
                return zip(text.utf16, lexeme.start..<lexeme.end).allSatisfy { $0 == u[$1] }
            }
            func word(_ lexeme: JSLexeme) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: u[lexeme.start..<lexeme.end]), as: UTF16.self)
            }
            let control: Set<String> = ["if", "for", "while", "switch", "catch", "with", "return", "typeof",
                                        "await", "yield", "in", "of", "new", "delete", "void", "throw", "case", "do",
                                        "else"]
            var parens: [Int] = []
            var opening: [Int: Int] = [:]
            var braces: [Int?] = []
            var found: [Function] = []
            for (index, lexeme) in lexemes.enumerated() {
                if punctuator(lexeme, "(") {
                    parens.append(index)
                } else if punctuator(lexeme, ")") {
                    if let opener = parens.popLast() { opening[index] = opener }
                } else if punctuator(lexeme, "{") {
                    var start: Int?
                    if index > 0 {
                        let previous = lexemes[index - 1]
                        if punctuator(previous, "=>"), index > 1 {
                            let parameters = lexemes[index - 2]
                            if punctuator(parameters, ")"), let opener = opening[index - 2] {
                                start = lexemes[opener].start
                            } else if parameters.kind == .identifier {
                                start = parameters.start
                            }
                        } else if punctuator(previous, ")"), let opener = opening[index - 1], opener > 0 {
                            let before = lexemes[opener - 1]
                            let name = before.kind == .identifier || before.kind == .keyword ? word(before) : ""
                            if name == "function" {
                                start = before.start
                            } else if opener > 1, lexemes[opener - 2].kind == .keyword, word(lexemes[opener - 2]) == "function" {
                                start = lexemes[opener - 2].start
                            } else if opener > 2, punctuator(lexemes[opener - 2], "*"),
                                      lexemes[opener - 3].kind == .keyword, word(lexemes[opener - 3]) == "function" {
                                start = lexemes[opener - 3].start
                            } else if !name.isEmpty, !control.contains(name) {
                                start = before.start
                            }
                        }
                    }
                    braces.append(start)
                } else if punctuator(lexeme, "}") {
                    if let entry = braces.popLast(), let start = entry { found.append(Function(start: start, end: lexeme.end)) }
                }
            }
            return found.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        }
    }

    /// Basic blocks as per-function coverage sees them: the script's top
    /// level as one used block, then each function as one block, used when
    /// any block inside it ran. `ranges(_:length:)` then paints the inner
    /// functions over the outer ones.
    static func functionBlocks(_ blocks: [Block], functions: [Function], length: Int) -> [Block] {
        guard !blocks.isEmpty, length > 0 else { return [] }
        var result = [Block(start: 0, end: length - 1, executed: true)]
        for function in functions {
            let ran = blocks.contains { $0.executed && $0.start >= function.start && $0.end <= function.end }
            result.append(Block(start: function.start, end: function.end - 1, executed: ran))
        }
        return result
    }

    // MARK: Export

    /// One file of Chrome's coverage export: the used ranges of its text.
    struct ExportEntry: Codable, Equatable {
        struct Span: Codable, Equatable {
            var start: Int
            var end: Int
        }

        var url: String
        var ranges: [Span]
        var text: String
    }

    static func exportEntry(url: String, text: String, ranges: [Range]) -> ExportEntry {
        ExportEntry(url: url, ranges: ranges.filter(\.used).map { ExportEntry.Span(start: $0.start, end: $0.end) },
                    text: text)
    }

    /// Chrome's "Export…" file: a JSON array of `{url, ranges, text}`.
    static func exportJSON(_ entries: [ExportEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    static func usedBytes(_ ranges: [Range]) -> Int {
        ranges.reduce(0) { $0 + ($1.used ? $1.length : 0) }
    }

    /// Each line's mark for the Sources gutter, by 0-based line in `text`:
    /// used when any of its code ran, unused when it has code and none of it
    /// did. Blank lines, and lines the ranges don't reach, get no mark.
    static func lineUsage(_ ranges: [Range], text: String) -> [Int: Bool] {
        guard !ranges.isEmpty else { return [:] }
        var result: [Int: Bool] = [:]
        var line = 0
        var current = 0
        var offset = 0
        for unit in text.utf16 {
            defer { offset += 1 }
            if unit == 10 { line += 1; continue }
            if unit == 32 || unit == 9 || unit == 13 { continue }
            while current < ranges.count && ranges[current].end <= offset { current += 1 }
            guard current < ranges.count else { break }
            guard ranges[current].start <= offset else { continue }
            if ranges[current].used { result[line] = true } else if result[line] == nil { result[line] = false }
        }
        return result
    }

    // MARK: CSS

    /// One rule from the page's stylesheets, as the page script reports it.
    /// Rules inside @media, @supports and the like come flattened, with
    /// `media` false when their condition doesn't hold now.
    struct CSSRule: Equatable {
        enum Kind: String {
            case style, keyframes, fontFace, other
        }

        var kind: Kind
        /// The rule's text as WebKit serialises it.
        var length: Int
        /// A style rule: whether one of its selectors matches an element
        /// (with :hover, ::before and the like taken off).
        var matched = false
        var media = true
        /// @keyframes' name, @font-face's family.
        var name: String?
        /// A style rule's animation names and font families.
        var references: [String] = []
    }

    static func cssRules(_ raw: [[String: Any]]) -> [CSSRule] {
        raw.compactMap { item in
            guard let kind = (item["kind"] as? String).flatMap(CSSRule.Kind.init(rawValue:)),
                  let length = item["length"] as? Int, length >= 0 else { return nil }
            return CSSRule(kind: kind, length: length, matched: item["matched"] as? Bool ?? false,
                           media: item["media"] as? Bool ?? true, name: item["name"] as? String,
                           references: (item["refs"] as? [String]) ?? [])
        }
    }

    /// A stylesheet's used and total bytes. A style rule is used when it
    /// matches something under media that applies; @keyframes and
    /// @font-face when a used rule names them; anything else (@charset,
    /// @namespace, @page, @property) always.
    static func cssUsage(_ rules: [CSSRule]) -> (used: Int, total: Int) {
        func key(_ name: String) -> String {
            name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines)).lowercased()
        }
        let referenced = Set(rules.filter { $0.kind == .style && $0.matched && $0.media }
            .flatMap(\.references).map(key))
        var used = 0, total = 0
        for rule in rules {
            total += rule.length
            let isUsed: Bool
            switch rule.kind {
            case .style: isUsed = rule.matched && rule.media
            case .keyframes, .fontFace: isUsed = rule.media && rule.name.map { referenced.contains(key($0)) } == true
            case .other: isUsed = true
            }
            if isUsed { used += rule.length }
        }
        return (used, total)
    }

    // MARK: Table

    /// A row of the table: one file, its JavaScript or its CSS.
    struct Entry: Identifiable, Equatable {
        enum Kind: String {
            case javaScript = "JS"
            case css = "CSS"
        }

        var url: String
        var kind: Kind
        var total: Int
        var unused: Int
        var id: String { kind.rawValue + " " + url }
        var used: Int { total - unused }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// Chrome's type filter.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case javaScript = "JavaScript"
        case css = "CSS"
        var id: Self { self }
    }

    /// The rows shown: those whose URL holds the filter text (any case) and
    /// of the type picked, most unused bytes first, as Chrome sorts them.
    static func shown(_ entries: [Entry], text: String, filter: Filter) -> [Entry] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            switch filter {
            case .all: break
            case .javaScript: if entry.kind != .javaScript { return false }
            case .css: if entry.kind != .css { return false }
            }
            return needle.isEmpty || entry.url.localizedCaseInsensitiveContains(needle)
        }
        .sorted { $0.unused != $1.unused ? $0.unused > $1.unused : $0.url < $1.url }
    }

    /// The footer: "12.3 kB of 45.6 kB used (27%)".
    static func summary(_ entries: [Entry]) -> String {
        let total = entries.reduce(0) { $0 + $1.total }
        let used = entries.reduce(0) { $0 + $1.used }
        return "\(bytes(used)) of \(bytes(total)) used (\(percent(used: used, total: total)))"
    }

    static func percent(used: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        let value = Double(used) / Double(total) * 100
        if value == 100 || value == 0 { return "\(Int(value))%" }
        return String(format: "%.1f%%", value)
    }

    /// Bytes as Chrome writes them: B under a kilobyte, then kB and MB.
    static func bytes(_ count: Int) -> String { DeveloperFormat.bytes(count) }
}

/// A recording's state: the page's scripts, their ranges as last read, the
/// stylesheets' usage, and the rows built from them.
@MainActor
final class DeveloperCoverage: ObservableObject {
    typealias Entry = DeveloperCoverageMath.Entry

    private weak var session: DeveloperToolsSession?

    @Published private(set) var recording = false
    /// Whether a recording is being started (the profiler turned on).
    @Published private(set) var starting = false
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var message: String?
    /// Stylesheets from other origins, whose rules the page can't read.
    @Published private(set) var skippedSheets = 0
    /// Gutter marks by script URL: 1-based line → used.
    @Published private(set) var lines: [String: [Int: Bool]] = [:]
    /// Per function or per block. WebKit only reports basic blocks, so per
    /// function is worked out from them: each function, found with the
    /// Sources lexer, counts as used, all of it, when any block in it ran.
    /// Switching redraws what was recorded; it doesn't need a new recording.
    @Published var granularity = DeveloperCoverageMath.Granularity.perBlock {
        didSet {
            guard granularity != oldValue else { return }
            for key in Array(scripts.keys) {
                guard var script = scripts[key] else { continue }
                refresh(&script)
                scripts[key] = script
            }
            publish()
        }
    }

    private struct Script {
        let id: String
        let url: String
        let target: String?
        /// Where the script starts in its file (an inline <script> in a page).
        let startLine: Int
        var source: String?
        var blocks: [DeveloperCoverageMath.Block] = []
        /// The script's functions, found the first time per function needs them.
        var functions: [DeveloperCoverageMath.Function]?
        var ranges: [DeveloperCoverageMath.Range] = []
        var lines: [Int: Bool] = [:]
    }

    private var scripts: [String: Script] = [:]
    private var cssEntries: [Entry] = []
    private var poll: Task<Void, Never>?
    /// Bumped on Clear, so a read already under way doesn't bring old rows back.
    private var generation = 0

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    // MARK: Events

    /// Scripts as they parse, while recording; drained with the session's events.
    func handle(_ method: String, params: [String: Any], targetID: String?) {
        guard recording || lighthouseScripts != nil else { return }
        switch method {
        case "Debugger.scriptParsed":
            // Extension content scripts aren't the page's, as Chrome leaves
            // them out by default; nor are scripts with no file (eval).
            guard params["isContentScript"] as? Bool != true, let id = params["scriptId"] as? String else { return }
            let url = [params["url"], params["sourceURL"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            // WebKit names scripts injected into the page world, the browser's
            // own and extensions', user-script:N; Chrome lists neither.
            guard !url.isEmpty, !url.hasPrefix("data:"), !url.hasPrefix("javascript:"),
                  !url.hasPrefix("user-script:") else { return }
            let script = Script(id: id, url: url, target: targetID, startLine: params["startLine"] as? Int ?? 0)
            if recording { scripts[(targetID ?? "") + "\n" + id] = script }
            if lighthouseScripts != nil { lighthouseScripts?[(targetID ?? "") + "\n" + id] = script }
        case "Debugger.globalObjectCleared":
            // The page (or a frame) navigated: its old scripts are gone.
            if recording {
                if let targetID { scripts = scripts.filter { $0.value.target != targetID } } else { scripts = [:] }
            }
            if let found = lighthouseScripts {
                lighthouseScripts = targetID.map { target in found.filter { $0.value.target != target } } ?? [:]
            }
        default:
            break
        }
    }

    // MARK: Lighthouse

    /// The Lighthouse panel's own capture over its Navigation run's reload
    /// (unused-javascript): the scripts that parsed, apart from a recording's.
    private var lighthouseScripts: [String: Script]?
    /// The profiler was turned on for the capture, so goes off after it.
    private var lighthouseProfiler = false

    /// Before the run's reload: the control flow profiler on (a recording
    /// may have it on already) and the scripts noted as they parse.
    func beginLighthouseCapture() async -> Bool {
        guard let session, session.ready else { return false }
        if !recording {
            do {
                _ = try await session.command("Runtime.enableControlFlowProfiler", targetID: session.runtimeTargetID)
            } catch {
                return false
            }
            lighthouseProfiler = true
        }
        lighthouseScripts = [:]
        return true
    }

    /// After the load: each script's length and unused part, by URL, in
    /// UTF-16 units; the profiler goes off again unless Coverage is recording.
    func endLighthouseCapture() async -> [Entry] {
        let found = lighthouseScripts ?? [:]
        lighthouseScripts = nil
        guard let session, session.ready else { lighthouseProfiler = false; return [] }
        var byURL: [String: Entry] = [:]
        for script in found.values.prefix(400) {
            guard let source = (try? await session.command("Debugger.getScriptSource", ["scriptId": script.id],
                                                           targetID: script.target))?["scriptSource"] as? String,
                  let reply = try? await session.command("Runtime.getBasicBlocks", ["sourceID": script.id],
                                                         targetID: script.target) else { continue }
            let ranges = DeveloperCoverageMath.ranges(DeveloperCoverageMath.blocks(reply["basicBlocks"] as? [[String: Any]] ?? []),
                                                      length: source.utf16.count)
            guard let total = ranges.last?.end, total > 0 else { continue }
            byURL[script.url, default: Entry(url: script.url, kind: .javaScript, total: 0, unused: 0)].total += total
            byURL[script.url]?.unused += total - DeveloperCoverageMath.usedBytes(ranges)
        }
        await cancelLighthouseCapture()
        return Array(byURL.values)
    }

    /// The run ended or stopped: the profiler off if the capture turned it on.
    func cancelLighthouseCapture() async {
        lighthouseScripts = nil
        guard lighthouseProfiler else { return }
        lighthouseProfiler = false
        guard let session, session.ready, !recording else { return }
        _ = try? await session.command("Runtime.disableControlFlowProfiler", targetID: session.runtimeTargetID)
    }

    /// Each stylesheet's used and unused rule text now (unused-css-rules),
    /// as Coverage reads it; sheets from other origins are left out.
    func lighthouseStyleSheets() async -> [Entry]? {
        guard let session, session.ready else { return nil }
        return await readStyleSheets(session)?.entries
    }

    // MARK: Recording

    /// Chrome's record button and "Start instrumenting coverage and reload
    /// page": turns the profiler on, then reloads so the page's scripts are
    /// compiled under it.
    func startAndReload() {
        guard let session, session.ready, !starting else { return }
        message = nil
        if recording {
            clear()
            session.reload()
            return
        }
        starting = true
        Task {
            defer { starting = false }
            do {
                _ = try await session.command("Runtime.enableControlFlowProfiler", targetID: session.runtimeTargetID)
            } catch {
                message = "WebKit couldn’t start instrumenting coverage: " + error.localizedDescription
                return
            }
            clear()
            recording = true
            session.reload()
            startPolling()
        }
    }

    /// Stops recording and keeps what was found, as Chrome does. The last
    /// read comes first: WebKit drops the counts when the profiler is off.
    func stop() {
        guard recording else { return }
        recording = false
        poll?.cancel()
        poll = nil
        Task {
            await update()
            guard let session, session.ready, !recording else { return }
            _ = try? await session.command("Runtime.disableControlFlowProfiler", targetID: session.runtimeTargetID)
        }
    }

    func clear() {
        generation += 1
        scripts = [:]
        cssEntries = []
        entries = []
        lines = [:]
        skippedSheets = 0
    }

    /// DevTools is closing: the profiler goes off with it.
    func detach() async {
        poll?.cancel()
        guard recording, let session else { return }
        recording = false
        _ = try? await session.command("Runtime.disableControlFlowProfiler", targetID: session.runtimeTargetID)
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            // A first read soon after the reload, then about every second
            // and a half, as Chrome's table fills in while recording.
            try? await Task.sleep(for: .milliseconds(800))
            while !Task.isCancelled {
                guard let self, self.recording else { return }
                await self.update()
                try? await Task.sleep(for: .milliseconds(1_500))
            }
        }
    }

    // MARK: Reading

    private func update() async {
        guard let session, session.ready else { return }
        let started = generation
        for key in Array(scripts.keys) {
            guard var script = scripts[key] else { continue }
            if script.source == nil {
                let reply = try? await session.command("Debugger.getScriptSource", ["scriptId": script.id],
                                                       targetID: script.target)
                script.source = reply?["scriptSource"] as? String
            }
            guard script.source != nil,
                  let reply = try? await session.command("Runtime.getBasicBlocks", ["sourceID": script.id],
                                                         targetID: script.target) else { continue }
            script.blocks = DeveloperCoverageMath.blocks(reply["basicBlocks"] as? [[String: Any]] ?? [])
            refresh(&script)
            // Cleared, or the page navigated, while this was being read.
            guard generation == started, scripts[key] != nil else { continue }
            scripts[key] = script
        }
        if let css = await readStyleSheets(session), generation == started {
            cssEntries = css.entries
            skippedSheets = css.skipped
        }
        guard generation == started else { return }
        publish()
    }

    /// The script's ranges and gutter marks from its blocks, per function or
    /// per block as picked.
    private func refresh(_ script: inout Script) {
        guard let source = script.source else { return }
        let length = source.utf16.count
        let ranges: [DeveloperCoverageMath.Range]
        switch granularity {
        case .perBlock:
            ranges = DeveloperCoverageMath.ranges(script.blocks, length: length)
        case .perFunction:
            let functions = script.functions ?? DeveloperCoverageMath.functions(source)
            script.functions = functions
            ranges = DeveloperCoverageMath.ranges(
                DeveloperCoverageMath.functionBlocks(script.blocks, functions: functions, length: length), length: length)
        }
        if ranges != script.ranges {
            script.ranges = ranges
            script.lines = DeveloperCoverageMath.lineUsage(ranges, text: source)
        }
    }

    /// Chrome's "Export…": each covered script's text and used ranges.
    /// Stylesheets are left out: WebKit gives no rule offsets to export.
    func exportEntries() -> [DeveloperCoverageMath.ExportEntry] {
        scripts.values.filter { !$0.ranges.isEmpty }
            .sorted { $0.url != $1.url ? $0.url < $1.url : $0.startLine < $1.startLine }
            .compactMap { script in
                script.source.map { DeveloperCoverageMath.exportEntry(url: script.url, text: $0, ranges: script.ranges) }
            }
    }

    var canExport: Bool { scripts.values.contains { !$0.ranges.isEmpty } }

    func export() {
        let data: Data
        do {
            data = try DeveloperCoverageMath.exportJSON(exportEntries())
        } catch {
            message = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let stamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "Coverage-\(stamp).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let write = { [weak self] (url: URL) in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.message = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                write(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    private func publish() {
        var byURL: [String: Entry] = [:]
        var marks: [String: [Int: Bool]] = [:]
        for script in scripts.values where !script.ranges.isEmpty {
            let total = script.ranges.last?.end ?? 0
            let unused = total - DeveloperCoverageMath.usedBytes(script.ranges)
            byURL[script.url, default: Entry(url: script.url, kind: .javaScript, total: 0, unused: 0)].total += total
            byURL[script.url]?.unused += unused
            for (line, used) in script.lines {
                let shown = script.startLine + line + 1
                marks[script.url, default: [:]][shown] = (marks[script.url]?[shown] ?? false) || used
            }
        }
        let built = Array(byURL.values) + cssEntries
        if built != entries { entries = built }
        if marks != lines { lines = marks }
    }

    /// Each same-origin stylesheet's rules, read and matched in the page.
    private func readStyleSheets(_ session: DeveloperToolsSession) async -> (entries: [Entry], skipped: Int)? {
        guard let reply = try? await session.command("Runtime.evaluate", [
            "expression": Self.styleSheetScript, "returnByValue": true,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: session.runtimeTargetID),
            reply["wasThrown"] as? Bool != true,
            let value = (reply["result"] as? [String: Any])?["value"] as? [String: Any],
            let sheets = value["sheets"] as? [[String: Any]] else { return nil }
        var byURL: [String: (used: Int, total: Int)] = [:]
        var order: [String] = []
        for sheet in sheets {
            guard let url = sheet["url"] as? String, !url.isEmpty else { continue }
            let usage = DeveloperCoverageMath.cssUsage(DeveloperCoverageMath.cssRules(sheet["rules"] as? [[String: Any]] ?? []))
            if byURL[url] == nil { order.append(url) }
            byURL[url, default: (0, 0)].used += usage.used
            byURL[url, default: (0, 0)].total += usage.total
        }
        let entries = order.compactMap { url -> Entry? in
            guard let usage = byURL[url], usage.total > 0 else { return nil }
            return Entry(url: url, kind: .css, total: usage.total, unused: usage.total - usage.used)
        }
        return (entries, value["skipped"] as? Int ?? 0)
    }

    // MARK: Sources

    /// The file's row, for the Sources status bar: its JavaScript, else its CSS.
    func entry(for url: String) -> Entry? {
        entries.first { $0.kind == .javaScript && DeveloperDebugger.sameScript($0.url, url) }
            ?? entries.first { $0.kind == .css && DeveloperDebugger.sameScript($0.url, url) }
    }

    /// The file's gutter marks, by 1-based line, when its scripts were covered.
    func lineUsage(for url: String) -> [Int: Bool] {
        lines.first { DeveloperDebugger.sameScript($0.key, url) }?.value ?? [:]
    }

    /// Each covered script of the file: its text and its ranges as last read.
    func scriptRanges(for url: String) -> [(source: String, ranges: [DeveloperCoverageMath.Range])] {
        scripts.values.filter { DeveloperDebugger.sameScript($0.url, url) && !$0.ranges.isEmpty }
            .sorted { $0.startLine < $1.startLine }
            .compactMap { script in script.source.map { ($0, script.ranges) } }
    }

    // MARK: Page script

    /// Runs in the inspected page. Rules flattened out of @media, @supports,
    /// @layer and the like, with whether their conditions hold; style rules
    /// matched against the document with state pseudo-classes and
    /// pseudo-elements taken off, since those can't be queried. Sheets from
    /// other origins can't be read and are only counted.
    static let styleSheetScript = #"""
    (() => {
        const page = location.href.split(/[?#]/)[0];
        const dynamic = /::?(?:hover|active|focus-visible|focus-within|focus|visited|target|before|after|first-line|first-letter|marker|placeholder|selection|backdrop|file-selector-button|cue|-webkit-[\w-]+|-moz-[\w-]+)(?:\([^()]*\))?/gi;
        const cache = new Map;
        const limit = 20000;
        let count = 0;
        let skipped = 0;
        const sheets = [];
        const seen = new Set;

        function is(rule, name) {
            return typeof globalThis[name] === "function" && rule instanceof globalThis[name];
        }

        function split(list) {
            const parts = [];
            let depth = 0, start = 0;
            for (let i = 0; i < list.length; i++) {
                const c = list[i];
                if (c === "(" || c === "[") depth++;
                else if (c === ")" || c === "]") depth--;
                else if (c === "," && depth === 0) { parts.push(list.slice(start, i)); start = i + 1; }
            }
            parts.push(list.slice(start));
            return parts.map((part) => part.trim()).filter(Boolean);
        }

        function query(selector) {
            if (cache.has(selector))
                return cache.get(selector);
            let found = false;
            try {
                found = !!document.querySelector(selector);
            } catch {}
            cache.set(selector, found);
            return found;
        }

        function matches(selectorText) {
            for (const part of split(selectorText || "")) {
                let stripped = part.replace(dynamic, "").trim();
                if (!stripped || /[>+~]$/.test(stripped))
                    stripped += "*";
                if (query(stripped) || (stripped !== part && query(part)))
                    return true;
            }
            return false;
        }

        function media(text) {
            if (!text)
                return true;
            try { return matchMedia(text).matches; } catch { return true; }
        }

        function names(value) {
            return (value || "").split(",").map((name) => name.trim().replace(/^["']|["']$/g, ""))
                .filter((name) => name && name !== "none" && name !== "initial" && name !== "inherit");
        }

        function walk(rules, applies, out) {
            for (const rule of rules) {
                if (count >= limit)
                    return;
                if (is(rule, "CSSStyleRule")) {
                    count++;
                    const style = rule.style;
                    out.push({kind: "style", length: rule.cssText.length, matched: matches(rule.selectorText),
                              media: applies, refs: names(style.animationName).concat(names(style.fontFamily))});
                } else if (is(rule, "CSSImportRule")) {
                    visit(rule.styleSheet, applies && media(rule.media?.mediaText));
                } else if (is(rule, "CSSMediaRule")) {
                    walk(rule.cssRules, applies && media(rule.media?.mediaText), out);
                } else if (is(rule, "CSSSupportsRule")) {
                    let supported = true;
                    try { supported = CSS.supports(rule.conditionText); } catch {}
                    walk(rule.cssRules, applies && supported, out);
                } else if (is(rule, "CSSKeyframesRule")) {
                    count++;
                    out.push({kind: "keyframes", length: rule.cssText.length, media: applies, name: rule.name});
                } else if (is(rule, "CSSFontFaceRule")) {
                    count++;
                    out.push({kind: "fontFace", length: rule.cssText.length, media: applies,
                              name: names(rule.style.getPropertyValue("font-family"))[0] ?? ""});
                } else if (rule.cssRules) {
                    // @layer, @container, @scope: their rules, as they are.
                    walk(rule.cssRules, applies, out);
                } else {
                    count++;
                    out.push({kind: "other", length: rule.cssText.length, media: applies});
                }
            }
        }

        function visit(sheet, applies) {
            if (!sheet || seen.has(sheet))
                return;
            seen.add(sheet);
            let rules;
            try { rules = sheet.cssRules; } catch { skipped++; return; }
            if (!rules) { skipped++; return; }
            const out = [];
            walk(rules, applies && !sheet.disabled && media(sheet.media?.mediaText), out);
            sheets.push({url: sheet.href ? sheet.href.split(/[?#]/)[0] : page, rules: out});
        }

        try {
            for (const sheet of document.styleSheets)
                visit(sheet, true);
            for (const sheet of document.adoptedStyleSheets ?? [])
                visit(sheet, true);
        } catch {}
        return {sheets, skipped};
    })()
    """#
}
