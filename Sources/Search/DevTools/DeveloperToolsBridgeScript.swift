enum DeveloperToolsBridgeScript {
    // Runs in WebKit's inspector frontend. The frontend owns the protocol
    // connection, request IDs and target lifetimes, including process swaps.
    static let source = DevToolsResources.script("DeveloperToolsBridgeScript-source.js")
}
