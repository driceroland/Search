import Foundation

// The scripts Search installs in WebKit's hidden inspector frontend.

enum DeveloperToolsBridgeScript {
    // Runs in WebKit's inspector frontend. The frontend owns the protocol
    // connection, request IDs and target lifetimes, including process swaps.
    static let source = DevToolsResources.script("DeveloperToolsBridgeScript-source.js")
}

/// The Console panel's half of the bridge. It runs in WebKit's hidden
/// inspector frontend next to `perchInspector` (DeveloperToolsBridgeScript)
/// and adds what Chrome's console needs and the event stream leaves out:
/// a message's arguments as remote objects with their previews, its stack
/// trace, and the object trees, completions and eager previews asked for
/// from the prompt. Every value is size limited before it reaches Swift.
enum DeveloperConsoleScript {
    static let source = DevToolsResources.script("DeveloperConsoleScript-source.js")
}

enum DeveloperElementsBridgeScript {
    /// Elements-panel helpers, installed beside `perchInspector` in WebKit's
    /// hidden inspector frontend the first time the panel needs one. They
    /// reach the page only through protocol commands (resolveNode and
    /// callFunctionOn for what DevTools itself runs in the page: paths,
    /// Hide element, Scroll into view, Store as global variable).
    static let source = DevToolsResources.script("DeveloperElementsBridgeScript-source.js")
}

enum DeveloperNetworkBridgeScript {
    // Runs in WebKit's inspector frontend next to `perchInspector`, for the
    // Network panel's own tools: request blocking, WebSocket messages, the
    // extra columns and filter keys, HAR export, search and bandwidth
    // throttling where the engine has it.
    static let source = DevToolsResources.script("DeveloperNetworkBridgeScript-source.js")

    static func eventSource(session: UUID) -> String {
        "((perchEventSourceSession) => \(source))('\(session.uuidString)')"
    }
}
