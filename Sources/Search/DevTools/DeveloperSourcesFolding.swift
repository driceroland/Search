import AppKit

// Code folding in the Sources editor, as Chrome's (Settings › Preferences ›
// Sources › Code folding): a marker in the gutter on each line that opens a
// bracket closed on a later line — {…}, […], (…) — or an HTML element or
// CSS block spanning lines. Folding one shows the line as `{…}` and the
// lines under it go, their numbers skipped.
//
// The text itself never changes: the folded characters get null glyphs and
// zero-height lines (SourceFoldLayout), so every offset — breakpoints, the
// execution line, search, go to line, inline values — still means what it
// did. A fold hides from just after its opening bracket to the end of its
// closing bracket's line; the closing part (`}`, `});`, `} else {`) is
// drawn after the `…`, as Chrome shows it.

/// One block the editor can fold.
struct SourceFold: Hashable {
    /// 0-based lines of the opening and the closing bracket.
    var startLine: Int
    var endLine: Int
    /// UTF-16 offsets: just after the opening bracket, and of the closing one.
    var start: Int
    var end: Int
    /// Where the closing bracket's line ends, before its line break.
    var lineEnd: Int
}

enum SourceFolding {
    // MARK: Finding the blocks

    /// Every foldable block, one per line it starts on (the first bracket
    /// opened on the line that closes on another), in line order.
    static func folds(_ text: String, language: SourceLanguage) -> [SourceFold] {
        let units = Array(text.utf16)
        var pairs: [(start: Int, end: Int)] = []
        units.withUnsafeBufferPointer { u in
            switch language {
            case let .javascript(_, jsx): bracketPairs(u, 0, u.count, jsx: jsx, into: &pairs)
            case .json: bracketPairs(u, 0, u.count, jsx: false, into: &pairs)
            case .css: cssPairs(u, 0, u.count, into: &pairs)
            case .html: htmlPairs(u, into: &pairs)
            case .plain: break
            }
        }
        guard !pairs.isEmpty else { return [] }
        let starts = SourceLexing.lineStarts(text)
        var byLine: [Int: SourceFold] = [:]
        for pair in pairs {
            let startLine = lineIndex(max(0, pair.start - 1), in: starts)
            let endLine = lineIndex(pair.end, in: starts)
            guard endLine > startLine else { continue }
            if let kept = byLine[startLine], kept.start <= pair.start { continue }
            var lineEnd = endLine + 1 < starts.count ? starts[endLine + 1] : units.count
            while lineEnd > pair.end, SourceLexing.isNewline(units[lineEnd - 1]) || units[lineEnd - 1] == 0x85 { lineEnd -= 1 }
            byLine[startLine] = SourceFold(startLine: startLine, endLine: endLine, start: pair.start, end: pair.end, lineEnd: lineEnd)
        }
        return byLine.values.sorted { $0.startLine < $1.startLine }
    }

