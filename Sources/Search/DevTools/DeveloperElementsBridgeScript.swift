enum DeveloperElementsBridgeScript {
    /// Elements-panel helpers, installed beside `perchInspector` in WebKit's
    /// hidden inspector frontend the first time the panel needs one. They
    /// reach the page only through protocol commands (resolveNode and
    /// callFunctionOn for what DevTools itself runs in the page: paths,
    /// Hide element, Scroll into view, Store as global variable).
    static let source = DevToolsResources.script("DeveloperElementsBridgeScript-source.js")
}
