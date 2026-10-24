import Foundation

// Markdown, turned into the HTML reading mode shows (see Reader.twin).
//
// A site that publishes a markdown copy of a page has already decided what
// the article is; this only has to draw it. What it draws is CommonMark and
// the GitHub additions people actually write (tables, strikethrough, task
// lists, bare links), close enough rather than to the letter.
//
// Two departures, both because of where twins come from. Most are written in
// MDX, the docs-site dialect, which puts markdown inside components and
// indents it: so four spaces is not a code block here (MDX dropped that rule
// for the same reason), and a component's tags are read for what they can
// give — a title, a link, a callout — and otherwise stepped over.
//
// Nothing from the markdown reaches the page as markup of its own. Every
// piece of text is escaped, every tag written in the source is rebuilt from a
// short list with its safe attributes only, and every address has to be a
// web or mail one.

enum Markdown {
    struct Page: Equatable {
        /// The page's heading, lifted out of the body so reading mode can
        /// set it the way it sets every title.
        var title: String?
        var html: String
    }

    static func page(_ text: String, base: URL?) -> Page {
        var lines = normalized(text)
        var title = frontMatter(&lines)
        var parser = Parser(base: base, references: [:])
        parser.references = references(&lines)
        var blocks = parser.blocks(lines[...])

        // The first heading of the top level is the title, if it comes
        // before any section does. It may sit below a skip link or a note to
        // agents; it still names the page.
        if let first = blocks.firstIndex(where: { if case .heading = $0 { return true } else { return false } }),
           case .heading(1, let text) = blocks[first] {
            title = plain(text)
            blocks.remove(at: first)
        }
        let html = parser.render(blocks, tight: false)
        return Page(title: title.flatMap { $0.isEmpty ? nil : $0 }, html: html)
    }

    // MARK: - lines

    fileprivate static func normalized(_ text: String) -> [Substring] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            // Inline uses these two to hold its place; nobody writes them.
            .replacingOccurrences(of: "\u{E000}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// YAML at the very top, between two lines of dashes: what the site
    /// publishes about the page. Only its title is of any use here.
    private static func frontMatter(_ lines: inout [Substring]) -> String? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              lines.count > 1, lines[1].contains(":"),
              let end = lines.dropFirst().firstIndex(where: {
                  let line = $0.trimmingCharacters(in: .whitespaces)
                  return line == "---" || line == "..."
              }) else { return nil }
        let head = lines[1..<end]
        lines.removeSubrange(0...end)
        for line in head where line.hasPrefix("title:") {
            var value = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// `[name]: address "title"` lines, wherever they are, taken out of the
    /// text and kept for the links that name them.
    private static func references(_ lines: inout [Substring]) -> [String: (String, String?)] {
        var found: [String: (String, String?)] = [:]
        var fenced = false
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            guard !fenced, trimmed.hasPrefix("["), let close = trimmed.range(of: "]:") else { return false }
            let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close.lowerBound]
            guard !name.isEmpty, !name.contains("]") else { return false }
            var scanner = Inline.Scanner(Array(trimmed[close.upperBound...]))
            guard let (address, title) = scanner.destination(closing: nil) else { return false }
            let key = label(String(name))
            if found[key] == nil { found[key] = (address, title) }
            return true
        }
        return found
    }

