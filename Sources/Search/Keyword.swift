import Foundation

// A shortcut typed before the words: "yt cats" goes straight to YouTube's
// search, whatever the default engine is. Firefox calls these keyword
// bookmarks; there is no bookmark here, only the word and where it sends you.

struct Keyword: Codable, Identifiable, Equatable {
    let id: UUID
    var keyword: String
    var template: String

    init(id: UUID = UUID(), keyword: String = "", template: String = "") {
        self.id = id
        self.keyword = keyword
        self.template = template
    }

    /// What a row calls this: the site's own name, stood in for by its host,
    /// the same way Engine.name(custom:) does for the one default engine.
    var name: String { Engine.bareHost(of: template) ?? template }

    /// `typed` starts with this keyword, a space, and something after it —
    /// the words to search with. Nil if the keyword is unset, there's no
    /// space, the word before it doesn't match, or nothing follows.
    private func matches(_ typed: String) -> String? {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, let space = typed.firstIndex(of: " ") else { return nil }
        guard typed[..<space].caseInsensitiveCompare(word) == .orderedSame else { return nil }
        let rest = typed[typed.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// The first keyword in the list that `typed` names, and the words to
    /// search it with — or nothing, if none of them were asked for. One whose
    /// address wouldn't be saved today is passed over rather than followed.
    static func match(_ typed: String, in keywords: [Keyword]) -> (Keyword, String)? {
        for keyword in keywords where accepts(keyword.template) {
            if let rest = keyword.matches(typed) { return (keyword, rest) }
        }
        return nil
    }

    /// An address a keyword may send its words to: http or https, one site
    /// whatever is searched for, and a single %s in the path, query or
    /// fragment. Anywhere else, in the host or before an @, the words would
    /// decide where you end up rather than what you look for there.
    static func accepts(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Engine.accepts(trimmed),
              trimmed.components(separatedBy: "%s").count == 2,
              let parts = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: mark))
        else { return false }
        return [parts.percentEncodedPath, parts.percentEncodedQuery, parts.percentEncodedFragment]
            .contains { $0?.contains(mark) == true }
    }

    private static let mark = "SEARCHWORDSGOHERE"

    /// Why `word` and `template` can't be saved alongside `keywords` yet, in
    /// a line Settings can show — or nil when they can.
    static func problem(word: String, template: String, among keywords: [Keyword]) -> String? {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty { return "A word to type first, like yt" }
        if word.contains(where: \.isWhitespace) { return "One word, with no spaces in it" }
        if let taken = keywords.first(where: { $0.keyword.caseInsensitiveCompare(word) == .orderedSame }) {
            return "\(taken.keyword) already goes to \(taken.name)"
        }
        guard accepts(template) else {
            return "An http or https address with %s once, where the words go"
        }
        return nil
    }
}
