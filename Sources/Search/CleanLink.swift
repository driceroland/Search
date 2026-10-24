import AppKit

/// Copy Clean Link: an address without the parameters that only say where
/// a click came from (#594). A short list, kept on purpose: a parameter
/// that might do something for the page stays, unknown ones stay, and so do
/// the others' order, their encoding and the part after #. An address that
/// carries a signature is copied as it is, since taking anything out of it
/// would break it. Nothing is looked up: it all happens here, on the text.
enum CleanLink {
    /// Names that track and do nothing else, on any site. `utm_` covers
    /// every one of Google Analytics' campaign tags.
    static let tracking: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid",
        "twclid", "ttclid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok",
    ]

    /// Names that track on some sites and may mean something on others: a
    /// YouTube or Spotify share's `si` is who shared it.
    static let trackingOn: [String: Set<String>] = [
        "si": ["youtube.com", "youtu.be", "spotify.com"],
    ]

    /// A signed address: S3, Google Cloud, CloudFront and the like.
    static let signatures: Set<String> = [
        "x-amz-signature", "x-goog-signature", "signature", "sig",
    ]

    /// The address without its tracking parameters, or the same address
    /// when there is nothing to take out or it can't be touched safely.
    static func clean(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.percentEncodedQuery, !query.isEmpty
        else { return url }
        let host = (parts.host ?? "").lowercased()
        let pieces = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        let names = pieces.map { piece -> String in
            let raw = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return (raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw).lowercased()
        }
        if names.contains(where: signatures.contains) { return url }
        let kept = zip(pieces, names).filter { !tracks($0.1, on: host) }.map(\.0)
        guard kept.count < pieces.count else { return url }
        parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return parts.url ?? url
    }

    static func tracks(_ name: String, on host: String) -> Bool {
        if name.hasPrefix("utm_") || tracking.contains(name) { return true }
        guard let sites = trackingOn[name] else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Into the clipboard, as Copy Address puts one there.
    static func copy(_ url: URL, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(clean(url).absoluteString, forType: .string)
    }

    /// What WebKit's own Copy Link just put in the clipboard, cleaned. Its
    /// address is read from the clipboard because only WebKit knows which
    /// link the right-click was on. WebKit may write it a moment later, so
    /// this waits for the clipboard to change, for a second at most.
    @MainActor static func rewrite(_ board: NSPasteboard = .general, since count: Int, tries: Int = 20) {
        guard board.changeCount != count else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { rewrite(board, since: count, tries: tries - 1) }
            }
            return
        }
        let text = board.string(forType: .URL) ?? board.string(forType: .string)
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        copy(url, to: board)
    }
}
