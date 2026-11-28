import AppKit
import SwiftUI

// The Sources panel's code view, as Chrome's: line numbers down the side
// (click one for a breakpoint), the line the caret is on lit, colours by
// token, ⌘F to find in the file, ⌃G to go to a line, and the `{}` button
// at the bottom that pretty-prints minified code — offered by an infobar
// when the file looks minified.
//
// The text is one NSTextView. Tokens are worked out off the main thread and
// painted as temporary attributes, a few thousand characters at a time, only
// where the view is looking: a 500 KB bundle on one line costs no more to
// show than a short file.

/// A breakpoint set at a column, as from a pretty-printed line: 1-based
/// line, 0-based column, as the inspector protocol counts columns.
struct SourceBreakpoint: Hashable {
    var line: Int
    var column: Int
}

// MARK: Document

@MainActor
final class SourceDocument: ObservableObject {
    struct Display {
        var id: Int
        var text: String
        var lineStarts: [Int]
        /// Where to put the caret once shown, as a UTF-16 offset.
        var caret: Int?
    }

    private struct Pretty {
        var text: String
        var lineStarts: [Int]
        var lines: [(line: Int, column: Int)]
        var firstLine: [Int: Int]
        var lineAt: [SourceBreakpoint: Int]
        /// Formatted line (0-based) for each original offset, as sorted pairs.
        var origins: [(offset: Int, line: Int)]
    }

    let url: String
    let language: SourceLanguage
    private let original: String
    private let originalStarts: [Int]
    private var prettyResult: Pretty?
    private var tokensByID: [Int: [SourceToken]] = [:]

    @Published private(set) var display: Display
    @Published private(set) var tokens: (id: Int, list: [SourceToken])?
    @Published private(set) var pretty = false
    @Published private(set) var formatting = false
    @Published private(set) var minified = false
    @Published var offerDismissed: Bool
    /// The caret, as the view last reported it.
    var caret = 0
    /// How far down the view was scrolled, kept while another tab is in
    /// front so coming back finds the same place, as in Chrome.
    var scrollY: CGFloat = 0
    /// The text as edited, for a file served from Local Overrides, until
    /// it is saved and after: the view shows it when it comes back.
    var editedText: String?

    private static var prettyURLs = Set<String>()
    private static var dismissedURLs = Set<String>()

    init(text: String, url: String, type: String) {
        self.url = url
        original = text
        language = SourceLanguage.detect(url: url, type: type, text: text)
        originalStarts = SourceLexing.lineStarts(text)
        display = Display(id: 0, text: text, lineStarts: originalStarts)
        offerDismissed = Self.dismissedURLs.contains(url)
        let language = language
        Task.detached(priority: .userInitiated) { [weak self] in
            let minified = language.canPrettyPrint && SourceLexing.looksMinified(text)
            await self?.finishPreparing(minified: minified)
        }
        highlight(id: 0, text: text)
    }

    private func finishPreparing(minified: Bool) {
        self.minified = minified
        if Self.prettyURLs.contains(url), !pretty { togglePretty() }
    }

    var offersPrettyPrint: Bool { minified && !pretty && !offerDismissed && !formatting && language.canPrettyPrint }

    func dismissOffer() {
        offerDismissed = true
        Self.dismissedURLs.insert(url)
    }

    private func highlight(id: Int, text: String) {
        if let cached = tokensByID[id] {
            tokens = (id, cached)
            return
        }
        guard language != .plain else { return }
        let language = language
        Task.detached(priority: .userInitiated) { [weak self] in
            let list = SourceHighlighter.tokens(text, language: language)
            await self?.highlighted(id: id, list)
        }
    }

    private func highlighted(id: Int, _ list: [SourceToken]) {
        tokensByID[id] = list
        if display.id == id { tokens = (id, list) }
    }

    func togglePretty() {
        guard language.canPrettyPrint, !formatting else { return }
        if pretty {
            pretty = false
            Self.prettyURLs.remove(url)
            let offset = prettyResult.map { originalOffset(ofLine: lineIndex(caret, in: $0.lineStarts), in: $0) } ?? 0
            show(id: 0, text: original, starts: originalStarts, caret: offset)
            return
        }
        Self.prettyURLs.insert(url)
        if let prettyResult {
            pretty = true
            show(id: 1, text: prettyResult.text, starts: prettyResult.lineStarts, caret: formattedOffset(forOriginal: caret, in: prettyResult))
            return
        }
        formatting = true
        let text = original, language = language, starts = originalStarts
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.prepare(SourceFormatter.format(text, language: language), originalStarts: starts)
            await self?.formatted(result)
        }
    }

    private func formatted(_ result: Pretty) {
        prettyResult = result
        formatting = false
        pretty = true
        show(id: 1, text: result.text, starts: result.lineStarts, caret: formattedOffset(forOriginal: caret, in: result))
    }

    private func show(id: Int, text: String, starts: [Int], caret: Int?) {
        tokens = nil
        display = Display(id: id, text: text, lineStarts: starts, caret: caret)
        highlight(id: id, text: text)
    }

    nonisolated private static func prepare(_ formatted: FormattedSource, originalStarts: [Int]) -> Pretty {
        var lines = [(line: Int, column: Int)]()
        lines.reserveCapacity(formatted.origins.count)
        var firstLine = [Int: Int]()
        var lineAt = [SourceBreakpoint: Int]()
        var origins = [(offset: Int, line: Int)]()
        var last = (line: 1, column: 0)
        for (index, origin) in formatted.origins.enumerated() {
            if let origin {
                var low = 0, high = originalStarts.count - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if originalStarts[mid] <= origin { low = mid } else { high = mid - 1 }
                }
                last = (low + 1, origin - originalStarts[low])
                if firstLine[last.line] == nil { firstLine[last.line] = index + 1 }
                let position = SourceBreakpoint(line: last.line, column: last.column)
                if lineAt[position] == nil { lineAt[position] = index + 1 }
                if origins.last.map({ origin > $0.offset }) ?? true { origins.append((origin, index)) }
            }
            lines.append(last)
        }
        return Pretty(text: formatted.text, lineStarts: SourceLexing.lineStarts(formatted.text), lines: lines,
                      firstLine: firstLine, lineAt: lineAt, origins: origins)
    }

    private func lineIndex(_ offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func originalOffset(ofLine index: Int, in pretty: Pretty) -> Int {
        guard index < pretty.lines.count else { return 0 }
        let position = pretty.lines[index]
        return originalStarts[min(position.line - 1, originalStarts.count - 1)] + position.column
    }

    private func formattedOffset(forOriginal offset: Int, in pretty: Pretty) -> Int {
        var low = 0, high = pretty.origins.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if pretty.origins[mid].offset <= offset { low = mid } else { high = mid - 1 }
        }
        let line = pretty.origins[low].line
        return line < pretty.lineStarts.count ? pretty.lineStarts[line] : 0
    }

    /// Where an original line (1-based) shows: itself, or its first
    /// formatted line once pretty-printed.
    func shownLine(forOriginal line: Int) -> Int {
        guard pretty, let prettyResult else { return line }
        if let first = prettyResult.firstLine[line] { return first }
        // A line with no code of its own: the next one that has some.
        let later = prettyResult.firstLine.filter { $0.key > line }.min { $0.key < $1.key }
        return later?.value ?? max(1, prettyResult.lineStarts.count)
    }

    /// Where an original position (1-based line, 0-based column) shows,
    /// to the statement: a minified file's one line spreads over many once
    /// pretty-printed, and a paused statement is on one of them.
    func shownLine(forOriginal line: Int, column: Int) -> Int {
        guard pretty, let prettyResult, !prettyResult.origins.isEmpty, line >= 1, line <= originalStarts.count else {
            return shownLine(forOriginal: line)
        }
        let offset = originalStarts[line - 1] + max(0, column)
        var low = 0, high = prettyResult.origins.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if prettyResult.origins[mid].offset <= offset { low = mid } else { high = mid - 1 }
        }
        return prettyResult.origins[low].line + 1
    }

    /// The UTF-16 offset in the shown text of an original position: the
    /// statement itself in the original, the start of its line once
    /// pretty-printed.
    func shownOffset(forOriginal line: Int, column: Int) -> Int {
        let starts = display.lineStarts
        let length = (display.text as NSString).length
        if pretty {
            let shown = min(max(shownLine(forOriginal: line, column: column), 1), starts.count)
            return starts[shown - 1]
        }
        guard line >= 1, line <= starts.count else { return length }
        let end = line < starts.count ? starts[line] : length
        return min(starts[line - 1] + max(0, column), max(starts[line - 1], end - 1))
    }

    /// The shown line (1-based) a breakpoint is marked on, or nil when a
    /// pretty-printed view has no line for it.
    func shownBreakpointLine(_ line: Int, column: Int?) -> Int? {
        guard pretty, let prettyResult else { return line }
        if let column { return prettyResult.lineAt[SourceBreakpoint(line: line, column: column)] }
        return prettyResult.firstLine[line]
    }

    /// The text as fetched, before any edits or formatting.
    var originalText: String { original }

    /// An original line's text (1-based), for a breakpoint's snippet.
    func originalLine(_ line: Int) -> String? {
        guard line >= 1, line <= originalStarts.count else { return nil }
        let text = original as NSString
        let end = line < originalStarts.count ? originalStarts[line] : text.length
        return text.substring(with: NSRange(location: originalStarts[line - 1], length: end - originalStarts[line - 1]))
            .trimmingCharacters(in: .newlines)
    }

    // MARK: Breakpoints

    /// What a click on a shown line sets: the original line, and a column
    /// when the line starts partway through one.
    func breakpointTarget(line: Int) -> (line: Int, column: Int?) {
        guard pretty, let prettyResult, line - 1 < prettyResult.lines.count, line > 0 else { return (line, nil) }
        let position = prettyResult.lines[line - 1]
        if prettyResult.firstLine[position.line] == line || position.column == 0 { return (position.line, nil) }
        return (position.line, position.column)
    }

    func shownBreakpoints(lines: Set<Int>, columns: Set<SourceBreakpoint>) -> Set<Int> {
        guard pretty, let prettyResult else { return lines.union(columns.map(\.line)) }
        var shown = Set<Int>()
        for line in lines { if let first = prettyResult.firstLine[line] { shown.insert(first) } }
        for position in columns { if let at = prettyResult.lineAt[position] { shown.insert(at) } }
        return shown
    }
}

