import AppKit

// Syntax highlighting for the Sources panel: JavaScript (with a little JSX
// and TypeScript), CSS, HTML and JSON, coloured as Chrome DevTools colours
// them. Everything here works on UTF-16 code units, the offsets NSTextView
// speaks, and runs off the main thread: a minified bundle is hundreds of
// kilobytes on one line, and the panel colours only what scrolls into view.

enum SourceLanguage: Equatable {
    case javascript(typescript: Bool, jsx: Bool)
    case css
    case html
    case json
    case plain

    static let js = SourceLanguage.javascript(typescript: false, jsx: false)

    /// The language a resource is in, by its path first, then by what the
    /// inspector called it, then by a look at its first characters.
    static func detect(url: String, type: String, text: String) -> SourceLanguage {
        let path = (URL(string: url)?.path ?? url).lowercased()
        let ext = (path as NSString).pathExtension
        switch ext {
        case "js", "mjs", "cjs": return .js
        case "jsx": return .javascript(typescript: false, jsx: true)
        case "ts", "mts", "cts": return .javascript(typescript: true, jsx: false)
        case "tsx": return .javascript(typescript: true, jsx: true)
        case "css": return .css
        case "json", "map", "webmanifest": return .json
        case "html", "htm", "xhtml", "svg", "xml": return .html
        default: break
        }
        switch type {
        case "Script": return .js
        case "Stylesheet": return .css
        default: break
        }
        let head = text.utf16.prefix(512).first { !SourceLexing.isSpace($0) && !SourceLexing.isNewline($0) }
        switch head {
        case UInt16(ascii: "{"), UInt16(ascii: "["): return .json
        case UInt16(ascii: "<"): return .html
        default: return type == "Document" ? .html : .plain
        }
    }

    var canPrettyPrint: Bool { self != .plain }
    var isJavaScript: Bool { if case .javascript = self { return true } else { return false } }
}

enum SourceTokenKind: UInt8, CaseIterable {
    case keyword, string, stringSpecial, number, atom, comment, property, definition
    case type, variableSpecial, tag, attribute, attributeValue, meta
}

struct SourceToken: Equatable {
    var start: Int
    var length: Int
    var kind: SourceTokenKind
    var end: Int { start + length }
}

// MARK: Colours

/// Chrome DevTools' `--sys-color-token-*` colours, light and dark.
enum SourceTheme {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let colours: [SourceTokenKind: NSColor] = {
        var map = [SourceTokenKind: NSColor]()
        for kind in SourceTokenKind.allCases {
            let (light, dark): (NSColor, NSColor)
            switch kind {
            case .keyword: (light, dark) = (rgb(185, 0, 99), rgb(191, 103, 255))
            case .string: (light, dark) = (rgb(179, 38, 30), rgb(254, 141, 89))
            case .stringSpecial: (light, dark) = (rgb(220, 54, 46), rgb(254, 141, 89))
            case .number: (light, dark) = (rgb(11, 87, 208), rgb(196, 238, 208))
            case .atom: (light, dark) = (rgb(6, 46, 111), rgb(196, 238, 208))
            case .comment: (light, dark) = (rgb(20, 108, 46), rgb(171, 171, 171))
            case .property: (light, dark) = (rgb(31, 31, 31), rgb(250, 204, 21))
            case .definition: (light, dark) = (rgb(8, 66, 160), rgb(124, 172, 248))
            case .type: (light, dark) = (rgb(25, 134, 57), rgb(124, 172, 248))
            case .variableSpecial: (light, dark) = (rgb(8, 66, 160), rgb(109, 213, 140))
            case .tag: (light, dark) = (rgb(142, 0, 75), rgb(124, 172, 248))
            case .attribute: (light, dark) = (rgb(159, 67, 18), rgb(168, 199, 250))
            case .attributeValue: (light, dark) = (rgb(8, 66, 160), rgb(254, 141, 89))
            case .meta: (light, dark) = (rgb(143, 143, 143), rgb(143, 143, 143))
            }
            map[kind] = dynamic(light, dark)
        }
        return map
    }()

    static let text = dynamic(rgb(31, 31, 31), rgb(199, 199, 199))
    static let lineNumber = dynamic(rgb(117, 117, 117), rgb(143, 143, 143))
    static let background = dynamic(.white, rgb(32, 33, 36))
    static let gutter = dynamic(rgb(248, 249, 250), rgb(40, 41, 44))
    static let currentLine = dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06))
    static let breakpoint = dynamic(rgb(26, 115, 232), rgb(124, 172, 248))
    static let breakpointText = dynamic(.white, rgb(32, 33, 36))
    /// Chrome's conditional breakpoint and logpoint markers.
    static let conditional = dynamic(rgb(242, 153, 0), rgb(253, 214, 99))
    static let logpoint = dynamic(rgb(243, 57, 160), rgb(255, 128, 191))
    /// Chrome's execution line, where the debugger is paused: a tinted line
    /// with an outline, and the arrow in the gutter.
    static let executionLine = dynamic(NSColor(srgbRed: 0, green: 59 / 255, blue: 1, alpha: 0.1),
                                       NSColor(srgbRed: 86 / 255, green: 135 / 255, blue: 1, alpha: 0.22))
    static let executionOutline = dynamic(rgb(64, 115, 244), rgb(124, 172, 248))
}

// MARK: Shared character classes

