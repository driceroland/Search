import Foundation

// Where this browser keeps things on Linux: $XDG_DATA_HOME/search, which is
// ~/.local/share/search unless somebody moved it.
//
// The Mac's rule holds here too: a run from the build folder, or one started
// with SEARCH_PROBE set, is a test run, and a test run never touches the
// folder of the browser somebody actually uses. It gets "search (test)".

enum Folder {
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] != nil { return true }
        // The resolved path, not argv[0]: `.build/debug/SearchLinux` typed
        // from the repository has no slash before `.build`.
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    static let root: URL = {
        let environment = ProcessInfo.processInfo.environment
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let home = data.appendingPathComponent(testing ? "search (test)" : "search", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }()

    static func file(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// Cookies, sign-ins, site data: WebKit's, in a folder of their own.
    static var websites: String { root.appendingPathComponent("websites").path }
    static var cache: String { root.appendingPathComponent("cache").path }
}