// MARK: Gutter markers

/// One line's breakpoint marker, as Chrome draws it: blue for a breakpoint,
/// orange for a conditional one, pink for a logpoint, faded when it is
/// disabled or breakpoints are deactivated.
struct SourceGutterMarker: Equatable {
    var kind: DeveloperDebugger.Breakpoint.Kind
    var enabled: Bool
    /// How many breakpoints show on the line (a pretty-printed line can
    /// hold several set at columns).
    var count = 1

    /// The marker for the breakpoints shown on one line: the enabled ones
    /// decide when there are any; a logpoint outranks a condition, which
    /// outranks a plain breakpoint.
    static func combine(_ items: [DeveloperDebugger.Breakpoint], active: Bool) -> SourceGutterMarker? {
        guard !items.isEmpty else { return nil }
        let enabled = items.filter(\.enabled)
        let deciding = enabled.isEmpty ? items : enabled
        let kind: DeveloperDebugger.Breakpoint.Kind = deciding.contains { $0.kind == .logpoint } ? .logpoint
            : deciding.contains { $0.kind == .conditional } ? .conditional : .regular
        return SourceGutterMarker(kind: kind, enabled: active && !enabled.isEmpty, count: items.count)
    }

    var colour: NSColor {
        switch kind {
        case .regular: return SourceTheme.breakpoint
        case .conditional: return SourceTheme.conditional
        case .logpoint: return SourceTheme.logpoint
        }
    }
}

// MARK: Pane

struct DeveloperSourcePane: View {
    @ObservedObject var session: DeveloperToolsSession
    /// Kept by the open-file tabs (DeveloperSourceTabs), so the file's place
    /// survives another tab coming to the front.
    @ObservedObject private var document: SourceDocument
    @ObservedObject private var debugger: DeveloperDebugger
    @ObservedObject private var coverage: DeveloperCoverage
    @State private var position = SourceTextView.Position()
    @State private var inlineAnnotations: (key: InlineKey, lines: [Int: String])?
    /// Settings › Preferences › Sources › Code folding.
    @AppStorage(DeveloperSourcesPreferences.codeFoldingKey, store: DevDefaults.store) private var codeFolding = false
    @AppStorage(DeveloperSourcesPreferences.scrollPastEndKey, store: DevDefaults.store) private var scrollPastEnd = true
    @AppStorage(DeveloperSourcesPreferences.inlineValuesKey, store: DevDefaults.store) private var inlineValuesOn = true

    init(session: DeveloperToolsSession, document: SourceDocument) {
        self.session = session
        debugger = session.debugger
        coverage = session.coverage
        self.document = document
    }

    /// The Coverage tool's marks for this file's lines, as Chrome's gutter
    /// shows them; none while pretty-printed, whose lines aren't the file's.
    private var coverageLines: [Int: Bool] {
        guard !document.pretty, !document.formatting else { return [:] }
        return coverage.lineUsage(for: document.url)
    }

    /// Performance's line-level profile in the lines shown: pretty-printed,
    /// or an authored file's through its source map, as Chrome's gutter.
    private var profileLines: [Int: Double] {
        guard !session.lineProfile.isEmpty, !document.formatting else { return [:] }
        let maps = session.sourceMaps, document = document
        return session.lineProfile.lines(of: document.url,
                                         original: isAuthored ? { maps.original(url: $0, line: $1, column: $2) } : nil,
                                         shown: { document.shownLine(forOriginal: $0, column: $1) })
    }

    /// Each shown line's breakpoint marker.
    private var markers: [Int: SourceGutterMarker] {
        let url = document.url
        let shown = Dictionary(grouping: debugger.breakpoints.filter { $0.url == url }) {
            document.shownBreakpointLine($0.line, column: $0.column) ?? 0
        }
        var markers: [Int: SourceGutterMarker] = [:]
        for (line, items) in shown where line > 0 {
            markers[line] = SourceGutterMarker.combine(items, active: debugger.breakpointsActive)
        }
        return markers
    }

    /// Where the selected call frame is paused in this file, as an offset
    /// in the text shown: Chrome's execution line.
    private var execution: Int? {
        guard let location = debugger.executionLocation(for: document.url), !document.formatting else { return nil }
        return document.shownOffset(forOriginal: location.line, column: location.column)
    }

    /// What the inline values depend on, cheap to compare on every body
    /// pass: the request itself is built only when this changes.
    private struct InlineKey: Equatable {
        let generation: Int
        let url: String
        let displayID: Int
        let formatting: Bool
        let shown: Bool
        /// Settings › Preferences › Sources › Display variable values inline while debugging.
        let enabled: Bool
    }

    private var inlineKey: InlineKey {
        // Not over a Local Overrides file, nor a snippet edited since it
        // opened: the lines shown aren't the ones running.
        let snippetEdited = isSnippet && snippets.snippet(named: snippetName)?.text != document.display.text
        // Nor a workspace file saved since the page ran it.
        let mappedEdited = mapped && (document.editedText != nil || workspace.needsReload.contains(document.url))
        return InlineKey(generation: debugger.inlineGeneration, url: document.url, displayID: document.display.id,
                         formatting: document.formatting, shown: !overridden && !snippetEdited && !mappedEdited,
                         enabled: inlineValuesOn)
    }

    private var canSetBreakpoints: Bool {
        session.sourceResource?.type == "Script" || (isAuthored && session.sourceMaps.isAuthoredScript(document.url))
    }
    /// A file from a source map (DeveloperSourceMaps), not one the page loaded.
    private var isAuthored: Bool { session.sourceResource?.type == DeveloperSourceMaps.authoredType }
    private var isSnippet: Bool { session.sourceResource?.type == "Snippet" }
    @ObservedObject private var overrides = DeveloperLocalOverrides.shared
    @ObservedObject private var snippets = DeveloperSnippets.shared
    /// Served from the Local Overrides folder: editable, saved with ⌘S.
    private var overridden: Bool { !isSnippet && overrides.isOverridden(document.url) }
    @ObservedObject private var workspace = DeveloperWorkspace.shared
    /// Mapped to a file in a workspace folder: editable, saved to it with ⌘S.
    private var mapped: Bool {
        !isSnippet && !overridden && session.sourceResource?.type != "ContentScript"
            && workspace.isMapped(document.url, page: session.address?.absoluteString)
    }
    private var snippetName: String { String((session.sourceResource?.url ?? "").dropFirst("snippet:///".count)) }
    @State private var ran = false

