import AppKit

/// Matches live bindings against names in the code without evaluating it.
enum SourceInlineValues {
    struct Binding: Equatable, Sendable {
        let start: Int
        let value: String
    }

    struct Request: Equatable, Sendable {
        let displayID: Int
        let start: Int
        let throughLine: Int
        let jsx: Bool
        /// The nearest scope first, then any enclosing scopes with the same name.
        let bindings: [String: [Binding]]
        /// The paused place, as an offset in the text shown.
        var paused: Int? = nil

        func annotations(in text: String, lineStarts: [Int]) -> [Int: String] {
            guard lineStarts.indices.contains(throughLine - 1), !bindings.isEmpty else { return [:] }
            let units = Array(text.utf16)
            let end = throughLine < lineStarts.count ? lineStarts[throughLine] : units.count
            guard start >= 0, start < end, end <= units.count else { return [:] }
            return units.withUnsafeBufferPointer { source in
                let lexemes = JSLexer.lex(source, start: start, end: end, jsx: jsx).filter { !$0.isComment }
                var annotations: [Int: String] = [:]
                var line = lineStarts.firstIndex { $0 > start } ?? lineStarts.count
                var names = Set<String>()
                var text = ""
                var full = false

                func token(_ index: Int, is punctuator: String) -> Bool {
                    guard lexemes.indices.contains(index), lexemes[index].kind == .punctuator else { return false }
                    let token = lexemes[index]
                    return source[token.start..<token.end].elementsEqual(punctuator.utf16)
                }
                let shadows = SourceInlineValues.shadows(lexemes, in: source, paused: paused)

                for (index, lexeme) in lexemes.enumerated() where lexeme.kind == .identifier || lexeme.kind == .keyword {
                    while line < throughLine, lineStarts[line] <= lexeme.start {
                        if !text.isEmpty { annotations[line] = text }
                        line += 1
                        names.removeAll(keepingCapacity: true)
                        text = ""
                        full = false
                    }
                    guard !full, !token(index - 1, is: "."), !token(index - 1, is: "?.") else { continue }
                    if token(index + 1, is: ":"), token(index - 1, is: "{") || token(index - 1, is: ",") { continue }
                    let name = String(decoding: source[lexeme.start..<lexeme.end], as: UTF16.self)
                    if shadows.contains(where: { $0.range.contains(lexeme.start) && $0.names.contains(name) }) { continue }
                    guard let binding = bindings[name]?.first(where: { $0.start <= lexeme.start }),
                          names.insert(name).inserted else { continue }
                    let value = binding.value.components(separatedBy: .newlines).joined(separator: " ")
                    let addition = (text.isEmpty ? "" : ", ") + name + " = " + value
                    if text.count + addition.count > 80 {
                        text = String((text + addition).prefix(79)) + "…"
                        full = true
                    } else {
                        text += addition
                    }
                }
                if !text.isEmpty { annotations[line] = text }
                return annotations
            }
        }
    }

