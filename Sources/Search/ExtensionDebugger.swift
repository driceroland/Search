import AppKit
import WebKit

// chrome.debugger, for an extension that asked for it in its manifest.
//
// WebKit has no DevTools protocol for an extension to speak, so Search
// answers the part of it that browser agents use — Claude in Chrome first —
// itself, with what it already has for its own agent (PageHands): a picture
// of the page, real mouse and key events into the page's view, a script run
// in the page, and the page's console and requests as events.
//
// What is answered:
//   Page.captureScreenshot (with or without a clip), Page.getFrameTree,
//   Runtime.evaluate, Input.dispatchMouseEvent, Input.dispatchKeyEvent,
//   Input.insertText, and the enable/disable calls around them.
//   Events: Runtime.consoleAPICalled, Runtime.exceptionThrown,
//   Network.requestWillBeSent / responseReceived / loadingFailed and
//   Page.frameNavigated, fetched by the shim while it is attached
//   (ExtensionShims, "debugger.events").
//
// Never: a private tab, or a page that isn't http, https or blank —
// Search's own pages, Settings, extensions and file:// stay out of reach, as
// chrome:// pages do in Chrome. A right click is the page's contextmenu
// event, not the native menu, which would hold up the whole app while open.

@MainActor
enum ExtensionDebugger {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// What is known of each attached tab.
    private struct Watch {
        var console = false
        var network = false
        var url = ""
        var loader = 1
    }
    private static var watched: [Tab.ID: Watch] = [:]

    // MARK: attach and detach

    static func attach(_ tab: Tab) throws {
        try reachable(tab)
        if watched[tab.id] == nil { watched[tab.id] = Watch(url: tab.address?.absoluteString ?? "") }
    }

    static func detach(_ tab: Tab) {
        watched[tab.id] = nil
    }