    static func label(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Text with the markup taken off, for a title.
    fileprivate static func plain(_ text: String) -> String {
        let html = Parser(base: nil, references: [:]).inline(text)
        let bare = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescape(bare).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - escaping

    static func escape(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    fileprivate static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// An address from the markdown, made whole against the twin's own and
    /// kept only if it goes somewhere a link should: a web page, a mail, or a
    /// place on this page. `javascript:` and its kind never get through.
    static func address(_ raw: String, base: URL?) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { return raw }
        let url = URL(string: raw, relativeTo: base)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#", "%"]))
                .flatMap { URL(string: $0, relativeTo: base) }
        guard let url = url?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    /// The id a heading is given, so that a contents list's `#links` land.
    /// GitHub's way, which is what most of those links were written for.
    static func slug(_ text: String) -> String {
        let kept = plain(text).lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }
}

// MARK: - blocks

private indirect enum Block {
    case heading(Int, String)
    case paragraph(String)
    case code(String?, String)
    case quote([Block])
    case list(ordered: Bool, start: Int, items: [[Block]], checks: [Bool?], tight: Bool)
    case rule
    case table(head: [String], aligns: [String?], rows: [[String]])
    /// A line of tags written in the source, rebuilt through Inline.tag.
    case html(String)
}

private struct Parser {
    let base: URL?
    var references: [String: (String, String?)]
    /// Ids already given, so two headings of the same name don't share one.
    var ids: [String: Int] = [:]

    init(base: URL?, references: [String: (String, String?)]) {
        self.base = base
        self.references = references
    }

    // MARK: reading lines into blocks

    func blocks(_ lines: ArraySlice<Substring>) -> [Block] {
        var out: [Block] = []
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if let (fence, info) = Self.fence(trimmed) {
                let indent = line.prefix(while: { $0 == " " }).count
                var body: [String] = []
                i += 1
                while i < lines.endIndex {
                    let inner = lines[i]
                    let bare = inner.trimmingCharacters(in: .whitespaces)
                    if bare.hasPrefix(fence), bare.allSatisfy({ $0 == fence.first }) {
                        i += 1
                        break
                    }
                    // Code indented along with its fence comes back out with it.
                    var dropped = 0
                    var text = inner[...]
                    while dropped < indent, text.first == " " {
                        text = text.dropFirst()
                        dropped += 1
                    }
                    body.append(String(text))
                    i += 1
                }
                let language = info.split(separator: " ").first.map(String.init)
                out.append(.code(language, body.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("<!--") {
                while i < lines.endIndex, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            if let heading = Self.atx(trimmed) {
                out.append(heading)
                i += 1
                continue
            }
            if Self.isRule(trimmed) {
                out.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var inner: [Substring] = []
                while i < lines.endIndex {
                    let bare = lines[i].trimmingCharacters(in: .whitespaces)
                    if bare.hasPrefix(">") {
                        var rest = bare.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(Substring(rest))
                    } else if !bare.isEmpty, let last = inner.last, !last.trimmingCharacters(in: .whitespaces).isEmpty,
                              !Self.starts(bare) {
                        // A paragraph carried on without its marker.
                        inner.append(Substring(bare))
                    } else {
                        break
                    }
                    i += 1
                }
                // A note left at the top for agents — where to find the
                // site's index for language models — says nothing to a
                // person reading.
                if inner.contains(where: { $0.contains("llms.txt") }) { continue }
                out.append(.quote(blocks(inner[...])))
                continue
            }
            if Self.marker(line) != nil {
                let (list, next) = self.list(lines, from: i)
                out.append(list)
                i = next
                continue
            }
            if i + 1 < lines.endIndex, trimmed.contains("|"), Self.delimiters(lines[i + 1]) != nil {
                let (table, next) = self.table(lines, from: i)
                out.append(table)
                i = next
                continue
            }
            if Self.isTagLine(trimmed) {
                // A tag may be spread over lines, attribute by attribute.
                var tag = trimmed
                var reach = 0
                while !tag.contains(">"), i + 1 < lines.endIndex, reach < 20 {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    tag += " " + next
                    i += 1
                    reach += 1
                }
                out.append(.html(tag))
                i += 1
                continue
            }
            // A paragraph, until something else begins.
            var text: [String] = [String(line.drop(while: { $0 == " " }))]
            i += 1
            var setext: Int?
            while i < lines.endIndex {
                let next = lines[i]
                let bare = next.trimmingCharacters(in: .whitespaces)
                if bare.isEmpty { break }
                if !bare.isEmpty, bare.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
                if bare.count >= 2, bare.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
                if Self.starts(bare) || Self.interrupts(next) { break }
                if bare.contains("|"), i + 1 < lines.endIndex, Self.delimiters(lines[i + 1]) != nil { break }
                text.append(String(next.drop(while: { $0 == " " })))
                i += 1
            }
            let joined = text.joined(separator: "\n")
            if let setext {
                out.append(.heading(setext, joined.trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(joined))
            }
        }
        return out
    }

    /// Lines that end a paragraph by starting something of their own.
    static func starts(_ bare: String) -> Bool {
        fence(bare) != nil || atx(bare) != nil || isRule(bare) || bare.hasPrefix(">")
            || bare.hasPrefix("<!--") || isTagLine(bare)
    }

    /// A list may break into a paragraph too — an ordered one only if it
    /// counts from one, so that a sentence ending "in 1984." on a new line
    /// stays a sentence.
    static func interrupts(_ line: Substring) -> Bool {
        guard let item = marker(line) else { return false }
        return !item.ordered || item.start == 1
    }

    static func fence(_ bare: String) -> (String, String)? {
        for mark in ["```", "~~~"] where bare.hasPrefix(mark) {
            let run = bare.prefix(while: { $0 == mark.first })
            let info = bare.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if mark == "```", info.contains("`") { return nil }
            return (String(run), info)
        }
        return nil
    }

    static func atx(_ bare: String) -> Block? {
        let hashes = bare.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = bare.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration, when it stands apart.
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(hashes, text)
    }

    static func isRule(_ bare: String) -> Bool {
        guard let mark = bare.first, "-*_".contains(mark) else { return false }
        let marks = bare.filter { $0 != " " }
        return marks.count >= 3 && marks.allSatisfy { $0 == mark }
    }

    /// A line that is nothing but tags: `<Note>`, `</Steps>`, `<img … />`,
    /// or the start of a tag that carries on below. An autolink is not one.
    static func isTagLine(_ bare: String) -> Bool {
        guard bare.hasPrefix("<"), bare.count > 2 else { return false }
        let second = bare[bare.index(after: bare.startIndex)]
        guard second.isLetter || second == "/" else { return false }
        if bare.range(of: #"^<[A-Za-z][A-Za-z0-9+.-]*:[^\s<>]*>$"#, options: .regularExpression) != nil { return false }
        if bare.range(of: #"^<[^\s<>@]+@[^\s<>@]+>$"#, options: .regularExpression) != nil { return false }
        return bare.hasSuffix(">") || !bare.contains(">")
    }

    struct Marker {
        var indent: Int
        var ordered: Bool
        var start: Int
        /// The character that makes the marker: -, * or +, or . or ) after a number.
        var sign: Character
        /// Where an item's own text begins, counted from the line's start.
        var content: Int
    }

    static func marker(_ line: Substring) -> Marker? {
        let indent = line.prefix(while: { $0 == " " }).count
        var rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        var width: Int
        var ordered = false
        var start = 1
        var sign = first
        if "-*+".contains(first) {
            width = 1
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
            rest = rest.dropFirst()
            ordered = true
            start = number
            sign = delimiter
            width = digits.count + 1
        }
        let spaces = rest.prefix(while: { $0 == " " }).count
        // A marker with nothing after it on the line is still an item; one
        // run straight into the text ("-not", "3.14") is not.
        guard spaces > 0 || rest.isEmpty else { return nil }
        width += (spaces > 4 || rest.dropFirst(spaces).isEmpty) ? 1 : spaces
        return Marker(indent: indent, ordered: ordered, start: start, sign: sign, content: indent + width)
    }

    func list(_ lines: ArraySlice<Substring>, from begin: Int) -> (Block, Int) {
        guard let first = Self.marker(lines[begin]) else { return (.paragraph(String(lines[begin])), begin + 1) }
        var items: [[Substring]] = []
        var current: [Substring] = []
        var content = first.content
        var blank = false
        var loose = false
        var i = begin
        while i < lines.endIndex {
            let line = lines[i]
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty {
                blank = true
                current.append("")
                i += 1
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if let item = Self.marker(line), item.ordered == first.ordered, item.sign == first.sign,
               indent < content, !Self.isRule(bare) {
                if !items.isEmpty || !current.isEmpty {
                    if blank { loose = true }
                    items.append(current)
                }
                // The text begins after the marker; dropping the item's
                // width from every line of it lines nested blocks up at 0.
                current = [line.dropFirst(min(item.content, line.count))]
                content = item.content
                blank = false
                i += 1
                continue
            }
            if indent >= content {
                if blank, current.contains(where: { !$0.isEmpty }) { loose = true }
                current.append(line.dropFirst(content))
                blank = false
                i += 1
                continue
            }
            // Carried on without its indent: part of the paragraph above,
            // unless it starts something of its own.
            if !blank, !Self.starts(bare), Self.marker(line) == nil {
                current.append(Substring(bare))
                i += 1
                continue
            }
            break
        }
        items.append(current)
        // Blank lines at the very end belong to whatever follows.
        var parsed: [[Block]] = []
        var checks: [Bool?] = []
        for var item in items {
            while item.last?.isEmpty == true { item.removeLast() }
            var check: Bool?
            if let head = item.first {
                for (box, state) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(box) {
                    check = state
                    item[item.startIndex] = head.dropFirst(box.count)
                }
            }
            checks.append(check)
            parsed.append(blocks(item[...]))
        }
        return (.list(ordered: first.ordered, start: first.start, items: parsed, checks: checks, tight: !loose), i)
    }

    static func delimiters(_ line: Substring) -> [String?]? {
        guard line.contains("|") else { return nil }
        let cells = row(String(line))
        guard !cells.isEmpty else { return nil }
        var aligns: [String?] = []
        for cell in cells {
            let bare = cell.trimmingCharacters(in: .whitespaces)
            guard bare.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (bare.hasPrefix(":"), bare.hasSuffix(":")) {
            case (true, true): aligns.append("center")
            case (false, true): aligns.append("right")
            case (true, false): aligns.append("left")
            default: aligns.append(nil)
            }
        }
        return aligns
    }

    /// A table row's cells. A pipe inside code, or escaped, stays in its cell.
    static func row(_ line: String) -> [String] {
        var bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("|") { bare.removeFirst() }
        if bare.hasSuffix("|"), !bare.hasSuffix("\\|") { bare.removeLast() }
        var cells: [String] = []
        var cell = ""
        var code = false
        var escaped = false
        for character in bare {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                code.toggle()
                cell.append(character)
            } else if character == "|", !code {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    func table(_ lines: ArraySlice<Substring>, from begin: Int) -> (Block, Int) {
        let head = Self.row(String(lines[begin]))
        let aligns = Self.delimiters(lines[begin + 1]) ?? []
        var rows: [[String]] = []
        var i = begin + 2
        while i < lines.endIndex {
            let bare = lines[i].trimmingCharacters(in: .whitespaces)
            if bare.isEmpty || Self.starts(bare) { break }
            rows.append(Self.row(bare))
            i += 1
        }
        return (.table(head: head, aligns: aligns, rows: rows), i)
    }

    // MARK: drawing blocks

    /// A tag that stood aside draws nothing, and leaves no gap for it.
    mutating func render(_ blocks: [Block], tight: Bool) -> String {
        var parts: [String] = []
        for block in blocks {
            let html = render(block, tight: tight)
            if !html.isEmpty { parts.append(html) }
        }
        return parts.joined(separator: "\n")
    }

    mutating func render(_ block: Block, tight: Bool) -> String {
        switch block {
        case .heading(let level, let text):
            var id = Markdown.slug(text)
            if let seen = ids[id] {
                ids[id] = seen + 1
                id += "-\(seen)"
            } else {
                ids[id] = 1
            }
            let attribute = id.isEmpty ? "" : " id=\"\(Markdown.escape(id))\""
            return "<h\(level)\(attribute)>\(inline(text))</h\(level)>"
        case .paragraph(let text):
            let html = inline(text)
            if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            return tight ? html : "<p>\(html)</p>"
        case .code(let language, let text):
            let kind = language.map { " class=\"language-\(Markdown.escape($0))\"" } ?? ""
            return "<pre><code\(kind)>\(Markdown.escape(text))</code></pre>"
        case .quote(let blocks):
            return "<blockquote>\(render(blocks, tight: false))</blockquote>"
        case .list(let ordered, let start, let items, let checks, let tight):
            let tag = ordered ? "ol" : "ul"
            let from = ordered && start != 1 ? " start=\"\(start)\"" : ""
            var html = "<\(tag)\(from)>"
            for (item, check) in zip(items, checks) {
                var box = ""
                if let check {
                    box = check ? "<input type=\"checkbox\" checked disabled> " : "<input type=\"checkbox\" disabled> "
                }
                html += "<li>" + box + render(item, tight: tight) + "</li>"
            }
            return html + "</\(tag)>"
        case .rule:
            return "<hr>"
        case .table(let head, let aligns, let rows):
            func cells(_ values: [String], _ tag: String) -> String {
                aligns.indices.map { index -> String in
                    let style = aligns[index].map { " style=\"text-align:\($0)\"" } ?? ""
                    let value = index < values.count ? values[index] : ""
                    return "<\(tag)\(style)>\(inline(value))</\(tag)>"
                }.joined()
            }
            let body = rows.map { "<tr>\(cells($0, "td"))</tr>" }.joined()
            // Wide tables scroll inside their own box, not the page.
            return "<div class=\"office-wide\"><table><thead><tr>\(cells(head, "th"))</tr></thead><tbody>\(body)</tbody></table></div>"
        case .html(let text):
            return Inline.tags(text, base: base, standing: true)
        }
    }

    // MARK: inline

    func inline(_ text: String) -> String {
        Inline(base: base, references: references).render(text)
    }
}

// MARK: - inline

private struct Inline {
    let base: URL?
    let references: [String: (String, String?)]

    /// The parts that are already HTML — code, links, tags — stand aside as
    /// placeholders while emphasis is worked out over what is left, so that
    /// an asterisk inside a URL or a code span is never read as one.
    func render(_ text: String) -> String {
        var kept: [String] = []
        func keep(_ html: String) -> String {
            kept.append(html)
            return "\u{E000}\(kept.count - 1)\u{E001}"
        }

        var scanner = Scanner(Array(text))
        var out = ""
        var pending = ""
        func flush() {
            out += Markdown.escape(pending)
            pending = ""
        }

        while let character = scanner.peek() {
            switch character {
            case "\\":
                scanner.advance()
                if let next = scanner.peek(), next.isASCII, next.isPunctuation || next.isSymbol {
                    // Held aside, so the emphasis pass never sees it as a mark.
                    flush()
                    out += keep(Markdown.escape(String(next)))
                    scanner.advance()
                } else if scanner.peek() == "\n" {
                    flush()
                    out += keep("<br>")
                } else {
                    pending.append("\\")
                }
            case "`":
                let mark = scanner.run(of: "`")
                if let code = scanner.until(run: mark) {
                    var code = code.replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    flush()
                    out += keep("<code>\(Markdown.escape(code))</code>")
                } else {
                    pending += mark
                }
            case "!" where scanner.peek(1) == "[":
                scanner.advance()
                if let (alt, address, title) = link(&scanner) {
                    flush()
                    // A picture with nowhere to come from — `![]()` — is left out.
                    if let source = Markdown.address(address, base: base) {
                        let plain = Markdown.plain(alt)
                        let caption = title.map { " title=\"\(Markdown.escape($0))\"" } ?? ""
                        out += keep("<img src=\"\(Markdown.escape(source))\" alt=\"\(Markdown.escape(plain))\"\(caption) loading=\"lazy\">")
                    }
                } else {
                    // Not a picture after all; the bracket is read next time round.
                    pending.append("!")
                }
            case "[":
                let save = scanner.position
                if let (label, address, title) = link(&scanner) {
                    flush()
                    let inner = Inline(base: base, references: references).render(label)
                    if let target = Markdown.address(address, base: base) {
                        let caption = title.map { " title=\"\(Markdown.escape($0))\"" } ?? ""
                        out += keep("<a href=\"\(Markdown.escape(target))\"\(caption)>\(inner)</a>")
                    } else {
                        out += keep(inner)
                    }
                } else {
                    scanner.position = save + 1
                    pending.append("[")
                }
            case "<":
                if let (html, length) = angle(Array(scanner.rest)) {
                    flush()
                    out += keep(html)
                    scanner.position += length
                } else {
                    pending.append("<")
                    scanner.advance()
                }
            case "h", "w":
                let apart = pending.last.map { !$0.isLetter && !$0.isNumber } ?? true
                let looks = scanner.rest.starts(with: "http") || scanner.rest.starts(with: "www.")
                if apart, looks, let (html, length) = bare(Array(scanner.rest)) {
                    flush()
                    out += keep(html)
                    scanner.position += length
                } else {
                    pending.append(character)
                    scanner.advance()
                }
            case "\n":
                // Two spaces at the end of a line break it.
                if pending.hasSuffix("  ") {
                    while pending.hasSuffix(" ") { pending.removeLast() }
                    flush()
                    out += keep("<br>")
                } else {
                    while pending.hasSuffix(" ") { pending.removeLast() }
                    pending.append("\n")
                }
                scanner.advance()
            case "&":
                // An entity written into the text is already HTML: &amp;,
                // &copy;, &#8212; go through as they are.
                let window = scanner.rest.prefix(12)
                if let end = window.firstIndex(of: ";"),
                   case let entity = String(window[...end]),
                   entity.range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,10});$"#, options: .regularExpression) != nil {
                    flush()
                    out += keep(entity)
                    scanner.position += entity.count
                } else {
                    pending.append("&")
                    scanner.advance()
                }
            default:
                pending.append(character)
                scanner.advance()
            }
        }
        flush()

        out = Self.emphasis(out)
        // Placeholders can hold placeholders of their own (a link's text).
        for (index, html) in kept.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: html)
        }
        return out
    }

    private static let emphases: [(NSRegularExpression, String)] = [
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "<strong>$1</strong>"),
        (#"(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])"#, "<strong>$1</strong>"),
        (#"\*(?=[^\s*])(.+?)(?<=[^\s*])\*"#, "<em>$1</em>"),
        (#"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#, "<em>$1</em>"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])).map { ($0, template) }
    }

    private static func emphasis(_ text: String) -> String {
        guard text.contains(where: { $0 == "*" || $0 == "_" || $0 == "~" }) else { return text }
        var text = text
        for (pattern, template) in emphases {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }

    /// `[text](address "title")`, `[text][name]`, `[text][]` or `[name]`,
    /// with the scanner on the opening bracket. Answers the link's text,
    /// where it goes and its title, and leaves the scanner after it.
    private func link(_ scanner: inout Scanner) -> (String, String, String?)? {
        let save = scanner.position
        guard scanner.peek() == "[" else { return nil }
        scanner.advance()
        var depth = 1
        var label = ""
        while let character = scanner.peek() {
            scanner.advance()
            if character == "\\", let next = scanner.peek() {
                label.append(character)
                label.append(next)
                scanner.advance()
                continue
            }
            if character == "`" {
                // A bracket inside code doesn't close the text.
                label.append(character)
                while let inner = scanner.peek() {
                    scanner.advance()
                    label.append(inner)
                    if inner == "`" { break }
                }
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            label.append(character)
        }
        guard depth == 0 else {
            scanner.position = save
            return nil
        }
        if scanner.peek() == "(" {
            scanner.advance()
            if let (address, title) = scanner.destination(closing: ")") {
                return (label, address, title)
            }
            scanner.position = save
            return nil
        }
        var name = label
        if scanner.peek() == "[" {
            let back = scanner.position
            scanner.advance()
            var written = ""
            while let character = scanner.peek(), character != "]", character != "[" {
                written.append(character)
                scanner.advance()
            }
            if scanner.peek() == "]" {
                scanner.advance()
                if !written.isEmpty { name = written }
            } else {
                scanner.position = back
            }
        }
        if let (address, title) = references[Markdown.label(name)] {
            return (label, address, title)
        }
        scanner.position = save
        return nil
    }

    /// Something in angle brackets: an autolink, a comment, or a tag.
    private func angle(_ rest: [Character]) -> (String, Int)? {
        let text = String(rest.prefix(2000))
        if let range = text.range(of: #"^<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*)>"#, options: .regularExpression) {
            let inner = String(text[range].dropFirst().dropLast())
            guard let target = Markdown.address(inner, base: base) else { return (Markdown.escape(inner), text[range].count) }
            return ("<a href=\"\(Markdown.escape(target))\">\(Markdown.escape(inner))</a>", text[range].count)
        }
        if let range = text.range(of: #"^<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+>"#, options: .regularExpression) {
            let inner = String(text[range].dropFirst().dropLast())
            return ("<a href=\"mailto:\(Markdown.escape(inner))\">\(Markdown.escape(inner))</a>", text[range].count)
        }
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            return ("", text.distance(from: text.startIndex, to: end.upperBound))
        }
        if let range = text.range(of: Self.tagPattern, options: .regularExpression) {
            return (Self.tags(String(text[range]), base: base, standing: false), text[range].count)
        }
        return nil
    }

    /// A web address written out bare, as GitHub links it: from http(s)://
    /// or www. to the next space, less the punctuation that ends a sentence.
    private func bare(_ rest: [Character]) -> (String, Int)? {
        let text = String(rest.prefix(2000))
        guard let range = text.range(of: #"^(https?://|www\.)[^\s<>]+"#, options: .regularExpression) else { return nil }
        var found = String(text[range])
        while let last = found.last, ".,:;!?\"'*_~".contains(last) || (last == ")" && found.filter({ $0 == "(" }).count < found.filter({ $0 == ")" }).count) {
            found.removeLast()
        }
        guard found.count > 7 else { return nil }
        let raw = found.hasPrefix("www.") ? "https://" + found : found
        guard let target = Markdown.address(raw, base: nil) else { return nil }
        return ("<a href=\"\(Markdown.escape(target))\">\(Markdown.escape(found))</a>", found.count)
    }

    // MARK: tags written in the markdown

    private static let tagExpression = try? NSRegularExpression(pattern: String(tagPattern.dropFirst()))

    static let tagPattern = #"^</?[A-Za-z][A-Za-z0-9-]*(\s+[^\s=>/"']+(\s*=\s*("[^"]*"|'[^']*'|\{[^}]*\}|[^\s"'=<>`]+))?)*\s*/?>"#

    /// Tags drawn as themselves, with the attributes each may keep.
    private static let kept: [String: Set<String>] = [
        "a": ["href", "title"], "img": ["src", "alt", "title"], "br": [],
        "em": [], "i": [], "strong": [], "b": [], "u": [], "s": [], "del": [], "ins": [],
        "code": [], "kbd": [], "mark": [], "sub": [], "sup": [], "small": [], "abbr": ["title"],
        "details": [], "summary": [], "figure": [], "figcaption": [],
        "table": [], "thead": [], "tbody": [], "tr": [], "th": ["align"], "td": ["align"],
        "blockquote": [], "hr": [], "p": [], "pre": [],
        "ul": [], "ol": ["start"], "li": [],
        "h1": [], "h2": [], "h3": [], "h4": [], "h5": [], "h6": [],
    ]

    /// The callouts docs sites write as components — a note, a tip, a
    /// warning — drawn as a quote, which is what they are to a reader.
    private static let callouts: Set<String> = [
        "note", "tip", "info", "warning", "caution", "danger", "check", "callout", "aside", "admonition",
    ]

    /// Tags from the source, rebuilt: a known one with its safe attributes,
    /// a callout as a quote, and any other component reduced to its title —
    /// linked, if it goes somewhere — or to nothing. Standing tags are on a
    /// line of their own, where a title can be a paragraph.
    static func tags(_ text: String, base: URL?, standing: Bool) -> String {
        guard let expression = tagExpression else { return Markdown.escape(text) }
        var out = ""
        let range = NSRange(text.startIndex..., in: text)
        var last = text.startIndex
        for match in expression.matches(in: text, range: range) {
            guard let span = Range(match.range, in: text) else { continue }
            out += Markdown.escape(text[last..<span.lowerBound])
            last = span.upperBound
            out += tag(String(text[span]), base: base, standing: standing)
        }
        out += Markdown.escape(text[last...])
        return out
    }

    private static func tag(_ source: String, base: URL?, standing: Bool) -> String {
        let closing = source.hasPrefix("</")
        let name = source.dropFirst(closing ? 2 : 1).prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
        let lower = name.lowercased()
        if callouts.contains(lower) {
            return closing ? "</blockquote>" : "<blockquote>"
        }
        let attributes = closing ? [:] : Self.attributes(source)
        // Lowercase is HTML; a capital is a component. A <Table> is not a <table>.
        guard name == name.lowercased(), let allowed = kept[lower] else {
            guard !closing, let title = attributes["title"].flatMap({ $0.isEmpty ? nil : $0 }) else { return "" }
            var html = "<strong>\(Markdown.escape(title))</strong>"
            if let href = attributes["href"], let target = Markdown.address(href, base: base) {
                html = "<a href=\"\(Markdown.escape(target))\">\(html)</a>"
            }
            return standing ? "<p class=\"office-part\">\(html)</p>" : html
        }
        if closing { return "</\(lower)>" }
        var html = "<\(lower)"
        for key in allowed.sorted() {
            guard var value = attributes[key] else { continue }
            if key == "href" || key == "src" {
                guard let target = Markdown.address(value, base: base) else {
                    if key == "src" { return "" }
                    continue
                }
                value = target
            }
            html += " \(key)=\"\(Markdown.escape(value))\""
        }
        if lower == "img" {
            guard attributes["src"] != nil else { return "" }
            html += " loading=\"lazy\""
        }
        return html + ">"
    }

    private static func attributes(_ source: String) -> [String: String] {
        var found: [String: String] = [:]
        let pattern = #"([^\s=>/"']+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`{}]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return found }
        let range = NSRange(source.startIndex..., in: source)
        for match in expression.matches(in: source, range: range) {
            guard let key = Range(match.range(at: 1), in: source) else { continue }
            let value = [3, 4, 5].lazy.compactMap { Range(match.range(at: $0), in: source) }.first
            found[source[key].lowercased()] = value.map { Markdown.unescape(String(source[$0])) } ?? ""
        }
        return found
    }

    // MARK: scanning

    struct Scanner {
        let characters: [Character]
        var position = 0

        init(_ characters: [Character]) { self.characters = characters }

        var rest: ArraySlice<Character> { characters[position...] }

        func peek(_ ahead: Int = 0) -> Character? {
            position + ahead < characters.count ? characters[position + ahead] : nil
        }

        mutating func advance() { position += 1 }

        mutating func run(of character: Character) -> String {
            var run = ""
            while peek() == character {
                run.append(character)
                advance()
            }
            return run
        }

        /// The text up to a run of backticks exactly as long as `mark`, with
        /// the scanner left after it; nothing, and the scanner unmoved, if
        /// there isn't one.
        mutating func until(run mark: String) -> String? {
            let save = position
            var text = ""
            while let character = peek() {
                if character == "`" {
                    let run = self.run(of: "`")
                    if run.count == mark.count { return text }
                    text += run
                } else {
                    text.append(character)
                    advance()
                }
            }
            position = save
            return nil
        }

        /// `address "title")` after a link's opening parenthesis, or the
        /// same with no closing one for a reference definition.
        mutating func destination(closing: Character?) -> (String, String?)? {
            skipSpaces()
            var address = ""
            if peek() == "<" {
                advance()
                while let character = peek(), character != ">", character != "\n" {
                    address.append(character)
                    advance()
                }
                guard peek() == ">" else { return nil }
                advance()
            } else {
                var depth = 0
                while let character = peek(), !character.isWhitespace {
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if character == "\\", let next = peek(1), next.isPunctuation {
                        address.append(next)
                        position += 2
                        continue
                    }
                    address.append(character)
                    advance()
                }
            }
            skipSpaces()
            var title: String?
            if let open = peek(), open == "\"" || open == "'" || open == "(" {
                let close: Character = open == "(" ? ")" : open
                advance()
                var text = ""
                while let character = peek(), character != close {
                    text.append(character)
                    advance()
                }
                guard peek() == close else { return nil }
                advance()
                title = text
                skipSpaces()
            }
            if let closing {
                guard peek() == closing else { return nil }
                advance()
            } else if position < characters.count {
                return nil
            }
            return (address, title)
        }

        mutating func skipSpaces() {
            while let character = peek(), character == " " || character == "\n" { advance() }
        }
    }
}