    static func lineIndex(_ offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Brackets in JavaScript, JSX and JSON, by the lexer: strings,
    /// comments, regular expressions and JSX text hold none. A template's
    /// `${…}` counts as a brace pair.
    static func bracketPairs(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, jsx: Bool,
                             into pairs: inout [(start: Int, end: Int)]) {
        let lexemes = JSLexer.lex(u, start: start, end: end, jsx: jsx)
        var stack: [(opener: UInt16, at: Int)] = []
        func close(_ opener: UInt16, at offset: Int) {
            guard let index = stack.lastIndex(where: { $0.opener == opener }) else { return }
            pairs.append((stack[index].at + 1, offset))
            stack.removeSubrange(index...)
        }
        let brace = UInt16(UInt8(ascii: "{")), closeBrace = UInt16(UInt8(ascii: "}"))
        for lexeme in lexemes {
            switch lexeme.kind {
            case .punctuator where lexeme.end - lexeme.start == 1:
                let c = u[lexeme.start]
                switch c {
                case brace, UInt16(UInt8(ascii: "[")), UInt16(UInt8(ascii: "(")): stack.append((c, lexeme.start))
                case closeBrace: close(brace, at: lexeme.start)
                case UInt16(UInt8(ascii: "]")): close(UInt16(UInt8(ascii: "[")), at: lexeme.start)
                case UInt16(UInt8(ascii: ")")): close(UInt16(UInt8(ascii: "(")), at: lexeme.start)
                default: break
                }
            case .template:
                if u[lexeme.start] == closeBrace { close(brace, at: lexeme.start) }
                if lexeme.end - lexeme.start >= 2, u[lexeme.end - 1] == brace, u[lexeme.end - 2] == UInt16(UInt8(ascii: "$")) {
                    stack.append((brace, lexeme.end - 1))
                }
            default: break
            }
        }
    }

    /// CSS's `{…}` blocks, past comments and strings.
    static func cssPairs(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int,
                         into pairs: inout [(start: Int, end: Int)]) {
        var stack: [Int] = []
        var i = start
        while i < end {
            let c = u[i]
            if c == UInt16(UInt8(ascii: "/")), i + 1 < end, u[i + 1] == UInt16(UInt8(ascii: "*")) {
                i += 2
                while i < end, !(u[i] == UInt16(UInt8(ascii: "*")) && i + 1 < end && u[i + 1] == UInt16(UInt8(ascii: "/"))) { i += 1 }
                i += 2
                continue
            }
            if c == UInt16(UInt8(ascii: "\"")) || c == UInt16(UInt8(ascii: "'")) {
                i += 1
                while i < end, u[i] != c, !SourceLexing.isNewline(u[i]) {
                    i += u[i] == UInt16(UInt8(ascii: "\\")) ? 2 : 1
                }
                i += 1
                continue
            }
            if c == UInt16(UInt8(ascii: "{")) {
                stack.append(i)
            } else if c == UInt16(UInt8(ascii: "}")), let open = stack.popLast() {
                pairs.append((open + 1, i))
            }
            i += 1
        }
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        "keygen", "!doctype",
    ]

    /// HTML elements from the end of their opening tag to the start of
    /// their closing one; inside `<script>` and `<style>`, the code's own
    /// blocks too.
    static func htmlPairs(_ u: UnsafeBufferPointer<UInt16>, into pairs: inout [(start: Int, end: Int)]) {
        let end = u.count
        var stack: [(name: String, at: Int)] = []
        var i = 0
        @inline(__always) func at(_ k: Int) -> UInt16 { k < end ? u[k] : 0 }
        func isNameStart(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) }
        func isNamePart(_ c: UInt16) -> Bool {
            isNameStart(c) || SourceLexing.isDigit(c) || c == UInt16(UInt8(ascii: "-")) || c == UInt16(UInt8(ascii: ":")) || c == UInt16(UInt8(ascii: "_"))
        }
        func name(from k: Int) -> (String, Int) {
            var j = k
            while j < end, isNamePart(u[j]) { j += 1 }
            let text = String(decoding: u[k..<j], as: UTF16.self).lowercased()
            return (text, j)
        }
        /// The offset after the `>` that ends a tag, past quoted values.
        func tagEnd(from k: Int) -> Int {
            var j = k
            var quote: UInt16 = 0
            while j < end {
                let c = u[j]
                if quote != 0 {
                    if c == quote { quote = 0 }
                } else if c == UInt16(UInt8(ascii: "\"")) || c == UInt16(UInt8(ascii: "'")) {
                    quote = c
                } else if c == UInt16(UInt8(ascii: ">")) {
                    return j + 1
                }
                j += 1
            }
            return end
        }
        /// Where `</name` next starts, any case, or the end.
        func closing(_ tag: String, from k: Int) -> Int {
            let needle = Array(("</" + tag).utf16)
            var j = k
            while j + needle.count <= end {
                if u[j] == UInt16(UInt8(ascii: "<")) {
                    var same = true
                    for (n, c) in needle.enumerated() where (u[j + n] | (n > 1 ? 0x20 : 0)) != c {
                        same = false
                        break
                    }
                    if same { return j }
                }
                j += 1
            }
            return end
        }
        while i < end {
            guard u[i] == UInt16(UInt8(ascii: "<")) else { i += 1; continue }
            if at(i + 1) == UInt16(UInt8(ascii: "!")), at(i + 2) == UInt16(UInt8(ascii: "-")), at(i + 3) == UInt16(UInt8(ascii: "-")) {
                var j = i + 4
                while j < end, !(u[j] == UInt16(UInt8(ascii: "-")) && at(j + 1) == UInt16(UInt8(ascii: "-")) && at(j + 2) == UInt16(UInt8(ascii: ">"))) { j += 1 }
                i = min(end, j + 3)
                continue
            }
            if at(i + 1) == UInt16(UInt8(ascii: "/")), isNameStart(at(i + 2)) {
                let (tag, _) = name(from: i + 2)
                if let index = stack.lastIndex(where: { $0.name == tag }) {
                    pairs.append((stack[index].at, i))
                    stack.removeSubrange(index...)
                }
                i = tagEnd(from: i + 2)
                continue
            }
            guard isNameStart(at(i + 1)) else {
                // <!DOCTYPE …>, <?xml …?>: nothing to fold.
                i = at(i + 1) == UInt16(UInt8(ascii: "!")) || at(i + 1) == UInt16(UInt8(ascii: "?")) ? tagEnd(from: i + 1) : i + 1
                continue
            }
            let (tag, after) = name(from: i + 1)
            let stop = tagEnd(from: after)
            let selfClosing = stop >= 2 && stop <= end && u[stop - 1] == UInt16(UInt8(ascii: ">")) && u[stop - 2] == UInt16(UInt8(ascii: "/"))
            i = stop
            if voidElements.contains(tag) || selfClosing { continue }
            stack.append((tag, stop))
            if tag == "script" || tag == "style" || tag == "textarea" || tag == "title" {
                // Raw text: no tags inside, but code with its own blocks.
                let close = closing(tag, from: stop)
                if tag == "script" { bracketPairs(u, stop, close, jsx: false, into: &pairs) }
                if tag == "style" { cssPairs(u, stop, close, into: &pairs) }
                i = close
            }
        }
    }