    /// Everything ⌘P can open: the page's files, content scripts, snippets.
    private var quickOpenFiles: [QuickOpenFile] {
        var files = (session.resources + session.contentScripts + session.sourceMaps.authoredResources).map { resource in
            QuickOpenFile(id: "r:" + resource.id, name: SourceTree.fileName(resource.url),
                          detail: resource.url.hasPrefix("http") ? String(resource.url.prefix(while: { $0 != "?" }).dropLast(SourceTree.fileName(resource.url).count).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")) : resource.url)
        }
        files += DeveloperSnippets.shared.snippets.map { QuickOpenFile(id: "s:" + $0.name, name: $0.name, detail: "Snippets") }
        return files
    }

    /// Opens a ⌘P choice; `app.js:120:5` opens it at that line and column.
    private func openQuickFile(_ id: String, line: Int?, column: Int?) {
        let url: String
        if id.hasPrefix("s:"), let snippet = DeveloperSnippets.shared.snippet(named: String(id.dropFirst(2))) {
            session.openSnippet(snippet.name, text: snippet.text)
            url = "snippet:///" + snippet.name
        } else if let resource = (session.resources + session.contentScripts + session.sourceMaps.authoredResources)
                    .first(where: { "r:" + $0.id == id }) {
            if session.sourceResource != resource { session.openSource(resource) }
            url = resource.url
        } else {
            return
        }
        if let line { session.revealSource(url: url, line: max(1, line), column: column.map { max(1, $0) }, showPanel: false) }
    }

    private func runSnippet(_ text: String) {
        session.evaluate(text)
        ran = true
    }

    private var actions: SourceEditorActions {
        let actions = SourceEditorActions()
        let session = session
        let document = document
        actions.canSetBreakpoints = canSetBreakpoints
        let url = document.url
        let breakpointsAt: (Int) -> [DeveloperDebugger.Breakpoint] = { line in
            debugger.breakpoints.filter { $0.url == url && document.shownBreakpointLine($0.line, column: $0.column) == line }
        }
        actions.breakpointsAt = breakpointsAt
        actions.setBreakpointsEnabled = { ids, enabled in
            for id in ids { debugger.setBreakpointEnabled(id, enabled) }
        }
        actions.removeBreakpoints = { ids in
            for id in ids { debugger.removeBreakpoint(id) }
            session.updateBreakpoints()
        }
        actions.breakpointEditor = { line, kind, done in
            // The one on the line, or a new one where a click would set it.
            let existing = breakpointsAt(line).first
            let target = document.breakpointTarget(line: line)
            let original = existing?.line ?? target.line
            let editor = DeveloperBreakpointEditor(
                debugger: debugger, url: url, line: original,
                column: existing != nil ? existing?.column : target.column,
                kind: existing.map { $0.kind == .regular ? kind : $0.kind } ?? kind,
                expression: existing?.expression ?? "",
                snippet: document.originalLine(original), done: done)
            let controller = NSHostingController(rootView: editor)
            controller.sizingOptions = .preferredContentSize
            return controller
        }
        actions.paused = debugger.pause != nil
        actions.clearLineProfile = { session.clearLineProfile() }
        actions.continueToHere = { line in
            debugger.continueToHere(url: url, line: document.breakpointTarget(line: line).line)
        }
        actions.hoverValue = { expression, serial in
            guard let value = await debugger.evaluateForPopover(expression) else { return nil }
            let controller = NSHostingController(rootView: DeveloperHoverValueView(
                debugger: debugger, expression: expression, value: value, path: "popover:\(serial)"))
            controller.sizingOptions = .preferredContentSize
            return controller
        }
        actions.toggleBreakpoint = { line in
            let target = document.breakpointTarget(line: line)
            session.toggleBreakpoint(line: target.line, column: target.column)
        }
        actions.setBreakpoint = { line, condition, log in
            let target = document.breakpointTarget(line: line)
            session.setBreakpoint(line: target.line, column: target.column, condition: condition, log: log)
        }
        actions.evaluate = { session.evaluate($0) }
        actions.addWatch = { debugger.addWatch($0) }
        let tabs = DeveloperSourceTabs.of(session)
        actions.closeTab = { tabs.closeCurrent() }
        actions.showSearch = { tabs.showSearch() }
        actions.url = session.sourceResource?.url ?? ""
        actions.isPretty = document.pretty
        actions.canPrettyPrint = document.language.canPrettyPrint && !isSnippet && !overridden && !mapped
        let overrides = overrides
        let workspace = workspace
        if mapped {
            let page = session.address?.absoluteString
            actions.edited = { text in
                document.editedText = text
                tabs.unsaved.insert(url)
            }
            actions.save = {
                do {
                    let text = document.editedText ?? document.originalText
                    let css = document.language == .css
                    try workspace.save(url: url, page: page, content: text, needsReload: !css)
                    tabs.unsaved.remove(url)
                    if css { DeveloperWorkspace.applyStyleSheet(url: url, text: text, session: session) }
                } catch {
                    session.message = error.localizedDescription
                }
            }
        } else if overridden {
            actions.edited = { text in
                document.editedText = text
                tabs.unsaved.insert(url)
            }
            actions.save = {
                do {
                    let text = document.editedText ?? document.originalText
                    try overrides.save(url: url, content: text)
                    tabs.unsaved.remove(url)
                    if document.language == .css { DeveloperWorkspace.applyStyleSheet(url: url, text: text, session: session) }
                } catch {
                    session.message = error.localizedDescription
                }
            }
        } else if !isSnippet, !isAuthored, session.sourceResource?.type != "ContentScript",
                  session.sourceResource?.type != DeveloperWorker.scriptType,
                  DeveloperLocalOverrides.relativePath(for: url) != nil {
            actions.overrideContent = {
                overrides.overrideContent(url: url, content: document.editedText ?? document.originalText, session: session)
            }
        }
        actions.togglePretty = { document.togglePretty() }
        if !isSnippet {
            actions.revealInSidebar = {
                let shell = DeveloperToolsShell.shared
                let hidden = shell.sourcesNavigatorHidden
                shell.sourcesNavigatorHidden = false
                // Once a navigator put back has appeared to hear it.
                DispatchQueue.main.asyncAfter(deadline: .now() + (hidden ? 0.15 : 0)) {
                    NotificationCenter.default.post(name: DeveloperSourcesNavigator.revealRequest, object: session)
                }
            }
        }
        let type = session.sourceResource?.type
        if type == "Script" || type == "Stylesheet" {
            let sourceMaps = session.sourceMaps
            let css = type == "Stylesheet"
            actions.addSourceMap = { address in sourceMaps.addSourceMap(address, to: url, css: css) }
        }
        if canSetBreakpoints, !url.isEmpty {
            let ignoring = debugger
            actions.ignoreState = ignoring.isListed(url) ? .listed : ignoring.isIgnored(url) ? .byRule : .notIgnored
            actions.setIgnored = { ignoring.setIgnored(url, $0) }
        }
        actions.files = { quickOpenFiles }
        actions.openFile = { openQuickFile($0, line: $1, column: $2) }
        if isSnippet {
            let name = snippetName
            actions.run = { runSnippet($0) }
            actions.edited = { DeveloperSnippets.shared.update(name, text: $0) }
        }
        return actions
    }

    /// The line a Console, Network or debugger link asked for, when it is
    /// in this file, in the lines shown now.
    private var reveal: SourceCodeView.Reveal? {
        guard let asked = session.sourceReveal, DeveloperDebugger.sameScript(asked.url, document.url),
              !document.formatting else { return nil }
        return .init(line: document.shownLine(forOriginal: asked.line),
                     column: document.pretty ? nil : asked.column, serial: asked.serial)
    }

    var body: some View {
        let key = inlineKey
        VStack(spacing: 0) {
            if document.offersPrettyPrint { infobar }
            if mapped, workspace.needsReload.contains(document.url) { reloadNote }
            SourceCodeView(
                document: document,
                markers: markers,
                editable: isSnippet || overridden || mapped,
                folding: codeFolding,
                scrollPastEnd: scrollPastEnd,
                actions: actions,
                reveal: reveal,
                execution: execution,
                coverage: coverageLines,
                profile: profileLines,
                inlineValues: inlineAnnotations?.key == key ? inlineAnnotations?.lines ?? [:] : [:],
                moved:{ position = $0; document.caret = $0.offset },
                revealed: { serial in DispatchQueue.main.async { session.revealedSource(serial) } }
            )
            Divider()
            statusBar
        }
        .frame(minWidth: 200, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: key) {
            guard key.shown, key.enabled,
                  let request = SourceInlineValues.request(for: document, debugger: debugger, sourceMaps: session.sourceMaps) else {
                inlineAnnotations = nil
                return
            }
            let text = document.display.text
            let lineStarts = document.display.lineStarts
            let lines = await Task.detached(priority: .userInitiated) {
                request.annotations(in: text, lineStarts: lineStarts)
            }.value
            guard !Task.isCancelled else { return }
            inlineAnnotations = (key, lines)
        }
    }

    /// After ⌘S on a workspace file: WebKit can't swap a running script
    /// (no Debugger.setScriptSource), so the saved one runs after a reload.
    private var reloadNote: some View {
        let url = document.url
        let isJavaScript: Bool
        if case .javascript = document.language { isJavaScript = true } else { isJavaScript = false }
        let script = isJavaScript || session.sourceResource?.type == "Script"
        return HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(DeveloperToolsStyle.tint)
            Text(script ? "Reload the page to run the saved file" : "Reload the page to use the saved file")
                .lineLimit(1).truncationMode(.tail)
            Button("Reload") {
                workspace.dismissReloadNote(url)
                session.reload()
            }
            .controlSize(.small).fixedSize()
            Spacer(minLength: 0)
            closeButton { workspace.dismissReloadNote(url) }
        }
        .modifier(SourceInfobarStyle())
        .accessibilityElement(children: .contain)
    }

    private var infobar: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(DeveloperToolsStyle.tint)
            // The question goes before it gets cut to "Pretty-print…" beside
            // a button saying the same.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("Pretty-print this minified file?").fixedSize()
                    Button("Pretty-print") { document.togglePretty() }.controlSize(.small).fixedSize()
                }
                Button("Pretty-print") { document.togglePretty() }.controlSize(.small).fixedSize()
                    .help("Pretty-print this minified file")
            }
            Spacer(minLength: 0)
            closeButton { document.dismissOffer() }
        }
        .modifier(SourceInfobarStyle())
    }

    /// An infobar's ✕.
    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
    }

    /// Chrome's: "Line 3, Column 7", or "12 characters selected", or
    /// "2 lines, 40 characters selected".
    static func positionText(_ position: SourceTextView.Position) -> String {
        if position.selected == 0 { return "Line \(position.line.formatted()), Column \(position.column.formatted())" }
        if position.selectedLines > 1 {
            return "\(position.selectedLines.formatted()) lines, \(position.selected.formatted()) characters selected"
        }
        return "\(position.selected.formatted()) characters selected"
    }

    /// Chrome's "(source mapped from bundle.js)": an authored file links
    /// back to the compiled one, at the caret's line where the map has it;
    /// a compiled file says how many authored files its map has.
    @ViewBuilder private var sourceMapLink: some View {
        let maps = session.sourceMaps
        if isAuthored, let compiled = maps.compiledFile(for: document.url) {
            Button("(source mapped from \(SourceTree.fileName(compiled)))") {
                let line = document.pretty ? nil : maps.generated(url: document.url, line: max(0, position.line - 1))
                session.revealSource(url: line?.url ?? compiled, line: (line?.line ?? 0) + 1,
                                     column: line.map { $0.column + 1 }, showPanel: false)
            }
            .buttonStyle(.link)
            .help(compiled)
            Divider().frame(height: 12)
        } else if !isAuthored, maps.authoredCount(for: document.url) > 0 {
            let count = maps.authoredCount(for: document.url)
            Text("Source map: \(count.formatted()) \(count == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
                .help("Its authored files are in the navigator under the top frame.")
            Divider().frame(height: 12)
        }
    }


    private var statusBar: some View {
        HStack(spacing: 8) {
            if isSnippet {
                // Chrome's snippet editor runs from its status bar too.
                Button {
                    runSnippet(DeveloperSnippets.shared.snippet(named: snippetName)?.text ?? "")
                } label: {
                    Label("Run", systemImage: "play.fill").labelStyle(.iconOnly)
                        .foregroundStyle(DeveloperToolsStyle.tint)
                        .frame(width: 20, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Run snippet (⌘↩)")
                Text("⌘↩").foregroundStyle(.secondary)
                if ran {
                    Button("Show result in Console") { session.select(.console); ran = false }
                        .buttonStyle(.link)
                }
                Divider().frame(height: 12)
            }
            Button { document.togglePretty() } label: {
                Text("{}")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(document.pretty ? DeveloperToolsStyle.tint : .secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!document.language.canPrettyPrint || document.formatting || isSnippet || overridden || mapped)
            .help(document.pretty ? "Show original" : "Pretty print")
            .accessibilityLabel("Pretty print")
            .accessibilityValue(document.pretty ? "On" : "Off")
            if document.formatting {
                ProgressView().controlSize(.mini)
                Text("Pretty-printing…").foregroundStyle(.secondary)
            } else {
                Text(Self.positionText(position))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            sourceMapLink
            // Chrome's coverage readout: the file's share used, once the
            // Coverage tool has recorded it; n/a before, as in Chrome.
            Text(coverage.entry(for: document.url).map {
                "Coverage: " + DeveloperCoverageMath.percent(used: $0.used, total: $0.total)
            } ?? "Coverage: n/a")
            .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: AppKit bridge

/// What the editor's context menu, gutter and quick-open box act through.
/// The blue band over the editor that offers pretty-printing or a reload.
private struct SourceInfobarStyle: ViewModifier {
    /// Made once: a dynamic colour built in a body is a new NSColor each time.
    private static let fill = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.2, blue: 0.27, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1)
    })

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .padding(.horizontal, 8).frame(height: 26)
            .background(Self.fill)
            .overlay(alignment: .bottom) { Divider() }
    }
}

final class SourceEditorActions {
    var canSetBreakpoints = false
    /// The breakpoints marked on a shown line.
    var breakpointsAt: (Int) -> [DeveloperDebugger.Breakpoint] = { _ in [] }
    var setBreakpointsEnabled: ([DeveloperDebugger.Breakpoint.ID], Bool) -> Void = { _, _ in }
    var removeBreakpoints: ([DeveloperDebugger.Breakpoint.ID]) -> Void = { _ in }
    /// Chrome's inline breakpoint editor for a shown line, preset to a kind;
    /// it calls back when closed.
    var breakpointEditor: ((_ line: Int, _ kind: DeveloperDebugger.Breakpoint.Kind,
                            _ done: @escaping () -> Void) -> NSViewController?)?
    /// Whether the debugger is paused, for Continue to here.
    var paused = false
    var continueToHere: (Int) -> Void = { _ in }
    /// The hover popover's content for an expression (and the popover's
    /// number), evaluated on the selected frame; nil when there's no value.
    var hoverValue: (@MainActor (String, Int) async -> NSViewController?)?
    var toggleBreakpoint: (Int) -> Void = { _ in }
    var setBreakpoint: (_ line: Int, _ condition: String?, _ log: String?) -> Void = { _, _, _ in }
    var evaluate: (String) -> Void = { _ in }
    var addWatch: (String) -> Void = { _ in }
    /// ⌥W: closes the file's tab.
    var closeTab: (() -> Void)?
    /// ⌥⌘F, ⇧⌘F: Search across all sources.
    var showSearch: (() -> Void)?
    /// The gutter's Clear line-level profile data.
    var clearLineProfile: () -> Void = {}
    var url = ""
    var isPretty = false
    var canPrettyPrint = false
    var togglePretty: () -> Void = {}
    var files: () -> [QuickOpenFile] = { [] }
    var openFile: (String, Int?, Int?) -> Void = { _, _, _ in }
    /// A snippet's: run it (⌘↩), and keep what is typed.
    var run: ((String) -> Void)?
    var edited: ((String) -> Void)?
    /// ⌘S, for a file served from Local Overrides.
    var save: (() -> Void)?
    /// "Override content": copy the file to the overrides folder to edit.
    var overrideContent: (() -> Void)?
    /// "Reveal in sidebar": the file in the navigator.
    var revealInSidebar: (() -> Void)?
    /// "Add source map…", for a compiled script or stylesheet: the map's address.
    var addSourceMap: ((String) -> Void)?
    /// The file's place on the ignore list: added by hand, by a rule or a
    /// map (removed in Settings), or not on it; nil where it can't be.
    enum IgnoreState { case listed, byRule, notIgnored }
    var ignoreState: IgnoreState?
    var setIgnored: (Bool) -> Void = { _ in }
    /// "Ask AI", while AI assistance is on: the text shown, the line
    /// clicked (1-based) and the selection.
}

struct SourceCodeView: NSViewRepresentable {
    @ObservedObject var document: SourceDocument
    var markers: [Int: SourceGutterMarker]
    var editable: Bool
    var folding = false
    var scrollPastEnd = false
    var actions: SourceEditorActions
    var reveal: Reveal? = nil
    /// The paused statement's offset in the shown text.
    var execution: Int? = nil
    /// Coverage marks by 1-based line: true for code that ran.
    var coverage: [Int: Bool] = [:]
    /// Line-level profile milliseconds by 1-based line.
    var profile: [Int: Double] = [:]
    var inlineValues: [Int: String] = [:]
    var moved: (SourceTextView.Position) -> Void
    var revealed: (Int) -> Void = { _ in }

    struct Reveal: Equatable {
        let line: Int
        let column: Int?
        let serial: Int
    }

    func makeNSView(context: Context) -> SourceContainerView {
        let container = SourceContainerView()
        update(container)
        return container
    }

    func updateNSView(_ container: SourceContainerView, context: Context) {
        update(container)
    }

    private func update(_ container: SourceContainerView) {
        let textView = container.textView
        textView.actions = actions
        textView.onMove = moved
        textView.canSetBreakpoints = actions.canSetBreakpoints
        textView.language = document.language
        textView.foldingEnabled = folding
        textView.scrollsPastEnd = scrollPastEnd
        textView.isEditable = editable
        textView.allowsUndo = editable
        let display = document.display
        let kept = self.document
        container.onScroll = { kept.scrollY = $0 }
        if textView.displayID != display.id {
            // A new view for a document shown before: back to its caret and scroll.
            let restoring = textView.displayID == -1 && (kept.caret > 0 || kept.scrollY > 0 || kept.editedText != nil)
            // Read before showing, which scrolls (and reports it).
            let y = kept.scrollY
            if restoring, editable, let edited = kept.editedText {
                textView.showEdited(edited, id: display.id, caret: kept.caret)
            } else {
                textView.show(display.text, lineStarts: display.lineStarts, id: display.id,
                              caret: restoring ? kept.caret : display.caret)
            }
            if restoring {
                DispatchQueue.main.async { container.restoreScroll(y) }
            }
        }
        if let tokens = document.tokens, tokens.id == display.id, textView.tokensID != tokens.id {
            textView.setTokens(tokens.list, id: tokens.id)
        }
        if textView.executionOffset != execution { textView.executionOffset = execution }
        textView.inlineValues = inlineValues
        if !actions.paused, textView.hoverRange != nil || textView.hoverPopover != nil { textView.closeHover() }
        if textView.breakpointMarkers != markers {
            textView.breakpointMarkers = markers
            container.gutter.needsDisplay = true
        }
        if textView.coverageLines != coverage {
            textView.coverageLines = coverage
            container.gutter.needsDisplay = true
        }
        if textView.profileLines != profile {
            textView.profileLines = profile
            container.gutter.updateThickness(lines: textView.lineStarts.count)
            container.gutter.needsDisplay = true
        }
        if let reveal, textView.displayID == display.id, container.revealed != reveal.serial {
            container.revealed = reveal.serial
            let done = revealed
            // After layout, so the line can be centred.
            DispatchQueue.main.async {
                textView.go(toLine: reveal.line, column: reveal.column ?? 1, flash: true)
                done(reveal.serial)
            }
        }
    }
}

/// The scroll view with the code, and the Go to line field over it.
final class SourceContainerView: NSView {
    let scrollView = NSScrollView()
    let textView: SourceTextView
    let gutter: SourceGutterView
    /// The last reveal request scrolled to.
    var revealed = -1

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)
        textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        gutter = SourceGutterView(scrollView: scrollView, orientation: .verticalRuler)
        super.init(frame: frame)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SourceTheme.background
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView
        gutter.clientView = textView
        gutter.textView = textView
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        textView.gutter = gutter
        textView.askQuickOpen = { [weak self] in self?.showQuickOpen($0) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reports how far down the code is scrolled, for the document to keep.
    var onScroll: ((CGFloat) -> Void)?

    func restoreScroll(_ y: CGFloat) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let height = scrollView.contentView.bounds.height
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: y + height), in: container)
        let top = min(y, max(0, textView.frame.height - height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func layout() {
        super.layout()
        textView.updateScrollPastEnd()
    }

    @objc private func scrolled() {
        if window != nil { onScroll?(scrollView.contentView.bounds.origin.y) }
        textView.paintVisible()
        if textView.hoverPopover != nil { textView.closeHover() }
    }

    // MARK: Quick open

    private var quickOpen: SourceQuickOpenView?

    /// Chrome's box: "" for files (⌘P), "@" for symbols (⇧⌘O), ":" for a
    /// line (⌃G).
    func showQuickOpen(_ prefix: String) {
        if let quickOpen {
            quickOpen.start(prefix)
            return
        }
        let box = SourceQuickOpenView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let textView = textView
        box.files = { textView.actions?.files() ?? [] }
        box.openFile = { textView.actions?.openFile($0, $1, $2) }
        box.symbols = { SourceOutline.symbols(textView.string, language: textView.language) }
        box.currentLine = { textView.lineIndex(of: textView.selectedRange().location) + 1 }
        box.lineCount = { textView.lineStarts.count }
        box.goToLine = { textView.go(toLine: $0, column: $1) }
        box.goToOffset = { offset in
            let index = textView.lineIndex(of: offset)
            textView.go(toLine: index + 1, column: offset - textView.lineStarts[index] + 1)
        }
        box.close = { [weak self] in self?.hideQuickOpen() }
        addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.7),
        ])
        quickOpen = box
        layoutSubtreeIfNeeded()
        box.start(prefix)
    }

    func hideQuickOpen() {
        guard let quickOpen else { return }
        quickOpen.removeFromSuperview()
        self.quickOpen = nil
        window?.makeFirstResponder(textView)
    }

    var showsQuickOpen: Bool { quickOpen != nil }
    var quickOpenTitles: [String] { quickOpen?.titles ?? [] }
    func chooseQuickOpen(_ row: Int) { quickOpen?.choose(row) }
}

