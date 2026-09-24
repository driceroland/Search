import Foundation

enum Engine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, startpage, kagi, brave, qwant, custom

    static let standard = Engine.google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .qwant: return "Qwant"
        case .custom: return "Custom"
        }
    }

    func template(custom: String) -> String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckduckgo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .startpage: return "https://www.startpage.com/sp/search?query=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .brave: return "https://search.brave.com/search?q=%s"
        case .qwant: return "https://www.qwant.com/?q=%s"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return Engine.accepts(trimmed) ? trimmed : Engine.standard.template(custom: "")
        }
    }

    func name(custom: String) -> String {
        guard self == .custom else { return title }
        guard let host = Engine.host(of: custom) else { return Engine.standard.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func accepts(_ template: String) -> Bool {
        host(of: template) != nil
    }

    static func url(for text: String, template: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty,
              let escaped = words.addingPercentEncoding(withAllowedCharacters: unreserved),
              let base = URL(string: template.replacingOccurrences(of: "%s", with: mark))?.absoluteString
        else { return nil }
        return URL(string: base.replacingOccurrences(of: mark, with: escaped), encodingInvalidCharacters: false)
    }

    private static let mark = "SEARCHWORDSGOHERE"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func host(of template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let parts = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "a")),
              let other = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "b")),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, host == other.host
        else { return nil }
        return host.lowercased()
    }
}
