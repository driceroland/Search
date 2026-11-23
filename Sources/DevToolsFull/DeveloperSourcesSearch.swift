import AppKit
import SwiftUI

// Chrome's Search tool (⌥⌘F, or ⇧⌘F in Sources): one query across every
// file the page loaded and the authored files its source maps name (their
// sourcesContent, or read from their address), with Match case and
// regular expressions; results
// grouped by file, a line each ("12  const total = …"), the match lit;
// clicking one opens the file at it. Files are fetched through the same
// path as the editor and searched off the main thread.
//
// The view is self-contained, made from a session alone, so the panel or
// a drawer can host it: DeveloperSourcesSearchView(session:).

/// The matching, kept apart from the view for the tests.
enum SourceSearch {
    /// One matching line.
    struct Match: Equatable, Sendable {
        /// 1-based.
        let line: Int
        /// 1-based, in UTF-16 units, of the line's first match.
        let column: Int
        /// The line as shown: leading blanks dropped, a long line cut to a
        /// window around the first match.
        let text: String
        /// The matches within `text`.
        let ranges: [NSRange]
    }

    struct BadPattern: LocalizedError {
        let errorDescription: String?
    }

    /// Chrome's longest result line before it is cut down around the match.
    static let window = 250

    /// What one search goes through, in order: the page's scripts, style
    /// sheets and documents, extensions' content scripts, then the
    /// authored files of its source maps (each once, and none the page
    /// itself listed at the same address). Content scripts and scripts
    /// with no address only with Settings › Preferences › Sources ›
    /// Search in anonymous and content scripts on.
    static func files(resources: [SourceResource], contentScripts: [SourceResource],
                      authored: [SourceResource], includeContentScripts: Bool = true) -> [SourceResource] {
        let page = resources.filter {
            ["Script", "Stylesheet", "Document"].contains($0.type) && (includeContentScripts || !$0.url.isEmpty)
        } + (includeContentScripts ? contentScripts : [])
        var seen = Set(page.map(\.url))
        return page + authored.filter { seen.insert($0.url).inserted }
    }

    static func expression(_ query: String, caseSensitive: Bool, regex: Bool) throws -> NSRegularExpression {
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        do {
            return try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw BadPattern(errorDescription: "Invalid regular expression: " + query)
        }
    }

    /// The lines of `text` that match, each once with all its matches, up
    /// to `limit` lines.
    static func find(_ query: String, in text: String, caseSensitive: Bool, regex: Bool,
                     limit: Int = 1_000) throws -> [Match] {
        guard !query.isEmpty else { return [] }
        let expression = try expression(query, caseSensitive: caseSensitive, regex: regex)
        let string = text as NSString
        let starts = SourceLexing.lineStarts(text)
        var byLine: [(line: Int, ranges: [NSRange])] = []
        var lineIndex = 0
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { result, _, halt in
            guard let range = result?.range, range.length > 0 else { return }
            while lineIndex + 1 < starts.count, starts[lineIndex + 1] <= range.location { lineIndex += 1 }
            if byLine.last?.line == lineIndex {
                byLine[byLine.count - 1].ranges.append(range)
            } else {
                if byLine.count >= limit { halt.pointee = true; return }
                byLine.append((lineIndex, [range]))
            }
        }
        return byLine.map { item in
            let start = starts[item.line]
            var end = item.line + 1 < starts.count ? starts[item.line + 1] : string.length
            while end > start, let scalar = UnicodeScalar(string.character(at: end - 1)),
                  CharacterSet.newlines.contains(scalar) { end -= 1 }
            let line = string.substring(with: NSRange(location: start, length: end - start)) as NSString
            var lead = 0
            while lead < line.length, line.character(at: lead) == 32 || line.character(at: lead) == 9 { lead += 1 }
            let first = item.ranges[0].location - start
            var low = lead, high = line.length
            var prefix = ""
            if high - low > window {
                low = max(lead, min(first - 60, line.length - window))
                high = min(line.length, low + window)
                if low > lead { prefix = "…" }
            }
            let shown = prefix + line.substring(with: NSRange(location: low, length: max(0, high - low)))
            let shift = (prefix as NSString).length - low
            let ranges = item.ranges.compactMap { range -> NSRange? in
                let from = max(range.location - start, low), to = min(NSMaxRange(range) - start, high)
                return to > from ? NSRange(location: from + shift, length: to - from) : nil
            }
            return Match(line: item.line + 1, column: first + 1, text: shown, ranges: ranges)
        }
    }
}

