import JavaScriptCore

/// What the Console prompt runs, decided by parsing it here: the inspector
/// frontend's Content Security Policy refuses `new Function`, and a
/// JavaScriptCore context of its own has none. Functions are only
/// built, never called, so nothing the prompt holds runs here.
@MainActor
enum DeveloperConsoleSyntax {
    struct Prepared: Equatable {
        var expression: String
        /// Run as an async function: its promise is awaited for the result.
        var awaited = false
    }

    private static let context: JSContext? = JSContext()

    /// Whether `body` parses as a function body; `async` for an async one.
    static func parses(_ body: String, async: Bool = false) -> Bool {
        guard let context else { return false }
        context.exception = nil
        context.setObject(body, forKeyedSubscript: "consoleSource" as NSString)
        context.evaluateScript(async ? "new (async function () {}).constructor(consoleSource)" : "new Function(consoleSource)")
        let ok = context.exception == nil
        context.exception = nil
        return ok
    }

    /// As Chrome's Console runs the prompt: `{a: 1}` as an object literal,
    /// and top-level await by running the input as an async function.
    /// An expression gives its value; statements give the value of a last
    /// expression on its own line, and names they declare at the start of a
    /// line with `const`, `let` or `var` become globals, as Chrome makes them.
    static func prepare(_ source: String, paused: Bool) -> Prepared {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), parses("return (" + trimmed + "\n)") {
            return Prepared(expression: "(" + trimmed + "\n)")
        }
        // While paused the page can't settle a promise.
        guard !paused, source.range(of: #"\bawait\b"#, options: .regularExpression) != nil,
              !parses(source) else { return Prepared(expression: source) }
        if parses("return (\n" + source + "\n)", async: true) {
            return Prepared(expression: "(async () => { return (\n" + source + "\n); })()", awaited: true)
        }
        guard parses(source, async: true) else { return Prepared(expression: source) }
        var body = source.replacingOccurrences(of: #"(?m)^([ \t]*)(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*="#,
                                               with: "$1globalThis.$2 =", options: .regularExpression)
        if !parses(body, async: true) { body = source }
        var lines = body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n")
        let last = (lines.popLast() ?? "").replacingOccurrences(of: #";\s*$"#, with: "", options: .regularExpression)
        let head = lines.joined(separator: "\n")
        if !last.trimmingCharacters(in: .whitespaces).isEmpty,
           parses(head + "\nreturn (\n" + last + "\n);", async: true) {
            return Prepared(expression: "(async () => {\n" + head + "\nreturn (\n" + last + "\n);\n})()", awaited: true)
        }
        return Prepared(expression: "(async () => {\n" + body + "\n})()", awaited: true)
    }
}
