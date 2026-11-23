import Foundation

// The Sources code editor's text commands, as Chrome DevTools' editor
// (CodeMirror) has them: ⌘/ toggles a comment, ⌘D selects the next
// occurrence of the selection, ⌃M goes to the matching bracket. Worked out
// on the text alone, apart from the view, so the tests can check them.
// Offsets and ranges are UTF-16, as NSTextView's.
enum SourceEditing {
    /// One replacement in the text, and the selection after it.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    /// What ⌘/ wraps code in: a line comment ("//") or a block's two ends.
    static func commentMarkers(_ language: SourceLanguage) -> (open: String, close: String)? {
        switch language {
        case .javascript: return (open: "//", close: "")
        case .css: return (open: "/*", close: "*/")
        case .html: return (open: "<!--", close: "-->")
        case .json, .plain: return nil
        }
    }

    // MARK: ⌘/

    /// ⌘/: comments out the lines the selection touches, or, when every
    /// one that holds code is commented already, takes the comments off.
    /// Line comments go in at the lines' shared indent, as CodeMirror puts
    /// them; a language with only block comments wraps the lines in one.
    static func toggleComment(_ text: String, selection: NSRange, language: SourceLanguage) -> Edit? {
        guard let markers = commentMarkers(language) else { return nil }
        let string = text as NSString
        let length = string.length
        let location = min(max(0, selection.location), length)
        var endPoint = min(length, max(location, NSMaxRange(selection)))
        // A selection ending at the very start of a line leaves that line out.
        if selection.length > 0, endPoint > location, string.character(at: endPoint - 1) == 10 { endPoint -= 1 }
        let first = string.lineRange(for: NSRange(location: location, length: 0))
        let last = string.lineRange(for: NSRange(location: endPoint, length: 0))
        let start = first.location
        var end = max(start, NSMaxRange(last))
        while end > start, string.character(at: end - 1) == 10 || string.character(at: end - 1) == 13 { end -= 1 }
        let original = NSRange(location: start, length: end - start)
        let block = string.substring(with: original)
        let lines = block.components(separatedBy: "\n")

        if markers.close.isEmpty {
            return toggleLineComment(lines, marker: markers.open, original: original, selection: selection)
        }
        return toggleBlockComment(block, open: markers.open, close: markers.close, original: original)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The spaces and tabs a line starts with, in UTF-16 units.
    static func indent(_ line: String) -> Int {
        let string = line as NSString
        var count = 0
        while count < string.length, string.character(at: count) == 32 || string.character(at: count) == 9 { count += 1 }
        return count
    }

    private static func toggleLineComment(_ lines: [String], marker: String, original: NSRange, selection: NSRange) -> Edit? {
        let filled = lines.filter { !isBlank($0) }
        guard !filled.isEmpty else { return nil }
        let markerLength = (marker as NSString).length
        let commented = filled.allSatisfy { line in
            let string = line as NSString
            return string.substring(from: indent(line)).hasPrefix(marker)
        }
        let shared = filled.map(indent).min() ?? 0
        var out: [String] = []
        // For a caret on a single line: where the change was and its size.
        var changeAt = 0, change = 0
        for line in lines {
            let string = line as NSString
            if isBlank(line) {
                out.append(line)
                continue
            }
            if commented {
                let at = indent(line)
                var cut = markerLength
                if at + cut < string.length, string.character(at: at + cut) == 32 { cut += 1 }
                out.append(string.replacingCharacters(in: NSRange(location: at, length: cut), with: ""))
                changeAt = at
                change = -cut
            } else {
                out.append(string.replacingCharacters(in: NSRange(location: shared, length: 0), with: marker + " "))
                changeAt = shared
                change = markerLength + 1
            }
        }
        let replacement = out.joined(separator: "\n")
        let newLength = (replacement as NSString).length
        let after: NSRange
        if selection.length == 0, lines.count == 1 {
            // The caret stays on the same code: after the change, it moves with it.
            let offset = selection.location - original.location
            let point: Int
            if change > 0 {
                point = offset >= changeAt ? offset + change : offset
            } else if offset >= changeAt - change {
                point = offset + change
            } else {
                point = min(offset, changeAt)
            }
            after = NSRange(location: original.location + min(max(0, point), newLength), length: 0)
        } else {
            after = NSRange(location: original.location, length: newLength)
        }
        return Edit(range: original, replacement: replacement, selection: after)
    }

    private static func toggleBlockComment(_ block: String, open: String, close: String, original: NSRange) -> Edit? {
        let string = block as NSString
        var lead = 0
        while lead < string.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: lead)) ?? " ") {
            lead += 1
        }
        guard lead < string.length else { return nil }
        var trail = string.length
        while trail > lead, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: trail - 1)) ?? " ") {
            trail -= 1
        }
        let prefix = string.substring(to: lead)
        let suffix = string.substring(from: trail)
        let code = string.substring(with: NSRange(location: lead, length: trail - lead))
        let openLength = (open as NSString).length, closeLength = (close as NSString).length
        let replacement: String
        let codeString = code as NSString
        if code.hasPrefix(open), code.hasSuffix(close), codeString.length >= openLength + closeLength {
            var inner = codeString.substring(with: NSRange(location: openLength, length: codeString.length - openLength - closeLength))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            replacement = prefix + inner + suffix
        } else {
            replacement = prefix + open + " " + code + " " + close + suffix
        }
        return Edit(range: original, replacement: replacement,
                    selection: NSRange(location: original.location, length: (replacement as NSString).length))
    }

    // MARK: ⌘D, ⌘U

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 95 || unit == 36  // _ and $
    }

    /// The word (letters, digits, _ and $) the caret is in or just after.
    static func wordRange(_ text: String, at offset: Int) -> NSRange? {
        let string = text as NSString
        let length = string.length
        var start = min(max(0, offset), length), end = start
        while start > 0, isWordUnit(string.character(at: start - 1)) { start -= 1 }
        while end < length, isWordUnit(string.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// ⌘D, as in Chrome: with only a caret, the word around it; with a
    /// selection, also the next place its text is, after the selections
    /// already made and round to the top. Nil when there is none left.
    static func addNextOccurrence(_ text: String, selections: [NSRange]) -> [NSRange]? {
        let chosen = selections.sorted { $0.location < $1.location }
        guard let last = chosen.last else { return nil }
        if chosen.count == 1, last.length == 0 {
            return wordRange(text, at: last.location).map { [$0] }
        }
        let string = text as NSString
        guard last.length > 0, NSMaxRange(last) <= string.length else { return nil }
        let needle = string.substring(with: last)
        let taken: (NSRange) -> Bool = { found in chosen.contains { NSIntersectionRange($0, found).length > 0 } }
        let after = chosen.map { NSMaxRange($0) }.max() ?? NSMaxRange(last)
        // After the last one, then from the top.
        for (from, to) in [(after, string.length), (0, string.length)] where to > from {
            var range = NSRange(location: from, length: to - from)
            while range.length > 0 {
                let found = string.range(of: needle, options: .literal, range: range)
                guard found.location != NSNotFound else { break }
                if !taken(found) { return chosen + [found] }
                let next = NSMaxRange(found)
                range = NSRange(location: next, length: max(0, to - next))
            }
        }
        return nil
    }

    // MARK: ⌃M

    private static let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]  // ( [ {

    /// ⌃M: the offset of the bracket matching the one at the caret (or
    /// just before it), counting nesting. Nil when there is none.
    static func matchingBracket(_ text: String, at caret: Int) -> Int? {
        let string = text as NSString
        let length = string.length
        let closers = Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key) })
        for at in [caret, caret - 1] where at >= 0 && at < length {
            let unit = string.character(at: at)
            if let closer = pairs[unit] {
                var depth = 0
                var index = at
                while index < length {
                    let current = string.character(at: index)
                    if current == unit { depth += 1 } else if current == closer {
                        depth -= 1
                        if depth == 0 { return index }
                    }
                    index += 1
                }
                return nil
            }
            if let opener = closers[unit] {
                var depth = 0
                var index = at
                while index >= 0 {
                    let current = string.character(at: index)
                    if current == unit { depth += 1 } else if current == opener {
                        depth -= 1
                        if depth == 0 { return index }
                    }
                    index -= 1
                }
                return nil
            }
        }
        return nil
    }
}
