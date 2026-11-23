import Foundation

/// Several carets in the Sources editor, as CodeMirror keeps them in
/// Chrome's (⌥-click adds one): NSTextView holds several selections but
/// only one empty one, so the editor keeps the extra bare carets itself and
/// edits at all of them through this.
enum SourceCarets {
    enum Operation: Equatable {
        case insert(String)
        case deleteBackward
        case deleteForward
    }

    /// The ranges sorted, with duplicates and overlaps merged.
    static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            if let last = out.last, range.location <= NSMaxRange(last), !(last.length == 0 && range.length == 0 && range.location != last.location) {
                if range.location < NSMaxRange(last) || range.location == last.location || range.length > 0 && range.location == NSMaxRange(last) && last.length > 0 {
                    out[out.count - 1] = NSUnionRange(last, range)
                    continue
                }
            }
            out.append(range)
        }
        return out
    }

    /// The edits `operation` makes at each caret (ascending, none
    /// overlapping) and where each caret is afterwards.
    static func apply(_ operation: Operation, to text: NSString, carets: [NSRange]) -> (edits: [(range: NSRange, text: String)], carets: [Int]) {
        var edits: [(range: NSRange, text: String)] = []
        for caret in normalize(carets) {
            var range = caret
            var inserted = ""
            switch operation {
            case .insert(let string):
                inserted = string
            case .deleteBackward where caret.length == 0:
                guard caret.location > 0 else { range = NSRange(location: caret.location, length: 0); break }
                range = text.rangeOfComposedCharacterSequence(at: caret.location - 1)
            case .deleteForward where caret.length == 0:
                guard caret.location < text.length else { break }
                range = text.rangeOfComposedCharacterSequence(at: caret.location)
            default:
                break
            }
            // Two carets side by side deleting into each other: once.
            if let last = edits.last, range.location < NSMaxRange(last.range) {
                range = NSRange(location: NSMaxRange(last.range), length: max(0, NSMaxRange(range) - NSMaxRange(last.range)))
            }
            edits.append((range, inserted))
        }
        var offset = 0
        var after: [Int] = []
        for edit in edits {
            let length = (edit.text as NSString).length
            after.append(edit.range.location + offset + length)
            offset += length - edit.range.length
        }
        var unique: [Int] = []
        for caret in after where unique.last != caret { unique.append(caret) }
        return (edits.filter { $0.range.length > 0 || !$0.text.isEmpty }, unique)
    }

    /// Each caret a character left (-1) or right (+1); a selection collapses
    /// to its own side instead, as in a text editor.
    static func move(_ carets: [NSRange], by step: Int, in text: NSString) -> [Int] {
        var out: [Int] = []
        for caret in normalize(carets) {
            let position: Int
            if caret.length > 0 {
                position = step < 0 ? caret.location : NSMaxRange(caret)
            } else if step < 0 {
                position = caret.location > 0 ? text.rangeOfComposedCharacterSequence(at: caret.location - 1).location : 0
            } else {
                position = caret.location < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: caret.location)) : text.length
            }
            if out.last != position { out.append(position) }
        }
        return out
    }

    /// The line (0-based) and column of `index`.
    static func lineAndColumn(_ index: Int, in text: NSString) -> (line: Int, column: Int, start: Int) {
        var line = 0, start = 0, position = 0
        let index = min(index, text.length)
        while position < index {
            if text.character(at: position) == 10 { line += 1; start = position + 1 }
            position += 1
        }
        return (line, index - start, start)
    }

    /// The index at `column` on `line`, or the line's end; nil past the text.
    static func index(line: Int, column: Int, in text: NSString) -> Int? {
        guard line >= 0 else { return nil }
        var current = 0, start = 0
        while current < line {
            let next = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            guard next.location != NSNotFound else { return nil }
            start = next.location + 1
            current += 1
        }
        let end = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
        let lineEnd = end.location == NSNotFound ? text.length : end.location
        return min(start + column, lineEnd)
    }

    /// ↑/↓ with several carets: each to the line above or below at its
    /// column (or the line's end); one with no line there stays.
    static func moveVertically(_ carets: [NSRange], by step: Int, in text: NSString) -> [Int] {
        var out: [Int] = []
        for caret in normalize(carets) {
            let from = step < 0 ? caret.location : NSMaxRange(caret)
            let place = lineAndColumn(from, in: text)
            let target = index(line: place.line + step, column: place.column, in: text) ?? from
            out.append(target)
        }
        return Array(Set(out)).sorted()
    }

    /// ⌥⌘↑/⌥⌘↓: a caret on the line above the topmost caret (or below the
    /// bottommost) at its column; nil when there is no such line.
    static func addAdjacent(_ carets: [NSRange], by step: Int, in text: NSString) -> Int? {
        let sorted = normalize(carets)
        guard let edge = step < 0 ? sorted.first.map({ $0.location }) : sorted.last.map({ NSMaxRange($0) }) else { return nil }
        let place = lineAndColumn(edge, in: text)
        return index(line: place.line + step, column: place.column, in: text)
    }
}