    /// Functions nested in the lexed range, with their parameter names:
    /// inside one, those names are its own, not the paused frame's.
    static func shadows(_ lexemes: [JSLexeme], in source: UnsafeBufferPointer<UInt16>,
                        paused: Int?) -> [(names: Set<String>, range: Range<Int>)] {
        func token(_ index: Int, is punctuator: String) -> Bool {
            guard lexemes.indices.contains(index), lexemes[index].kind == .punctuator else { return false }
            return source[lexemes[index].start..<lexemes[index].end].elementsEqual(punctuator.utf16)
        }
        // Each bracket's partner, by index.
        var partner = [Int](repeating: -1, count: lexemes.count)
        var open: [Int] = []
        for index in lexemes.indices where lexemes[index].kind == .punctuator {
            if token(index, is: "(") || token(index, is: "{") || token(index, is: "[") {
                open.append(index)
            } else if token(index, is: ")") || token(index, is: "}") || token(index, is: "]"), let first = open.popLast() {
                partner[first] = index
                partner[index] = first
            }
        }
        var shadows: [(names: Set<String>, range: Range<Int>)] = []
        for index in lexemes.indices {
            let params: ClosedRange<Int>
            let body: Int
            let kind = lexemes[index].kind
            if kind == .keyword || kind == .identifier,
               source[lexemes[index].start..<lexemes[index].end].elementsEqual("function".utf16) {
                var paren = index + 1
                if lexemes.indices.contains(paren), lexemes[paren].kind == .identifier { paren += 1 }
                guard token(paren, is: "("), partner[paren] > paren else { continue }
                params = paren...partner[paren]
                body = partner[paren] + 1
            } else if token(index, is: "=>"), index > 0 {
                if token(index - 1, is: ")"), partner[index - 1] >= 0 {
                    params = partner[index - 1]...(index - 1)
                } else if lexemes[index - 1].kind == .identifier {
                    params = (index - 1)...(index - 1)
                } else {
                    continue
                }
                body = index + 1
            } else {
                continue
            }
            guard lexemes.indices.contains(body) else { continue }
            // A braced body ends at its brace; an expression body before
            // the comma, semicolon or bracket that closes around it.
            var last = body
            if token(body, is: "{") {
                guard partner[body] > body else { continue }
                last = partner[body]
            } else {
                var next = body
                while lexemes.indices.contains(next), !token(next, is: ","), !token(next, is: ";"),
                      partner[next] < 0 || partner[next] > next {
                    last = max(next, partner[next])
                    next = last + 1
                }
                // Still open where the range stops: it may be the paused one.
                guard lexemes.indices.contains(next) else { continue }
            }
            let range = lexemes[params.lowerBound].start..<lexemes[last].end
            // The paused function itself, closing on the paused line.
            if let paused, range.contains(paused) { continue }
            var names = Set<String>()
            for item in params where lexemes[item].kind == .identifier && !token(item - 1, is: ".") {
                names.insert(String(decoding: source[lexemes[item].start..<lexemes[item].end], as: UTF16.self))
            }
            if !names.isEmpty { shadows.append((names, range)) }
        }
        return shadows
    }

    /// The editor's request for the top frame's values while `document`
    /// shows the file it is paused in: names from the local scope's start
    /// through the paused line, each with the nearest scope's value.
    @MainActor static func request(for document: SourceDocument, debugger: DeveloperDebugger,
                                   sourceMaps: DeveloperSourceMaps) -> Request? {
        guard !document.formatting, let frame = debugger.pause?.frames.first,
              !debugger.inlineScopes.isEmpty else { return nil }
        let url = document.url
        let location: SourceBreakpoint
        let authored: Bool
        if let original = frame.original, DeveloperDebugger.sameScript(original.url, url) {
            location = SourceBreakpoint(line: original.line + 1, column: original.column)
            authored = true
        } else if DeveloperDebugger.sameScript(frame.url, url) {
            location = SourceBreakpoint(line: frame.line + 1, column: frame.column)
            authored = false
        } else {
            return nil
        }
        // The runtime's names are the compiled file's: an authored file
        // needs to know which authored name each one came from.
        let names = authored ? debugger.inlineNames : nil
        if authored, names == nil { return nil }

        let line = document.shownLine(forOriginal: location.line, column: location.column)
        let display = document.display
        guard display.lineStarts.indices.contains(line - 1) else { return nil }
        let pausedLineStart = display.lineStarts[line - 1]
        func offset(_ start: DeveloperDebugger.Scope.Start?) -> Int? {
            guard let start, start.scriptID == nil || start.scriptID == frame.scriptID else { return nil }
            var place = start.position
            if authored {
                guard let original = sourceMaps.original(url: frame.url, line: place.line - 1, column: place.column),
                      DeveloperDebugger.sameScript(original.url, url) else { return nil }
                place = SourceBreakpoint(line: original.line + 1, column: original.column)
            }
            // JSC's scope location can point into the scope's first line
            // (after a declaration's name), so the scope reads from that
            // line's start.
            let offset = document.shownOffset(forOriginal: place.line, column: place.column)
            let shown = document.shownLine(forOriginal: place.line, column: place.column)
            guard display.lineStarts.indices.contains(shown - 1) else { return offset }
            return min(offset, display.lineStarts[shown - 1])
        }

        let start = offset(frame.scopes.first { $0.kind == .local }?.start) ?? pausedLineStart
        var bindings: [String: [Binding]] = [:]
        for scope in debugger.inlineScopes {
            // JSC reports a function body's let and const as a block scope,
            // often with no start: those still read from the function's top,
            // as Chrome shows them. A catch binding starts at the paused line.
            let fallback = scope.kind == .catch ? pausedLineStart : start
            let bound = max(start, offset(scope.start) ?? fallback)
            for (name, value) in scope.values { bindings[name, default: []].append(.init(start: bound, value: value)) }
        }
        if let names { bindings = Self.authored(bindings, names: names) }
        let jsx: Bool
        if case .javascript(_, let acceptsJSX) = document.language { jsx = acceptsJSX } else { jsx = false }
        return .init(displayID: display.id, start: start, throughLine: line, jsx: jsx, bindings: bindings,
                     paused: document.shownOffset(forOriginal: location.line, column: location.column))
    }