// MARK: Text view

final class SourceTextView: NSTextView {
    struct Position: Equatable {
        var line = 1
        var column = 1
        var selected = 0
        var selectedLines = 0
        var offset = 0
    }

    private(set) var lineStarts: [Int] = [0]
    private(set) var displayID = -1
    private(set) var tokensID = -1
    private var tokens: [SourceToken] = []
    private var painted = IndexSet()
    private static let chunk = 4096

    var breakpointMarkers: [Int: SourceGutterMarker] = [:]
    /// The Coverage tool's marks by 1-based line: true for code that ran.
    var coverageLines: [Int: Bool] = [:]
    /// Performance's line-level profile: milliseconds by 1-based line.
    var profileLines: [Int: Double] = [:]
    var inlineValues: [Int: String] = [:] {
        didSet { if inlineValues != oldValue { needsDisplay = true } }
    }
    /// Where the debugger is paused, as an offset in the text: the visual
    /// line holding it gets Chrome's execution-line tint and gutter arrow.
    var executionOffset: Int? {
        didSet {
            guard executionOffset != oldValue else { return }
            if let executionOffset { reveal(offset: executionOffset) }
            needsDisplay = true
            gutter?.needsDisplay = true
        }
    }
    var canSetBreakpoints = false
    var actions: SourceEditorActions?
    var language = SourceLanguage.plain
    var onMove: ((Position) -> Void)?
    var askQuickOpen: ((String) -> Void)?
    weak var gutter: SourceGutterView?

