import Foundation

// What to do with words that aren't a place: ask Google.
//
// The field still tells an address from a phrase — typing a domain goes
// straight there, without a round trip through anyone's results page. Only
// what can't be a place gets searched.

enum Google {
    static let name = "Google"

    /// A place if it can be one, a search if it can't.
    static func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? url(for: typed)
    }

    static func url(for text: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        // Everything a query string can't carry raw, including the plus sign,
        // which would otherwise come out the far end as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = words.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://www.google.com/search?q=" + escaped)
    }
}