    // MARK: Source-mapped names

    /// Which compiled identifier each authored one became, from the map's
    /// named segments whose authored place is from `start` through the
    /// end of `throughLine` (0-based, in `source`): the compiled text at a
    /// segment is the new name, the segment's name the authored one. An
    /// authored name that became two different ones maps to "", unknown.
    static func authoredNames(map: DeveloperSourceMap, generated text: String, source: String,
                              from start: (line: Int, column: Int), throughLine: Int) -> [String: String] {
        guard let source = map.sources.firstIndex(of: source) else { return [:] }
        let units = Array(text.utf16)
        let lineStarts = SourceLexing.lineStarts(text)
        var names: [String: String] = [:]
        for item in map.mappings {
            guard item.source == source, let name = item.name, map.names.indices.contains(name),
                  (item.originalLine, item.originalColumn) >= (start.line, start.column), item.originalLine <= throughLine,
                  lineStarts.indices.contains(item.generatedLine) else { continue }
            let first = lineStarts[item.generatedLine] + item.generatedColumn
            guard first < units.count, SourceLexing.isIDStart(units[first]) else { continue }
            var end = first + 1
            while end < units.count, SourceLexing.isIDPart(units[end]) { end += 1 }
            let generated = String(decoding: units[first..<end], as: UTF16.self)
            let authored = map.names[name]
            if let known = names[authored], known != generated { names[authored] = "" } else { names[authored] = generated }
        }
        return names
    }

    /// Runtime bindings filed under the authored names they came from. A
    /// compiled name another authored one became isn't kept as itself:
    /// the same text in the authored file is a different variable.
    static func authored(_ bindings: [String: [Binding]], names: [String: String]) -> [String: [Binding]] {
        let renamed = Set(names.filter { $0.key != $0.value && !$0.value.isEmpty }.values)
        var result: [String: [Binding]] = [:]
        for (name, list) in bindings where names[name] == nil && !renamed.contains(name) { result[name] = list }
        for (authored, generated) in names where !generated.isEmpty {
            if let list = bindings[generated] { result[authored] = list }
        }
        return result
    }
}

extension SourceTextView {
    /// An overlay keeps these hints out of selection, search and copied source.
    func drawInlineValues(in dirtyRect: NSRect) {
        guard !inlineValues.isEmpty, let layoutManager, let textContainer else { return }
        let source = string as NSString
        guard source.length > 0 else { return }
        let origin = textContainerOrigin
        let area = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
        guard glyphs.length > 0 else { return }
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.location != NSNotFound, characters.length > 0 else { return }
        let first = lineIndex(of: characters.location)
        let last = lineIndex(of: NSMaxRange(characters) - 1)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.codeFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]
        for index in first...last {
            // Not on a line folded away.
            guard !hiddenLines.contains(index), let annotation = inlineValues[index + 1] else { continue }
            let start = lineStarts[index]
            var end = index + 1 < lineStarts.count ? lineStarts[index + 1] : source.length
            while end > start, SourceLexing.isNewline(source.character(at: end - 1)) { end -= 1 }
            guard end > start else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: end - 1)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = used.maxX + origin.x + 12
            guard x < bounds.maxX - 4 else { continue }
            let slot = NSRect(x: x, y: used.minY + origin.y, width: bounds.maxX - x - 4, height: used.height)
            if slot.intersects(dirtyRect) { (annotation as NSString).draw(in: slot, withAttributes: attributes) }
        }
    }
}
