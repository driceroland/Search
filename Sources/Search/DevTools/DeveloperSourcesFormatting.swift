import AppKit

// The Sources panel's `{}` pretty-printer: minified JavaScript, CSS, HTML and
// JSON laid out one statement, declaration or tag to a line, four spaces to a
// level, as Chrome DevTools does. Only whitespace changes: every token is
// copied as it was, so strings, template literals, regular expressions and
// comments come through untouched. Each output line remembers where in the
// original its first token was, so a breakpoint set on a formatted line can
// go to the right place in the real script.

struct FormattedSource {
    var text: String
    /// For each line of `text`, the UTF-16 offset in the original of the first
    /// thing on it, or nil for a line with nothing on it.
    var origins: [Int?]
}

enum SourceFormatter {
    static func format(_ text: String, language: SourceLanguage) -> FormattedSource {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { u in
            var writer = Writer()
            switch language {
            case .javascript, .plain: formatJavaScript(u, 0, u.count, into: &writer)
            case .json: formatJSON(u, 0, u.count, into: &writer)
            case .css: formatCSS(u, 0, u.count, into: &writer)
            case .html: formatHTML(u, into: &writer)
            }
            return writer.finish()
        }
    }

    // MARK: Output

    struct Writer {
        var out: [UInt16] = []
        var origins: [Int?] = [nil]
        var atLineStart = true
        var pendingSpace = false
        var indent = 0
        /// Inside `${…}` everything stays on one line.
        var inline = 0
        private var blankLines = 0

        init() { out.reserveCapacity(1 << 16) }

        mutating func newline() {
            if inline > 0 { pendingSpace = true; return }
            guard !atLineStart else { return }
            out.append(10)
            origins.append(nil)
            atLineStart = true
            pendingSpace = false
            blankLines = 0
        }

        /// One empty line, never more, and none at the very top.
        mutating func blankLine() {
            if inline > 0 { pendingSpace = true; return }
            newline()
            guard blankLines == 0, !out.isEmpty else { return }
            out.append(10)
            origins.append(nil)
            blankLines = 1
        }

        mutating func space() { if !atLineStart { pendingSpace = true } }

        mutating func write(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) {
            guard start < end else { return }
            if atLineStart {
                for _ in 0..<max(0, indent) { out.append(contentsOf: [32, 32, 32, 32]) }
                if origins[origins.count - 1] == nil { origins[origins.count - 1] = start }
                atLineStart = false
            } else if pendingSpace {
                out.append(32)
            }
            pendingSpace = false
            var k = start
            while k < end {
                let c = u[k]
                // A token across lines (a comment, a template): its lines too.
                if c == 13 {
                    out.append(10)
                    if k + 1 < end, u[k + 1] == 10 { k += 1 }
                    origins.append(k + 1)
                } else {
                    out.append(c)
                    if c == 10 { origins.append(k + 1) }
                }
                k += 1
            }
            blankLines = 0
        }

        func finish() -> FormattedSource {
            var out = out
            var origins = origins
            while out.last == 10 || out.last == 32 {
                if out.removeLast() == 10 { origins.removeLast() }
            }
            return FormattedSource(text: String(decoding: out, as: UTF16.self), origins: origins)
        }
    }

    // MARK: JavaScript

    private struct Context {
        enum Kind { case brace, paren, bracket, template }
        var kind: Kind
        var ternaries = 0
        var isSwitch = false
        var inCase = false
        var isDo = false
        var forHeader = false
        var owner: UInt64 = 0
        var multiline = false
    }

    private enum Role { case start, open, dot, prefix, word, binary }

    private static let keyFor = JSKeyword.pack("for")
    private static let keySwitch = JSKeyword.pack("switch")
    private static let keyDo = JSKeyword.pack("do")
    private static let keyCase = JSKeyword.pack("case")
    private static let keyDefault = JSKeyword.pack("default")
    private static let keyElse = JSKeyword.pack("else")
    private static let keyCatch = JSKeyword.pack("catch")
    private static let keyFinally = JSKeyword.pack("finally")
    private static let keyWhile = JSKeyword.pack("while")
    private static let keyFunction = JSKeyword.pack("function")
    private static let keyYield = JSKeyword.pack("yield")

