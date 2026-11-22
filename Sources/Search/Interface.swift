import Foundation

enum Interface {
    // build.sh installs the tables in Search.app. SwiftPM keeps them in its resource bundle.
    private static let bundle: Bundle = Bundle.main.bundleURL.pathExtension == "app" ? .main : .module

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Interface")
    }

    static let locale = Locale(identifier: bundle.preferredLocalizations.first ?? "en")

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
