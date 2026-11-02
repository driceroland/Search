import Foundation

// Typos in the address field: a word with a letter wrong, missing or
// swapped still finds what it meant (#762). Only a fallback, ranked below
// exact matches.
//
// Works on bytes because it runs over the whole history on every key, and
// String's own search was several times slower.

enum Fuzzy {
    /// 1 if every word is in `text` as typed, 0 if one needed a typo
    /// forgiven, nil if one isn't there. Both are lowercased.
    static func match(_ typed: [[UInt8]], in text: String) -> Int? {
        var text = text
        return text.withUTF8 { text in
            var slipped = false
            for word in typed where !contains(text, word) {
                guard nearly(word, in: text) else { return nil }
                slipped = true
            }
            return slipped ? 0 : 1
        }
    }

    /// Whether a word in `text` starts with `typed`, allowing one typo, or
    /// two in long words. None under four letters, where a guess is noise.
    static func nearly(_ typed: [UInt8], in text: String) -> Bool {
        var text = text
        return text.withUTF8 { nearly(typed, in: $0) }
    }

    /// "dwn" for downloads: the letters in order, starting with the first.
    static func abbreviates(_ typed: some StringProtocol, _ word: some StringProtocol) -> Bool {
        guard let first = typed.first, word.first == first else { return false }
        var rest = typed.dropFirst()[...]
        for letter in word.dropFirst() where letter == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    private static func contains(_ text: UnsafeBufferPointer<UInt8>, _ word: [UInt8]) -> Bool {
        word.withUnsafeBytes { memmem(text.baseAddress, text.count, $0.baseAddress, $0.count) != nil }
    }

    /// Letters and digits, and anything outside ASCII.
    private static func inWord(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func nearly(_ typed: [UInt8], in text: UnsafeBufferPointer<UInt8>) -> Bool {
        let allowed = typed.count < 4 ? 0 : typed.count < 8 ? 1 : 2
        guard allowed > 0 else { return false }
        // Edit distance to the start of each word, where swapping two
        // letters counts as one. Rows are reused across words.
        let width = typed.count + allowed + 1
        var before = [Int](repeating: 0, count: width)
        var above = before
        var row = before
        var start = 0
        while start < text.count {
            guard inWord(text[start]) else { start += 1; continue }
            var end = start
            while end < text.count, inWord(text[end]) { end += 1 }
            defer { start = end }
            let word = UnsafeBufferPointer(rebasing: text[start..<end])
            // People rarely get the first letter wrong, so require it (or a
            // swap with the second). This skips most words cheaply.
            guard word.count >= 2, word.count >= typed.count - allowed,
                  word[0] == typed[0] || (word[0] == typed[1] && word[1] == typed[0])
            else { continue }
            let columns = min(word.count, width - 1)
            for j in 0...columns { above[j] = j }
            var far = false
            for i in 1...typed.count {
                row[0] = i
                var least = i
                for j in 1...columns {
                    var best = min(above[j] + 1, row[j - 1] + 1, above[j - 1] + (typed[i - 1] == word[j - 1] ? 0 : 1))
                    if i > 1, j > 1, typed[i - 1] == word[j - 2], typed[i - 2] == word[j - 1] {
                        best = min(best, before[j - 2] + 1)
                    }
                    row[j] = best
                    least = min(least, best)
                }
                // Already too many typos.
                if least > allowed { far = true; break }
                (before, above, row) = (above, row, before)
            }
            if !far, above[1...columns].contains(where: { $0 <= allowed }) { return true }
        }
        return false
    }
}