    // MARK: Folded state

    /// The lines (0-based) folded away: under each folded block's first
    /// line, down to and with its closing line.
    static func hiddenLines(_ folded: Set<SourceFold>) -> IndexSet {
        var lines = IndexSet()
        for fold in folded where fold.endLine > fold.startLine {
            lines.insert(integersIn: (fold.startLine + 1)...fold.endLine)
        }
        return lines
    }

    /// The folds to open so an offset (a caret, a match, the paused
    /// statement) is on screen: each one hiding it.
    static func revealing(_ offset: Int, in folded: Set<SourceFold>) -> Set<SourceFold> {
        folded.filter { $0.start < offset && offset < $0.lineEnd }
    }

    /// The shown line numbers (1-based) for a file of `count` lines.
    static func shownLines(count: Int, hidden: IndexSet) -> [Int] {
        (0..<max(0, count)).filter { !hidden.contains($0) }.map { $0 + 1 }
    }

    /// One line as folding shows it: the characters hidden from the first
    /// fold on, and what is drawn in their place — `…` for each fold, and
    /// the text after its closing bracket, which may open another.
    struct FoldedLine: Equatable {
        enum Piece: Equatable {
            case placeholder(SourceFold)
            /// Text drawn as is, a UTF-16 range of the source.
            case text(start: Int, end: Int)
        }

        var hidden: NSRange
        var pieces: [Piece]
    }