    // Code folding (DeveloperSourcesFolding.swift).
    /// Settings › Preferences › Sources › Code folding.
    var foldingEnabled = false {
        didSet {
            guard foldingEnabled != oldValue else { return }
            if !foldingEnabled { unfoldAll() }
            refreshFolds()
            gutter?.updateThickness(lines: lineStarts.count)
            gutter?.needsDisplay = true
        }
    }
    /// The blocks that can fold, by the 0-based line they start on.
    var foldsByLine: [Int: SourceFold] = [:]
    var folded: Set<SourceFold> = []
    var foldedLines: [SourceFolding.FoldedLine] = []
    /// 0-based lines folded away.
    var hiddenLines = IndexSet()
    var foldGeneration = 0
    let foldLayout = SourceFoldLayout()

    /// Forgets the folds, for new text (whose offsets they don't fit).
    private func clearFolds() {
        folded = []
        foldedLines = []
        hiddenLines = []
        foldsByLine = [:]
        foldLayout.update([], widths: [:])
    }

    // The hover popover (DeveloperSourcesHover.swift).
    var hoverTimer: DispatchWorkItem?
    var hoverPopover: NSPopover?
    var hoverRange: NSRange?
    var hoverSerial = 0
    private var hoverTracking: NSTrackingArea?

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        usesFontPanel = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        drawsBackground = true
        backgroundColor = SourceTheme.background
        textColor = SourceTheme.text
        font = Self.codeFont
        textContainerInset = NSSize(width: 0, height: 4)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        setAccessibilityLabel("Source")
        layoutManager?.delegate = foldLayout
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, lineStarts: [Int], id: Int, caret: Int?) {
        self.lineStarts = lineStarts
        displayID = id
        tokensID = -1
        tokens = []
        painted = []
        clearFolds()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.codeFont, .foregroundColor: SourceTheme.text]
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        refreshFolds()
        typingAttributes = attributes
        gutter?.updateThickness(lines: lineStarts.count)
        let length = (string as NSString).length
        let at = min(max(0, caret ?? 0), length)
        setSelectedRange(NSRange(location: at, length: 0))
        if caret != nil, at > 0 {
            scrollRangeToVisible(NSRange(location: at, length: 0))
        } else {
            scroll(.zero)
        }
        gutter?.needsDisplay = true
        needsDisplay = true
    }

    /// The colour class of the character at an offset, once tokens are in.
    func tokenKind(at offset: Int) -> SourceTokenKind? {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].end <= offset { low = mid + 1 } else { high = mid }
        }
        guard low < tokens.count, tokens[low].start <= offset else { return nil }
        return tokens[low].kind
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.cancel()
        hoverTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        closeHover()
        // A click on a fold's `…` opens it, as in Chrome.
        if let fold = foldHit(at: convert(event.locationInWindow, from: nil)) {
            setFolded(folded.subtracting([fold]))
            return
        }
        // ⌘-click while paused: Continue to here, as in Chrome.
        if canSetBreakpoints, let actions, actions.paused,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            actions.continueToHere(line(at: convert(event.locationInWindow, from: nil)))
            return
        }
        // ⌥-click: another caret, as in Chrome (⌥-click on one takes it
        // away). A ⌥-drag stays NSTextView's column selection.
        if isEditable, event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option,
           let window, let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                                     until: Date().addingTimeInterval(NSEvent.doubleClickInterval), inMode: .eventTracking,
                                                     dequeue: false), next.type == .leftMouseUp {
            _ = window.nextEvent(matching: [.leftMouseUp])
            addCaret(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Extra carets

    /// Bare carets besides the selection (⌥-click), which NSTextView can't
    /// hold: typing, deleting and ←/→ act at all of them (SourceCarets).
    private(set) var extraCarets: [Int] = [] {
        didSet { if extraCarets != oldValue { needsDisplay = true } }
    }
    private var keepingCarets = false

    func addCaret(at index: Int) {
        let length = (string as NSString).length
        let index = min(max(0, index), length)
        let main = selectedRanges.map(\.rangeValue)
        if extraCarets.contains(index) {
            extraCarets.removeAll { $0 == index }
        } else if main.count == 1, main[0].length == 0, main[0].location == index {
            // The main caret itself: the next extra one takes its place.
            guard let first = extraCarets.first else { return }
            extraCarets.removeFirst()
            keepingCarets = true
            setSelectedRange(NSRange(location: first, length: 0))
            keepingCarets = false
        } else {
            extraCarets = (extraCarets + [index]).sorted()
        }
    }

    func clearExtraCarets() { extraCarets = [] }

    private var allCarets: [NSRange] {
        selectedRanges.map(\.rangeValue) + extraCarets.map { NSRange(location: $0, length: 0) }
    }

    /// One edit at every caret, as one step ⌘Z takes back. False when
    /// there are no extra carets, for NSTextView to do it as usual.
    private func editAtCarets(_ operation: SourceCarets.Operation) -> Bool {
        guard !extraCarets.isEmpty else { return false }
        guard isEditable else { return true }
        let result = SourceCarets.apply(operation, to: string as NSString, carets: allCarets)
        guard !result.edits.isEmpty else { return true }
        guard shouldChangeText(inRanges: result.edits.map { NSValue(range: $0.range) },
                               replacementStrings: result.edits.map(\.text)) else { return true }
        textStorage?.beginEditing()
        for edit in result.edits.reversed() { textStorage?.replaceCharacters(in: edit.range, with: edit.text) }
        textStorage?.endEditing()
        didChangeText()
        placeCarets(result.carets)
        return true
    }

    private func placeCarets(_ carets: [Int]) {
        guard let first = carets.first else { return }
        keepingCarets = true
        setSelectedRange(NSRange(location: first, length: 0))
        keepingCarets = false
        extraCarets = Array(carets.dropFirst())
        scrollRangeToVisible(NSRange(location: first, length: 0))
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string
        if replacementRange.location == NSNotFound, let text, editAtCarets(.insert(text)) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if editAtCarets(.insert("\n")) { return }
        super.insertNewline(sender)
    }

    /// Tab: the file's indent (Settings › Preferences › Sources › Detect
    /// indentation, Default indentation), or, with Tab moves focus on,
    /// the next control, as in Chrome.
    override func insertTab(_ sender: Any?) {
        let defaults = DevDefaults.store
        if DeveloperSourcesPreferences.bool(DeveloperSourcesPreferences.tabMovesFocusKey, default: false, in: defaults) {
            window?.selectNextKeyView(sender)
            return
        }
        let unit = DeveloperSourcesPreferences.indentUnit(for: string, in: defaults)
        if editAtCarets(.insert(unit)) { return }
        guard isEditable, unit != "\t" else { return super.insertTab(sender) }
        let caret = selectedRange().location
        let column = caret - lineStarts[lineIndex(of: caret)]
        insertText(SourceIndentation.insertion(unit: unit, column: column), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        if DeveloperSourcesPreferences.bool(DeveloperSourcesPreferences.tabMovesFocusKey, default: false) {
            window?.selectPreviousKeyView(sender)
            return
        }
        super.insertBacktab(sender)
    }

    // MARK: Scrolling past the end

    /// Settings › Preferences › Sources › Allow scrolling past end of
    /// file: room under the last line for it to come up to the top.
    var scrollsPastEnd = false {
        didSet { if scrollsPastEnd != oldValue { updateScrollPastEnd() } }
    }

    private static let topInset: CGFloat = 4

    /// The text starts 4 points down; the inset's rest is room at the bottom.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: Self.topInset)
    }

    func updateScrollPastEnd() {
        let visible = enclosingScrollView?.contentView.bounds.height ?? 0
        let line = layoutManager?.defaultLineHeight(for: Self.codeFont) ?? 14
        let room = scrollsPastEnd ? max(0, visible - line - Self.topInset * 2) : 0
        // The inset is top and bottom alike: half the room each, the top
        // half taken back by textContainerOrigin.
        let height = Self.topInset + room / 2
        guard abs(textContainerInset.height - height) > 0.5 else { return }
        textContainerInset = NSSize(width: 0, height: height)
    }

    override func deleteBackward(_ sender: Any?) {
        if editAtCarets(.deleteBackward) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if editAtCarets(.deleteForward) { return }
        super.deleteForward(sender)
    }

    override func paste(_ sender: Any?) {
        if !extraCarets.isEmpty, let text = NSPasteboard.general.string(forType: .string), editAtCarets(.insert(text)) { return }
        super.paste(sender)
    }

    override func moveLeft(_ sender: Any?) {
        guard !extraCarets.isEmpty else { return super.moveLeft(sender) }
        placeCarets(SourceCarets.move(allCarets, by: -1, in: string as NSString))
    }

    override func moveRight(_ sender: Any?) {
        guard !extraCarets.isEmpty else { return super.moveRight(sender) }
        placeCarets(SourceCarets.move(allCarets, by: 1, in: string as NSString))
    }

    override func moveUp(_ sender: Any?) {
        guard !extraCarets.isEmpty else { return super.moveUp(sender) }
        placeCarets(SourceCarets.moveVertically(allCarets, by: -1, in: string as NSString))
    }

    override func moveDown(_ sender: Any?) {
        guard !extraCarets.isEmpty else { return super.moveDown(sender) }
        placeCarets(SourceCarets.moveVertically(allCarets, by: 1, in: string as NSString))
    }

    /// ⌥⌘↑ / ⌥⌘↓: another caret on the line above the topmost or below
    /// the bottommost, as Chrome's editor adds them.
    func addCaretVertically(by step: Int) {
        guard let index = SourceCarets.addAdjacent(allCarets, by: step, in: string as NSString) else { NSSound.beep(); return }
        if !extraCarets.contains(index), !selectedRanges.contains(where: { $0.rangeValue.location == index }) {
            extraCarets = (extraCarets + [index]).sorted()
        }
        scrollRangeToVisible(NSRange(location: index, length: 0))
    }

    /// Where a caret at `index` is drawn.
    func caretRect(at index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        if index >= length, length == 0 || (string as NSString).character(at: length - 1) == 10 {
            var rect = layoutManager.extraLineFragmentRect
            guard !rect.isEmpty else { return nil }
            rect.origin.x += textContainer.lineFragmentPadding
            rect.origin.y += textContainerOrigin.y
            rect.origin.x += textContainerOrigin.x
            rect.size.width = 1.5
            return rect
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let x = index >= length ? glyphRect.maxX : glyphRect.minX
        return NSRect(x: x + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 1.5, height: line.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFolds(in: dirtyRect)
        drawInlineValues(in: dirtyRect)
        guard !extraCarets.isEmpty else { return }
        (insertionPointColor ?? .textColor).setFill()
        for caret in extraCarets {
            if let rect = caretRect(at: caret), rect.intersects(dirtyRect) { rect.fill() }
        }
    }

    /// Text edited before this view was made (a Local Overrides file whose
    /// tab came back), coloured here rather than from the document.
    func showEdited(_ text: String, id: Int, caret: Int) {
        show(text, lineStarts: SourceLexing.lineStarts(text), id: id, caret: caret)
        tokens = SourceHighlighter.tokens(text, language: language)
        tokensID = id
        painted = []
        paintVisible()
    }

    func setTokens(_ list: [SourceToken], id: Int) {
        tokens = list
        tokensID = id
        painted = []
        paintVisible()
    }

    /// Colours the tokens in and around what is on screen, a chunk at a time,
    /// each chunk once.
    func paintVisible() {
        guard !tokens.isEmpty, let layoutManager, let textContainer else { return }
        let visible = visibleRect
        guard !visible.isEmpty else { return }
        let area = visible.insetBy(dx: 0, dy: -visible.height / 2).offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (string as NSString).length
        guard length > 0 else { return }
        let first = characters.location / Self.chunk
        let last = min(NSMaxRange(characters), length - 1) / Self.chunk
        guard first <= last else { return }
        for chunk in first...last where !painted.contains(chunk) {
            painted.insert(chunk)
            paint(from: chunk * Self.chunk, to: min(length, (chunk + 1) * Self.chunk), layoutManager)
        }
    }

    private func paint(from low: Int, to high: Int, _ layoutManager: NSLayoutManager) {
        // The first token that ends past `low`.
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].end <= low { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        while index < tokens.count, tokens[index].start < high {
            let token = tokens[index]
            let start = max(token.start, low)
            let end = min(token.end, high)
            if end > start, let colour = SourceTheme.colours[token.kind] {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: colour, forCharacterRange: NSRange(location: start, length: end - start))
            }
            index += 1
        }
    }

    // MARK: Lines

    func lineIndex(of offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The line a link revealed, tinted for a moment as Chrome tints it.
    private(set) var flashedLine: Int?
    private var flashClear: DispatchWorkItem?

    func go(toLine line: Int, column: Int = 1, flash: Bool = false) {
        if flash {
            flashedLine = min(max(line, 1), lineStarts.count)
            flashClear?.cancel()
            let clear = DispatchWorkItem { [weak self] in
                self?.flashedLine = nil
                self?.needsDisplay = true
            }
            flashClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: clear)
        }
        let index = min(max(line, 1), lineStarts.count) - 1
        let length = (string as NSString).length
        let lineEnd = index + 1 < lineStarts.count ? lineStarts[index + 1] : length
        let at = min(lineStarts[index] + max(column, 1) - 1, max(lineStarts[index], lineEnd))
        let range = NSRange(location: min(at, length), length: 0)
        setSelectedRange(range)
        window?.makeFirstResponder(self)
        if let layoutManager, let textContainer {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(range.location, max(0, length - 1)))
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y += textContainerOrigin.y
            _ = textContainer
            // The line in the middle, as Chrome puts it.
            let height = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
            scrollToVisible(NSRect(x: 0, y: rect.midY - height / 2, width: 1, height: height))
        }
        if length > 0 { showFindIndicator(for: NSRange(location: lineStarts[index], length: max(0, min(lineEnd, length) - lineStarts[index]))) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Any other move, click or selection lets the extra carets go.
        if !keepingCarets, !extraCarets.isEmpty { extraCarets = [] }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // A caret or match inside folded code opens the fold, as Chrome's
        // search and go to line do.
        if !folded.isEmpty {
            for value in ranges {
                let range = value.rangeValue
                reveal(offset: range.location)
                if range.length > 0 { reveal(offset: NSMaxRange(range)) }
            }
        }
        needsDisplay = true
        gutter?.needsDisplay = true
        let range = selectedRange()
        let index = lineIndex(of: range.location)
        let lines = range.length == 0 ? 0 : lineIndex(of: max(range.location, NSMaxRange(range) - 1)) - index + 1
        let position = Position(line: index + 1, column: range.location - lineStarts[index] + 1, selected: range.length, selectedLines: lines, offset: range.location)
        onMove?(position)
    }

    /// A whole source line (1-based), wrapped pieces included.
    func lineRect(_ line: Int) -> NSRect? {
        guard let layoutManager, let textContainer, line >= 1, line <= lineStarts.count else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : length
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(start, length - 1), length: max(1, min(end, length) - start)),
                                              actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = bounds.width
        return rect
    }

    /// The visual line the caret is on: a wrapped line's piece, not the whole
    /// of a minified file.
    var currentLineRect: NSRect? {
        guard let layoutManager else { return nil }
        let length = (string as NSString).length
        let location = selectedRange().location
        var rect: NSRect
        if length == 0 || location >= length, !layoutManager.extraLineFragmentRect.isEmpty || length == 0 {
            rect = layoutManager.extraLineFragmentRect
            if rect.isEmpty {
                guard length > 0 else { return nil }
                rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
            }
        } else {
            rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: min(location, length - 1)), effectiveRange: nil)
        }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = bounds.width
        return rect
    }

    /// The visual line the paused statement is on.
    var executionRect: NSRect? {
        guard let offset = executionOffset, let layoutManager else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(max(0, offset), length - 1))
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = bounds.width
        return rect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = flashedLine, let flash = lineRect(line), flash.intersects(rect) {
            NSColor.systemYellow.withAlphaComponent(0.28).setFill()
            flash.fill()
        }
        if let execution = executionRect, execution.intersects(rect) {
            // Chrome's execution line takes the place of the caret line's tint.
            SourceTheme.executionLine.setFill()
            execution.fill()
            SourceTheme.executionOutline.setFill()
            NSRect(x: execution.minX, y: execution.minY, width: execution.width, height: 1).fill()
            NSRect(x: execution.minX, y: execution.maxY - 1, width: execution.width, height: 1).fill()
        } else if let line = currentLineRect, line.intersects(rect) {
            SourceTheme.currentLine.setFill()
            line.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        gutter?.needsDisplay = true
    }

    // MARK: Editing (snippets)

    /// An edit opens every fold first: their offsets would move under it.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !folded.isEmpty { setFolded([]) }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if !folded.isEmpty { setFolded([]) }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func didChangeText() {
        super.didChangeText()
        // Small enough to colour again at once; offsets moved under the
        // temporary colours, so they go first.
        lineStarts = SourceLexing.lineStarts(string)
        let length = (string as NSString).length
        // The folds' offsets moved with the edit: they open, and are found again.
        if !folded.isEmpty { setFolded([]) }
        refreshFolds()
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        tokens = SourceHighlighter.tokens(string, language: language)
        painted = []
        paintVisible()
        gutter?.updateThickness(lines: lineStarts.count)
        gutter?.needsDisplay = true
        actions?.edited?(string)
    }

    // MARK: Context menu

    /// The selection, when it holds more than blanks.
    var selectedText: String {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return "" }
        let text = (string as NSString).substring(with: range)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// The line a point in this view is on, 1-based.
    func line(at point: NSPoint) -> Int {
        let index = characterIndexForInsertion(at: point)
        return lineIndex(of: min(index, max(0, (string as NSString).length))) + 1
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let line = line(at: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        if canSetBreakpoints { addBreakpointItems(to: menu, line: line) }
        let selection = (string as NSString).substring(with: selectedRange())
        if isEditable {
            menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        if isEditable {
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Select all", action: #selector(selectAll(_:)), keyEquivalent: "")
        if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            menu.addItem(.separator())
            // Chrome's pair, with its keys: ⌃⇧A and ⌃⇧E.
            menu.addItem(item("Add selected text to watches") { [weak self] in self?.actions?.addWatch(selection) })
            menu.addItem(item("Evaluate selected text in console") { [weak self] in self?.actions?.evaluate(selection) })
        }
        if let actions, actions.run != nil {
            menu.addItem(.separator())
            menu.addItem(item("Run") { [weak self] in guard let self else { return }; actions.run?(self.string) })
        }
        menu.addItem(.separator())
        if let actions, actions.canPrettyPrint {
            menu.addItem(item(actions.isPretty ? "Show original" : "Pretty print") { actions.togglePretty() })
        }
        menu.addItem(item("Go to line…") { [weak self] in self?.askQuickOpen?(":") })
        menu.addItem(item("Go to symbol…") { [weak self] in self?.askQuickOpen?("@") })
        menu.addItem(item("Find…") { [weak self] in self?.perform(.showFindInterface) })
        if let url = actions?.url, !url.isEmpty, !url.hasPrefix("snippet:") {
            menu.addItem(.separator())
            if let reveal = actions?.revealInSidebar {
                menu.addItem(item("Reveal in sidebar", reveal))
            }
            if let address = URL(string: url), address.scheme?.hasPrefix("http") == true {
                menu.addItem(item("Open in new tab") { DevHost.open(address) })
            }
            menu.addItem(item("Copy link address") { Self.copyText(url) })
            menu.addItem(item("Copy file name") { Self.copyText(SourceTree.fileName(url)) })
            menu.addItem(item("Save as…") { [weak self] in self?.saveAs(name: SourceTree.fileName(url)) })
            if let override = actions?.overrideContent {
                menu.addItem(item("Override content", override))
            }
            if let save = actions?.save {
                menu.addItem(item("Save", save))
            }
            if let actions, actions.addSourceMap != nil || actions.ignoreState != nil {
                menu.addItem(.separator())
            }
            if let add = actions?.addSourceMap {
                menu.addItem(item("Add source map…") { [weak self] in self?.askSourceMapURL(add) })
            }
            if let actions, let state = actions.ignoreState {
                switch state {
                case .listed:
                    menu.addItem(item("Remove from ignore list") { actions.setIgnored(false) })
                case .byRule:
                    // A rule or a source map's ignore list, kept in Settings.
                    let removal = item("Remove from ignore list") {}
                    removal.action = nil
                    removal.toolTip = "A rule in Settings › Ignore list ignores this script."
                    menu.addItem(removal)
                case .notIgnored:
                    menu.addItem(item("Add script to ignore list") { actions.setIgnored(true) })
                }
            }
        }
        return menu
    }

    /// Add source map…: Chrome's prompt for the map's address.
    private func askSourceMapURL(_ add: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Add source map"
        alert.informativeText = "Source map URL:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "https://example.com/app.js.map"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let done = { (response: NSApplication.ModalResponse) in
            let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !address.isEmpty { add(address) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    /// Chrome's line menu: Continue to here while paused; then add,
    /// conditional, logpoint, never pause; or, on a line with one, remove,
    /// edit, and disable or enable.
    func addBreakpointItems(to menu: NSMenu, line: Int) {
        guard let actions else { return }
        if actions.paused {
            menu.addItem(item("Continue to here") { actions.continueToHere(line) })
            menu.addItem(.separator())
        }
        let existing = actions.breakpointsAt(line)
        if let first = existing.first {
            let ids = existing.map(\.id)
            let several = existing.count > 1
            menu.addItem(item(several ? "Remove all breakpoints in line" : "Remove breakpoint") {
                actions.removeBreakpoints(ids)
            })
            let kind = first.kind == .regular ? DeveloperDebugger.Breakpoint.Kind.conditional : first.kind
            menu.addItem(item(first.kind == .logpoint ? "Edit logpoint…" : "Edit breakpoint…") { [weak self] in
                self?.editBreakpoint(line: line, kind: kind)
            })
            if existing.contains(where: \.enabled) {
                menu.addItem(item(several ? "Disable all breakpoints in line" : "Disable breakpoint") {
                    actions.setBreakpointsEnabled(ids, false)
                })
            } else {
                menu.addItem(item(several ? "Enable all breakpoints in line" : "Enable breakpoint") {
                    actions.setBreakpointsEnabled(ids, true)
                })
            }
        } else {
            menu.addItem(item("Add breakpoint") { actions.toggleBreakpoint(line) })
            menu.addItem(item("Add conditional breakpoint…") { [weak self] in self?.editBreakpoint(line: line, kind: .conditional) })
            menu.addItem(item("Add logpoint…") { [weak self] in self?.editBreakpoint(line: line, kind: .logpoint) })
            menu.addItem(item("Never pause here") { actions.setBreakpoint(line, "false", nil) })
        }
        menu.addItem(.separator())
    }

    private var breakpointPopover: NSPopover?

    /// Chrome's inline breakpoint editor, under the line: the kind, and the
    /// condition or log message. A sheet when there is no editor to show.
    func editBreakpoint(line: Int, kind: DeveloperDebugger.Breakpoint.Kind) {
        breakpointPopover?.close()
        let popover = NSPopover()
        guard let controller = actions?.breakpointEditor?(line, kind, { [weak popover] in popover?.close() }) else {
            askCondition(line: line, log: kind == .logpoint)
            return
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        breakpointPopover = popover
        let rect = lineRect(line) ?? NSRect(x: 0, y: visibleRect.midY, width: 1, height: 16)
        let anchor = NSRect(x: min(60, rect.width / 2), y: rect.minY, width: 1, height: rect.height)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    private func askCondition(line: Int, log: Bool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = log ? "Line \(line): Logpoint" : "Line \(line): Conditional breakpoint"
        alert.informativeText = log ? "Log a message to the Console, and don't pause." : "Pause only when this expression is true."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.font = Self.codeFont
        field.placeholderString = log ? "Log message, e.g. 'x is', x" : "Expression to check before pausing, e.g. x > 5"
        alert.accessoryView = field
        alert.addButton(withTitle: log ? "Add logpoint" : "Add breakpoint")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.actions?.setBreakpoint(line, log ? nil : text, log ? text : nil)
        }
    }

    private func saveAs(name: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.components(separatedBy: "?").first ?? name
        let text = string
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    fileprivate func item(_ title: String, _ perform: @escaping () -> Void) -> NSMenuItem {
        let item = SourceMenuItem(title: title, action: #selector(SourceMenuItem.fire), keyEquivalent: "")
        item.handler = perform
        item.target = item
        return item
    }

    // MARK: Keys

    func perform(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    // MARK: Editor commands (SourceEditing)

    /// The occurrences ⌘D added, latest last, for ⌘U to take back.
    private var addedOccurrences: [NSRange] = []

    /// Replaces text as typing would, so the change is saved and coloured.
    private func apply(_ edit: SourceEditing.Edit) {
        guard isEditable, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(NSRange(location: edit.selection.location, length: 0))
    }

    /// ⌘/: the lines the selection touches commented out, or back in.
    func toggleComment() {
        guard isEditable else { return }
        guard let edit = SourceEditing.toggleComment(string, selection: selectedRange(), language: language) else { return }
        apply(edit)
    }

    /// ⌘D: the word at the caret, then each next place its text is, as
    /// further selections; typing then changes them all.
    func selectNextOccurrence() {
        let current = selectedRanges.map(\.rangeValue)
        guard let next = SourceEditing.addNextOccurrence(string, selections: current), let added = next.last else {
            NSSound.beep()
            return
        }
        if current.count == 1 { addedOccurrences = [] }
        addedOccurrences.append(added)
        setSelectedRanges(next.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(added)
    }

    /// ⌘U: the last occurrence ⌘D added, let go again.
    func undoOccurrence() {
        let current = selectedRanges.map(\.rangeValue)
        guard current.count > 1 else { return }
        while let last = addedOccurrences.popLast() {
            guard current.contains(last) else { continue }
            let kept = current.filter { $0 != last }
            setSelectedRanges(kept.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            if let back = kept.last { scrollRangeToVisible(back) }
            return
        }
    }

    /// ⌃M: to the bracket matching the one at the caret, on its far side.
    func goToMatchingBracket() {
        let caret = selectedRange().location
        guard let match = SourceEditing.matchingBracket(string, at: caret) else { return }
        let target = match >= caret ? match + 1 : match
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// The line the caret is on, 1-based.
    var caretLine: Int { lineIndex(of: selectedRange().location) + 1 }

    /// ⌘B: a breakpoint on the caret's line, or the line's taken away.
    func toggleBreakpointAtCaret() {
        guard canSetBreakpoints, let actions else { return }
        let line = caretLine
        let existing = actions.breakpointsAt(line)
        if existing.isEmpty { actions.toggleBreakpoint(line) } else { actions.removeBreakpoints(existing.map(\.id)) }
    }

    /// ⌥⌘B: the caret line's breakpoint editor (a condition or a log message).
    func editBreakpointAtCaret() {
        guard canSetBreakpoints else { return }
        let line = caretLine
        let kind: DeveloperDebugger.Breakpoint.Kind = breakpointMarkers[line]?.kind == .logpoint ? .logpoint : .conditional
        editBreakpoint(line: line, kind: kind)
    }

    override func keyDown(with event: NSEvent) {
        closeHover()
        if DeveloperSourceKeys.handle(event, in: self) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, DeveloperSourceKeys.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The keys the code view answers, taken before the window's shortcuts —
/// ⌘F in the panel is Find in this file, not on the page, as in Chrome.
enum DeveloperSourceKeys {
    /// Asked first by DevTools' key monitor (DeveloperToolsKeys.takeFirst),
    /// before the window's shortcuts, which take ⌘F for Find on Page.
    /// Whether the key was the code view's, when the keyboard is in it, its
    /// find bar or its Go to line field.
    @MainActor static func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        var view: NSView? = event.window?.firstResponder as? NSView
        while let current = view {
            if let container = current as? SourceContainerView { return handle(event, in: container.textView) }
            view = current.superview
        }
        // Elsewhere in the Sources panel: its tab and Search keys.
        return DeveloperSourcesKeyAnchor.Anchor.take(event)
    }

    @MainActor static func handle(_ event: NSEvent, in textView: SourceTextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let container = textView.enclosingScrollView?.superview as? SourceContainerView
        let inQuickOpen = container?.showsQuickOpen == true && textView.window?.firstResponder !== textView
        let inText = textView.window?.firstResponder === textView
        switch (flags, key) {
        case ([.command, .option], "o"):
            textView.askQuickOpen?("")
        case ([.option], "w") where !inQuickOpen && textView.actions?.closeTab != nil:
            textView.actions?.closeTab?()
        case ([.command, .option], "f") where textView.actions?.showSearch != nil,
             ([.command, .shift], "f") where textView.actions?.showSearch != nil:
            container?.hideQuickOpen()
            textView.actions?.showSearch?()
        case ([.command, .shift], "o"):
            textView.askQuickOpen?("@")
        case ([.command], "s") where textView.actions?.save != nil && !inQuickOpen:
            textView.actions?.save?()
        case ([.command], "\r") where textView.actions?.run != nil && !inQuickOpen:
            textView.actions?.run?(textView.string)
        case ([.command], "f"):
            container?.hideQuickOpen()
            textView.perform(.showFindInterface)
        case ([.command], "g"):
            textView.perform(.nextMatch)
        case ([.command, .shift], "g"):
            textView.perform(.previousMatch)
        case ([.command], "e"):
            textView.perform(.setSearchString)
        case ([.control], "g"):
            textView.askQuickOpen?(":")
        case ([.control, .shift], "e") where !inQuickOpen && !textView.selectedText.isEmpty:
            textView.actions?.evaluate(textView.selectedText)
        case ([.control, .shift], "a") where !inQuickOpen && !textView.selectedText.isEmpty:
            textView.actions?.addWatch(textView.selectedText)
        // Chrome's editor keys (CodeMirror's), with the keyboard in the code.
        case ([.command], "/") where inText:
            textView.toggleComment()
        case ([.command], "d") where inText:
            textView.selectNextOccurrence()
        case ([.command], "u") where inText:
            textView.undoOccurrence()
        case ([.control], "m") where inText:
            textView.goToMatchingBracket()
        case ([.command], "b") where inText && textView.canSetBreakpoints:
            textView.toggleBreakpointAtCaret()
        case ([.command, .option], "b") where inText && textView.canSetBreakpoints:
            textView.editBreakpointAtCaret()
        case ([.command, .option], _) where inText && textView.isEditable && (event.keyCode == 126 || event.keyCode == 125):
            textView.addCaretVertically(by: event.keyCode == 126 ? -1 : 1)
        default:
            guard event.keyCode == 53, flags.isEmpty else { return false }
            if inText, !textView.extraCarets.isEmpty {
                // Esc: the extra carets go, as in Chrome.
                textView.clearExtraCarets()
            } else if inText, textView.selectedRanges.count > 1 {
                // Several selections (⌘D, ⌘-drag) go back to the first, as in Chrome.
                textView.setSelectedRange(textView.selectedRange())
            } else if container?.showsQuickOpen == true {
                container?.hideQuickOpen()
            } else if textView.enclosingScrollView?.isFindBarVisible == true {
                textView.perform(.hideFindInterface)
                textView.window?.makeFirstResponder(textView)
            } else {
                return false
            }
        }
        return true
    }
}

/// A menu item that runs a closure.
final class SourceMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

// MARK: Gutter

final class SourceGutterView: NSRulerView {
    weak var textView: SourceTextView?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 34
        // Since macOS 14 a view draws past its bounds unless told not to,
        // and the border line ran up out of the code view.
        clipsToBounds = true
        setAccessibilityLabel("Line numbers")
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    /// The column of fold markers, right of the numbers, when code folding is on.
    static let foldWidth: CGFloat = 12
    var foldColumn: CGFloat { textView?.foldingEnabled == true ? Self.foldWidth : 0 }
    /// The line-level profile's timings, left of the numbers, while there are any.
    var profileColumn: CGFloat {
        guard let most = textView?.profileLines.values.max() else { return 0 }
        return ceil((DeveloperLineProfile.label(most) as NSString).size(withAttributes: [.font: Self.font]).width) + 8
    }

    func updateThickness(lines: Int) {
        let digits = max(2, String(lines).count)
        let width = CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: Self.font]).width + 22 + foldColumn
            + profileColumn
        if abs(width - ruleThickness) > 0.5 { ruleThickness = ceil(width) }
    }

    /// Each line's number, at the top of its first piece, for the lines on
    /// screen: (line number, y in this view, height).
    private func visibleLines() -> [(Int, CGFloat, CGFloat)] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        let starts = textView.lineStarts
        var index = textView.lineIndex(of: characters.location)
        var lines: [(Int, CGFloat, CGFloat)] = []
        let hidden = textView.hiddenLines
        while index < starts.count {
            let start = starts[index]
            if start > NSMaxRange(characters) { break }
            // Folded away: no number, as in Chrome.
            if hidden.contains(index) {
                index += 1
                continue
            }
            var rect: NSRect
            if start >= length {
                rect = layoutManager.extraLineFragmentRect
                if rect.isEmpty { break }
            } else {
                rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: rect.minY + origin.y), from: textView).y
            lines.append((index + 1, y, rect.height))
            if start >= length { break }
            index += 1
        }
        return lines
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        SourceTheme.gutter.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let shown = rect.intersection(bounds)
        NSRect(x: bounds.maxX - 1, y: shown.minY, width: 1, height: shown.height).fill()
        guard let textView else { return }
        let current = textView.lineIndex(of: textView.selectedRange().location) + 1
        let markers = textView.breakpointMarkers
        let coverage = textView.coverageLines
        let foldColumn = self.foldColumn
        let profile = textView.profileLines, profileColumn = self.profileColumn
        let most = profile.values.max() ?? 0
        for (line, y, height) in visibleLines() {
            let lineRect = NSRect(x: 0, y: y, width: bounds.width - 1, height: height)
            guard lineRect.intersects(rect) else { continue }
            if let ms = profile[line], most > 0 {
                // Chrome's line-level timing, shaded by its share of the busiest line's.
                NSColor.systemOrange.withAlphaComponent(0.1 + 0.5 * ms / most).setFill()
                NSRect(x: 0, y: y, width: profileColumn - 2, height: height).fill()
                let label = NSAttributedString(string: DeveloperLineProfile.label(ms),
                                               attributes: [.font: Self.font, .foregroundColor: SourceTheme.text])
                let size = label.size()
                label.draw(at: NSPoint(x: profileColumn - 5 - size.width, y: y + (min(height, 16) - size.height) / 2))
            }
            if let used = coverage[line] {
                // Chrome's coverage bar down the gutter's edge, under a marker.
                (used ? DeveloperCoverageStyle.used : DeveloperCoverageStyle.unused).setFill()
                NSRect(x: bounds.maxX - 4, y: y, width: 3, height: height).fill()
            }
            let marker = markers[line]
            let marked = marker != nil
            if let marker {
                // Chrome's marker: a tag over the number, pointing at the code.
                let tag = NSRect(x: 2 + profileColumn, y: y + 1, width: bounds.width - 5 - foldColumn - profileColumn,
                                 height: max(height - 2, 10))
                let path = NSBezierPath()
                let tip: CGFloat = 5
                path.move(to: NSPoint(x: tag.minX + 2, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX - tip, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX, y: tag.midY))
                path.line(to: NSPoint(x: tag.maxX - tip, y: tag.maxY))
                path.line(to: NSPoint(x: tag.minX + 2, y: tag.maxY))
                path.curve(to: NSPoint(x: tag.minX, y: tag.maxY - 2), controlPoint1: NSPoint(x: tag.minX, y: tag.maxY), controlPoint2: NSPoint(x: tag.minX, y: tag.maxY))
                path.line(to: NSPoint(x: tag.minX, y: tag.minY + 2))
                path.curve(to: NSPoint(x: tag.minX + 2, y: tag.minY), controlPoint1: NSPoint(x: tag.minX, y: tag.minY), controlPoint2: NSPoint(x: tag.minX, y: tag.minY))
                path.close()
                marker.colour.withAlphaComponent(marker.enabled ? 1 : 0.4).setFill()
                path.fill()
                if marker.count > 1 {
                    // Several on the line: an edge under the tag, as a second one behind it.
                    marker.colour.withAlphaComponent(marker.enabled ? 0.55 : 0.25).setFill()
                    NSRect(x: tag.minX + 1, y: tag.maxY, width: tag.width - tip - 1, height: 1).fill()
                }
            }
            let colour = marked ? SourceTheme.breakpointText : line == current ? SourceTheme.text : SourceTheme.lineNumber
            let label = NSAttributedString(string: String(line), attributes: [.font: Self.font, .foregroundColor: colour])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - 9 - foldColumn - size.width, y: y + (min(height, 16) - size.height) / 2))
            if foldColumn > 0, let fold = textView.foldsByLine[line - 1] {
                drawFoldMarker(folded: textView.folded.contains(fold), y: y, height: height)
            }
        }
        if let execution = textView.executionRect {
            NSGraphicsContext.saveGraphicsState()
            // Right of the profile's timings, at the numbers' left edge.
            let shift = NSAffineTransform()
            shift.translateX(by: profileColumn, yBy: 0)
            shift.concat()
            drawExecutionArrow(at: convert(NSPoint(x: 0, y: execution.minY), from: textView).y, height: execution.height)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Chrome's fold marker: ▾ on a block that can fold, ▸ on a folded one.
    private func drawFoldMarker(folded: Bool, y: CGFloat, height: CGFloat) {
        let size: CGFloat = 6
        let x = bounds.maxX - 1 - Self.foldWidth / 2
        let mid = y + min(height, 16) / 2
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: x - size / 3, y: mid - size / 2))
            path.line(to: NSPoint(x: x + size * 2 / 3 - 1, y: mid))
            path.line(to: NSPoint(x: x - size / 3, y: mid + size / 2))
        } else {
            path.move(to: NSPoint(x: x - size / 2, y: mid - size / 3))
            path.line(to: NSPoint(x: x + size / 2, y: mid - size / 3))
            path.line(to: NSPoint(x: x, y: mid + size * 2 / 3 - 1))
        }
        path.close()
        (folded ? SourceTheme.text : SourceTheme.lineNumber).setFill()
        path.fill()
    }

    /// The paused line's arrow, at the gutter's left edge, over a marker.
    private func drawExecutionArrow(at y: CGFloat, height: CGFloat) {
        let size = min(max(height - 4, 8), 12)
        let top = y + (min(height, 16) - size) / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1, y: top + size * 0.3))
        path.line(to: NSPoint(x: 5, y: top + size * 0.3))
        path.line(to: NSPoint(x: 5, y: top))
        path.line(to: NSPoint(x: 10, y: top + size / 2))
        path.line(to: NSPoint(x: 5, y: top + size))
        path.line(to: NSPoint(x: 5, y: top + size * 0.7))
        path.line(to: NSPoint(x: 1, y: top + size * 0.7))
        path.close()
        SourceTheme.executionOutline.setFill()
        path.fill()
        SourceTheme.gutter.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = visibleLines().last(where: { $0.1 <= point.y }) else { return }
        if foldColumn > 0, point.x >= bounds.maxX - 1 - foldColumn {
            // The fold column: folds or unfolds the line's block.
            if textView.foldsByLine[hit.0 - 1] != nil { textView.toggleFold(line: hit.0) }
            return
        }
        if textView.canSetBreakpoints, let actions = textView.actions {
            let existing = actions.breakpointsAt(hit.0)
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command {
                // ⌘-click: the conditional breakpoint editor; ⇧⌘-click: a logpoint's.
                let kind: DeveloperDebugger.Breakpoint.Kind = textView.breakpointMarkers[hit.0]?.kind == .logpoint ? .logpoint : .conditional
                textView.editBreakpoint(line: hit.0, kind: kind)
            } else if modifiers == [.command, .shift] {
                textView.editBreakpoint(line: hit.0, kind: .logpoint)
            } else if event.modifierFlags.contains(.shift), !existing.isEmpty {
                // Shift-click turns a breakpoint off and on, as in Chrome.
                actions.setBreakpointsEnabled(existing.map(\.id), !existing.contains(where: \.enabled))
            } else if let marker = textView.breakpointMarkers[hit.0], marker.kind != .regular {
                // A condition or a log message opens to edit rather than being lost.
                textView.editBreakpoint(line: hit.0, kind: marker.kind)
            } else if !existing.isEmpty {
                actions.removeBreakpoints(existing.map(\.id))
            } else {
                actions.toggleBreakpoint(hit.0)
            }
        } else {
            textView.go(toLine: hit.0)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let textView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if textView.canSetBreakpoints, let hit = visibleLines().last(where: { $0.1 <= point.y }) {
            textView.addBreakpointItems(to: menu, line: hit.0)
        }
        if !textView.profileLines.isEmpty, let actions = textView.actions {
            menu.addItem(textView.item("Clear line-level profile data", actions.clearLineProfile))
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu.items.isEmpty ? nil : menu
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