    static func formatJavaScript(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, into w: inout Writer) {
        let lexemes = JSLexer.lex(u, start: start, end: end)
        var stack = [Context(kind: .brace)]
        var role = Role.start
        var previous: JSLexeme?
        var pendingCase = false
        var lastClosedOwner: UInt64 = 0
        let baseIndent = w.indent

        func indentLevel() -> Int {
            var level = baseIndent
            for (n, context) in stack.enumerated() where n > 0 {
                switch context.kind {
                case .brace: level += 1
                case .paren, .bracket: if context.multiline { level += 1 }
                case .template: break
                }
            }
            if stack[stack.count - 1].inCase { level += 1 }
            return level
        }

        func punct(_ lexeme: JSLexeme) -> String? {
            guard lexeme.kind == .punctuator else { return nil }
            return String(decoding: UnsafeBufferPointer(rebasing: u[lexeme.start..<lexeme.end]), as: UTF16.self)
        }

        func key(_ lexeme: JSLexeme?) -> UInt64 {
            guard let lexeme, lexeme.kind == .keyword else { return 0 }
            return JSKeyword.pack(u, lexeme.start, lexeme.end) ?? 0
        }

        func lineBreak() {
            w.newline()
            w.indent = indentLevel()
        }

        func emit(_ lexeme: JSLexeme) {
            w.indent = indentLevel()
            w.write(u, lexeme.start, lexeme.end)
        }

        /// A line break where a statement starts.
        func newStatement() {
            lineBreak()
            role = .start
        }

        /// An operator between two things, a space either side.
        func binary(_ lexeme: JSLexeme) {
            w.space()
            emit(lexeme)
            w.space()
            role = .binary
        }

        func next(after index: Int) -> JSLexeme? {
            var n = index + 1
            while n < lexemes.count {
                if !lexemes[n].isComment { return lexemes[n] }
                n += 1
            }
            return nil
        }

        func spaceIf(_ condition: Bool) { if condition { w.space() } }

        /// After a `}`: `} else`, `} while`, `})` and the like stay on its
        /// line; anything else starts a new one.
        func afterClosingBrace(_ following: JSLexeme?, isDo: Bool) {
            guard let following else { return }
            let word = key(following)
            if word == keyElse || word == keyCatch || word == keyFinally || (word == keyWhile && isDo) {
                w.space()
                return
            }
            if following.kind == .template, u[following.start] == UInt16(ascii: "}") { return }
            if let text = punct(following) {
                switch text {
                case ")", "]", ",", ";", ".", "?.", "(", ":", "?", "=>", "[":
                    if text == "[" { break }
                    return
                case "{", "}", "!", "~", "++", "--", "...", "@", "#": break
                default: return  // an operator: the expression goes on
                }
            }
            newStatement()
        }

        var index = 0
        while index < lexemes.count {
            let lexeme = lexemes[index]
            defer { index += 1 }
            let top = stack[stack.count - 1]

            // A line break in the original is kept: that is where a statement
            // without its semicolon ended, or where its author wanted one.
            if lexeme.breaks > 0, w.inline == 0, !w.atLineStart {
                if top.kind == .paren || top.kind == .bracket { stack[stack.count - 1].multiline = true }
                if lexeme.breaks > 1 { w.blankLine() } else { lineBreak() }
                role = .start
            }

            switch lexeme.kind {
            case .lineComment:
                spaceIf(!w.atLineStart)
                emit(lexeme)
                newStatement()
                continue
            case .blockComment:
                spaceIf(!w.atLineStart)
                emit(lexeme)
                if let following = index + 1 < lexemes.count ? lexemes[index + 1] : nil, following.breaks > 0 {
                    newStatement()
                } else {
                    w.space()
                }
                continue
            case .template:
                let first: UInt16 = u[lexeme.start]
                let long: Bool = lexeme.end - lexeme.start >= 2
                let opensExpression: Bool = u[lexeme.end - 1] == UInt16(ascii: "{") && long && u[lexeme.end - 2] == UInt16(ascii: "$")
                if first == UInt16(ascii: "}") {
                    // The end of `${…}`.
                    while stack.count > 1, stack[stack.count - 1].kind != .template { stack.removeLast() }
                    if stack.count > 1 { stack.removeLast() }
                    w.inline = max(0, w.inline - 1)
                    w.pendingSpace = false
                } else {
                    spaceIf(role == .word || role == .binary)
                }
                emit(lexeme)
                if opensExpression {
                    stack.append(Context(kind: .template))
                    w.inline += 1
                    role = .open
                } else {
                    role = .word
                }
                previous = lexeme
                continue
            default: break
            }

            let text = punct(lexeme)
            switch text {
            case "{"?:
                var context = Context(kind: .brace)
                if let previous, punct(previous) == ")" { context.isSwitch = lastClosedOwner == keySwitch }
                context.isDo = key(previous) == keyDo
                if index + 1 < lexemes.count, punct(lexemes[index + 1]) == "}" {
                    spaceIf(role == .word || role == .binary)
                    emit(lexeme)
                    // `{}`, kept together.
                    index += 1
                    w.write(u, lexemes[index].start, lexemes[index].end)
                    previous = lexemes[index]
                    role = .word
                    afterClosingBrace(next(after: index), isDo: context.isDo)
                    continue
                }
                spaceIf(role == .word || role == .binary)
                emit(lexeme)
                stack.append(context)
                newStatement()
            case "}"?:
                while stack.count > 1, stack[stack.count - 1].kind != .brace { stack.removeLast() }
                let closed = stack.count > 1 ? stack.removeLast() : stack[0]
                lineBreak()
                emit(lexeme)
                role = .word
                previous = lexeme
                afterClosingBrace(next(after: index), isDo: closed.isDo)
                continue
            case "("?:
                if let previous, previous.kind == .keyword {
                    let flags = JSKeyword.lookup(u, previous.start, previous.end)
                    spaceIf(flags.contains(.spaceBeforeParen) || role == .binary)
                } else {
                    spaceIf(role == .binary)
                }
                emit(lexeme)
                var context = Context(kind: .paren)
                context.owner = key(previous)
                context.forHeader = context.owner == keyFor
                stack.append(context)
                role = .open
            case ")"?, "]"?:
                w.pendingSpace = false
                let kind: Context.Kind = text == ")" ? .paren : .bracket
                if let position = stack.lastIndex(where: { $0.kind == kind }), position > 0,
                   !stack[position...].contains(where: { $0.kind == .brace || $0.kind == .template }) {
                    lastClosedOwner = stack[position].owner
                    stack.removeSubrange(position...)
                }
                emit(lexeme)
                role = .word
            case "["?:
                if let previous, previous.kind == .keyword, !JSKeyword.lookup(u, previous.start, previous.end).contains(.atom) {
                    spaceIf(key(previous) != JSKeyword.pack("this") && key(previous) != JSKeyword.pack("super"))
                } else {
                    spaceIf(role == .binary)
                }
                emit(lexeme)
                stack.append(Context(kind: .bracket))
                role = .open
            case ";"?:
                w.pendingSpace = false
                emit(lexeme)
                if top.kind == .paren && top.forHeader {
                    w.space()
                    role = .binary
                } else {
                    newStatement()
                }
            case ","?:
                w.pendingSpace = false
                emit(lexeme)
                if top.kind == .brace {
                    newStatement()
                } else {
                    w.space()
                    role = .binary
                }
            case ":"?:
                if top.ternaries > 0 {
                    stack[stack.count - 1].ternaries -= 1
                    binary(lexeme)
                } else if pendingCase {
                    pendingCase = false
                    emit(lexeme)
                    stack[stack.count - 1].inCase = true
                    newStatement()
                } else {
                    emit(lexeme)
                    w.space()
                    role = .binary
                }
            case "?"?:
                stack[stack.count - 1].ternaries += 1
                binary(lexeme)
            case "."?, "?."?:
                emit(lexeme)
                role = .dot
            case "..."?, "!"?, "~"?:
                spaceIf(role == .word || role == .binary)
                emit(lexeme)
                role = .prefix
            case "++"?, "--"?:
                if role == .word {
                    emit(lexeme)
                    role = .word
                } else {
                    spaceIf(role == .binary)
                    emit(lexeme)
                    role = .prefix
                }
            case "+"?, "-"?:
                if role == .word {
                    binary(lexeme)
                } else {
                    spaceIf(role == .binary)
                    emit(lexeme)
                    role = .prefix
                }
            case "*"? where key(previous) == keyFunction || key(previous) == keyYield:
                emit(lexeme)
                role = .word
            case "@"?, "#"?:
                spaceIf(role == .word || role == .binary)
                emit(lexeme)
                role = .prefix
            case let other?:
                // Every other punctuator is an operator between two things.
                if other == "=>" || other.count > 1 || "=<>*/%&|^".contains(other) {
                    binary(lexeme)
                } else {
                    spaceIf(role == .word || role == .binary)
                    emit(lexeme)
                    role = .word
                }
            case nil:
                // A word: an identifier, keyword, number, string or regex.
                let word = key(lexeme)
                if (word == keyCase || word == keyDefault) && top.isSwitch && top.kind == .brace
                    && !(previous.flatMap(punct) == ".") && top.ternaries == 0 {
                    stack[stack.count - 1].inCase = false
                    lineBreak()
                    pendingCase = true
                }
                spaceIf(role == .word || role == .binary)
                emit(lexeme)
                // After `return`, `typeof`, `in` and the like an expression
                // starts: `return -1`, not `return - 1`.
                role = lexeme.kind == .keyword && JSKeyword.lookup(u, lexeme.start, lexeme.end).contains(.regexAfter) ? .binary : .word
            }
            previous = lexeme
        }

        w.indent = baseIndent
    }

