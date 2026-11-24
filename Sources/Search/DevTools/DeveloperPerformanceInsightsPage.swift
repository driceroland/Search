import Foundation

/// What the page said about itself as a recording stopped for the newer
/// Insights (DeveloperLiveMetrics.pageInfo): its viewport meta tag, its
/// images' sizes, its @font-face rules and how its LCP image was asked
/// for. Each is a string in the profile's `pageInfo`, the lists as JSON;
/// a recording made before these were read has none of them, and the
/// insights that need them are left out.
enum DeveloperPerformanceInsightsPage {
    /// The page's keys, as DeveloperPerformancePageTimings copies them into
    /// the recording.
    static let keys = ["viewport", "devicePixelRatio", "pageImages", "fontFaces", "lcpTag", "lcpLoading",
                       "lcpFetchPriority", "lcpPreloaded", "lcpInitiator", "charsetMeta"]
    /// The longest a value can be and be kept.
    static let limit = 400_000

    struct Image: Equatable {
        let src: String
        let naturalWidth: Double
        let naturalHeight: Double
        let displayedWidth: Double
        let displayedHeight: Double
    }

    struct FontFace: Equatable {
        let family: String
        /// Its font-display: "auto" when the rule doesn't say.
        let display: String
        let urls: [String]
    }

    private static func json(_ text: String?) -> Any? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func number(_ value: Any?) -> Double {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    /// The viewport meta tag's content: nil when the page wasn't asked,
    /// .some(nil) when it has none.
    static func viewport(_ info: [String: String]) -> String?? {
        guard let raw = info["viewport"] else { return nil }
        guard let value = json(raw) else { return .some(nil) }
        return .some(value as? String)
    }

    static func devicePixelRatio(_ info: [String: String]) -> Double {
        guard let value = info["devicePixelRatio"].flatMap(Double.init), value.isFinite, value > 0 else { return 1 }
        return value
    }

    static func images(_ info: [String: String]) -> [Image]? {
        guard info["pageImages"] != nil else { return nil }
        let list = json(info["pageImages"]) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let src = item["src"] as? String, !src.isEmpty else { return nil }
            return Image(src: src, naturalWidth: number(item["nw"]), naturalHeight: number(item["nh"]),
                         displayedWidth: number(item["dw"]), displayedHeight: number(item["dh"]))
        }
    }

    /// The document's `<meta charset>`, or `<meta http-equiv="Content-Type">`
    /// with a charset: what it names, and how many bytes into the markup
    /// it ends (-1 when that couldn't be told).
    struct CharsetMeta: Equatable {
        let charset: String
        let end: Int
    }

    /// The page's charset meta tag: nil when the page wasn't asked,
    /// .some(nil) when it has none.
    static func charsetMeta(_ info: [String: String]) -> CharsetMeta?? {
        guard let raw = info["charsetMeta"] else { return nil }
        guard let item = json(raw) as? [String: Any], let charset = item["charset"] as? String,
              !charset.trimmingCharacters(in: .whitespaces).isEmpty else { return .some(nil) }
        let end = (item["end"] as? NSNumber)?.intValue ?? -1
        return .some(CharsetMeta(charset: charset.trimmingCharacters(in: .whitespaces), end: end))
    }

    /// The charset a Content-Type header names, as `text/html; charset=utf-8`
    /// does; nil when it names none.
    static func charset(contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fontFaces(_ info: [String: String]) -> [FontFace]? {
        guard info["fontFaces"] != nil else { return nil }
        let list = json(info["fontFaces"]) as? [[String: Any]] ?? []
        return list.map { item in
            let display = (item["display"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let family = (item["family"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return FontFace(family: family, display: display.isEmpty ? "auto" : display,
                            urls: item["urls"] as? [String] ?? [])
        }
    }
}

// MARK: - Character set

extension DeveloperPerformanceInsights {
    /// How far into the markup a `<meta charset>` still counts: the bytes
    /// the HTML parser's encoding prescan reads, as Chrome's Character set
    /// insight and Lighthouse's charset audit allow.
    static let charsetPrescanBytes = 1_024

    /// devtools-frontend's CharacterSet: the page's document should name
    /// its character encoding, in its Content-Type header or in a
    /// `<meta charset>` within its first 1,024 bytes, or the browser may
    /// guess, re-parse the page, or show it garbled. Left out when the
    /// recording has neither the header nor the page's tags to judge by.
    static func characterSet(_ profile: Profile, page: URL? = nil) -> Insight? {
        let document = mainDocument(profile, page: page)
        let header = DeveloperPerformanceInsightsPage.charset(contentType: document?.contentType)
        let meta = DeveloperPerformanceInsightsPage.charsetMeta(profile.pageInfo)
        guard header != nil || meta != nil else { return nil }
        let found: DeveloperPerformanceInsightsPage.CharsetMeta? = meta ?? nil
        // A tag whose place couldn't be told (-1) is given the benefit of the doubt.
        let early = found.map { $0.end <= charsetPrescanBytes } ?? false
        let declared = header != nil || early
        var rows = [Row(id: 0, label: "Content-Type header", value: header ?? "No charset",
                        detail: document?.contentType, failing: !declared)]
        if meta != nil {
            let detail: String? = found.flatMap { found in found.end > charsetPrescanBytes
                ? "Ends at byte \(found.end.formatted()), past the first \(charsetPrescanBytes.formatted()) bytes" : nil }
            rows.append(Row(id: 1, label: "<meta charset>", value: found?.charset ?? "Missing", detail: detail,
                            failing: !declared))
        }
        let headline = header != nil ? "Declared in the Content-Type header"
            : early ? "Declared by <meta charset>"
            : found != nil ? "<meta charset> comes too late" : "No character set declared"
        return Insight(kind: .characterSet, title: "Declare a character set", verdict: declared ? .pass : .fail,
                       explanation: "Declare the document's character encoding in the Content-Type response header, "
                           + "or with a <meta charset> tag within the first 1,024 bytes of the HTML. Without it the "
                           + "browser may have to guess the encoding, re-parse the page, or show its text garbled.",
                       headline: headline, rows: rows,
                       ranges: document.map { [$0.start...$0.end] } ?? [])
    }
}