enum SourceLexing {
    @inline(__always) static func isNewline(_ c: UInt16) -> Bool {
        c == 10 || c == 13 || c == 0x2028 || c == 0x2029
    }

    @inline(__always) static func isSpace(_ c: UInt16) -> Bool {
        c == 32 || c == 9 || c == 11 || c == 12 || c == 0xA0 || c == 0xFEFF
            || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0x1680
    }

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    @inline(__always) static func isIDStart(_ c: UInt16) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 36 || c == 95
            || (c >= 0x80 && !isSpace(c) && !isNewline(c))
    }

    @inline(__always) static func isIDPart(_ c: UInt16) -> Bool { isIDStart(c) || isDigit(c) }

    /// Over `count` ascending values: the last index whose value is at most
    /// `target` (0 when none is).
    static func lastIndex(_ count: Int, atMost target: Int, _ value: (Int) -> Int) -> Int {
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if value(mid) <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Over `count` ascending values: the first index whose value is past
    /// `target` (`count` when none is).
    static func firstIndex(_ count: Int, past target: Int, _ value: (Int) -> Int) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if value(mid) <= target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The 0-based line an offset is on.
    static func lineIndex(_ offset: Int, in starts: [Int]) -> Int {
        lastIndex(starts.count, atMost: offset) { starts[$0] }
    }

    /// Where every line starts, counting line breaks the way NSTextView
    /// does: \n, \r, \r\n, U+2028, U+2029 and U+0085.
    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var previous: UInt16 = 0
        var index = 0
        for c in text.utf16 {
            if c == 10 {
                if previous == 13 { starts[starts.count - 1] = index + 1 } else { starts.append(index + 1) }
            } else if c == 13 || c == 0x2028 || c == 0x2029 || c == 0x85 {
                starts.append(index + 1)
            }
            previous = c
            index += 1
        }
        return starts
    }

    /// Whether a text looks minified, as Chrome judges it before offering to
    /// pretty-print: a line that runs far longer than people write them.
    static func looksMinified(_ text: String) -> Bool {
        var length = 0
        var long = 0
        var lines = 0
        for c in text.utf16 {
            if c == 10 || c == 13 {
                if length > 0 { lines += 1 }
                if length > 500 { long += 1 }
                length = 0
            } else {
                length += 1
            }
        }
        if length > 0 { lines += 1 }
        if length > 500 { long += 1 }
        return long > 0 && (lines < 10 || long * 20 >= lines)
    }
}

// MARK: JavaScript lexer

struct JSLexeme {
    enum Kind: UInt8 {
        case identifier, keyword, punctuator, number, string, template, regex
        case lineComment, blockComment, privateName, jsxTag, jsxAttribute, jsxText
    }

    var kind: Kind
    var start: Int
    var end: Int
    /// Line breaks between this and the lexeme before, capped at 2.
    var breaks: UInt8

    var isComment: Bool { kind == .lineComment || kind == .blockComment }
}

/// Facts about the words that are keywords somewhere, packed by spelling.
struct JSKeyword: OptionSet {
    let rawValue: UInt16
    static let keyword = JSKeyword(rawValue: 1)
    static let atom = JSKeyword(rawValue: 2)
    static let typescript = JSKeyword(rawValue: 4)
    static let regexAfter = JSKeyword(rawValue: 8)
    static let declares = JSKeyword(rawValue: 16)
    static let typeName = JSKeyword(rawValue: 32)
    static let spaceBeforeParen = JSKeyword(rawValue: 64)
    static let declaresType = JSKeyword(rawValue: 128)

