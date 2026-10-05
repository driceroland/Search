import Foundation
import Observation

/// UI language only. Website content, URLs and stored user data are never translated.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, french = "fr", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System")
        case .french: return "Français"
        case .english: return "English"
        }
    }
    func code(preferred: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .french: return "fr"
        case .english: return "en"
        case .system: return preferred.first?.lowercased().hasPrefix("fr") == true ? "fr" : "en"
        }
    }
}

@Observable
final class Localization {
    static let shared = Localization()
    var language: InterfaceLanguage {
        didSet { Store.settings.set(language.rawValue, forKey: "interface.language") }
    }
    var locale: Locale { Locale(identifier: language.code()) }
    init() {
        language = Store.settings.string(forKey: "interface.language").flatMap(InterfaceLanguage.init) ?? .system
    }
    static let resources: Bundle = {
        // SwiftPM's generated accessor only checks the app root and the original
        // build directory. Standalone macOS bundles keep resources in Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Search_Search.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()
    static let french: [String: String] = {
        guard let url = resources.url(forResource: "fr", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
    static func text(_ key: String) -> String {
        render(LocalizedPhrase(stringLiteral: key), language: shared.language.code())
    }
    static func render(_ phrase: LocalizedPhrase, language: String) -> String {
        let template = language == "fr" ? french[phrase.key] ?? phrase.key : phrase.key
        // A single pass means a value containing a placeholder is never interpolated twice.
        let pattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = template as NSString
        var result = template
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let index = Int(source.substring(with: match.range(at: 1))), phrase.values.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: phrase.values[index])
        }
        return result
    }
}

struct LocalizedPhrase: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let values: [String]
    init(stringLiteral value: String) { key = value; values = [] }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; values = stringInterpolation.values }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var values: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(values.count)}"
            values.append(String(describing: value))
        }
    }
}

func L(_ phrase: LocalizedPhrase) -> String {
    Localization.render(phrase, language: Localization.shared.language.code())
}
