/// The Console panel's half of the bridge. It runs in WebKit's hidden
/// inspector frontend next to `searchInspector` (DeveloperToolsBridgeScript)
/// and adds what Chrome's console needs and the event stream leaves out:
/// a message's arguments as remote objects with their previews, its stack
/// trace, and the object trees, completions and eager previews asked for
/// from the prompt. Every value is size limited before it reaches Swift.
enum DeveloperConsoleScript {
    static let source = DevToolsScripts.consoleScriptSource
}
