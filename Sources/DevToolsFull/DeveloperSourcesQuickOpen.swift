import AppKit

// Chrome's quick-open box for the Sources panel: ⌘P (or ⌘O) for a file by
// name, ⇧⌘O for a symbol in this one (`@`), ⌃G for a line (`:`). One field;
// what it starts with says which list it shows, as in Chrome.

struct SourceSymbol: Equatable {
    var name: String
    var offset: Int
}

enum SourceOutline {
    /// Functions, classes and methods in JavaScript, with their parameters;
    /// rules in CSS. As Chrome's ⇧⌘O lists them.
    static func symbols(_ text: String, language: SourceLanguage) -> [SourceSymbol] {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { u in
            switch language {
            case .javascript: return javascript(u, 0, u.count)
            case .css: return css(u)
            case .html:
                // The scripts and styles in the page.
                var symbols: [SourceSymbol] = []
                var k = 0
                while k < u.count {
                    for name in ["script", "style"] {
                        let open = Array("<\(name)".utf16)
                        guard k + open.count < u.count, zip(open, u[k..<(k + open.count)]).allSatisfy({ $0 == ($1 | (($1 >= 65 && $1 <= 90) ? 0x20 : 0)) }) else { continue }
                        var body = k + open.count
                        while body < u.count, u[body] != 62 { body += 1 }
                        body += 1
                        let end = SourceHighlighter.rawTextEnd(u, from: min(body, u.count), name: name)
                        if body < end { symbols += name == "script" ? javascript(u, body, end) : cssRange(u, body, end) }
                        k = end
                    }
                    k += 1
                }
                return symbols
            default: return []
            }
        }
    }

    private static func string(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: u[start..<end]), as: UTF16.self)
    }

    private static func javascript(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> [SourceSymbol] {
        let all = JSLexer.lex(u, start: start, end: end)
        let lexemes = all.filter { !$0.isComment }
        var symbols: [SourceSymbol] = []
        func text(_ n: Int) -> String? { n >= 0 && n < lexemes.count ? string(u, lexemes[n].start, lexemes[n].end) : nil }
        func isWord(_ n: Int) -> Bool { n >= 0 && n < lexemes.count && lexemes[n].kind == .identifier }
        /// The parameters from the `(` at `n`, run together: "(a, b)". And
        /// the index just past the `)`.
        func parameters(_ n: Int) -> (String, Int)? {
            guard text(n) == "(" else { return nil }
            var depth = 0
            var parts: [String] = []
            var k = n
            while k < lexemes.count {
                let t = text(k)!
                if t == "(" || t == "[" || t == "{" { depth += 1 }
                if t == ")" || t == "]" || t == "}" { depth -= 1 }
                if depth == 0 { break }
                if k > n { parts.append(t == "," ? ", " : t) }
                k += 1
            }
            let joined = parts.joined()
            return ("(" + (joined.count > 60 ? String(joined.prefix(57)) + "…" : joined) + ")", k + 1)
        }
        var n = 0
        while n < lexemes.count {
            defer { n += 1 }
            let t = text(n)!
            if lexemes[n].kind == .keyword, t == "function" {
                var name = n + 1
                if text(name) == "*" { name += 1 }
                if isWord(name), let (params, _) = parameters(name + 1) {
                    symbols.append(SourceSymbol(name: text(name)! + params, offset: lexemes[name].start))
                }
            } else if lexemes[n].kind == .keyword, t == "class", isWord(n + 1) {
                symbols.append(SourceSymbol(name: "class " + text(n + 1)!, offset: lexemes[n + 1].start))
            } else if isWord(n) || (lexemes[n].kind == .keyword && n > 0 && (text(n - 1) == "." )) {
                let next = text(n + 1)
                // name = function (…), name: function (…), name = (…) =>, name = x =>
                if next == "=" || next == ":" {
                    var k = n + 2
                    if text(k) == "async" { k += 1 }
                    var params: String?
                    if text(k) == "function" {
                        var p = k + 1
                        if text(p) == "*" { p += 1 }
                        if isWord(p) { p += 1 }
                        params = parameters(p)?.0
                    } else if let (list, after) = parameters(k), text(after) == "=>" {
                        params = list
                    } else if isWord(k), text(k + 1) == "=>" {
                        params = "(" + text(k)! + ")"
                    }
                    if let params {
                        // a.b.c = function …: the whole name.
                        var first = n
                        while first >= 2, text(first - 1) == ".", lexemes[first - 2].kind == .identifier || lexemes[first - 2].kind == .keyword { first -= 2 }
                        let name = (first..<(n + 1)).compactMap(text).joined()
                        symbols.append(SourceSymbol(name: name + params, offset: lexemes[first].start))
                    }
                } else if next == "(", let previous = text(n - 1), ["{", "}", ";", "static", "async", "get", "set", "*"].contains(previous),
                          let (params, after) = parameters(n + 1), text(after) == "{" {
                    // A method in a class or an object.
                    symbols.append(SourceSymbol(name: t + params, offset: lexemes[n].start))
                }
            }
        }
        return symbols
    }

    private static func css(_ u: UnsafeBufferPointer<UInt16>) -> [SourceSymbol] { cssRange(u, 0, u.count) }

    private static func cssRange(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> [SourceSymbol] {
        var symbols: [SourceSymbol] = []
        var k = start
        var statement = start
        while k < end {
            let c = u[k]
            if c == 47, k + 1 < end, u[k + 1] == 42 {
                k += 2
                while k + 1 < end, !(u[k] == 42 && u[k + 1] == 47) { k += 1 }
                k += 2
                if statement == k - 2 || statement >= k - 2 { statement = k }
                continue
            }
            if c == 34 || c == 39 { k = SourceHighlighter.cssStringEnd(u, k, end); continue }
            if c == 123 || c == 125 || c == 59 {
                if c == 123 {
                    let words = string(u, statement, k).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    // Strip a comment that sat before the selector.
                    let name = words.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        var at = statement
                        while at < k, SourceLexing.isSpace(u[at]) || SourceLexing.isNewline(u[at]) { at += 1 }
                        symbols.append(SourceSymbol(name: name, offset: at))
                    }
                }
                statement = k + 1
            }
            k += 1
        }
        return symbols
    }
}

