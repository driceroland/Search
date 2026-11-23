import AppKit
import Foundation

// Chrome's Changes drawer tool (More tools › Changes): every edit made in
// DevTools to a style sheet (Styles' declarations, selectors and new
// rules, element.style) or to a Local Overrides file in Sources, shown as
// a diff against the text before the first edit.
//
// DeveloperChanges keeps each file's first and latest text for a session;
// DeveloperChangesDiff works out the line diff, the unchanged runs folded
// away, the counts and Copy's text on the text alone, for the tests.

// MARK: Diff

enum DeveloperChangesDiff {
    enum Kind: Equatable {
        case equal, insert, delete
    }

    /// One line of the diff, with its 1-based number in the original text
    /// (nil for an insertion) and in the current one (nil for a deletion).
    struct Line: Equatable {
        let kind: Kind
        let text: String
        let original: Int?
        let current: Int?
    }

    /// A row the view draws: a line (by its index in the diff), or a run
    /// of unchanged lines folded into "… N unchanged lines".
    enum Row: Equatable, Identifiable {
        case line(Int, Line)
        case collapsed(at: Int, count: Int)

        var id: Int {
            switch self {
            case .line(let index, _): index
            case .collapsed(let at, _): at
            }
        }
    }

    /// Past this many edits (or this many lines left once the shared start
    /// and end are taken off) the middle is shown as replaced whole: a
    /// diff stays quick, and its memory small, for any file.
    static let editLimit = 2_000
    static let lineLimit = 200_000