/// The Search tool's state for one DevTools session: the query and its
/// options, the results, and the files' text fetched for them.
@MainActor
final class DeveloperSourcesSearchModel: ObservableObject {
    private static var models: [ObjectIdentifier: DeveloperSourcesSearchModel] = [:]

    static func of(_ session: DeveloperToolsSession) -> DeveloperSourcesSearchModel {
        let key = ObjectIdentifier(session)
        if let model = models[key], model.session === session { return model }
        models = models.filter { $0.value.session != nil }
        let model = DeveloperSourcesSearchModel(session: session)
        models[key] = model
        return model
    }

    struct FileResult: Identifiable {
        let resource: SourceResource
        let matches: [SourceSearch.Match]
        var id: String { resource.id }
    }

    private(set) weak var session: DeveloperToolsSession?
    @Published var query = ""
    @Published var matchCase = false
    @Published var regex = false
    @Published private(set) var results: [FileResult] = []
    @Published private(set) var searching = false
    @Published private(set) var status: String?
    @Published var collapsed = Set<String>()
    private var task: Task<Void, Never>?
    private var contents: [String: String] = [:]
    private var listed: [String] = []

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    /// ⌥⇧⌘} and ⌥⇧⌘{: every file's matches shown, or every file folded.
    func setAllExpanded(_ expanded: Bool) {
        collapsed = expanded ? [] : Set(results.map(\.id))
    }

    /// The files Chrome searches: scripts, style sheets, documents,
    /// extensions' content scripts, and the authored files the loaded
    /// source maps name (only while source maps are on).
    private var files: [SourceResource] {
        guard let session else { return [] }
        return SourceSearch.files(resources: session.resources, contentScripts: session.contentScripts,
                                  authored: session.sourceMaps.authoredResources,
                                  includeContentScripts: DeveloperSourcesPreferences.bool(
                                      DeveloperSourcesPreferences.searchContentScriptsKey, default: false))
    }

    func search() {
        task?.cancel()
        let query = self.query
        guard !query.isEmpty, session != nil else {
            results = []
            status = nil
            searching = false
            return
        }
        let files = self.files
        // A different page: its files are fetched afresh.
        if files.map(\.id) != listed {
            listed = files.map(\.id)
            contents = [:]
        }
        let caseSensitive = matchCase, regex = regex
        results = []
        collapsed = []
        searching = true
        status = "Searching…"
        task = Task { [weak self] in
            var found: [FileResult] = []
            var lines = 0
            for resource in files {
                guard let self, !Task.isCancelled else { return }
                guard let text = await self.content(of: resource), !Task.isCancelled else { continue }
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[SourceSearch.Match], Error> in
                    Result { try SourceSearch.find(query, in: text, caseSensitive: caseSensitive, regex: regex) }
                }.value
                guard !Task.isCancelled else { return }
                switch outcome {
                case let .failure(error):
                    self.searching = false
                    self.status = error.localizedDescription
                    return
                case let .success(matches) where !matches.isEmpty:
                    found.append(FileResult(resource: resource, matches: matches))
                    lines += matches.count
                    self.results = found
                default:
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.searching = false
            self.status = found.isEmpty ? "No matches found."
                : "Search finished. Found \(lines) matching line\(lines == 1 ? "" : "s") in \(found.count) file\(found.count == 1 ? "" : "s")."
        }
    }

    /// Clears the query and results, as Chrome's Clear button does.
    func clear() {
        task?.cancel()
        query = ""
        results = []
        status = nil
        searching = false
    }

    /// Fetches the files again on the next search.
    func refresh() {
        contents = [:]
        listed = []
        if !query.isEmpty { search() }
    }

    private func content(of resource: SourceResource) async -> String? {
        if let text = contents[resource.id] { return text }
        guard let session else { return nil }
        var text: String?
        if resource.type == DeveloperSourceMaps.authoredType {
            // The map's sourcesContent, else the file read from its address.
            text = await session.sourceMaps.searchableContent(of: resource.url)
        } else if let saved = DeveloperLocalOverrides.shared.activeContent(for: resource.url) {
            text = saved
        } else if resource.type == "ContentScript" {
            text = (try? await session.command("Debugger.getScriptSource", ["scriptId": resource.frame]))?["scriptSource"] as? String
        } else {
            text = (try? await session.evaluateInFrontend("""
                const result = await searchInspector.command("Page.getResourceContent", resource);
                return result.base64Encoded ? null : (result.content ?? "").slice(0, 10000000);
                """, ["resource": ["frameId": resource.frame, "url": resource.url]])) as? String
        }
        if let text { contents[resource.id] = text }
        return text
    }
}

struct DeveloperSourcesSearchView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperSourcesSearchModel
    @ObservedObject private var tabs: DeveloperSourceTabs
    private let onClose: (() -> Void)?
    @FocusState private var fieldFocused: Bool