/// Chrome's file matching in ⌘P, roughly: every typed character in order,
/// best when they start the name or a word in it, run together, and
/// near the front.
enum QuickOpenMatch {
    static func score(_ query: String, _ candidate: String) -> Int? {
        let query = Array(query.lowercased().unicodeScalars)
        let text = Array(candidate.lowercased().unicodeScalars)
        let original = Array(candidate.unicodeScalars)
        guard !query.isEmpty else { return 0 }
        var score = 0
        var at = 0
        var previous = -2
        for character in query {
            guard let found = text[at...].firstIndex(of: character) else { return nil }
            var points = 1
            if found == previous + 1 { points += 5 }
            if found == 0 { points += 8 } else {
                let before = original[found - 1]
                if "/._-?=&".unicodeScalars.contains(before) || (CharacterSet.uppercaseLetters.contains(original[found]) && CharacterSet.lowercaseLetters.contains(before)) { points += 4 }
            }
            score += points
            previous = found
            at = found + 1
        }
        return score * 100 - text.count
    }

    /// Chrome's `file.js:120` and `file.js:120:5` in ⌘P: the name to match,
    /// and the 1-based line and column to open at. A trailing `:` still
    /// being typed is dropped; a URL's own colons stay in the name.
    static func location(_ query: String) -> (name: String, line: Int?, column: Int?) {
        let parts = query.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (query, nil, nil) }
        func number(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        let last = parts[parts.count - 1]
        if parts.count >= 3, let line = number(parts[parts.count - 2]) {
            let name = parts.dropLast(2).joined(separator: ":")
            if let column = number(last), !name.isEmpty { return (name, line, column) }
            if last.isEmpty, !name.isEmpty { return (name, line, nil) }
        }
        let name = parts.dropLast().joined(separator: ":")
        guard !name.isEmpty else { return (query, nil, nil) }
        if let line = number(last) { return (name, line, nil) }
        if last.isEmpty { return (name, nil, nil) }
        return (query, nil, nil)
    }
}

