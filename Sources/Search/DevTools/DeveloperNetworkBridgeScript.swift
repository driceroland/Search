import Foundation

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