    static func foldedLines(_ folded: Set<SourceFold>) -> [FoldedLine] {
        let sorted = folded.sorted { $0.start < $1.start }
        var lines: [FoldedLine] = []
        var i = 0
        while i < sorted.count {
            let first = sorted[i]
            var pieces: [FoldedLine.Piece] = [.placeholder(first)]
            var position = first.end
            var hiddenEnd = first.lineEnd
            var j = i + 1
            while j < sorted.count {
                let next = sorted[j]
                if next.start < position {
                    // Inside a fold already hidden.
                    j += 1
                } else if next.start <= hiddenEnd {
                    // Opened on the closing line: `} else {…}`.
                    pieces.append(.text(start: position, end: next.start))
                    pieces.append(.placeholder(next))
                    position = next.end
                    hiddenEnd = max(hiddenEnd, next.lineEnd)
                    j += 1
                } else {
                    break
                }
            }
            if position < hiddenEnd { pieces.append(.text(start: position, end: hiddenEnd)) }
            lines.append(FoldedLine(hidden: NSRange(location: first.start, length: hiddenEnd - first.start), pieces: pieces))
            i = j
        }
        return lines
    }
}

// MARK: Layout

/// Hides folded text from the layout: null glyphs for its characters, a
/// box as wide as the drawn `{…}` for the first, and no height for the
/// lines under it.
final class SourceFoldLayout: NSObject, NSLayoutManagerDelegate {
    /// The hidden ranges, sorted, and each one's box width by its start.
    private(set) var hidden: [NSRange] = []
    private var widths: [Int: CGFloat] = [:]

    func update(_ lines: [SourceFolding.FoldedLine], widths: [Int: CGFloat]) {
        hidden = lines.map(\.hidden)
        self.widths = widths
    }

    /// The hidden range holding a character, if any.
    func range(containing index: Int) -> NSRange? {
        var low = 0, high = hidden.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(hidden[mid]) <= index { low = mid + 1 } else { high = mid }
        }
        guard low < hidden.count, hidden[low].location <= index, index < NSMaxRange(hidden[low]) else { return nil }
        return hidden[low]
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hidden.isEmpty, glyphRange.length > 0 else { return 0 }
        let first = charIndexes[0], last = charIndexes[glyphRange.length - 1]
        guard hidden.contains(where: { $0.location <= last && first < NSMaxRange($0) }) else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for index in 0..<glyphRange.length {
            guard let range = range(containing: charIndexes[index]) else { continue }
            properties[index] = charIndexes[index] == range.location ? .controlCharacter : .null
        }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes,
                                    font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        widths[charIndex] != nil ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: glyphPosition.x, y: 0, width: widths[charIndex] ?? 0, height: proposedRect.height)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !hidden.isEmpty, glyphRange.length > 0 else { return false }
        let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        // A line that starts inside folded text is folded away.
        guard let range = range(containing: character), character > range.location else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.width = 0
        return true
    }
}

// MARK: Text view

extension SourceTextView {
    static let foldPlaceholder = "…"