    /// A text's lines: a trailing newline doesn't make an empty last line,
    /// and \r\n counts as one break.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // "\r\n" is one Character to Swift; split on the UTF-16 units.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    static func diff(_ original: String, _ current: String) -> [Line] {
        diff(lines: lines(original), lines(current))
    }

    /// Myers' O(ND) diff, after the lines both texts start and end with are
    /// set aside; past the limits, the rest as deleted and then inserted.
    static func diff(lines a: [String], _ b: [String], editLimit: Int = editLimit) -> [Line] {
        var ids: [String: Int] = [:]
        func id(_ line: String) -> Int {
            if let known = ids[line] { return known }
            let new = ids.count
            ids[line] = new
            return new
        }
        let x = a.map(id), y = b.map(id)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix,
              x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let middleA = Array(x[prefix..<(x.count - suffix)]), middleB = Array(y[prefix..<(y.count - suffix)])
        let script: [Kind]
        if middleA.count + middleB.count > lineLimit {
            script = replaced(middleA.count, middleB.count)
        } else {
            script = myers(middleA, middleB, limit: editLimit) ?? replaced(middleA.count, middleB.count)
        }

        var out: [Line] = []
        out.reserveCapacity(prefix + script.count + suffix)
        var i = 0, j = 0
        func emit(_ kind: Kind) {
            switch kind {
            case .equal:
                out.append(Line(kind: .equal, text: b[j], original: i + 1, current: j + 1))
                i += 1; j += 1
            case .delete:
                out.append(Line(kind: .delete, text: a[i], original: i + 1, current: nil))
                i += 1
            case .insert:
                out.append(Line(kind: .insert, text: b[j], original: nil, current: j + 1))
                j += 1
            }
        }
        for _ in 0..<prefix { emit(.equal) }
        for kind in script { emit(kind) }
        for _ in 0..<suffix { emit(.equal) }
        return out
    }

    private static func replaced(_ deleted: Int, _ inserted: Int) -> [Kind] {
        Array(repeating: .delete, count: deleted) + Array(repeating: .insert, count: inserted)
    }

    /// The edit script from `a` to `b`, deletions before insertions where
    /// both would do; nil past `limit` edits.
    private static func myers(_ a: [Int], _ b: [Int], limit: Int) -> [Kind]? {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let most = min(n + m, limit)
        let offset = most + 1
        var v = [Int](repeating: 0, count: 2 * most + 3)
        // Each round's furthest points as the round before left them,
        // k from -d to d, for the walk back.
        var trace: [[Int]] = []
        for d in 0...most {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var px = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var py = px - k
                while px < n, py < m, a[px] == b[py] { px += 1; py += 1 }
                v[offset + k] = px
                if px >= n, py >= m { return backtrack(trace, rounds: d, n: n, m: m) }
            }
        }
        return nil
    }

    private static func backtrack(_ trace: [[Int]], rounds: Int, n: Int, m: Int) -> [Kind] {
        var x = n, y = m
        var ops: [Kind] = []
        ops.reserveCapacity(n + m)
        for d in stride(from: rounds, to: 0, by: -1) {
            let before = trace[d]
            func at(_ k: Int) -> Int { before[k + d] }
            let k = x - y
            let down = k == -d || (k != d && at(k - 1) < at(k + 1))
            let previousK = down ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                ops.append(.equal)
                x -= 1; y -= 1
            }
            ops.append(down ? .insert : .delete)
            x = previousX
            y = previousY
        }
        while x > 0, y > 0 {
            ops.append(.equal)
            x -= 1; y -= 1
        }
        return ops.reversed()
    }

    // MARK: Rows and counts

    /// The rows as Chrome's Changes shows them: `context` unchanged lines
    /// kept beside each change, the rest of an unchanged run folded into
    /// one row unless it was expanded (by the index the row starts at). A
    /// fold never hides a single line: the row would take its place.
    static func rows(_ lines: [Line], context: Int = 3, expanded: Set<Int> = []) -> [Row] {
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .equal else {
                rows.append(.line(index, lines[index]))
                index += 1
                continue
            }
            var end = index
            while end < lines.count, lines[end].kind == .equal { end += 1 }
            let head = index > 0 ? context : 0
            let tail = end < lines.count ? context : 0
            let hidden = end - index - head - tail
            let foldAt = index + head
            if hidden >= 2, !expanded.contains(foldAt) {
                for at in index..<foldAt { rows.append(.line(at, lines[at])) }
                rows.append(.collapsed(at: foldAt, count: hidden))
                for at in (foldAt + hidden)..<end { rows.append(.line(at, lines[at])) }
            } else {
                for at in index..<end { rows.append(.line(at, lines[at])) }
            }
            index = end
        }
        return rows
    }

    static func counts(_ lines: [Line]) -> (insertions: Int, deletions: Int) {
        lines.reduce(into: (0, 0)) { counts, line in
            if line.kind == .insert { counts.0 += 1 } else if line.kind == .delete { counts.1 += 1 }
        }
    }

    /// The footer: "1 insertion (+), 2 deletions (−)".
    static func summary(_ lines: [Line]) -> String {
        let (insertions, deletions) = counts(lines)
        return "\(insertions) insertion\(insertions == 1 ? "" : "s") (+), \(deletions) deletion\(deletions == 1 ? "" : "s") (−)"
    }

    // MARK: Copy

    /// Copy for a script or other text: the changes as a unified diff, each
    /// hunk with `context` lines round it.
    static func unified(_ lines: [Line], context: Int = 3) -> String {
        var hunks: [[Line]] = [[]]
        for row in rows(lines, context: context) {
            switch row {
            case .line(_, let line): hunks[hunks.count - 1].append(line)
            case .collapsed: hunks.append([])
            }
        }
        var out: [String] = []
        for hunk in hunks where hunk.contains(where: { $0.kind != .equal }) {
            let originals = hunk.compactMap(\.original), currents = hunk.compactMap(\.current)
            let firstIndex = lines.firstIndex(of: hunk[0]) ?? 0
            // An empty side starts at the line before, as diff counts it.
            let before = lines[..<firstIndex]
            let originalStart = originals.first ?? (before.last { $0.original != nil }?.original ?? 0)
            let currentStart = currents.first ?? (before.last { $0.current != nil }?.current ?? 0)
            out.append("@@ -\(originalStart),\(originals.count) +\(currentStart),\(currents.count) @@")
            for line in hunk {
                let mark = line.kind == .insert ? "+" : line.kind == .delete ? "-" : " "
                out.append(mark + line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Chrome's Copy for a style sheet: each rule with a changed line, its
    /// declarations that were taken out commented, the ones put in as they
    /// are now. A declaration both taken out and put back (a line rewritten
    /// round it) is left out. `inline` text is element.style's own.
    static func cssChanges(_ lines: [Line], original: String, current: String, inline: Bool = false) -> String {
        let originalSelectors = inline ? [] : selectors(original)
        let currentSelectors = inline ? [] : selectors(current)
        struct Group {
            let selector: String
            var entries: [(kind: Kind, text: String)] = []
            /// The selector is new (renamed or the rule added).
            var opened = false
        }
        var groups: [Group] = []
        func group(_ selector: String) -> Int {
            if let index = groups.firstIndex(where: { $0.selector == selector }) { return index }
            groups.append(Group(selector: selector))
            return groups.count - 1
        }
        for line in lines where line.kind != .equal {
            let selector: String?
            if inline {
                selector = "element.style"
            } else if line.kind == .insert, let number = line.current {
                selector = currentSelectors.indices.contains(number - 1) ? currentSelectors[number - 1] : nil
            } else if let number = line.original {
                selector = originalSelectors.indices.contains(number - 1) ? originalSelectors[number - 1] : nil
            } else {
                selector = nil
            }
            guard let selector else { continue }
            let index = group(selector)
            if line.kind == .insert, !inline, line.text.contains("{") { groups[index].opened = true }
            for declaration in declarations(inLine: line.text, inline: inline) {
                groups[index].entries.append((line.kind, declaration))
            }
        }

        var blocks: [String] = []
        for group in groups {
            // Taken out and put back the same: not a change.
            var removed: [String: Int] = [:], added: [String: Int] = [:]
            for entry in group.entries {
                if entry.kind == .delete { removed[entry.text, default: 0] += 1 } else { added[entry.text, default: 0] += 1 }
            }
            var cancel: [String: Int] = [:]
            for (text, count) in removed { cancel[text] = min(count, added[text] ?? 0) }
            var cancelDeleted = cancel, cancelInserted = cancel
            var body: [String] = []
            for entry in group.entries {
                if entry.kind == .delete {
                    if let left = cancelDeleted[entry.text], left > 0 { cancelDeleted[entry.text] = left - 1; continue }
                    let line = "  " + commented(entry.text)
                    if !body.contains(line) { body.append(line) }
                } else {
                    if let left = cancelInserted[entry.text], left > 0 { cancelInserted[entry.text] = left - 1; continue }
                    let line = "  " + (isComment(entry.text) ? entry.text : entry.text + ";")
                    if !body.contains(line) { body.append(line) }
                }
            }
            guard !body.isEmpty || group.opened else { continue }
            blocks.append(([group.selector + " {"] + body + ["}"]).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func isComment(_ text: String) -> Bool { text.hasPrefix("/*") && text.hasSuffix("*/") }

    /// A declaration taken out, as Chrome writes it: inside a comment (one
    /// already switched off stays as it was).
    private static func commented(_ text: String) -> String {
        isComment(text) ? text : "/* " + text + "; */"
    }

    /// The declarations a line holds, each without its `;` and with its
    /// white space folded: what lies inside the braces on it, split at
    /// semicolons outside comments, strings and brackets. A switched-off
    /// declaration (a comment) is one.
    static func declarations(inLine text: String, inline: Bool = false) -> [String] {
        var body = Substring(text)
        if !inline {
            if let open = body.lastIndex(of: "{") { body = body[body.index(after: open)...] }
            else if body.contains("}") == false, looksLikeSelector(body) { return [] }
            if let close = body.firstIndex(of: "}") { body = body[..<close] }
        }
        var pieces: [String] = []
        var piece = ""
        var depth = 0
        var quote: Character?
        var comment = false
        var previous: Character = " "
        for character in body {
            piece.append(character)
            if comment {
                if previous == "*" && character == "/" {
                    comment = false
                    // A comment on its own is a declaration switched off.
                    if piece.trimmingCharacters(in: .whitespaces).hasPrefix("/*") {
                        pieces.append(piece)
                        piece = ""
                    }
                    previous = " "
                    continue
                }
            } else if let open = quote {
                if character == open && previous != "\\" { quote = nil }
            } else if previous == "/" && character == "*" {
                comment = true
                previous = " "
                continue
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth = max(0, depth - 1)
            } else if character == ";" && depth == 0 {
                piece.removeLast()
                pieces.append(piece)
                piece = ""
            }
            previous = character
        }
        pieces.append(piece)
        // A selector's part on its own line ("a:hover,") isn't a declaration.
        return pieces.map(fold).filter { !$0.isEmpty && ($0.contains(":") || isComment($0)) && !$0.hasSuffix(",") }
    }

    /// A line with no braces outside a declaration list is a selector's
    /// first part ("a,") when it has no colon before any bracket.
    private static func looksLikeSelector(_ text: Substring) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(",") && !trimmed.contains(";")
    }

    private static func fold(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// For each line of a style sheet, the selector (or at-rule prelude) of
    /// the innermost block the line is in, folded to one line; nil outside
    /// any. A line that opens a block belongs to the block it opens.
    static func selectors(_ text: String) -> [String?] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String?] = []
        var stack: [String] = []
        var prelude = ""
        var comment = false
        var quote: Character?
        var previous: Character = " "
        var lineStart: String?
        var opened: String?
        func endLine() {
            result.append(opened ?? lineStart)
            lineStart = stack.last
            opened = nil
        }
        for character in text {
            if character == "\n" {
                endLine()
                if !comment, quote == nil { prelude.append(" ") }
                previous = " "
                continue
            }
            if comment {
                if previous == "*" && character == "/" { comment = false; previous = " "; continue }
            } else if let open = quote {
                prelude.append(character)
                if character == open && previous != "\\" { quote = nil }
            } else if previous == "/" && character == "*" {
                comment = true
                if !prelude.isEmpty { prelude.removeLast() }
                previous = " "
                continue
            } else if character == "\"" || character == "'" {
                quote = character
                prelude.append(character)
            } else if character == "{" {
                let selector = fold(prelude.trimmingCharacters(in: .whitespacesAndNewlines))
                stack.append(selector)
                opened = selector
                prelude = ""
            } else if character == "}" {
                if !stack.isEmpty { stack.removeLast() }
                prelude = ""
            } else if character == ";" {
                prelude = ""
            } else {
                prelude.append(character)
            }
            previous = character
        }
        // The last line, when no newline ends it.
        if !text.isEmpty, !text.hasSuffix("\n") { endLine() }
        return result
    }
}

// MARK: Tracker

/// The files edited in one DevTools session, kept for as long as it
/// lasts: what each held before its first edit, and now. A navigation
/// clears the page's style sheets; Local Overrides files stay, as their
/// edits are on disk.
@MainActor
final class DeveloperChanges: ObservableObject {
    struct File: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A page style sheet or <style>, by styleSheetId.
            case styleSheet
            /// An element's style attribute.
            case inline
            /// The inspector-stylesheet New Style Rule adds to.
            case inspector
            /// A Local Overrides file edited in Sources.
            case source
        }

        let id: String
        let kind: Kind
        var name: String
        var url: String
        /// The styleSheetId and DOM target, for a style sheet.
        let sheet: String?
        let target: String?
        let css: Bool
        var original: String
        var current: String

        var changed: Bool { original != current }
    }

    private static var stores: [ObjectIdentifier: DeveloperChanges] = [:]

    static func of(_ session: DeveloperToolsSession) -> DeveloperChanges {
        let key = ObjectIdentifier(session)
        if let store = stores[key], store.session === session { return store }
        stores = stores.filter { $0.value.session != nil }
        let store = DeveloperChanges(session: session)
        stores[key] = store
        return store
    }

    /// The page navigated: its style sheets went with it.
    static func navigated(_ session: DeveloperToolsSession) {
        guard let store = stores[ObjectIdentifier(session)], store.session === session else { return }
        store.files.removeAll { $0.kind != .source }
        if let selected = store.selected, !store.files.contains(where: { $0.id == selected }) { store.selected = nil }
    }

    private(set) weak var session: DeveloperToolsSession?
    /// Every file edited, in the order first edited; the list shows those
    /// still different from how they began.
    @Published private(set) var files: [File] = []
    @Published var selected: String?

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    var changed: [File] { files.filter(\.changed) }

    /// The file the diff shows: the one chosen, else the first.
    var shown: File? {
        let changed = changed
        return changed.first { $0.id == selected } ?? changed.first
    }

    private func index(_ id: String) -> Int? { files.firstIndex { $0.id == id } }

    // MARK: Style sheets

    /// Before a style sheet's first edit: its text as it is, kept as the
    /// original.
    func willEditStyleSheet(_ sheet: String) async {
        guard let session, index(Self.sheetID(sheet)) == nil else { return }
        let target = session.domTargetID
        let about = describe(sheet, in: session)
        guard let text = await Self.text(of: sheet, target: target, in: session) else { return }
        guard index(Self.sheetID(sheet)) == nil else { return }
        files.append(File(id: Self.sheetID(sheet), kind: about.kind, name: about.name, url: about.url,
                          sheet: sheet, target: target, css: true, original: text, current: text))
    }

    /// After an edit: the style sheet's text now. One not seen before (the
    /// inspector-stylesheet a new rule made) began empty.
    func didEditStyleSheet(_ sheet: String, created: Bool = false) async {
        guard let session else { return }
        let target = session.domTargetID
        guard let text = await Self.text(of: sheet, target: target, in: session) else { return }
        if let at = index(Self.sheetID(sheet)) {
            files[at].current = text
        } else {
            let about = created ? (kind: File.Kind.inspector, name: "inspector-stylesheet", url: session.address?.absoluteString ?? "")
                                : describe(sheet, in: session)
            files.append(File(id: Self.sheetID(sheet), kind: about.kind, name: about.name, url: about.url,
                              sheet: sheet, target: target, css: true, original: created ? "" : text, current: text))
        }
        // A style sheet mapped to a workspace folder is saved there too.
        if let file = files.first(where: { $0.id == Self.sheetID(sheet) }), file.kind == .styleSheet {
            DeveloperWorkspace.shared.styleSheetEdited(url: file.url, text: text, session: session)
        }
    }

    private static func sheetID(_ sheet: String) -> String { "sheet:" + sheet }

    private static func text(of sheet: String, target: String?, in session: DeveloperToolsSession) async -> String? {
        let result = try? await session.command("CSS.getStyleSheetText", ["styleSheetId": sheet], targetID: target)
        return result?["text"] as? String
    }

    /// What the Styles pane knows of a sheet: an element's style
    /// attribute ("inline styles of div#main", as Chrome names it), the
    /// inspector-stylesheet, or a file by its address.
    private func describe(_ sheet: String, in session: DeveloperToolsSession) -> (kind: File.Kind, name: String, url: String) {
        let page = session.address?.absoluteString ?? ""
        let rule = session.matchedStyles.first { $0.style?.sheet == sheet || $0.rule?.sheet == sheet }
        if let rule, rule.inline || rule.origin == "inline" {
            let node = rule.inline ? session.selectedNode : rule.sectionNode
            return (.inline, "inline styles of " + Self.label(node.flatMap { session.nodes[$0] }), page)
        }
        if rule?.origin == "inspector" { return (.inspector, "inspector-stylesheet", page) }
        let url = rule?.sourceURL.flatMap { $0.isEmpty ? nil : $0 } ?? page
        return (.styleSheet, Self.fileName(url), url)
    }

    /// An element as Chrome labels it: tag, then #id or its classes.
    static func label(_ node: DeveloperToolsSession.DOMNode?) -> String {
        guard let node else { return "element" }
        func attribute(_ name: String) -> String? {
            stride(from: 0, to: max(0, node.attributes.count - 1), by: 2)
                .first { node.attributes[$0] == name }.map { node.attributes[$0 + 1] }
        }
        var label = node.name.lowercased()
        if let id = attribute("id"), !id.isEmpty {
            label += "#" + id
        } else if let classes = attribute("class")?.split(whereSeparator: \.isWhitespace), !classes.isEmpty {
            label += "." + classes.joined(separator: ".")
        }
        return label
    }

    /// The last part of an address, "(index)" for a folder's own page.
    static func fileName(_ url: String) -> String {
        guard let address = URL(string: url), address.scheme != nil else { return url.isEmpty ? "(index)" : url }
        let last = address.lastPathComponent
        return last.isEmpty || last == "/" ? "(index)" : last
    }

    // MARK: Sources

    /// A Local Overrides file's text as edited in Sources; `original` is
    /// what the editor opened it with, kept from the first edit.
    func editedSource(url: String, original: String, text: String, css: Bool) {
        let id = "source:" + url
        if let at = index(id) {
            files[at].current = text
        } else if original != text {
            files.append(File(id: id, kind: .source, name: Self.fileName(url), url: url, sheet: nil, target: nil,
                              css: css, original: original, current: text))
        }
    }

    // MARK: Revert

    /// Revert all changes to the file: its first text set back the way it
    /// was edited (the style sheet's text, the style attribute, the file on
    /// disk), and the Styles pane read again.
    func revert(_ file: File) {
        guard let session, let at = index(file.id) else { return }
        let original = file.original
        switch file.kind {
        case .source:
            do {
                try DeveloperLocalOverrides.shared.save(url: file.url, content: original)
            } catch {
                session.message = error.localizedDescription
                return
            }
            files[at].current = original
            DeveloperSourceTabs.of(session).reload(file.url)
        case .styleSheet, .inline, .inspector:
            guard let sheet = file.sheet else { return }
            let target = file.target
            let inline = file.kind == .inline
            session.run { session in
                if inline {
                    // The style attribute is one style, written as Styles writes it.
                    _ = try await session.bridge("return await perchInspector.setStyleText(style, text, target);", [
                        "style": ["styleSheetId": sheet, "ordinal": 0], "text": original, "target": target as Any? ?? NSNull(),
                    ])
                } else {
                    _ = try await session.command("CSS.setStyleSheetText", ["styleSheetId": sheet, "text": original],
                                                  targetID: target)
                }
                _ = try? await session.command("DOM.markUndoableState", targetID: target)
                let changes = DeveloperChanges.of(session)
                if let at = changes.index(file.id) {
                    changes.files[at].current = await Self.text(of: sheet, target: target, in: session) ?? original
                }
                if let selected = session.selectedNode { session.selectNode(selected) }
            }
        }
    }

    /// Copy: a style sheet's changed rules, or a script's diff.
    func copy(_ file: File) {
        let lines = DeveloperChangesDiff.diff(file.original, file.current)
        let text = file.css
            ? DeveloperChangesDiff.cssChanges(lines, original: file.original, current: file.current, inline: file.kind == .inline)
            : DeveloperChangesDiff.unified(lines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension DeveloperToolsSession {
    /// CSS.setStyleText as the Styles pane writes a rule, its style sheet's
    /// text kept for Changes before and after.
    func setTrackedStyleText(_ style: StyleID, _ text: String) async throws {
        let changes = DeveloperChanges.of(self)
        await changes.willEditStyleSheet(style.sheet)
        _ = try await bridge("return await perchInspector.setStyleText(style, text, target);", [
            "style": style.protocolValue, "text": text, "target": domTargetID as Any? ?? NSNull(),
        ])
        await changes.didEditStyleSheet(style.sheet)
    }
}