// MARK: The box

struct QuickOpenFile {
    var id: String
    var name: String
    var detail: String
}

final class SourceQuickOpenView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        var title: String
        var detail: String
        var perform: () -> Void
    }

    let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    private var heightConstraint: NSLayoutConstraint!

    var files: () -> [QuickOpenFile] = { [] }
    var symbols: () -> [SourceSymbol] = { [] }
    var currentLine: () -> Int = { 1 }
    var lineCount: () -> Int = { 1 }
    /// Opens a file, at a line and column when the query named one.
    var openFile: (String, Int?, Int?) -> Void = { _, _, _ in }
    var goToOffset: (Int) -> Void = { _ in }
    var goToLine: (Int, Int) -> Void = { _, _ in }
    var close: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 8

        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("Quick open")

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.style = .plain
        table.backgroundColor = .clear
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(field)
        addSubview(scroll)
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(_ prefix: String) {
        field.stringValue = prefix
        refresh()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (prefix as NSString).length, length: 0)
    }

    /// What the rows are for the text as typed (for the tests too).
    var titles: [String] { rows.map(\.title) }

    func refresh() {
        let text = field.stringValue
        if text.hasPrefix(":") {
            let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            field.placeholderString = nil
            if let line = parts.first ?? nil {
                let column = parts.count > 1 ? (parts[1] ?? 1) : 1
                let clamped = min(max(line, 1), lineCount())
                rows = [Row(title: parts.count > 1 ? "Go to line \(clamped) and column \(column)." : "Go to line \(clamped).", detail: "") { [weak self] in
                    self?.goToLine(clamped, column)
                }]
            } else {
                rows = [Row(title: "Current line: \(currentLine()). Type a line number between 1 and \(lineCount()) to navigate to.", detail: "") {}]
            }
        } else if text.hasPrefix("@") {
            let query = String(text.dropFirst())
            let found = symbols()
            let scored = query.isEmpty ? found.map { ($0, 0) } : found.compactMap { symbol in QuickOpenMatch.score(query, symbol.name).map { (symbol, $0) } }.sorted { $0.1 > $1.1 }
            rows = scored.prefix(500).map { symbol, _ in Row(title: symbol.name, detail: "") { [weak self] in self?.goToOffset(symbol.offset) } }
            if rows.isEmpty { rows = [Row(title: found.isEmpty ? "No symbols in this file" : "No results found", detail: "") {}] }
        } else {
            let location = QuickOpenMatch.location(text.trimmingCharacters(in: .whitespaces))
            let query = location.name
            let found = files()
            let scored = query.isEmpty ? found.map { ($0, 0) } : found.compactMap { file in
                (QuickOpenMatch.score(query, file.name) ?? QuickOpenMatch.score(query, file.detail + file.name).map { $0 / 2 }).map { (file, $0) }
            }.sorted { $0.1 > $1.1 }
            rows = scored.prefix(500).map { file, _ in
                Row(title: file.name, detail: file.detail) { [weak self] in self?.openFile(file.id, location.line, location.column) }
            }
            if rows.isEmpty { rows = [Row(title: "No results found", detail: "") {}] }
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        heightConstraint.constant = min(CGFloat(rows.count), 10) * table.rowHeight
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        let item = rows[row]
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        if !item.detail.isEmpty {
            title.append(NSAttributedString(string: "  " + item.detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = title
        label.lineBreakMode = .byTruncatingMiddle
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)), #selector(moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let step = selector == #selector(moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + step, 0), rows.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(insertNewline(_:)):
            choose(table.selectedRow)
            return true
        case #selector(cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func clicked() { choose(table.clickedRow) }

    func choose(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        let perform = rows[row].perform
        close()
        perform()
    }
}
