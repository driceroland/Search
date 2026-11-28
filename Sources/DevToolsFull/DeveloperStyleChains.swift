import Foundation

// Chrome 138's Styles hovers: a var() followed through every custom
// property it leads to, and calc(), min(), max() and clamp() taken apart
// into the sub-expressions the page evaluates one by one.
extension DeveloperStyleEditing {
    /// A custom property's winning declaration, and where it is.
    struct Declared: Equatable {
        let value: String
        var place: String? = nil
    }

    /// "var(--name, fallback)" as its name and fallback (nil without a comma).
    static func variableParts(_ reference: String) -> (name: String, fallback: String?)? {
        let text = reference.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("var("), text.hasSuffix(")") else { return nil }
        let parts = text.dropFirst(4).dropLast().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard name.hasPrefix("--") else { return nil }
        return (name, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil)
    }

    /// The hover on a var() reference: each custom property it leads to,
    /// indented a level per var(), with its value and where it is declared;
    /// fallbacks taken where a property is unset or in a cycle; then what
    /// it all comes to.
    static func variableChain(_ reference: String, declared: (String) -> Declared?) -> [String] {
        var lines: [String] = []
        func substitute(_ value: String, depth: Int, visiting: [String]) -> String? {
            var output = ""
            for segment in segments(value) {
                guard depth < 32, lines.count < 160, output.utf8.count < 16_384 else {
                    lines.append("The variable chain exceeds the preview limit.")
                    return nil
                }
                guard segment.variable != nil, let parts = variableParts(segment.text) else {
                    output += segment.text
                    continue
                }
                let indent = String(repeating: "  ", count: depth)
                if visiting.contains(parts.name) {
                    lines.append(indent + "\(parts.name) is in a cycle")
                } else if let found = declared(parts.name) {
                    lines.append(indent + "\(parts.name): \(found.value)" + (found.place.map { " — \($0)" } ?? ""))
                    if let resolved = substitute(found.value, depth: depth + 1, visiting: visiting + [parts.name]) {
                        output += resolved
                        continue
                    }
                } else {
                    lines.append(indent + "\(parts.name) is not defined")
                }
                guard let fallback = parts.fallback else { return nil }
                lines.append(indent + "Fallback: \(fallback)")
                guard let resolved = substitute(fallback, depth: depth + 1, visiting: visiting) else { return nil }
                output += resolved
            }
            return output
        }
        let result = substitute(reference, depth: 0, visiting: [])
        lines.append(result.map { "Value: \($0.trimmingCharacters(in: .whitespaces))" } ?? "Invalid at computed-value time")
        return lines
    }

    private static let mathFunctions: Set<String> = ["calc", "min", "max", "clamp", ""]

    /// The sub-expressions of a value's calc(), min(), max() and clamp()
    /// (and bracketed groups in them) to evaluate, innermost first, each
    /// function after its parts: min/max/clamp's arguments and calc's terms
    /// either side of + and -. Plain numbers and px lengths are left out.
    static func mathSteps(_ value: String) -> [String] {
        var steps: [String] = []
        func add(_ step: String) {
            let step = step.trimmingCharacters(in: .whitespaces)
            if !step.isEmpty, step.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)(px)?$"#, options: .regularExpression) == nil,
               !steps.contains(step) { steps.append(step) }
        }
        func walk(_ text: String) {
            for call in calls(in: text) {
                guard mathFunctions.contains(call.name) else { walk(call.arguments); continue }
                let parts = topLevel(call.arguments, splitting: call.name == "calc" || call.name.isEmpty ? [" + ", " - "] : [","])
                for part in parts {
                    walk(part)
                    if parts.count > 1 { add(part) }
                }
                add(call.text)
            }
        }
        guard functionNames(value).contains(where: { $0 != "" && mathFunctions.contains($0) }) else { return [] }
        walk(value)
        return steps
    }

    /// The outermost function calls and bracketed groups in `text`:
    /// "a(b(c)) (d)" as a(b(c)) and (d), names lowercased ("" for a group).
    static func calls(in text: String) -> [(name: String, arguments: String, text: String)] {
        let characters = Array(text)
        var found: [(name: String, arguments: String, text: String)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "(" else { index += 1; continue }
            var start = index
            while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber || characters[start - 1] == "-" {
                start -= 1
            }
            var depth = 0
            var end = characters.count - 1
            for position in index..<characters.count {
                if characters[position] == "(" { depth += 1 }
                if characters[position] == ")" { depth -= 1; if depth == 0 { end = position; break } }
            }
            found.append((name: String(characters[start..<index]).lowercased(),
                           arguments: String(characters[(index + 1)..<max(index + 1, end)]),
                           text: String(characters[start...end])))
            index = end + 1
        }
        return found
    }

    /// `text` cut at each separator outside brackets.
    static func topLevel(_ text: String, splitting separators: [String]) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        outer: while index < characters.count {
            let character = characters[index]
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 {
                for separator in separators where index + separator.count <= characters.count
                    && String(characters[index..<(index + separator.count)]) == separator {
                    parts.append(current)
                    current = ""
                    index += separator.count
                    continue outer
                }
            }
            current.append(character)
            index += 1
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The math hover's lines: each step the page could evaluate with its
    /// result, then the value the element uses.
    static func mathLines(_ steps: [String], results: [String?], used: String?) -> [String] {
        var lines = zip(steps, results).compactMap { step, result in result.map { "\(step) = \($0)" } }
        if !lines.isEmpty, let used { lines.append("Used value: \(used)") }
        return lines
    }

    /// A declaration an editor sets (the grid or flex editor's), where it
    /// already is in the rule, as Chrome edits it, else at the end; any
    /// repeats of it go. No value removes it.
    static func setting<T>(_ property: String, to added: [T], in properties: [T], name: (T) -> String) -> [T] {
        guard let at = properties.firstIndex(where: { name($0) == property }) else { return properties + added }
        return Array(properties[..<at]) + added + properties[at...].filter { name($0) != property }
    }
}
