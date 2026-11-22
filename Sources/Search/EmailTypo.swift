import Foundation

// "Did you mean …?" for the news-by-email field (OptIn.swift): a likely typo
// in the domain (gmail.con, gnail.com, studio.cmo) gives the corrected
// address; anything else, including every real domain not listed here,
// gives nil. Worked out on the Mac: the address is never sent anywhere to be
// checked, and never corrected without a click. The same rules as the
// site's src/email-typo.js; keep the two in step.

enum EmailTypo {
    static let providers = [
        "gmail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "yahoo.com", "proton.me", "protonmail.com", "pm.me", "fastmail.com",
        "hey.com", "aol.com", "gmx.com", "web.de", "qq.com", "163.com",
    ]

    /// Real providers a letter or two away from one above: never "corrected".
    static let alsoReal: Set<String> = ["mail.com", "email.com", "ymail.com", "foxmail.com", "googlemail.com", "126.com", "msn.com", "gmx.de", "gmx.net"]

    static let tlds = ["com", "co", "net", "org", "io", "me", "app", "dev", "fr", "de", "uk"]

    static let slips = [
        "gmail.con": "gmail.com", "gmail.cin": "gmail.com", "gnail.com": "gmail.com",
        "gmial.com": "gmail.com", "gmal.com": "gmail.com", "gamil.com": "gmail.com",
        "icloud.con": "icloud.com", "iclod.com": "icloud.com", "outlok.com": "outlook.com",
        "hotmial.com": "hotmail.com", "yaho.com": "yahoo.com",
    ]

    static let tldSlips = ["col": "com", "cmo": "com", "vom": "com"]

    /// Damerau-Levenshtein distance (optimal string alignment).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// How far a typed domain may be from a provider: short names are too
    /// close to real domains to guess at.
    private static func reach(_ provider: String) -> Int {
        provider.count >= 9 ? 2 : provider.count >= 7 ? 1 : 0
    }

    private static func fix(_ domain: String) -> String? {
        if providers.contains(domain) || alsoReal.contains(domain) { return nil }
        if let slip = slips[domain] { return slip }
        var best: String?
        var bestDistance = Int.max
        for provider in providers {
            let n = distance(domain, provider)
            if n > 0, n <= reach(provider), n < bestDistance {
                best = provider
                bestDistance = n
            }
        }
        if let best { return best }
        // Not a provider: only the ending. Two-letter endings are left
        // alone, every country has one and they're all a letter apart.
        guard let dot = domain.lastIndex(of: ".") else { return nil }
        let name = String(domain[..<dot])
        let tld = String(domain[domain.index(after: dot)...])
        if name.isEmpty || tlds.contains(tld) { return nil }
        if let slip = tldSlips[tld] { return "\(name).\(slip)" }
        if tld.count < 3 { return nil }
        guard let near = tlds.first(where: { $0.count >= 3 && distance(tld, $0) == 1 }) else { return nil }
        return "\(name).\(near)"
    }

    /// The address it was likely meant to be, or nil.
    static func suggestion(for email: String) -> String? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = email.lastIndex(of: "@"), at > email.startIndex else { return nil }
        let local = String(email[..<at])
        let domain = String(email[email.index(after: at)...]).lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
        guard let fixed = fix(domain), fixed != domain else { return nil }
        return "\(local)@\(fixed)"
    }

    /// A press of Join: the line to show instead of sending, or nil to send
    /// as typed. The line shows once for what was typed; the next press with
    /// the same address sends it.
    static func hold(_ typed: String, shownFor: String?) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != shownFor else { return nil }
        return suggestion(for: typed)
    }
}
