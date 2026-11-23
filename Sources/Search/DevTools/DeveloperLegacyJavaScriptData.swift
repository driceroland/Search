import Foundation

/// Lighthouse's legacy-javascript data (core/lib/legacy-javascript, Apache-2.0),
/// which Chrome's Legacy JavaScript insight reads: each polyfill and the
/// core-js (or npm) modules that provide it, and the estimated size of
/// the modules each polyfill pulls in. Copied from Lighthouse 13.6.0's
/// polyfill-module-data.json and polyfill-graph-data.json into
/// Resources/data/DeveloperLegacyJavaScript-polyfills.json (build.sh copies
/// it into the app); regenerate from there, don't edit by hand. It is read
/// the first time the insight asks for it.
enum DeveloperLegacyJavaScriptData {
    struct Polyfill: Decodable {
        let name: String
        let modules: [String]
        /// Whether core-js provides it, so its minified code can be matched.
        let coreJS: Bool
    }

    private struct Table: Decodable {
        let maxSize: Int
        let polyfills: [Polyfill]
        let moduleSizes: [Int]
        let dependencies: [String: [Int]]
    }

    static let fileName = "DeveloperLegacyJavaScript-polyfills.json"

    private static let table: Table = DeveloperMeasure.bundled(Table.self, named: fileName)
        ?? Table(maxSize: 0, polyfills: [], moduleSizes: [], dependencies: [:])

    static var polyfills: [Polyfill] { table.polyfills }

    /// The most a script's polyfills can be estimated to cost.
    static var maxSize: Int { table.maxSize }

    /// Each module's estimated size in bytes, by index.
    static var moduleSizes: [Int] { table.moduleSizes }

    /// The modules (indices into `moduleSizes`) each polyfill pulls in.
    static var dependencies: [String: [Int]] { table.dependencies }
}