    private static func reachable(_ tab: Tab) throws {
        guard !tab.shy else { throw Failure("Cannot access a private tab") }
        guard let url = tab.address else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) || url.absoluteString == "about:blank" else {
            throw Failure("Cannot access contents of url \"\(url.absoluteString)\"")
        }
    }

    // MARK: commands

    static func send(_ method: String, _ params: [String: Any], to tab: Tab) async throws -> Any {
        try reachable(tab)
        guard watched[tab.id] != nil else { throw Failure("Debugger is not attached to the tab") }
        switch method {
        case "Page.enable", "Page.disable", "Runtime.runIfWaitingForDebugger", "Emulation.setFocusEmulationEnabled",
             "Input.cancelDragging", "Page.setLifecycleEventsEnabled", "Log.enable", "Log.disable", "DOM.enable",
             "DOM.disable", "CSS.enable", "Overlay.enable", "Overlay.disable", "Page.bringToFront":
            return [String: Any]()
        case "Runtime.enable":
            watched[tab.id]?.console = true
            _ = await drain(tab)
            return [String: Any]()
        case "Runtime.disable":
            watched[tab.id]?.console = false
            return [String: Any]()
        case "Network.enable":
            watched[tab.id]?.network = true
            _ = await drain(tab)
            return [String: Any]()
        case "Network.disable":
            watched[tab.id]?.network = false
            return [String: Any]()
        case "Page.getFrameTree":
            return ["frameTree": ["frame": frame(tab), "childFrames": [Any]()]]
        case "Page.captureScreenshot":
            return try await screenshot(params, of: tab)
        case "Runtime.evaluate":
            return await evaluate(params, in: tab)
        case "Input.dispatchMouseEvent":
            try await mouse(params, on: tab)
            return [String: Any]()
        case "Input.dispatchKeyEvent":
            try await key(params, on: tab)
            return [String: Any]()
        case "Input.insertText":
            try await insert(params["text"] as? String ?? "", into: tab)
            return [String: Any]()
        case "Page.handleJavaScriptDialog":
            throw Failure("No dialog is showing")
        default:
            throw Failure("'\(method)' wasn't found")
        }
    }

    // MARK: events

    /// Whatever happened in the tab since the last time it was asked.
    static func events(_ tab: Tab) async -> [[String: Any]] {
        guard watched[tab.id] != nil else { return [] }
        var out: [[String: Any]] = []
        let before = watched[tab.id]?.loader
        let now = frame(tab)
        if watched[tab.id]?.loader != before {
            out.append(["method": "Page.frameNavigated", "params": ["frame": now, "type": "Navigation"]])
        }
        out += await drain(tab)
        return out
    }

    /// The main frame as CDP describes it. A new address is a new loader.
    private static func frame(_ tab: Tab) -> [String: Any] {
        let url = tab.address?.absoluteString ?? "about:blank"
        if var watch = watched[tab.id], watch.url != url {
            watch.url = url
            watch.loader += 1
            watched[tab.id] = watch
        }
        let loader = watched[tab.id]?.loader ?? 1
        let origin = tab.address.flatMap { address -> String? in
            guard let scheme = address.scheme, let host = address.host() else { return nil }
            return "\(scheme)://\(host)" + (address.port.map { ":\($0)" } ?? "")
        } ?? "null"
        return ["id": "main-\(tab.id.uuidString)", "loaderId": "loader-\(loader)", "url": url,
                "securityOrigin": origin, "mimeType": "text/html", "domainAndRegistry": tab.address?.host() ?? ""]
    }

    /// The page's console and requests, from hooks put in the page the first
    /// time they're asked for (again after each navigation).
    private static func drain(_ tab: Tab) async -> [[String: Any]] {
        guard let watch = watched[tab.id], watch.console || watch.network, let web = tab.built else { return [] }
        guard let json = try? await run(Hooks.drain(console: watch.console, network: watch.network), in: web, world: .page) as? String,
              let data = json.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        for item in items {
            let at = (item["ts"] as? Double) ?? Date().timeIntervalSince1970 * 1000
            switch item["k"] as? String {
            case "console" where watch.console:
                let args = (item["args"] as? [String] ?? []).map { ["type": "string", "value": $0] }
                var params: [String: Any] = ["type": item["type"] as? String ?? "log", "args": args, "timestamp": at,
                                             "executionContextId": 1]
                if let url = item["url"] as? String {
                    params["stackTrace"] = ["callFrames": [["functionName": "", "url": url,
                                                            "lineNumber": item["line"] ?? 0, "columnNumber": item["col"] ?? 0]]]
                }
                out.append(["method": "Runtime.consoleAPICalled", "params": params])
            case "exception" where watch.console:
                let text = item["text"] as? String ?? "Uncaught"
                out.append(["method": "Runtime.exceptionThrown", "params": ["timestamp": at, "exceptionDetails": [
                    "exceptionId": 1, "text": "Uncaught", "url": item["url"] ?? "", "lineNumber": item["line"] ?? 0,
                    "columnNumber": item["col"] ?? 0, "timestamp": at,
                    "exception": ["type": "object", "subtype": "error", "description": text],
                ]]])
            case "req" where watch.network:
                out.append(["method": "Network.requestWillBeSent", "params": [
                    "requestId": item["id"] ?? "", "documentURL": item["doc"] ?? "", "timestamp": at / 1000,
                    "request": ["url": item["url"] ?? "", "method": item["method"] ?? "GET", "headers": [String: Any]()],
                    "type": item["type"] ?? "Other",
                ]])
            case "res" where watch.network:
                out.append(["method": "Network.responseReceived", "params": [
                    "requestId": item["id"] ?? "", "timestamp": at / 1000, "type": item["type"] ?? "Other",
                    "response": ["url": item["url"] ?? "", "status": item["status"] ?? 200, "headers": [String: Any]()],
                ]])
            case "fail" where watch.network:
                out.append(["method": "Network.loadingFailed", "params": [
                    "requestId": item["id"] ?? "", "timestamp": at / 1000, "errorText": "net::ERR_FAILED", "type": "Other",
                ]])
            default:
                continue
            }
        }
        return out
    }

    // MARK: a picture

    private static func screenshot(_ params: [String: Any], of tab: Tab) async throws -> [String: Any] {
        let web = try laidOut(tab)
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        let zoom = Double(web.pageZoom * web.magnification)
        if let clip = params["clip"] as? [String: Any] {
            // In CSS pixels of the document, as in Chrome; the view's rect is
            // the part of it on screen.
            let scrolled = (try? await run("[window.scrollX, window.scrollY]", in: web, world: Web.world)) as? [Double] ?? [0, 0]
            let x = number(clip["x"]) - (scrolled.first ?? 0), y = number(clip["y"]) - (scrolled.last ?? 0)
            let width = max(number(clip["width"]), 1), height = max(number(clip["height"]), 1)
            let scale = number(clip["scale"], or: 1)
            var rect = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
            if !web.isFlipped { rect.origin.y = web.bounds.height - rect.maxY }
            shot.rect = rect
            shot.snapshotWidth = NSNumber(value: width * scale)
        }
        let rep: NSBitmapImageRep = try await withCheckedThrowingContinuation { done in
            web.takeSnapshot(with: shot) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    done.resume(throwing: Failure(error?.localizedDescription ?? "No picture of the page"))
                    return
                }
                done.resume(returning: rep)
            }
        }
        let png = (params["format"] as? String) == "png"
        let quality = min(max(number(params["quality"], or: 80), 1), 100) / 100
        guard let data = png ? rep.representation(using: .png, properties: [:])
                             : rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw Failure("Failed to encode the picture")
        }
        return ["data": data.base64EncodedString()]
    }

    /// The tab's view, in a window, so it is laid out and painted: a tab
    /// nobody is looking at goes to the room off every screen until its
    /// window takes it back (PageRoom).
    private static func laidOut(_ tab: Tab) throws -> WKWebView {
        let web = tab.web
        if web.window == nil { PageRoom.shared.lend(tab) }
        guard web.window != nil else { throw Failure("The tab isn't laid out") }
        return web
    }

    // MARK: a script

    /// Runtime.evaluate in the page's own world, as Chrome runs it. The
    /// expression is tried first as a value to return, then with its last
    /// statement returned, then as statements; each try that doesn't parse
    /// never ran, so nothing runs twice.
    private static func evaluate(_ params: [String: Any], in tab: Tab) async -> [String: Any] {
        guard let web = try? laidOut(tab) else { return exception("Error: The tab isn't laid out") }
        var expression = params["expression"] as? String ?? ""
        // In REPL mode a block's value is its last statement's, as in the
        // console: Claude sends its code as "{code\n}" for that. Here the
        // block is taken off, and the last statement returned (bodies).
        if params["replMode"] as? Bool == true, expression.hasPrefix("{"), expression.hasSuffix("\n}") {
            expression = String(expression.dropFirst().dropLast(2))
        }
        let timeout = number(params["timeout"], or: 30_000) / 1000
        var lastSyntax = "SyntaxError: Unexpected token"
        for body in bodies(expression) {
            let outcome: Outcome = await withCheckedContinuation { done in
                var finished = false
                let finish: (Outcome) -> Void = { outcome in
                    guard !finished else { return }
                    finished = true
                    done.resume(returning: outcome)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(timeout, 1)) { finish(.timedOut) }
                web.callAsyncJavaScript(Hooks.evaluate(body), arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): finish(.value(value as? String ?? ""))
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                            ?? error.localizedDescription
                        finish(message.contains("SyntaxError") ? .unparsed(message) : .failed(message))
                    }
                }
            }
            switch outcome {
            case .unparsed(let message):
                lastSyntax = message
                continue
            case .timedOut:
                return exception("Error: execution was terminated")
            case .failed(let message):
                return exception(message)
            case .value(let json):
                guard let data = json.data(using: .utf8),
                      let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return ["result": ["type": "undefined"]]
                }
                if let thrown = said["x"] as? [String: Any] {
                    return exception(thrown["description"] as? String ?? "Error", className: thrown["name"] as? String)
                }
                return ["result": said["r"] ?? ["type": "undefined"]]
            }
        }
        return exception(lastSyntax, className: "SyntaxError")
    }

    private enum Outcome {
        case value(String)
        case unparsed(String)
        case failed(String)
        case timedOut
    }

    /// The ways to run an expression, most faithful first.
    static func bodies(_ expression: String) -> [String] {
        var code = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        while code.hasSuffix(";") { code.removeLast(); code = code.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ["return (\n\(code)\n);"]
        // The last statement returned, split after the last ";" or "}" that
        // ends a line or a statement.
        let characters = Array(code)
        var split: Int?
        var index = characters.count - 1
        while index > 0 {
            if characters[index] == ";" || (characters[index] == "\n" && [";", "}"].contains(lastVisible(characters, before: index))) {
                split = index + 1
                break
            }
            index -= 1
        }
        // And after the last line break, when the line before looks finished
        // and the last line doesn't carry on from it: code written without
        // semicolons. One that doesn't parse never ran.
        var lineSplit: Int?
        index = characters.count - 1
        while index > 0 {
            if characters[index] == "\n" {
                let before = lastVisible(characters, before: index)
                let after = characters[(index + 1)...].first { !$0.isWhitespace }
                if let before, let after, !"{([,=+-*/%&|?:.!<>".contains(before), !".,+-*/%&|?:=)]}`([".contains(after) {
                    lineSplit = index + 1
                }
                break
            }
            index -= 1
        }
        for at in [split, lineSplit].compactMap({ $0 }) where at < characters.count {
            let head = String(characters[..<at]), tail = String(characters[at...])
            let body = "\(head)\nreturn (\n\(tail)\n);"
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !out.contains(body) { out.append(body) }
        }
        out.append(code)
        return out
    }

    private static func lastVisible(_ characters: [Character], before index: Int) -> Character? {
        var at = index - 1
        while at >= 0, characters[at].isWhitespace { at -= 1 }
        return at >= 0 ? characters[at] : nil
    }

    private static func exception(_ description: String, className: String? = nil) -> [String: Any] {
        var thrown: [String: Any] = ["type": "object", "subtype": "error", "description": description]
        if let className { thrown["className"] = className }
        return ["result": thrown, "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0,
                                                       "columnNumber": 0, "exception": thrown]]
    }

    // MARK: the mouse

    private static func mouse(_ params: [String: Any], on tab: Tab) async throws {
        let web = try laidOut(tab)
        let type = params["type"] as? String ?? ""
        let x = number(params["x"]), y = number(params["y"])
        let button = params["button"] as? String ?? "none"
        if type == "mouseWheel" {
            _ = try? await run(Hooks.wheel(x: x, y: y, dx: number(params["deltaX"]), dy: number(params["deltaY"])),
                               in: web, world: Web.world)
            return
        }
        // The native context menu would hold the app until it closes.
        if button == "right", type == "mousePressed" || type == "mouseReleased" {
            _ = try? await run(Hooks.rightButton(x: x, y: y, down: type == "mousePressed"), in: web, world: Web.world)
            return
        }
        guard let window = web.window else { throw Failure("The tab isn't laid out") }
        let zoom = Double(web.pageZoom * web.magnification)
        let local = NSPoint(x: x * zoom, y: web.isFlipped ? y * zoom : Double(web.bounds.height) - y * zoom)
        let spot = web.convert(local, to: nil)
        let buttons = (params["buttons"] as? NSNumber)?.intValue ?? 0
        let middle = button == "middle"
        let kind: NSEvent.EventType
        switch type {
        case "mousePressed": kind = middle ? .otherMouseDown : .leftMouseDown
        case "mouseReleased": kind = middle ? .otherMouseUp : .leftMouseUp
        case "mouseMoved": kind = buttons & 1 != 0 ? .leftMouseDragged : (buttons & 4 != 0 ? .otherMouseDragged : .mouseMoved)
        default: throw Failure("Invalid mouse event type: \(type)")
        }
        let clicks = type == "mouseMoved" ? 0 : max((params["clickCount"] as? NSNumber)?.intValue ?? 1, 1)
        guard var event = NSEvent.mouseEvent(
            with: kind, location: spot, modifierFlags: flags(params["modifiers"]),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: type == "mousePressed" ? 1 : 0
        ) else { throw Failure("Failed to make the mouse event") }
        if middle, let raw = event.cgEvent {
            raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            if let again = NSEvent(cgEvent: raw) { event = again }
        }
        if type == "mousePressed", window.firstResponder !== web { window.makeFirstResponder(web) }
        switch kind {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .otherMouseDown: web.otherMouseDown(with: event)
        case .otherMouseUp: web.otherMouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        case .otherMouseDragged: web.otherMouseDragged(with: event)
        default: web.mouseMoved(with: event)
        }
    }

    /// CDP's modifiers: 1 Alt, 2 Ctrl, 4 Meta (⌘), 8 Shift.
    private static func flags(_ value: Any?) -> NSEvent.ModifierFlags {
        let bits = (value as? NSNumber)?.intValue ?? 0
        var out: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { out.insert(.option) }
        if bits & 2 != 0 { out.insert(.control) }
        if bits & 4 != 0 { out.insert(.command) }
        if bits & 8 != 0 { out.insert(.shift) }
        return out
    }

    // MARK: keys

    private static func key(_ params: [String: Any], on tab: Tab) async throws {
        let web = try laidOut(tab)
        let type = params["type"] as? String ?? ""
        let code = params["code"] as? String ?? ""
        let name = params["key"] as? String ?? ""
        let text = params["text"] as? String ?? ""
        var held = flags(params["modifiers"])
        if let window = web.window, window.firstResponder !== web { window.makeFirstResponder(web) }

        if type == "char" {
            if !text.isEmpty { try await insert(text, into: tab) }
            return
        }
        // Keys that only change the others.
        if ["Shift", "Control", "Alt", "Meta", "CapsLock"].contains(name) { return }

        // Editing commands, as Chrome takes them with a key ("selectAll"),
        // and ⌘ with a letter, which Cocoa sends as a menu action rather than
        // as a key a view hears.
        var commands = (params["commands"] as? [String] ?? []).filter { !$0.isEmpty }
        if commands.isEmpty, held.contains(.command), type != "keyUp" {
            let letter = name.lowercased()
            switch letter {
            case "a": commands = ["selectAll"]
            case "c": commands = ["copy"]
            case "x": commands = ["cut"]
            case "v": commands = ["paste"]
            case "z": commands = [held.contains(.shift) ? "redo" : "undo"]
            default: break
            }
        }
        if !commands.isEmpty {
            if type != "keyUp" {
                for command in commands {
                    let selector = NSSelectorFromString(command.prefix(1).lowercased() + command.dropFirst() + ":")
                    if !NSApp.sendAction(selector, to: web, from: nil) {
                        _ = try? await run("document.execCommand(\(literal(command)))", in: web, world: .page)
                    }
                }
            }
            return
        }

        guard let (keyCode, special) = keys[code] ?? keys[name] ?? character(name) else { return }
        if keyCode >= 115 && keyCode <= 126 { held.insert(.function) }
        let characters = text.isEmpty ? special : text
        let plain = (params["unmodifiedText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? characters
        let kind: NSEvent.EventType = type == "keyUp" ? .keyUp : .keyDown
        guard let event = NSEvent.keyEvent(
            with: kind, location: .zero, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: web.window?.windowNumber ?? 0, context: nil,
            characters: type == "rawKeyDown" && text.isEmpty && special.isEmpty ? "" : characters,
            charactersIgnoringModifiers: plain, isARepeat: params["autoRepeat"] as? Bool ?? false, keyCode: keyCode
        ) else { throw Failure("Failed to make the key event") }
        if kind == .keyUp { web.keyUp(with: event) } else { web.keyDown(with: event) }
    }

    /// One printable character: its key on a US layout, and itself.
    private static func character(_ name: String) -> (UInt16, String)? {
        guard name.count == 1, let first = name.first else { return nil }
        return (Bench.keyCode(for: Character(first.lowercased())), name)
    }

    /// CDP's `code` (and the named `key`) as a Mac key code and the
    /// characters AppKit gives that key.
    private static let keys: [String: (UInt16, String)] = {
        func function(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        var out: [String: (UInt16, String)] = [
            "Enter": (36, "\r"), "NumpadEnter": (76, "\u{3}"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"),
            "Backspace": (51, "\u{7f}"), "Delete": (117, function(NSDeleteFunctionKey)), "Space": (49, " "), " ": (49, " "),
            "ArrowUp": (126, function(NSUpArrowFunctionKey)), "ArrowDown": (125, function(NSDownArrowFunctionKey)),
            "ArrowLeft": (123, function(NSLeftArrowFunctionKey)), "ArrowRight": (124, function(NSRightArrowFunctionKey)),
            "Home": (115, function(NSHomeFunctionKey)), "End": (119, function(NSEndFunctionKey)),
            "PageUp": (116, function(NSPageUpFunctionKey)), "PageDown": (121, function(NSPageDownFunctionKey)),
            "Minus": (27, "-"), "Equal": (24, "="), "BracketLeft": (33, "["), "BracketRight": (30, "]"),
            "Backslash": (42, "\\"), "Semicolon": (41, ";"), "Quote": (39, "'"), "Comma": (43, ","),
            "Period": (47, "."), "Slash": (44, "/"), "Backquote": (50, "`"),
        ]
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
        ]
        for (letter, code) in letters { out["Key" + letter.uppercased()] = (code, String(letter)) }
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() { out["Digit\(digit)"] = (code, "\(digit)") }
        let fs: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fs.enumerated() {
            out["F\(index + 1)"] = (code, function(NSF1FunctionKey + index))
        }
        return out
    }()

    // MARK: text

    /// Text put in where the page's focus is, the way typing or a paste
    /// would put it: WebKit's own insertText, which fires the input events
    /// a page listens for.
    private static func insert(_ text: String, into tab: Tab) async throws {
        let web = try laidOut(tab)
        let done = (try? await run("document.execCommand('insertText', false, \(literal(text)))", in: web, world: .page)) as? Bool
        if done != true { web.insertText(text) }
    }

    // MARK: helpers

    private static func run(_ script: String, in web: WKWebView, world: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { done in
            web.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): done.resume(returning: value)
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
    }

    private static func number(_ value: Any?, or fallback: Double = 0) -> Double {
        (value as? NSNumber)?.doubleValue ?? fallback
    }

    /// A string as a JavaScript literal.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - the scripts put in the page

    enum Hooks {
        /// An expression's value, as CDP's RemoteObject with returnByValue,
        /// or what it threw.
        static func evaluate(_ body: String) -> String {
            """
            const __describe = (v) => {
              const t = typeof v;
              if (v === undefined) return { type: "undefined" };
              if (v === null) return { type: "object", subtype: "null", value: null };
              if (t === "function") return { type: "function", description: String(v).slice(0, 2000) };
              if (t === "bigint") return { type: "bigint", description: String(v) + "n" };
              if (t === "symbol") return { type: "symbol", description: String(v) };
              if (t !== "object") return (t === "number" && !Number.isFinite(v)) ? { type: t, description: String(v) } : { type: t, value: v };
              if (typeof Node !== "undefined" && v instanceof Node) {
                const name = (v.nodeName || "node").toLowerCase();
                const id = v.id ? "#" + v.id : "";
                const cls = typeof v.className === "string" && v.className.trim() ? "." + v.className.trim().split(/\\s+/).join(".") : "";
                return { type: "object", subtype: "node", description: name + id + cls };
              }
              if (v instanceof Error) return { type: "object", subtype: "error", className: v.name, description: v.stack ? v.name + ": " + v.message + "\\n" + v.stack : String(v) };
              let value;
              try { value = JSON.parse(JSON.stringify(v)); } catch (e) {}
              if (Array.isArray(v)) return { type: "object", subtype: "array", value, description: value !== undefined ? JSON.stringify(value) : "Array(" + v.length + ")" };
              return value === undefined ? { type: "object", description: String(v) } : { type: "object", value };
            };
            let __value;
            try {
              __value = await (async () => {
            \(body)
              })();
            } catch (e) {
              const name = e && e.name ? String(e.name) : "Error";
              const description = e instanceof Error ? (e.stack ? name + ": " + e.message + "\\n" + e.stack : name + ": " + e.message) : "Uncaught " + String(e);
              return JSON.stringify({ x: { name, description } });
            }
            try { return JSON.stringify({ r: __describe(__value) }); } catch (e) { return JSON.stringify({ r: { type: "object", description: String(__value) } }); }
            """
        }

        /// The console and requests since the last time, with the hooks put
        /// in first if this page doesn't have them yet.
        static func drain(console: Bool, network: Bool) -> String {
            """
            (() => {
              const C = \(console), N = \(network);
              let h = window.__searchDebugger;
              if (!h) {
                h = { q: [], n: 0, console: false, network: false };
                try { Object.defineProperty(window, "__searchDebugger", { value: h, enumerable: false, configurable: true }); } catch (e) { return "[]"; }
              }
              const push = (e) => { if (h.q.length < 3000) h.q.push(e); };
              const text = (v) => {
                try {
                  if (typeof v === "string") return v;
                  if (v instanceof Error) return v.stack ? v.name + ": " + v.message + "\\n" + v.stack : String(v);
                  if (typeof Node !== "undefined" && v instanceof Node) return "<" + (v.nodeName || "node").toLowerCase() + ">";
                  const s = JSON.stringify(v);
                  return s === undefined ? String(v) : s;
                } catch (e) { try { return String(v); } catch (e2) { return "[object]"; } }
              };
              const where = () => {
                const lines = String(new Error().stack || "").split("\\n");
                for (const line of lines.slice(2)) {
                  const m = line.match(/((?:https?|blob|file):\\/\\/[^\\s]*?):(\\d+):(\\d+)\\)?\\s*$/);
                  if (m) return { url: m[1], line: Number(m[2]) - 1, col: Number(m[3]) - 1 };
                }
                return {};
              };
              if (C && !h.console) {
                h.console = true;
                for (const type of ["log", "info", "warn", "error", "debug", "trace"]) {
                  const original = console[type];
                  if (typeof original !== "function") continue;
                  console[type] = function (...args) {
                    try { push({ k: "console", type: type === "warn" ? "warning" : type, args: args.slice(0, 50).map((a) => text(a).slice(0, 16384)), ts: Date.now(), ...where() }); } catch (e) {}
                    return original.apply(this, args);
                  };
                }
                addEventListener("error", (ev) => {
                  if (!ev || !ev.message) return;
                  const error = ev.error;
                  push({ k: "exception", text: error instanceof Error && error.stack ? error.name + ": " + error.message + "\\n" + error.stack : "Uncaught " + ev.message, url: ev.filename || "", line: Math.max((ev.lineno || 1) - 1, 0), col: Math.max((ev.colno || 1) - 1, 0), ts: Date.now() });
                }, true);
                addEventListener("unhandledrejection", (ev) => push({ k: "exception", text: "Uncaught (in promise) " + text(ev.reason), ts: Date.now() }));
              }
              if (N && !h.network) {
                h.network = true;
                const id = () => "search." + (++h.n);
                const absolute = (u) => { try { return new URL(String(u), location.href).href; } catch (e) { return String(u); } };
                const realFetch = window.fetch;
                if (typeof realFetch === "function") {
                  window.fetch = function (input, init) {
                    const rid = id();
                    let url = "", method = "GET";
                    try {
                      url = absolute(typeof input === "string" || input instanceof URL ? input : input.url);
                      method = String((init && init.method) || (input && input.method) || "GET").toUpperCase();
                    } catch (e) {}
                    push({ k: "req", id: rid, url, method, doc: location.href, type: "Fetch", ts: Date.now() });
                    return realFetch.apply(this, arguments).then(
                      (r) => { push({ k: "res", id: rid, url, status: r.status, type: "Fetch", ts: Date.now() }); return r; },
                      (e) => { push({ k: "fail", id: rid, ts: Date.now() }); throw e; });
                  };
                }
                const X = XMLHttpRequest.prototype, open = X.open, send = X.send, seen = new WeakMap();
                X.open = function (method, url) {
                  try { seen.set(this, { id: id(), method: String(method).toUpperCase(), url: absolute(url) }); } catch (e) {}
                  return open.apply(this, arguments);
                };
                X.send = function () {
                  const r = seen.get(this);
                  if (r) {
                    push({ k: "req", id: r.id, url: r.url, method: r.method, doc: location.href, type: "XHR", ts: Date.now() });
                    this.addEventListener("loadend", () => push(this.status ? { k: "res", id: r.id, url: r.url, status: this.status, type: "XHR", ts: Date.now() } : { k: "fail", id: r.id, ts: Date.now() }));
                  }
                  return send.apply(this, arguments);
                };
                const kinds = { script: "Script", link: "Stylesheet", css: "Stylesheet", img: "Image", image: "Image", font: "Font", iframe: "Document", navigation: "Document" };
                const entry = (e) => {
                  if (e.initiatorType === "fetch" || e.initiatorType === "xmlhttprequest") return;
                  const rid = id(), type = kinds[e.initiatorType] || "Other";
                  push({ k: "req", id: rid, url: e.name, method: "GET", doc: location.href, type, ts: Date.now() });
                  push({ k: "res", id: rid, url: e.name, status: e.responseStatus || 200, type, ts: Date.now() });
                };
                try {
                  for (const e of performance.getEntriesByType("navigation")) entry(e);
                  new PerformanceObserver((list) => { for (const e of list.getEntries()) entry(e); }).observe({ type: "resource", buffered: true });
                } catch (e) {}
              }
              const q = h.q;
              h.q = [];
              return JSON.stringify(q);
            })()
            """
        }

        /// A wheel turned over a point: the page hears the wheel event, and
        /// unless it takes it, the nearest box that scrolls that way scrolls.
        static func wheel(x: Double, y: Double, dx: Double, dy: Double) -> String {
            """
            (() => {
              const x = \(x), y = \(y), dx = \(dx), dy = \(dy);
              const start = document.elementFromPoint(x, y) || document.scrollingElement || document.documentElement;
              const wheel = new WheelEvent("wheel", { deltaX: dx, deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true });
              if (!start.dispatchEvent(wheel)) return true;
              const scrolls = (el) => {
                const s = getComputedStyle(el);
                const yes = (o) => /(auto|scroll|overlay)/.test(o);
                return (dy && yes(s.overflowY) && el.scrollHeight > el.clientHeight) || (dx && yes(s.overflowX) && el.scrollWidth > el.clientWidth);
              };
              for (let el = start; el && el !== document.body && el !== document.documentElement; el = el.parentElement || (el.getRootNode && el.getRootNode().host)) {
                if (scrolls(el)) { el.scrollBy({ left: dx, top: dy, behavior: "instant" }); return true; }
              }
              (document.scrollingElement || document.documentElement).scrollBy({ left: dx, top: dy, behavior: "instant" });
              return true;
            })()
            """
        }

        /// The right button over a point, as the page's mouse and
        /// contextmenu events.
        static func rightButton(x: Double, y: Double, down: Bool) -> String {
            """
            (() => {
              const x = \(x), y = \(y);
              const el = document.elementFromPoint(x, y) || document.body;
              const options = { clientX: x, clientY: y, button: 2, buttons: \(down ? 2 : 0), bubbles: true, cancelable: true, composed: true, view: window };
              el.dispatchEvent(new MouseEvent(\(down ? "\"mousedown\"" : "\"mouseup\""), options));
              \(down ? "el.dispatchEvent(new MouseEvent(\"contextmenu\", options));" : "")
              return true;
            })()
            """
        }
    }
}