    private var foldTextAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.codeFont, .foregroundColor: SourceTheme.text]
    }

    /// How wide a folded line's pieces draw, each.
    func foldPieceWidths(_ line: SourceFolding.FoldedLine) -> [CGFloat] {
        let source = string as NSString
        return line.pieces.map { piece in
            switch piece {
            case .placeholder:
                return (Self.foldPlaceholder as NSString).size(withAttributes: foldTextAttributes).width + 8
            case let .text(start, end):
                guard start < end, end <= source.length else { return 0 }
                return (source.substring(with: NSRange(location: start, length: end - start)) as NSString)
                    .size(withAttributes: foldTextAttributes).width
            }
        }
    }

    /// Works out the blocks to fold, off the main thread, after the text
    /// is shown or changed.
    func refreshFolds() {
        foldGeneration += 1
        let generation = foldGeneration
        guard foldingEnabled else {
            foldsByLine = [:]
            gutter?.needsDisplay = true
            return
        }
        let text = string, language = language
        Task.detached(priority: .userInitiated) { [weak self] in
            let folds = SourceFolding.folds(text, language: language)
            await MainActor.run {
                guard let self, self.foldGeneration == generation else { return }
                self.foldsByLine = Dictionary(folds.map { ($0.startLine, $0) }, uniquingKeysWith: { first, _ in first })
                self.gutter?.needsDisplay = true
            }
        }
    }

    /// Folds or unfolds the block starting on a line (1-based).
    func toggleFold(line: Int) {
        guard let fold = foldsByLine[line - 1] else { return }
        var next = folded
        if next.contains(fold) {
            next.remove(fold)
        } else {
            next.insert(fold)
            // A caret in what goes away comes out to the fold's start.
            let caret = selectedRange().location
            if fold.start < caret, caret < fold.lineEnd {
                setFolded(next)
                setSelectedRange(NSRange(location: fold.start, length: 0))
                return
            }
        }
        setFolded(next)
    }

    func unfoldAll() {
        guard !folded.isEmpty else { return }
        setFolded([])
    }

    /// Opens whichever folds hide an offset.
    func reveal(offset: Int) {
        guard !folded.isEmpty else { return }
        let opening = SourceFolding.revealing(offset, in: folded)
        guard !opening.isEmpty else { return }
        setFolded(folded.subtracting(opening))
    }

    func setFolded(_ next: Set<SourceFold>) {
        guard next != folded, let layoutManager else { return }
        let before = foldLayout.hidden
        folded = next
        foldedLines = SourceFolding.foldedLines(next)
        hiddenLines = SourceFolding.hiddenLines(next)
        var widths: [Int: CGFloat] = [:]
        for line in foldedLines { widths[line.hidden.location] = foldPieceWidths(line).reduce(0, +) }
        foldLayout.update(foldedLines, widths: widths)
        let length = (string as NSString).length
        // Everything that was or now is hidden lays out again, from its line's start.
        var low = length, high = 0
        for range in before + foldLayout.hidden {
            low = min(low, range.location)
            high = max(high, NSMaxRange(range))
        }
        if low < high {
            let start = lineStarts[lineIndex(of: low)]
            let range = NSRange(location: start, length: min(length, high + 1) - start)
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        needsDisplay = true
        gutter?.needsDisplay = true
    }

    /// Where each folded line's pieces are drawn, in this view.
    func foldPieceRects() -> [(piece: SourceFolding.FoldedLine.Piece, rect: NSRect)] {
        guard !foldedLines.isEmpty, let layoutManager, let textContainer else { return [] }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        var out: [(piece: SourceFolding.FoldedLine.Piece, rect: NSRect)] = []
        for line in foldedLines where line.hidden.location < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: line.hidden.location)
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            var x = box.minX + origin.x
            for (piece, width) in zip(line.pieces, foldPieceWidths(line)) {
                out.append((piece: piece, rect: NSRect(x: x, y: fragment.minY + origin.y, width: width, height: fragment.height)))
                x += width
            }
        }
        return out
    }

    /// Draws `…` for each fold, in Chrome's small box, and the text after
    /// its closing bracket.
    func drawFolds(in dirtyRect: NSRect) {
        guard !foldedLines.isEmpty else { return }
        let source = string as NSString
        for (piece, rect) in foldPieceRects() where rect.intersects(dirtyRect) {
            switch piece {
            case .placeholder:
                let box = NSRect(x: rect.minX + 2, y: rect.minY + 2, width: rect.width - 4, height: max(rect.height - 4, 8))
                NSColor.secondaryLabelColor.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                let label = NSAttributedString(string: Self.foldPlaceholder,
                                               attributes: [.font: Self.codeFont, .foregroundColor: NSColor.secondaryLabelColor])
                let size = label.size()
                label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + (rect.height - size.height) / 2))
            case let .text(start, end):
                guard start < end, end <= source.length else { continue }
                let text = source.substring(with: NSRange(location: start, length: end - start))
                let label = NSAttributedString(string: text, attributes: foldTextAttributes)
                label.draw(at: NSPoint(x: rect.minX, y: rect.minY + (rect.height - label.size().height) / 2))
            }
        }
    }

    /// A click on a fold's `…` opens it.
    func foldHit(at point: NSPoint) -> SourceFold? {
        for (piece, rect) in foldPieceRects() where rect.contains(point) {
            if case let .placeholder(fold) = piece { return fold }
        }
        return nil
    }
}
