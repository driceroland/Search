import Foundation

enum DeveloperNetworkBridgeScript {
    // Runs in WebKit's inspector frontend next to the inspector bridge, for
    // the Network panel's own tools: request blocking, WebSocket messages,
    // the extra columns and filter keys, HAR export, search and bandwidth
    // throttling where the engine has it.
    static let source = DevToolsScripts.networkBridgeScriptSource
}
