import Foundation

// The JavaScript Shy puts into pages, kept as the .js files they are
// (Sources/Shy/Scripts) rather than as strings in Swift, and copied into the
// app's Resources by build.sh. A missing one is a packaging mistake, and
// stops the app at once instead of leaving a page without its script.
enum Scripts {
    nonisolated static func load(_ name: String) -> String {
        var url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Scripts")
        #if DEBUG
        // `swift test` runs without an app bundle: the sources are beside it.
        if url == nil {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Scripts/\(name).js")
        }
        #endif
        guard let url, var text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Scripts/\(name).js is missing from the app")
        }
        // The file ends in a newline, as files do; a string literal does not.
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
