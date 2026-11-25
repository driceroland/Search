import Foundation

/// Chrome's Settings › Preferences › Sources options for the code editor,
/// kept in UserDefaults; the Settings view binds them with @AppStorage.
/// Each defaults to Chrome's default.
enum DeveloperSourcesPreferences {
    /// "Code folding": off.
    static let codeFoldingKey = "DeveloperSourcesCodeFolding"
    /// "Display variable values inline while debugging": on.
    static let inlineValuesKey = "DeveloperSourcesInlineValues"
    /// "Detect indentation": on.
    static let detectIndentationKey = "DeveloperSourcesDetectIndentation"
    /// "Default indentation": 4 spaces. One of `indentationChoices`' values.
    static let defaultIndentationKey = "DeveloperSourcesDefaultIndentation"
    /// "Tab moves focus": off.
    static let tabMovesFocusKey = "DeveloperSourcesTabMovesFocus"
    /// "Automatically reveal files in sidebar": on.
    static let autoRevealKey = "DeveloperSourcesAutoReveal"
    /// "Search in anonymous and content scripts": off.
    static let searchContentScriptsKey = "DeveloperSourcesSearchContentScripts"
    /// "Allow scrolling past end of file": on.
    static let scrollPastEndKey = "DeveloperSourcesScrollPastEnd"

    /// Default indentation's menu, as Chrome words it.
    struct IndentationChoice: Identifiable {
        let title: String
        let value: String
        var id: String { value }
    }

    static let indentationChoices = [
        IndentationChoice(title: "2 spaces", value: "  "), IndentationChoice(title: "4 spaces", value: "    "),
        IndentationChoice(title: "8 spaces", value: "        "), IndentationChoice(title: "Tab character", value: "\t"),
    ]
    static let defaultIndentation = "    "

    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = DevDefaults.store) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// The indent the editor's Tab key puts in for a text: the one it
    /// uses already, when Detect indentation is on and it has one, else
    /// the default.
    static func indentUnit(for text: String, in defaults: UserDefaults = DevDefaults.store) -> String {
        let saved = defaults.string(forKey: defaultIndentationKey)
        let fallback = saved.flatMap { value in indentationChoices.contains { $0.value == value } ? value : nil }
            ?? defaultIndentation
        return SourceIndentation.unit(for: text, detect: bool(detectIndentationKey, default: true, in: defaults),
                                      fallback: fallback)
    }
}

/// Telling a file's indentation from its lines, as Chrome's editor does
/// for Detect indentation.
enum SourceIndentation {
    /// A tab, or 2 to 8 spaces: the step most lines indent by from the one
    /// before; nil when the lines don't say.
    static func detect(_ text: String, maxLines: Int = 1_000) -> String? {
        var tabs = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var seen = 0
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            seen += 1
            if seen > maxLines { break }
            guard let first = line.first else { continue }
            if first == "\t" {
                tabs += 1
                continue
            }
            let spaces = line.prefix { $0 == " " }.count
            // Blank lines say nothing.
            if spaces == line.count { continue }
            let step = abs(spaces - previous)
            previous = spaces
            // One space is a comment's ` * `, not an indent.
            if step >= 2, step <= 8 { steps[step, default: 0] += 1 }
        }
        let best = steps.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
        if tabs > 0, tabs >= best?.value ?? 0 { return "\t" }
        return best.map { String(repeating: " ", count: $0.key) }
    }

    static func unit(for text: String, detect: Bool, fallback: String) -> String {
        guard detect, let detected = self.detect(text) else { return fallback }
        return detected
    }

    /// What Tab inserts at a column (0-based): a tab, or the spaces to the
    /// next indent stop.
    static func insertion(unit: String, column: Int) -> String {
        guard unit != "\t", !unit.isEmpty else { return "\t" }
        let width = unit.count
        return String(repeating: " ", count: width - max(0, column) % width)
    }
}