    init(session: DeveloperToolsSession, onClose: (() -> Void)? = nil) {
        self.session = session
        model = DeveloperSourcesSearchModel.of(session)
        tabs = DeveloperSourceTabs.of(session)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onClose {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Text("Search").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    DeveloperPanelIcon(symbol: "xmark", title: "Close Search", size: 18, action: onClose)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight - 4)
                .background(DeveloperToolsStyle.chrome)
                Divider()
            }
            toolbar
            Divider()
            results
            Divider()
            HStack(spacing: 6) {
                if model.searching { ProgressView().controlSize(.mini) }
                Text(model.status ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: 22)
            .background(DeveloperToolsStyle.chrome)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: tabs.searchFocus) { _, _ in fieldFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            TextField("Search", text: $model.query)
                .focused($fieldFocused)
                .onSubmit { model.search() }
                .onExitCommand { onClose?() }
                .developerToolsField()
            option("Aa", "Match case", isOn: $model.matchCase)
            option(".*", "Use regular expression", isOn: $model.regex)
            Divider().frame(height: 14)
            DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh", size: 20) { model.refresh() }
            DeveloperPanelIcon(symbol: "nosign", title: "Clear", size: 20) { model.clear() }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func option(_ label: String, _ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            if !model.query.isEmpty { model.search() }
        } label: {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? Palette.ink : .secondary)
                .frame(width: 22, height: 20)
                .background(isOn.wrappedValue ? DeveloperToolsStyle.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.results) { file in
                    let open = !model.collapsed.contains(file.id)
                    fileRow(file, open: open)
                    if open {
                        ForEach(Array(file.matches.enumerated()), id: \.offset) { _, match in
                            matchRow(match, in: file.resource)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeveloperToolsStyle.surface)
    }

    private func fileRow(_ file: DeveloperSourcesSearchModel.FileResult, open: Bool) -> some View {
        Button {
            if open { model.collapsed.insert(file.id) } else { model.collapsed.remove(file.id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 10)
                Text(SourceTree.fileName(file.resource.url)).fontWeight(.medium).lineLimit(1)
                Text(file.resource.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(file.matches.count.formatted())
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 5).background(DeveloperToolsStyle.raised, in: Capsule())
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.resource.url)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    private func matchRow(_ match: SourceSearch.Match, in resource: SourceResource) -> some View {
        Button {
            session.revealSource(url: resource.url, line: match.line, column: match.column)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(match.line.formatted(.number.grouping(.never)))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
                Text(Self.highlighted(match)).font(DeveloperToolsStyle.code).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, DeveloperToolsStyle.gutter + 6).padding(.trailing, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(SourceTree.fileName(resource.url)):\(match.line)")
    }

    /// The line with each match lit, as Chrome marks them.
    static func highlighted(_ match: SourceSearch.Match) -> AttributedString {
        var text = AttributedString(match.text)
        for range in match.ranges {
            guard let found = Range(range, in: match.text), let marked = Range(found, in: text) else { continue }
            text[marked].backgroundColor = Color(nsColor: .findHighlightColor).opacity(0.55)
        }
        return text
    }
}
