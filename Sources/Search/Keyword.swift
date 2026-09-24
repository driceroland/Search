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

    /// `typed` starts with this keyword, a space, and something after it -
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
    /// search it with - or nothing, if none of them were asked for.
    static func match(_ typed: String, in keywords: [Keyword]) -> (Keyword, String)? {
        for keyword in keywords {
            if let rest = keyword.matches(typed) { return (keyword, rest) }
        }
        return nil
    }
}