    // MARK: JSON

    static func formatJSON(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, into w: inout Writer) {
        let lexemes = JSLexer.lex(u, start: start, end: end)
        let base = w.indent
        var depth = 0
        var index = 0
        func isPunct(_ lexeme: JSLexeme, _ c: Character) -> Bool {
            lexeme.kind == .punctuator && lexeme.end - lexeme.start == 1 && u[lexeme.start] == c.utf16.first!
        }
        while index < lexemes.count {
            let lexeme = lexemes[index]
            defer { index += 1 }
            w.indent = base + depth
            if lexeme.isComment {
                w.space()
                w.write(u, lexeme.start, lexeme.end)
                w.newline()
                continue
            }
            if isPunct(lexeme, "{") || isPunct(lexeme, "[") {
                w.write(u, lexeme.start, lexeme.end)
                let close: Character = isPunct(lexeme, "{") ? "}" : "]"
                if index + 1 < lexemes.count, isPunct(lexemes[index + 1], close) {
                    w.write(u, lexemes[index + 1].start, lexemes[index + 1].end)
                    index += 1
                    continue
                }
                depth += 1
                w.newline()
            } else if isPunct(lexeme, "}") || isPunct(lexeme, "]") {
                depth = max(0, depth - 1)
                w.newline()
                w.indent = base + depth
                w.write(u, lexeme.start, lexeme.end)
            } else if isPunct(lexeme, ",") {
                w.write(u, lexeme.start, lexeme.end)
                w.newline()
            } else if isPunct(lexeme, ":") {
                w.write(u, lexeme.start, lexeme.end)
                w.space()
            } else {
                w.write(u, lexeme.start, lexeme.end)
            }
        }
        w.indent = base
    }