    /// Up to ten ASCII letters, six bits each.
    @inline(__always) static func pack(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> UInt64? {
        let length = end - start
        guard length >= 2, length <= 10 else { return nil }
        var key: UInt64 = 0
        for i in start..<end {
            let c = u[i]
            let v: UInt64
            if c >= 97 && c <= 122 { v = UInt64(c - 96) } else if c >= 65 && c <= 90 { v = UInt64(c - 64 + 26) } else { return nil }
            key = key << 6 | v
        }
        return key
    }

    static func pack(_ word: String) -> UInt64 {
        let units = Array(word.utf16)
        return units.withUnsafeBufferPointer { pack($0, 0, $0.count)! }
    }

    static let table: [UInt64: JSKeyword] = {
        var table = [UInt64: JSKeyword]()
        func add(_ words: String, _ flags: JSKeyword) {
            for word in words.split(separator: " ") { table[pack(String(word)), default: []].formUnion(flags) }
        }
        add("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return super switch this throw try typeof var void while with yield let static async await of", .keyword)
        add("true false null undefined NaN Infinity", [.atom])
        add("return typeof instanceof in of new delete void throw case do else yield await extends", .regexAfter)
        add("var let const function class", .declares)
        add("if for while switch catch with return typeof in of instanceof new delete void throw case yield await else do", .spaceBeforeParen)
        add("interface type enum implements private public protected readonly declare namespace abstract as keyof infer is asserts satisfies module", [.keyword, .typescript])
        add("interface type enum namespace", .declaresType)
        add("string number boolean any unknown never object symbol bigint", [.typeName, .typescript])
        return table
    }()

    static func lookup(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> JSKeyword {
        guard let key = pack(u, start, end) else { return [] }
        return table[key] ?? []
    }
}

struct JSLexer {
    let u: UnsafeBufferPointer<UInt16>
    let end: Int
    let jsx: Bool
    var i: Int
    var out: [JSLexeme] = []

    private enum Brace { case block, template, jsxAttribute, jsxChild }
    private enum Mode { case js, jsxAttributes, jsxChildren }
    private var braces: [Brace] = []
    private var jsxDepths: [Int] = []
    private var mode = Mode.js
    private var breaks: UInt8 = 0
    /// The last lexeme that wasn't a comment, for telling a regex from a division.
    private var last: JSLexeme?

    init(_ u: UnsafeBufferPointer<UInt16>, start: Int = 0, end: Int? = nil, jsx: Bool = false) {
        self.u = u
        self.i = start
        self.end = end ?? u.count
        self.jsx = jsx
        out.reserveCapacity((self.end - start) / 4)
    }

    static func lex(_ u: UnsafeBufferPointer<UInt16>, start: Int = 0, end: Int? = nil, jsx: Bool = false) -> [JSLexeme] {
        var lexer = JSLexer(u, start: start, end: end, jsx: jsx)
        lexer.run()
        return lexer.out
    }

    @inline(__always) private func at(_ k: Int) -> UInt16 { k < end ? u[k] : 0 }

    private mutating func emit(_ kind: JSLexeme.Kind, _ start: Int, _ stop: Int) {
        let lexeme = JSLexeme(kind: kind, start: start, end: stop, breaks: breaks)
        out.append(lexeme)
        breaks = 0
        if !lexeme.isComment { last = lexeme }
    }

    private var regexAllowed: Bool {
        guard let last else { return true }
        switch last.kind {
        case .identifier, .number, .string, .regex, .privateName, .jsxText: return false
        case .template: return u[last.end - 1] == UInt16(ascii: "{")
        case .keyword: return JSKeyword.lookup(u, last.start, last.end).contains(.regexAfter)
        case .jsxTag, .jsxAttribute: return false
        case .punctuator:
            let c = u[last.start]
            let length = last.end - last.start
            if length == 1 { return c != UInt16(ascii: ")") && c != UInt16(ascii: "]") }
            if length == 2, (c == UInt16(ascii: "+") || c == UInt16(ascii: "-")), u[last.start + 1] == c { return false }
            return true
        default: return true
        }
    }

    mutating func run() {
        if i + 1 < end, u[i] == UInt16(ascii: "#"), u[i + 1] == UInt16(ascii: "!") {
            let start = i
            while i < end, !SourceLexing.isNewline(u[i]) { i += 1 }
            emit(.lineComment, start, i)
        }
        while i < end {
            switch mode {
            case .js: lexJS()
            case .jsxAttributes: lexJSXAttribute()
            case .jsxChildren: lexJSXChildren()
            }
        }
    }

    private mutating func skipSpace() -> Bool {
        while i < end {
            let c = u[i]
            if SourceLexing.isNewline(c) {
                if !(c == 10 && i > 0 && u[i - 1] == 13) { breaks = min(breaks + 1, 2) }
                i += 1
            } else if SourceLexing.isSpace(c) {
                i += 1
            } else {
                return true
            }
        }
        return false
    }

    private mutating func lexJS() {
        guard skipSpace() else { return }
        let start = i
        let c = u[i]
        let next = at(i + 1)
        let slash = UInt16(ascii: "/")

        if c == slash && next == slash {
            while i < end, !SourceLexing.isNewline(u[i]) { i += 1 }
            return emit(.lineComment, start, i)
        }
        if c == slash && next == UInt16(ascii: "*") {
            i += 2
            while i < end, !(u[i] == UInt16(ascii: "*") && at(i + 1) == slash) { i += 1 }
            i = min(i + 2, end)
            return emit(.blockComment, start, i)
        }
        if SourceLexing.isIDStart(c) || c == UInt16(ascii: "\\") {
            i += 1
            while i < end, SourceLexing.isIDPart(u[i]) || u[i] == UInt16(ascii: "\\") { i += 1 }
            let afterDot: Bool = {
                guard let last, last.kind == .punctuator else { return false }
                let l = u[last.end - 1]
                return l == UInt16(ascii: ".") && (last.end - last.start == 1 || u[last.start] == UInt16(ascii: "?"))
            }()
            let word = afterDot ? [] : JSKeyword.lookup(u, start, i)
            return emit(word.isEmpty ? .identifier : .keyword, start, i)
        }
        if c == UInt16(ascii: "#") && SourceLexing.isIDStart(next) {
            i += 1
            while i < end, SourceLexing.isIDPart(u[i]) { i += 1 }
            return emit(.privateName, start, i)
        }
        if SourceLexing.isDigit(c) || (c == UInt16(ascii: ".") && SourceLexing.isDigit(next)) {
            let hex = c == 48 && (next | 0x20) == UInt16(ascii: "x")
            i += 1
            while i < end {
                let d = u[i]
                if SourceLexing.isIDPart(d) || d == UInt16(ascii: ".") {
                    i += 1
                } else if !hex, (d == UInt16(ascii: "+") || d == UInt16(ascii: "-")), (u[i - 1] | 0x20) == UInt16(ascii: "e") {
                    i += 1
                } else {
                    break
                }
            }
            return emit(.number, start, i)
        }
        if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
            i += 1
            while i < end {
                let d = u[i]
                if d == UInt16(ascii: "\\") { i += 2; continue }
                if d == c { i += 1; break }
                if d == 10 || d == 13 { break }
                i += 1
            }
            i = min(i, end)
            return emit(.string, start, i)
        }
        if c == UInt16(ascii: "`") {
            i += 1
            return lexTemplate(from: start)
        }
        if c == UInt16(ascii: "{") {
            braces.append(.block)
            i += 1
            return emit(.punctuator, start, i)
        }
        if c == UInt16(ascii: "}") {
            switch braces.popLast() {
            case .template?:
                i += 1
                return lexTemplate(from: start)
            case .jsxAttribute?:
                mode = .jsxAttributes
            case .jsxChild?:
                mode = .jsxChildren
            default: break
            }
            i += 1
            return emit(.punctuator, start, i)
        }
        if c == slash && regexAllowed, let stop = regexEnd(from: i) {
            i = stop
            return emit(.regex, start, i)
        }
        if jsx && c == UInt16(ascii: "<") && regexAllowed && (SourceLexing.isIDStart(next) || next == UInt16(ascii: ">")) {
            jsxDepths.append(0)
            return openJSXTag()
        }
        if jsx && c == UInt16(ascii: "<") && next == slash && SourceLexing.isIDStart(at(i + 2)), closeJSXTag() {
            return
        }
        i += Self.punctuatorLength(u, i, end)
        emit(.punctuator, start, i)
    }

    /// From just inside a backtick or the `}` that ends `${…}`, to the next
    /// backtick or `${`.
    private mutating func lexTemplate(from start: Int) {
        while i < end {
            let d = u[i]
            if d == UInt16(ascii: "\\") { i += 2; continue }
            if d == UInt16(ascii: "`") { i += 1; break }
            if d == UInt16(ascii: "$") && at(i + 1) == UInt16(ascii: "{") {
                i += 2
                braces.append(.template)
                break
            }
            i += 1
        }
        i = min(i, end)
        emit(.template, start, i)
    }

    /// The end of a regular expression literal starting at `k`, or nil if
    /// the line ends first — then it was a division after all.
    private func regexEnd(from k: Int) -> Int? {
        var j = k + 1
        var inClass = false
        while j < end {
            let d = u[j]
            if SourceLexing.isNewline(d) { return nil }
            if d == UInt16(ascii: "\\") { j += 2; continue }
            if d == UInt16(ascii: "[") { inClass = true } else if d == UInt16(ascii: "]") { inClass = false } else if d == UInt16(ascii: "/") && !inClass {
                j += 1
                while j < end, SourceLexing.isIDPart(u[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    static func punctuatorLength(_ u: UnsafeBufferPointer<UInt16>, _ k: Int, _ end: Int) -> Int {
        @inline(__always) func at(_ n: Int) -> UInt16 { k + n < end ? u[k + n] : 0 }
        let c = at(0), d = at(1), e = at(2)
        let eq = UInt16(ascii: "=")
        switch c {
        case UInt16(ascii: "."):
            return d == c && e == c ? 3 : 1
        case UInt16(ascii: "?"):
            if d == UInt16(ascii: ".") && !SourceLexing.isDigit(e) { return 2 }
            if d == c { return e == eq ? 3 : 2 }
            return 1
        case UInt16(ascii: "="):
            if d == UInt16(ascii: ">") { return 2 }
            if d == eq { return e == eq ? 3 : 2 }
            return 1
        case UInt16(ascii: "!"):
            if d == eq { return e == eq ? 3 : 2 }
            return 1
        case UInt16(ascii: "<"), UInt16(ascii: "*"), UInt16(ascii: "&"), UInt16(ascii: "|"):
            if d == c { return e == eq ? 3 : 2 }
            return d == eq ? 2 : 1
        case UInt16(ascii: ">"):
            if d == c {
                if e == c { return at(3) == eq ? 4 : 3 }
                return e == eq ? 3 : 2
            }
            return d == eq ? 2 : 1
        case UInt16(ascii: "+"), UInt16(ascii: "-"):
            return d == c || d == eq ? 2 : 1
        case UInt16(ascii: "/"), UInt16(ascii: "%"), UInt16(ascii: "^"):
            return d == eq ? 2 : 1
        default:
            // A lone surrogate half would split a character; keep pairs whole.
            if c >= 0xD800 && c <= 0xDBFF && d >= 0xDC00 && d <= 0xDFFF { return 2 }
            return 1
        }
    }

    // MARK: JSX

    private mutating func scanName() {
        while i < end, SourceLexing.isIDPart(u[i]) || u[i] == UInt16(ascii: "-") || u[i] == UInt16(ascii: ".") || u[i] == UInt16(ascii: ":") { i += 1 }
    }

    /// `<name` or the `<>` of a fragment.
    private mutating func openJSXTag() {
        let start = i
        i += 1
        jsxDepths[jsxDepths.count - 1] += 1
        if at(i) == UInt16(ascii: ">") {
            i += 1
            emit(.jsxTag, start, i)
            mode = .jsxChildren
            return
        }
        scanName()
        emit(.jsxTag, start, i)
        mode = .jsxAttributes
    }

    /// `</name>` or `</>`; false, with nothing read, if it isn't one.
    private mutating func closeJSXTag() -> Bool {
        let start = i
        var j = i + 2
        while j < end, SourceLexing.isIDPart(u[j]) || u[j] == UInt16(ascii: "-") || u[j] == UInt16(ascii: ".") || u[j] == UInt16(ascii: ":") { j += 1 }
        while j < end, SourceLexing.isSpace(u[j]) { j += 1 }
        guard j < end, u[j] == UInt16(ascii: ">") else { return false }
        i = j + 1
        emit(.jsxTag, start, i)
        closedJSXElement()
        return true
    }

    private mutating func closedJSXElement() {
        guard !jsxDepths.isEmpty else { mode = .js; return }
        jsxDepths[jsxDepths.count - 1] -= 1
        if jsxDepths[jsxDepths.count - 1] <= 0 {
            jsxDepths.removeLast()
            mode = .js
        } else {
            mode = .jsxChildren
        }
    }

    private mutating func lexJSXAttribute() {
        guard skipSpace() else { return }
        let start = i
        let c = u[i]
        if c == UInt16(ascii: "/") && at(i + 1) == UInt16(ascii: ">") {
            i += 2
            emit(.jsxTag, start, i)
            return closedJSXElement()
        }
        if c == UInt16(ascii: ">") {
            i += 1
            emit(.jsxTag, start, i)
            mode = .jsxChildren
            return
        }
        if c == UInt16(ascii: "{") {
            i += 1
            braces.append(.jsxAttribute)
            mode = .js
            return emit(.punctuator, start, i)
        }
        if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
            i += 1
            while i < end, u[i] != c { i += 1 }
            i = min(i + 1, end)
            return emit(.string, start, i)
        }
        if SourceLexing.isIDStart(c) {
            scanName()
            return emit(.jsxAttribute, start, i)
        }
        i += 1
        emit(.punctuator, start, i)
    }

    private mutating func lexJSXChildren() {
        let start = i
        let c = u[i]
        if c == UInt16(ascii: "<") {
            if at(i + 1) == UInt16(ascii: "/"), closeJSXTag() { return }
            if SourceLexing.isIDStart(at(i + 1)) || at(i + 1) == UInt16(ascii: ">") { return openJSXTag() }
        }
        if c == UInt16(ascii: "{") {
            i += 1
            braces.append(.jsxChild)
            mode = .js
            return emit(.punctuator, start, i)
        }
        i += 1
        while i < end, u[i] != UInt16(ascii: "<"), u[i] != UInt16(ascii: "{") { i += 1 }
        emit(.jsxText, start, i)
    }
}

// MARK: Highlighter

enum SourceHighlighter {
    static func tokens(_ text: String, language: SourceLanguage) -> [SourceToken] {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { u in
            var tokens = [SourceToken]()
            switch language {
            case let .javascript(typescript, jsx): javascript(u, 0, u.count, typescript: typescript, jsx: jsx, json: false, into: &tokens)
            case .json: javascript(u, 0, u.count, typescript: false, jsx: false, json: true, into: &tokens)
            case .css: css(u, 0, u.count, into: &tokens)
            case .html: html(u, into: &tokens)
            case .plain: break
            }
            return tokens
        }
    }

    // MARK: JavaScript and JSON

    static func javascript(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, typescript: Bool, jsx: Bool, json: Bool, into tokens: inout [SourceToken]) {
        let lexemes = JSLexer.lex(u, start: start, end: end, jsx: jsx)
        tokens.reserveCapacity(tokens.count + lexemes.count / 2)

        func punct(_ lexeme: JSLexeme?, _ text: String) -> Bool {
            guard let lexeme, lexeme.kind == .punctuator, lexeme.end - lexeme.start == text.utf16.count else { return false }
            var k = lexeme.start
            for c in text.utf16 { if u[k] != c { return false }; k += 1 }
            return true
        }

        // The lexemes that aren't comments, in order, as indices into lexemes.
        var significant = [Int]()
        significant.reserveCapacity(lexemes.count)
        for (index, lexeme) in lexemes.enumerated() where !lexeme.isComment { significant.append(index) }

        var s = 0
        for (index, lexeme) in lexemes.enumerated() {
            if lexeme.isComment {
                tokens.append(SourceToken(start: lexeme.start, length: lexeme.end - lexeme.start, kind: .comment))
                continue
            }
            while s < significant.count, significant[s] < index { s += 1 }
            let previous = s > 0 ? lexemes[significant[s - 1]] : nil
            let next = s + 1 < significant.count ? lexemes[significant[s + 1]] : nil
            let kind: SourceTokenKind?
            switch lexeme.kind {
            case .keyword:
                let word = JSKeyword.lookup(u, lexeme.start, lexeme.end)
                if punct(next, ":") && (punct(previous, "{") || punct(previous, ",")) && !word.contains(.atom) && !(lexeme.end - lexeme.start == 7 && u[lexeme.start] == UInt16(ascii: "d")) {
                    kind = .property
                } else if word.contains(.atom) {
                    kind = .atom
                } else if word.contains(.typeName) {
                    kind = typescript ? .type : nil
                } else if word.contains(.typescript) && !typescript {
                    kind = nil
                } else {
                    kind = .keyword
                }
            case .identifier:
                if json {
                    kind = nil
                } else if punct(previous, ".") || punct(previous, "?.") {
                    kind = .property
                } else if let previous, previous.kind == .keyword {
                    let word = JSKeyword.lookup(u, previous.start, previous.end)
                    if word.contains(.declares) { kind = .definition } else if typescript && word.contains(.declaresType) { kind = .type } else { kind = nil }
                } else if punct(next, ":") && (punct(previous, "{") || punct(previous, ",")) {
                    kind = .property
                } else {
                    kind = nil
                }
            case .privateName: kind = .property
            case .string:
                if json && punct(next, ":") {
                    kind = .property
                } else if jsx, punct(previous, "="), s >= 2, lexemes[significant[s - 2]].kind == .jsxAttribute {
                    kind = .attributeValue
                } else {
                    kind = .string
                }
            case .template: kind = .string
            case .regex: kind = .stringSpecial
            case .number: kind = .number
            case .jsxTag: kind = .tag
            case .jsxAttribute: kind = .attribute
            default: kind = nil
            }
            if let kind { tokens.append(SourceToken(start: lexeme.start, length: lexeme.end - lexeme.start, kind: kind)) }
        }
    }

    // MARK: CSS

    static func css(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, into tokens: inout [SourceToken]) {
        var i = start
        var depth = 0
        @inline(__always) func at(_ k: Int) -> UInt16 { k < end ? u[k] : 0 }

        while i < end {
            // The statement from here: up to `{`, `;` or `}` at the top level.
            var j = i
            var parens = 0
            var terminator: UInt16 = 0
            while j < end {
                let c = u[j]
                if c == UInt16(ascii: "/") && at(j + 1) == UInt16(ascii: "*") {
                    j += 2
                    while j < end, !(u[j] == UInt16(ascii: "*") && at(j + 1) == UInt16(ascii: "/")) { j += 1 }
                    j = min(j + 2, end)
                    continue
                }
                if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
                    j = cssStringEnd(u, j, end)
                    continue
                }
                if c == UInt16(ascii: "(") { parens += 1 } else if c == UInt16(ascii: ")") { parens = max(0, parens - 1) } else if parens == 0, c == UInt16(ascii: "{") || c == UInt16(ascii: ";") || c == UInt16(ascii: "}") {
                    terminator = c
                    break
                }
                j += 1
            }
            let first = firstSignificant(u, i, j)
            let atRule = first < j && u[first] == UInt16(ascii: "@")
            if terminator == UInt16(ascii: "{") {
                if atRule { cssValue(u, i, j, prelude: true, into: &tokens) } else { cssSelector(u, i, j, into: &tokens) }
                depth += 1
            } else if depth == 0 && !atRule {
                cssSelector(u, i, j, into: &tokens)
            } else {
                cssDeclaration(u, i, j, atRule: atRule, into: &tokens)
            }
            if terminator == UInt16(ascii: "}") { depth = max(0, depth - 1) }
            i = j + 1
        }
    }

    static func cssStringEnd(_ u: UnsafeBufferPointer<UInt16>, _ k: Int, _ end: Int) -> Int {
        let quote = u[k]
        var j = k + 1
        while j < end {
            let c = u[j]
            if c == UInt16(ascii: "\\") { j += 2; continue }
            if c == quote { return j + 1 }
            if c == 10 { return j }
            j += 1
        }
        return end
    }

    private static func firstSignificant(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> Int {
        var k = start
        while k < end {
            let c = u[k]
            if SourceLexing.isSpace(c) || SourceLexing.isNewline(c) { k += 1; continue }
            if c == UInt16(ascii: "/") && k + 1 < end && u[k + 1] == UInt16(ascii: "*") {
                k += 2
                while k + 1 < end, !(u[k] == UInt16(ascii: "*") && u[k + 1] == UInt16(ascii: "/")) { k += 1 }
                k += 2
                continue
            }
            break
        }
        return min(k, end)
    }

    @inline(__always) private static func isCSSName(_ c: UInt16) -> Bool {
        SourceLexing.isIDPart(c) || c == UInt16(ascii: "-") || c == UInt16(ascii: "\\")
    }

    /// Comments and strings, which read the same everywhere in CSS. Returns
    /// where they end, or nil if there isn't one at `k`.
    private static func cssCommon(_ u: UnsafeBufferPointer<UInt16>, _ k: Int, _ end: Int, into tokens: inout [SourceToken]) -> Int? {
        let c = u[k]
        if c == UInt16(ascii: "/") && k + 1 < end && u[k + 1] == UInt16(ascii: "*") {
            var j = k + 2
            while j + 1 < end, !(u[j] == UInt16(ascii: "*") && u[j + 1] == UInt16(ascii: "/")) { j += 1 }
            j = min(j + 2, end)
            tokens.append(SourceToken(start: k, length: j - k, kind: .comment))
            return j
        }
        if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
            let j = cssStringEnd(u, k, end)
            tokens.append(SourceToken(start: k, length: j - k, kind: .string))
            return j
        }
        return nil
    }

    private static func cssSelector(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, into tokens: inout [SourceToken]) {
        var k = start
        var inAttribute = false
        while k < end {
            if let j = cssCommon(u, k, end, into: &tokens) { k = j; continue }
            let c = u[k]
            let s = k
            if c == UInt16(ascii: "[") { inAttribute = true; k += 1; continue }
            if c == UInt16(ascii: "]") { inAttribute = false; k += 1; continue }
            if c == UInt16(ascii: ".") || c == UInt16(ascii: "#") || c == UInt16(ascii: ":") {
                k += 1
                if c == UInt16(ascii: ":") && k < end && u[k] == c { k += 1 }
                guard k < end, isCSSName(u[k]) else { continue }
                while k < end, isCSSName(u[k]) { k += 1 }
                let kind: SourceTokenKind = c == UInt16(ascii: ".") ? .type : c == UInt16(ascii: "#") ? .definition : .variableSpecial
                tokens.append(SourceToken(start: s, length: k - s, kind: kind))
                continue
            }
            if isCSSName(c) && !SourceLexing.isDigit(c) {
                while k < end, isCSSName(u[k]) { k += 1 }
                tokens.append(SourceToken(start: s, length: k - s, kind: inAttribute ? .attribute : .tag))
                continue
            }
            if c == UInt16(ascii: "*") { tokens.append(SourceToken(start: s, length: 1, kind: .tag)) }
            k += 1
        }
    }

    private static func cssDeclaration(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, atRule: Bool, into tokens: inout [SourceToken]) {
        if atRule { return cssValue(u, start, end, prelude: true, into: &tokens) }
        var k = start
        while k < end {
            if let j = cssCommon(u, k, end, into: &tokens) { k = j; continue }
            let c = u[k]
            if isCSSName(c) {
                let s = k
                while k < end, isCSSName(u[k]) { k += 1 }
                tokens.append(SourceToken(start: s, length: k - s, kind: .property))
                break
            }
            if c == UInt16(ascii: ":") { break }
            k += 1
        }
        while k < end, u[k] != UInt16(ascii: ":") {
            if let j = cssCommon(u, k, end, into: &tokens) { k = j; continue }
            k += 1
        }
        if k < end { cssValue(u, k + 1, end, prelude: false, into: &tokens) }
    }

    private static func cssValue(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, prelude: Bool, into tokens: inout [SourceToken]) {
        var k = start
        while k < end {
            if let j = cssCommon(u, k, end, into: &tokens) { k = j; continue }
            let c = u[k]
            let s = k
            let next: UInt16 = k + 1 < end ? u[k + 1] : 0
            if c == UInt16(ascii: "@") || c == UInt16(ascii: "!") {
                k += 1
                while k < end, SourceLexing.isSpace(u[k]) { k += 1 }
                while k < end, isCSSName(u[k]) { k += 1 }
                tokens.append(SourceToken(start: s, length: k - s, kind: .keyword))
                continue
            }
            if c == UInt16(ascii: "#") && isCSSName(next) {
                k += 1
                while k < end, isCSSName(u[k]) { k += 1 }
                tokens.append(SourceToken(start: s, length: k - s, kind: .atom))
                continue
            }
            if SourceLexing.isDigit(c) || ((c == UInt16(ascii: ".") || c == UInt16(ascii: "-") || c == UInt16(ascii: "+")) && SourceLexing.isDigit(next))
                || (c == UInt16(ascii: "-") && next == UInt16(ascii: ".")) {
                k += 1
                while k < end, SourceLexing.isDigit(u[k]) || u[k] == UInt16(ascii: ".") { k += 1 }
                if k < end, (u[k] | 0x20) == UInt16(ascii: "e"), k + 1 < end, SourceLexing.isDigit(u[k + 1]) {
                    k += 1
                    while k < end, SourceLexing.isDigit(u[k]) { k += 1 }
                }
                while k < end, SourceLexing.isIDStart(u[k]) || u[k] == UInt16(ascii: "%") { k += 1 }
                tokens.append(SourceToken(start: s, length: k - s, kind: .number))
                continue
            }
            if isCSSName(c) {
                while k < end, isCSSName(u[k]) { k += 1 }
                let length = k - s
                if k < end && u[k] == UInt16(ascii: "(") {
                    // url(…) unquoted reads as a string, as in Chrome.
                    if length == 3, (u[s] | 0x20) == UInt16(ascii: "u"), (u[s + 1] | 0x20) == UInt16(ascii: "r"), (u[s + 2] | 0x20) == UInt16(ascii: "l") {
                        var j = k + 1
                        while j < end, SourceLexing.isSpace(u[j]) { j += 1 }
                        if j < end, u[j] != UInt16(ascii: "\""), u[j] != UInt16(ascii: "'") {
                            var close = j
                            while close < end, u[close] != UInt16(ascii: ")") { close += 1 }
                            tokens.append(SourceToken(start: j, length: close - j, kind: .string))
                            k = close
                        }
                    }
                    continue
                }
                var kind = SourceTokenKind.atom
                if prelude {
                    // A media feature's name, before its colon.
                    var j = k
                    while j < end, SourceLexing.isSpace(u[j]) { j += 1 }
                    if j < end && u[j] == UInt16(ascii: ":") { kind = .property }
                }
                tokens.append(SourceToken(start: s, length: length, kind: kind))
                continue
            }
            k += 1
        }
    }

    // MARK: HTML

    static func html(_ u: UnsafeBufferPointer<UInt16>, into tokens: inout [SourceToken]) {
        let end = u.count
        var k = 0
        @inline(__always) func at(_ n: Int) -> UInt16 { n < end ? u[n] : 0 }
        while k < end {
            guard u[k] == UInt16(ascii: "<") else { k += 1; continue }
            let s = k
            if at(k + 1) == UInt16(ascii: "!") && at(k + 2) == UInt16(ascii: "-") && at(k + 3) == UInt16(ascii: "-") {
                k += 4
                while k < end, !(u[k] == UInt16(ascii: "-") && at(k + 1) == UInt16(ascii: "-") && at(k + 2) == UInt16(ascii: ">")) { k += 1 }
                k = min(k + 3, end)
                tokens.append(SourceToken(start: s, length: k - s, kind: .comment))
                continue
            }
            if at(k + 1) == UInt16(ascii: "!") || at(k + 1) == UInt16(ascii: "?") {
                while k < end, u[k] != UInt16(ascii: ">") { k += 1 }
                k = min(k + 1, end)
                tokens.append(SourceToken(start: s, length: k - s, kind: .meta))
                continue
            }
            let closing = at(k + 1) == UInt16(ascii: "/")
            let nameStart = closing ? k + 2 : k + 1
            guard SourceLexing.isIDStart(at(nameStart)) else { k += 1; continue }
            var n = nameStart
            while n < end, SourceLexing.isIDPart(u[n]) || u[n] == UInt16(ascii: "-") || u[n] == UInt16(ascii: ":") { n += 1 }
            let name = String(decoding: UnsafeBufferPointer(rebasing: u[nameStart..<n]), as: UTF16.self).lowercased()
            tokens.append(SourceToken(start: s, length: n - s, kind: .tag))
            k = n
            var scriptType: String?
            var lastAttribute = ""
            // Attributes, to the tag's end.
            while k < end {
                let c = u[k]
                if c == UInt16(ascii: ">") || (c == UInt16(ascii: "/") && at(k + 1) == UInt16(ascii: ">")) {
                    let length = c == UInt16(ascii: ">") ? 1 : 2
                    tokens.append(SourceToken(start: k, length: length, kind: .tag))
                    k += length
                    break
                }
                if SourceLexing.isSpace(c) || SourceLexing.isNewline(c) || c == UInt16(ascii: "/") { k += 1; continue }
                if c == UInt16(ascii: "=") {
                    k += 1
                    while k < end, SourceLexing.isSpace(u[k]) || SourceLexing.isNewline(u[k]) { k += 1 }
                    guard k < end else { break }
                    let v = k
                    let quote = u[k]
                    if quote == UInt16(ascii: "\"") || quote == UInt16(ascii: "'") {
                        k += 1
                        while k < end, u[k] != quote { k += 1 }
                        k = min(k + 1, end)
                    } else {
                        while k < end, !SourceLexing.isSpace(u[k]), !SourceLexing.isNewline(u[k]), u[k] != UInt16(ascii: ">") { k += 1 }
                    }
                    tokens.append(SourceToken(start: v, length: k - v, kind: .attributeValue))
                    if lastAttribute == "type" {
                        scriptType = String(decoding: UnsafeBufferPointer(rebasing: u[v..<k]), as: UTF16.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
                    }
                    continue
                }
                let a = k
                while k < end, !SourceLexing.isSpace(u[k]), !SourceLexing.isNewline(u[k]), u[k] != UInt16(ascii: "="), u[k] != UInt16(ascii: ">"), u[k] != UInt16(ascii: "/") { k += 1 }
                if k == a { k += 1; continue }
                tokens.append(SourceToken(start: a, length: k - a, kind: .attribute))
                lastAttribute = String(decoding: UnsafeBufferPointer(rebasing: u[a..<k]), as: UTF16.self).lowercased()
            }
            guard !closing, name == "script" || name == "style" else { continue }
            let bodyEnd = rawTextEnd(u, from: k, name: name)
            if name == "style" {
                css(u, k, bodyEnd, into: &tokens)
            } else if let kind = HTMLScriptKind(type: scriptType) {
                switch kind {
                case .javascript: javascript(u, k, bodyEnd, typescript: false, jsx: false, json: false, into: &tokens)
                case .json: javascript(u, k, bodyEnd, typescript: false, jsx: false, json: true, into: &tokens)
                }
            }
            k = bodyEnd
        }
    }

    /// The offset after the `>` that ends a tag, past quoted values, or the end.
    static func tagEnd(_ u: UnsafeBufferPointer<UInt16>, from k: Int) -> Int {
        var j = k
        var quote: UInt16 = 0
        while j < u.count {
            let c = u[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == UInt16(ascii: "\"") || c == UInt16(ascii: "'") {
                quote = c
            } else if c == UInt16(ascii: ">") {
                return j + 1
            }
            j += 1
        }
        return u.count
    }

    /// Where `</name` starts, after `k`, in any case.
    static func rawTextEnd(_ u: UnsafeBufferPointer<UInt16>, from k: Int, name: String) -> Int {
        let target = Array(name.utf16)
        var j = k
        let end = u.count
        while j + 1 + target.count < end {
            if u[j] == UInt16(ascii: "<"), u[j + 1] == UInt16(ascii: "/") {
                var matches = true
                for (offset, c) in target.enumerated() where (u[j + 2 + offset] | 0x20) != c { matches = false; break }
                if matches { return j }
            }
            j += 1
        }
        return end
    }
}

enum HTMLScriptKind {
    case javascript, json

    init?(type: String?) {
        guard let type, !type.isEmpty else { self = .javascript; return }
        if type.contains("json") { self = .json } else if type.contains("javascript") || type.contains("ecmascript") || type == "module" || type.contains("jsx") || type.contains("babel") {
            self = .javascript
        } else {
            return nil
        }
    }
}

extension UInt16 {
    /// A code unit for an ASCII character, as UInt8(ascii:) is for bytes.
    @inline(__always) init(ascii scalar: Unicode.Scalar) { self = UInt16(truncatingIfNeeded: scalar.value) }
}
