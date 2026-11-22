import Foundation

enum Registrable {
    static func domain(of host: String, isSuffix: ((String) -> Bool)?) -> String {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = name.split(separator: ".").map(String.init)
        let address = name.contains(":") || labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard let isSuffix, !address, labels.count > 1, !isSuffix(name) else { return name }
        for count in stride(from: labels.count - 1, through: 1, by: -1)
        where isSuffix(labels.suffix(count).joined(separator: ".")) {
            return labels.suffix(count + 1).joined(separator: ".")
        }
        return name
    }

    /// Whether two hosts are one site: the same host, or the same
    /// registrable domain (idmsa.apple.com and account.apple.com). Never for
    /// an address, nor when the domain couldn't be worked out.
    static func sameSite(_ one: String, _ other: String, isSuffix: ((String) -> Bool)?) -> Bool {
        let a = one.lowercased(), b = other.lowercased()
        if a == b { return true }
        let left = domain(of: a, isSuffix: isSuffix)
        return left.contains(".") && left == domain(of: b, isSuffix: isSuffix)
    }

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk.
    static func of(_ host: String) -> String {
        domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    /// The host of an address typed or exported as text, without "www.":
    /// a website's, and nothing else. Empty for anything that is not an
    /// http or https address (an Android app's name in an export, say).
    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased()
        else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
