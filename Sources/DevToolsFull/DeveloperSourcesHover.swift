import AppKit

// Chrome's value popover in the Sources editor: while the debugger is
// paused, resting the pointer on a name or a member chain (`a.b.c`,
// `this.x`) for a moment evaluates it on the selected call frame and shows
// the value, objects as an expandable tree. Only what can be read without
// running code is offered: names and property chains, never a call or an
// index whose value would have to be computed.

/// What a hover over a line evaluates.
enum SourceHoverExpression {
    /// Words that aren't values. `this` is, and stays.
    static let keywords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "return", "static", "super", "switch", "throw", "true", "try",
        "typeof", "var", "void", "while", "with", "yield",
    ]

    /// The expression under a UTF-16 offset in a line of JavaScript: the
    /// name there, with the member chain before it, up to and including
    /// the hovered name — hovering `b` in `a.b.c` gives `a.b`, as Chrome
    /// evaluates it. Nil off a name, on a keyword or a number, or when the
    /// chain starts from a call or an index.
    static func expression(in line: String, at offset: Int) -> (start: Int, end: Int, text: String)? {
        let u = Array(line.utf16)
        guard offset >= 0, offset < u.count, isName(u[offset]) else { return nil }
        var start = offset
        while start > 0, isName(u[start - 1]) { start -= 1 }
        var end = offset
        while end < u.count, isName(u[end]) { end += 1 }
        guard let word = name(u, start, end) else { return nil }
        if keywords.contains(word) { return nil }
        // Walk left over `.name` and `?.name` links.
        while start > 0, u[start - 1] == 46 /* . */ {
            var dot = start - 1
            if dot > 0, u[dot - 1] == 63 /* ? */ { dot -= 1 }
            // `1.5`, `...spread` and a chain from a call or index are left alone.
            guard dot > 0 else { return nil }
            let before = u[dot - 1]
            if before == 41 /* ) */ || before == 93 /* ] */ || before == 46 /* . */ { return nil }
            guard isName(before) else { return nil }
            var previous = dot
            while previous > 0, isName(u[previous - 1]) { previous -= 1 }
            guard let link = name(u, previous, dot) else { return nil }
            if keywords.contains(link) { return nil }
            start = previous
        }
        let text = String(decoding: u[start..<end], as: UTF16.self)
        return (start, end, text)
    }

    /// A name's text, or nil for a number.
    private static func name(_ u: [UInt16], _ start: Int, _ end: Int) -> String? {
        guard start < end, !(48...57).contains(u[start]) else { return nil }
        return String(decoding: u[start..<end], as: UTF16.self)
    }

    private static func isName(_ c: UInt16) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 36
            || (c >= 0xAA && !(0x2000...0x206F).contains(c) && c != 0xA0 && c != 0xFEFF && c != 0x3000)
    }
}

extension SourceTextView {
    /// Token kinds a hover never evaluates: text and literals, not code.
    private static let notCode: Set<SourceTokenKind> = [
        .string, .stringSpecial, .comment, .number, .meta, .tag, .attribute, .attributeValue,
    ]

    /// The expression under a point, as a range in the text.
    func hoverTarget(at point: NSPoint) -> (range: NSRange, text: String)? {
        switch language {
        case .javascript, .html: break
        default: return nil
        }
        guard let layoutManager, let textContainer else { return nil }
        let text = string as NSString
        guard text.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < text.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -1, dy: 0).contains(local) else { return nil }
        if let kind = tokenKind(at: index), Self.notCode.contains(kind) { return nil }
        let line = lineIndex(of: index)
        let lineStart = lineStarts[line]
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        // A window around the pointer: a minified file is one long line.
        let low = max(lineStart, index - 400), high = min(lineEnd, index + 200)
        guard low < high else { return nil }
        let piece = text.substring(with: NSRange(location: low, length: high - low))
        guard let found = SourceHoverExpression.expression(in: piece, at: index - low) else { return nil }
        return (NSRange(location: low + found.start, length: found.end - found.start), found.text)
    }

    /// The pointer moved over the code: after 300 ms on an expression, its
    /// value; off it, the popover goes.
    func hover(at point: NSPoint) {
        guard actions?.paused == true, actions?.hoverValue != nil, window != nil else {
            closeHover()
            return
        }
        guard let target = hoverTarget(at: point) else {
            hoverTimer?.cancel()
            hoverTimer = nil
            if hoverPopover?.isShown == true { closeHoverSoon() } else { hoverRange = nil }
            return
        }
        if target.range == hoverRange, hoverPopover?.isShown == true || hoverTimer != nil { return }
        closeHover()
        hoverRange = target.range
        let work = DispatchWorkItem { [weak self] in self?.showHover(target) }
        hoverTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Leaving the expression: close unless the pointer went into the popover.
    private func closeHoverSoon() {
        let range = hoverRange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.hoverRange == range, let popover = self.hoverPopover, popover.isShown else { return }
            if let frame = popover.contentViewController?.view.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            if let window = self.window {
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                if let target = self.hoverTarget(at: point), target.range == range { return }
            }
            self.closeHover()
        }
    }

    private func showHover(_ target: (range: NSRange, text: String)) {
        hoverTimer = nil
        guard let evaluate = actions?.hoverValue else { return }
        hoverSerial += 1
        let serial = hoverSerial
        Task { @MainActor [weak self] in
            guard let controller = await evaluate(target.text, serial) else { return }
            guard let self, self.hoverSerial == serial, self.hoverRange == target.range, self.window != nil,
                  let layoutManager = self.layoutManager, let textContainer = self.textContainer else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: target.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += self.textContainerOrigin.x
            rect.origin.y += self.textContainerOrigin.y
            layoutManager.addTemporaryAttribute(.backgroundColor, value: SourceTheme.executionLine, forCharacterRange: target.range)
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .semitransient
            popover.animates = false
            self.hoverPopover = popover
            popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        }
    }

    func closeHover() {
        hoverTimer?.cancel()
        hoverTimer = nil
        if let range = hoverRange, NSMaxRange(range) <= (string as NSString).length {
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        hoverRange = nil
        hoverSerial += 1
        if let popover = hoverPopover {
            hoverPopover = nil
            popover.close()
        }
    }
}
