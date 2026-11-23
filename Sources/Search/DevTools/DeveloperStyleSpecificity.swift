import Foundation

/// A selector's specificity per Selectors Level 4, as Chrome DevTools shows
/// it when a selector in Styles is hovered: "Specificity: (a,b,c)".
/// a counts ids; b classes, attribute selectors and pseudo-classes; c type
/// selectors and pseudo-elements. :is(), :not() and :has() take their most
/// specific argument, :where() counts nothing, :nth-child(An+B of S) adds
/// S's, and the legacy single-colon pseudo-elements (:before) count as
/// elements. The universal selector and combinators count nothing.
struct DeveloperStyleSpecificity: Comparable, Hashable {
    var a = 0
    var b = 0
    var c = 0

    static let zero = Self()

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.a, lhs.b, lhs.c) < (rhs.a, rhs.b, rhs.c)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(a: lhs.a + rhs.a, b: lhs.b + rhs.b, c: lhs.c + rhs.c)
    }

    /// "(a,b,c)", as Chrome writes it.
    var text: String { "(\(a),\(b),\(c))" }

    /// The specificity of one complex selector; for a list, its most
    /// specific member.
    static func of(_ selector: String) -> Self {
        var parser = Parser(Array(selector))
        return parser.list().max() ?? .zero
    }

    /// Each selector of a list beside its specificity, in order.
    static func components(of selectorList: String) -> [(selector: String, specificity: Self)] {
        split(selectorList).map { ($0, of($0)) }
    }

    /// The tooltip on a Styles selector: one line per selector of a list.
    static func tooltip(for selectorList: String) -> String {
        let parts = components(of: selectorList)
        guard parts.count > 1 else { return "Specificity: " + of(selectorList).text }
        return parts.map { $0.selector + " — Specificity: " + $0.specificity.text }.joined(separator: "\n")
    }

    /// A selector list split at its top-level commas, each part trimmed.
    static func split(_ selectorList: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in selectorList {
            if escaped {
                escaped = false
                current.append(character)
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    /// CSS 2's pseudo-elements, still written with one colon.
    private static let legacyPseudoElements: Set<String> = ["before", "after", "first-line", "first-letter"]
    /// Pseudo-classes whose specificity is their most specific argument's.
    private static let matchesAny: Set<String> = ["is", "not", "has", "matches", "-webkit-any", "-moz-any"]

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        private var current: Character? { index < characters.count ? characters[index] : nil }
        private func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        /// A selector list up to the closing parenthesis (left for the
        /// caller) or the end: one specificity per complex selector.
        mutating func list() -> [DeveloperStyleSpecificity] {
            var result: [DeveloperStyleSpecificity] = []
            var total = DeveloperStyleSpecificity.zero
            while let character = current {
                switch character {
                case ")":
                    result.append(total)
                    return result
                case ",":
                    result.append(total)
                    total = .zero
                    index += 1
                case "#":
                    index += 1
                    _ = name()
                    total.a += 1
                case ".":
                    index += 1
                    _ = name()
                    total.b += 1
                case "[":
                    skipBracket()
                    total.b += 1
                case ":":
                    index += 1
                    total = total + pseudo()
                case "\"", "'":
                    skipString()
                case "/" where peek(1) == "*":
                    skipComment()
                case "|":
                    // A namespace bar (*|a, |a) or the column combinator (||).
                    index += 1
                default:
                    if Self.startsName(character, next: peek(1)) {
                        _ = name()
                        // ns|type: the namespace prefix counts nothing.
                        if current == "|", peek(1) != "=", peek(1) != "|" {
                            index += 1
                        } else {
                            total.c += 1
                        }
                    } else {
                        // *, &, combinators and whitespace.
                        index += 1
                    }
                }
            }
            result.append(total)
            return result
        }

        /// After a colon: a pseudo-class or (after a second) pseudo-element.
        private mutating func pseudo() -> DeveloperStyleSpecificity {
            if current == ":" {
                index += 1
                let pseudoName = name().lowercased()
                var value = DeveloperStyleSpecificity(c: 1)
                if current == "(" {
                    index += 1
                    let inner = list()
                    close()
                    // ::slotted(x) adds its argument's (CSS Scoping).
                    if pseudoName == "slotted" { value = value + (inner.max() ?? .zero) }
                }
                return value
            }
            let pseudoName = name().lowercased()
            guard current == "(" else {
                return DeveloperStyleSpecificity.legacyPseudoElements.contains(pseudoName)
                    ? DeveloperStyleSpecificity(c: 1) : DeveloperStyleSpecificity(b: 1)
            }
            index += 1
            switch pseudoName {
            case _ where DeveloperStyleSpecificity.matchesAny.contains(pseudoName):
                let inner = list()
                close()
                return inner.max() ?? .zero
            case "where":
                _ = list()
                close()
                return .zero
            case "nth-child", "nth-last-child":
                let selectors = nthSelectors()
                close()
                return DeveloperStyleSpecificity(b: 1) + (selectors?.max() ?? .zero)
            case "host", "host-context":
                let inner = list()
                close()
                return DeveloperStyleSpecificity(b: 1) + (inner.max() ?? .zero)
            default:
                skipArguments()
                return DeveloperStyleSpecificity(b: 1)
            }
        }

        /// An+B, then the selectors after "of" if there are any.
        private mutating func nthSelectors() -> [DeveloperStyleSpecificity]? {
            while let character = current, character != ")" {
                if Self.startsName(character, next: peek(1)) {
                    let word = name()
                    if word.lowercased() == "of" { return list() }
                } else {
                    index += 1
                }
            }
            return nil
        }

        private mutating func close() {
            if current == ")" { index += 1 }
        }

        /// Past a function's arguments and its closing parenthesis.
        private mutating func skipArguments() {
            var depth = 1
            while let character = current {
                switch character {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { index += 1; return }
                case "\"", "'":
                    skipString()
                    continue
                case "\\":
                    index += 1
                default: break
                }
                index += 1
            }
        }

        private mutating func skipBracket() {
            index += 1
            while let character = current {
                switch character {
                case "]":
                    index += 1
                    return
                case "\"", "'":
                    skipString()
                    continue
                case "\\":
                    index += 1
                default: break
                }
                index += 1
            }
        }

        private mutating func skipString() {
            guard let open = current else { return }
            index += 1
            while let character = current {
                index += 1
                if character == "\\" { index += 1; continue }
                if character == open { return }
            }
        }

        private mutating func skipComment() {
            index += 2
            while current != nil {
                if current == "*", peek(1) == "/" { index += 2; return }
                index += 1
            }
        }

        /// An identifier, escapes included.
        private mutating func name() -> String {
            var output = ""
            while let character = current {
                if character == "\\" {
                    index += 1
                    guard let escaped = current else { break }
                    if escaped.isHexDigit {
                        var hex = ""
                        while let digit = current, digit.isHexDigit, hex.count < 6 {
                            hex.append(digit)
                            index += 1
                        }
                        if let space = current, space.isWhitespace { index += 1 }
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            output.append(Character(scalar))
                        }
                    } else {
                        output.append(escaped)
                        index += 1
                    }
                } else if Self.isNameCharacter(character) {
                    output.append(character)
                    index += 1
                } else {
                    break
                }
            }
            return output
        }

        static func isNameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
                || !(character.isASCII)
        }

        static func startsName(_ character: Character, next: Character?) -> Bool {
            if character == "\\" { return true }
            if character == "-" { return next.map { isNameCharacter($0) || $0 == "\\" } ?? false }
            return character.isLetter || character == "_" || !character.isASCII
        }
    }
}