    // MARK: CSS

    /// The characters that end a run of a CSS statement: braces, `;`, `:`,
    /// `,`, quotes and parentheses.
    private static func endsCSSRun(_ d: UInt16) -> Bool {
        switch d {
        case 0x7B, 0x7D, 0x3B, 0x3A, 0x2C, 0x22, 0x27, 0x28, 0x29: return true  // { } ; : , " ' ( )
        default: return false
        }
    }

    static func formatCSS(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, into w: inout Writer) {
        let base = w.indent
        var depth = 0
        var k = start
        @inline(__always) func at(_ n: Int) -> UInt16 { n < end ? u[n] : 0 }

        // One statement's pieces: runs of the original, and spaces between.
        var pieces: [(Int, Int)] = []
        var firstColon = -1

        func flush(selector: Bool) {
            defer { pieces.removeAll(keepingCapacity: true); firstColon = -1 }
            guard !pieces.isEmpty else { return }
            w.indent = base + depth
            for (n, piece) in pieces.enumerated() {
                if piece.0 == -1 {
                    // `a: b`, not `a : b` or `a:  b`, in a declaration.
                    if !selector && (n + 1 == firstColon || n - 1 == firstColon) { continue }
                    w.space()
                    continue
                }
                w.write(u, piece.0, piece.1)
                let single: UInt16 = piece.1 - piece.0 == 1 ? u[piece.0] : 0
                let isColon: Bool = single == UInt16(ascii: ":")
                let isComma: Bool = single == UInt16(ascii: ",")
                if (!selector && n == firstColon && isColon) || (selector && isComma) { w.space() }
            }
        }

        func add(_ s: Int, _ e: Int) {
            pieces.append((s, e))
        }

        func addSpace() {
            if let last = pieces.last, last.0 != -1 { pieces.append((-1, -1)) }
        }

        func trimSpaces() { while pieces.last?.0 == -1 { pieces.removeLast() } }

        var parens = 0
        while k < end {
            let c = u[k]
            if c == UInt16(ascii: "/") && at(k + 1) == UInt16(ascii: "*") {
                var j = k + 2
                while j < end, !(u[j] == UInt16(ascii: "*") && at(j + 1) == UInt16(ascii: "/")) { j += 1 }
                j = min(j + 2, end)
                if pieces.isEmpty {
                    w.indent = base + depth
                    w.write(u, k, j)
                    w.newline()
                } else {
                    add(k, j)
                }
                k = j
                continue
            }
            if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
                let j = SourceHighlighter.cssStringEnd(u, k, end)
                add(k, j)
                k = j
                continue
            }
            if SourceLexing.isSpace(c) || SourceLexing.isNewline(c) {
                if !pieces.isEmpty { addSpace() }
                k += 1
                continue
            }
            if c == UInt16(ascii: "(") { parens += 1 }
            if c == UInt16(ascii: ")") { parens = max(0, parens - 1) }
            if parens == 0 && c == UInt16(ascii: "{") {
                trimSpaces()
                flush(selector: true)
                w.indent = base + depth
                w.space()
                w.write(u, k, k + 1)
                depth += 1
                w.newline()
                k += 1
                continue
            }
            if parens == 0 && c == UInt16(ascii: ";") {
                trimSpaces()
                add(k, k + 1)
                flush(selector: false)
                w.newline()
                k += 1
                continue
            }
            if parens == 0 && c == UInt16(ascii: "}") {
                trimSpaces()
                flush(selector: false)
                depth = max(0, depth - 1)
                w.newline()
                w.indent = base + depth
                w.write(u, k, k + 1)
                w.newline()
                k += 1
                continue
            }
            if c == UInt16(ascii: ":") && firstColon == -1 && parens == 0 {
                firstColon = pieces.count
                add(k, k + 1)
                k += 1
                continue
            }
            if c == UInt16(ascii: ",") && parens == 0 {
                trimSpaces()
                add(k, k + 1)
                k += 1
                while k < end, SourceLexing.isSpace(u[k]) || SourceLexing.isNewline(u[k]) { k += 1 }
                continue
            }
            var j = k + 1
            while j < end {
                let d = u[j]
                if SourceLexing.isSpace(d) || SourceLexing.isNewline(d) || endsCSSRun(d)
                    || (d == UInt16(ascii: "/") && at(j + 1) == UInt16(ascii: "*")) { break }
                j += 1
            }
            add(k, j)
            k = j
        }
        trimSpaces()
        flush(selector: depth == 0 && firstColon == -1)
        w.indent = base
    }

    // MARK: HTML

    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen", "command"]
    private static let closedBySibling: Set<String> = ["p", "li", "option", "tr", "td", "th", "dt", "dd"]
    private static let preserved: Set<String> = ["pre", "textarea"]

    static func formatHTML(_ u: UnsafeBufferPointer<UInt16>, into w: inout Writer) {
        let end = u.count
        var k = 0
        var open: [String] = []
        @inline(__always) func at(_ n: Int) -> UInt16 { n < end ? u[n] : 0 }

        func text(_ s: Int, _ e: Int) {
            // Words, with runs of space between them made one.
            var j = s
            var wrote = false
            while j < e {
                while j < e, SourceLexing.isSpace(u[j]) || SourceLexing.isNewline(u[j]) { j += 1 }
                guard j < e else { break }
                let wordStart = j
                while j < e, !SourceLexing.isSpace(u[j]), !SourceLexing.isNewline(u[j]) { j += 1 }
                if !wrote { w.indent = open.count; w.newline(); wrote = true } else { w.space() }
                w.write(u, wordStart, j)
            }
            if wrote { w.newline() }
        }

        var textStart = 0
        while k < end {
            guard u[k] == UInt16(ascii: "<") else { k += 1; continue }
            let s = k
            let isComment = at(k + 1) == UInt16(ascii: "!") && at(k + 2) == UInt16(ascii: "-") && at(k + 3) == UInt16(ascii: "-")
            let isDeclaration = at(k + 1) == UInt16(ascii: "!") || at(k + 1) == UInt16(ascii: "?")
            let closing = at(k + 1) == UInt16(ascii: "/")
            let nameStart = closing ? k + 2 : k + 1
            guard isComment || isDeclaration || SourceLexing.isIDStart(at(nameStart)) else { k += 1; continue }
            text(textStart, s)
            if isComment || isDeclaration {
                if isComment {
                    k += 4
                    while k < end, !(u[k] == UInt16(ascii: "-") && at(k + 1) == UInt16(ascii: "-") && at(k + 2) == UInt16(ascii: ">")) { k += 1 }
                    k = min(k + 3, end)
                } else {
                    while k < end, u[k] != UInt16(ascii: ">") { k += 1 }
                    k = min(k + 1, end)
                }
                w.newline()
                w.indent = open.count
                w.write(u, s, k)
                w.newline()
                textStart = k
                continue
            }
            var n = nameStart
            while n < end, SourceLexing.isIDPart(u[n]) || u[n] == UInt16(ascii: "-") || u[n] == UInt16(ascii: ":") { n += 1 }
            let name = String(decoding: UnsafeBufferPointer(rebasing: u[nameStart..<n]), as: UTF16.self).lowercased()
            // The tag's end, past quoted values that may hold a `>`.
            let tagEnd = SourceHighlighter.tagEnd(u, from: n)
            var typeValue: String?
            let selfClosing = tagEnd >= 2 && u[tagEnd - 2] == UInt16(ascii: "/")
            if name == "script" {
                let tag = String(decoding: UnsafeBufferPointer(rebasing: u[s..<tagEnd]), as: UTF16.self).lowercased()
                if let range = tag.range(of: #"type\s*=\s*["']?([^"'\s>]+)"#, options: .regularExpression) {
                    typeValue = String(tag[range]).replacingOccurrences(of: #"type\s*=\s*["']?"#, with: "", options: .regularExpression)
                }
            }
            if closing {
                if let position = open.lastIndex(of: name) { open.removeSubrange(position...) }
                w.newline()
                w.indent = open.count
                writeTag(u, s, tagEnd, into: &w)
                w.newline()
                k = tagEnd
                textStart = k
                continue
            }
            if closedBySibling.contains(name), open.last == name { open.removeLast() }
            w.newline()
            w.indent = open.count
            writeTag(u, s, tagEnd, into: &w)
            k = tagEnd
            textStart = k
            if voidElements.contains(name) || selfClosing { w.newline(); continue }

            if name == "script" || name == "style" || preserved.contains(name) {
                let bodyEnd = SourceHighlighter.rawTextEnd(u, from: k, name: name)
                if preserved.contains(name) {
                    w.write(u, k, bodyEnd)
                } else if firstSignificant(u, k, bodyEnd) < bodyEnd {
                    w.newline()
                    w.indent = open.count + 1
                    if name == "style" {
                        formatCSS(u, k, bodyEnd, into: &w)
                    } else {
                        switch HTMLScriptKind(type: typeValue) {
                        case .javascript?: formatJavaScript(u, k, bodyEnd, into: &w)
                        case .json?: formatJSON(u, k, bodyEnd, into: &w)
                        case nil: w.write(u, k, bodyEnd)
                        }
                    }
                    w.newline()
                }
                // The closing tag, on the opening's level.
                var close = bodyEnd
                while close < end, u[close] != UInt16(ascii: ">") { close += 1 }
                close = min(close + 1, end)
                if !preserved.contains(name) { w.newline() }
                w.indent = open.count
                w.write(u, bodyEnd, close)
                w.newline()
                k = close
                textStart = k
                continue
            }
            open.append(name)
            w.newline()
        }
        text(textStart, end)
    }

    /// A tag with the space inside it made tidy: one space between attributes.
    private static func writeTag(_ u: UnsafeBufferPointer<UInt16>, _ s: Int, _ e: Int, into w: inout Writer) {
        var k = s
        var quote: UInt16 = 0
        var runStart = s
        while k < e {
            let c = u[k]
            if quote != 0 {
                if c == quote { quote = 0 }
                k += 1
                continue
            }
            if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") { quote = c; k += 1; continue }
            if SourceLexing.isSpace(c) || SourceLexing.isNewline(c) {
                w.write(u, runStart, k)
                while k < e, SourceLexing.isSpace(u[k]) || SourceLexing.isNewline(u[k]) { k += 1 }
                if k < e, u[k] != UInt16(ascii: ">"), !(u[k] == UInt16(ascii: "/") && k + 1 < e && u[k + 1] == UInt16(ascii: ">")) { w.space() }
                runStart = k
                continue
            }
            k += 1
        }
        w.write(u, runStart, e)
    }

    private static func firstSignificant(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> Int {
        var k = start
        while k < end, SourceLexing.isSpace(u[k]) || SourceLexing.isNewline(u[k]) { k += 1 }
        return k
    }
}
