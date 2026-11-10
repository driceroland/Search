import AppKit
import Combine
import WebKit

// chrome.debugger for an extension's worker: the part of the DevTools
// protocol an extension needs to read a page, click in it, type in it, take
// its picture and send it elsewhere.
//
// WebKit has no protocol of this kind to hand over, so each command is
// carried out here: JavaScript in the page for what the page's own objects
// answer (ExtensionDebuggerPage), and the events a hand would make for
// everything else, so a click or a key is trusted by the page as a real
// one is. A command this file doesn't know is answered the way Chrome
// answers one it doesn't: with the protocol's own error, not an exception.
//
// Who may: only an extension whose manifest asks for `debugger`, only after
// the person at the keyboard allowed it (once per launch, as a sheet naming
// the extension), and never on one of Search's own pages, an extension's
// page or a file. A tab being debugged shows it on its row for as long as
// it lasts.
//
// What an extension's worker can't be called into with is carried by a long
// poll: the shim asks for what has happened (`poll`), and the answer comes
// when something does, or after a few seconds with nothing.

@available(macOS 15.4, *)
@MainActor
final class ExtensionDebugger {
    static let shared = ExtensionDebugger()

    /// A protocol error, in the text Chrome gives a script for one:
    /// `{"code":-32601,"message":"…"}`.
    struct Failure: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? {
            let data = try? JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [.sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? message
        }
        static func missing(_ method: String) -> Failure { Failure(code: -32601, message: "'\(method)' wasn't found") }
        static func invalid(_ what: String) -> Failure { Failure(code: -32602, message: "Invalid parameters: \(what)") }
        static func server(_ message: String) -> Failure { Failure(code: -32000, message: message) }
    }

    final class Session {
        let id = UUID().uuidString.lowercased()
        let extensionID: String
        let name: String
        weak var tab: Tab?
        let tabID: Tab.ID
        /// The domains switched on with `<Domain>.enable`.
        var enabled: Set<String> = []
        /// Worlds made by Page.createIsolatedWorld, by execution context id.
        var isolated: [Int: WKContentWorld] = [:]
        var nextContext = 2
        /// Counts the documents the tab has shown while attached.
        var loader = 1
        var pointer = CGPoint.zero
        /// The buttons held, as the protocol numbers them (1 left, 2 right, 4 middle).
        var held = 0
        var bag = Set<AnyCancellable>()

        init(extensionID: String, name: String, tab: Tab) {
            self.extensionID = extensionID
            self.name = name
            self.tab = tab
            self.tabID = tab.id
        }
        var frame: String { tabID.uuidString.replacingOccurrences(of: "-", with: "") }
        var loaderID: String { frame + String(format: "%04d", loader) }
    }

    /// What has happened for one extension and not yet been asked for.
    private final class Queue {
        var items: [[String: Any]] = []
        var wake: (() -> Void)?
    }

    private var sessions: [String: Session] = [:]
    private var queues: [String: Queue] = [:]
    /// Extensions the person allowed since the app started.
    private var allowed: Set<String> = []
    private var watching: Task<Void, Never>?

    // MARK: - who may attach

    /// Whether a page may be debugged: the web, and a blank tab to take
    /// somewhere. Not Search's own pages, an extension's, a file, or a
    /// private tab the extension isn't let into (that is checked where the
    /// tab is found).
    static func mayDebug(_ tab: Tab) -> Bool {
        guard tab.page == nil else { return false }
        guard let address = tab.address else { return true }
        return mayDebug(address)
    }

    static func mayDebug(_ address: URL) -> Bool {
        guard let scheme = address.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) || address.absoluteString.lowercased() == "about:blank"
    }

    func attach(to tab: Tab, context: WKWebExtensionContext, owner: Extensions) async throws -> [String: Any] {
        let id = context.uniqueIdentifier
        guard Self.mayDebug(tab) else {
            throw ExtensionShims.Unsupported(what: "Cannot access a chrome:// URL")
        }
        if let known = sessions.values.first(where: { $0.extensionID == id && $0.tabID == tab.id }) {
            throw ExtensionShims.Unsupported(what: "Another debugger is already attached to the tab with id: \(known.frame).")
        }
        if !allowed.contains(id) {
            guard await owner.ask(debugging: context) else {
                throw ExtensionShims.Unsupported(what: "Cannot attach to this target.")
            }
            allowed.insert(id)
        }
        // The page may have gone elsewhere while the sheet was up.
        guard Self.mayDebug(tab) else { throw ExtensionShims.Unsupported(what: "Cannot access a chrome:// URL") }

        let session = Session(extensionID: id, name: context.webExtension.displayName ?? "An extension", tab: tab)
        sessions[session.id] = session
        follow(session, tab)
        mark(tab)
        keepWatching()
        return ["session": session.id]
    }

    /// The session an extension has on a tab, if it has.
    func session(on tab: Tab?, for extensionID: String) -> String? {
        guard let tab else { return nil }
        return sessions.values.first { $0.extensionID == extensionID && $0.tabID == tab.id }?.id
    }

    /// The extension let go. Nothing is told to it: Chrome doesn't.
    func detach(_ id: String, extensionID: String) {
        guard let session = sessions[id], session.extensionID == extensionID else { return }
        end(session, reason: nil)
    }

    /// Every session an extension has, when it is switched off, removed or
    /// taken up again.
    func detachAll(extension id: String, reason: String = "canceled_by_user") {
        for session in sessions.values where session.extensionID == id { end(session, reason: reason) }
        allowed.remove(id)
        queues[id] = nil
    }

    private func end(_ session: Session, reason: String?) {
        sessions[session.id] = nil
        session.bag.removeAll()
        if let reason { enqueue(session.extensionID, ["session": session.id, "detach": reason]) }
        if let tab = session.tab { mark(tab) }
    }

    /// The tab's row says who is driving it.
    private func mark(_ tab: Tab) {
        let names = sessions.values.filter { $0.tabID == tab.id }.map(\.name)
        let sorted = Array(Set(names)).sorted()
        if tab.debuggedBy != sorted { tab.debuggedBy = sorted }
    }

    /// A tab that is closed ends its sessions; checked now and then, as a
    /// tab leaving a row has no one signal.
    private func keepWatching() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while let self, !self.sessions.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                let open = Set(Browsers.all.flatMap(\.tabs).map(\.id))
                for session in self.sessions.values where !open.contains(session.tabID) {
                    self.end(session, reason: "target_closed")
                }
            }
            self?.watching = nil
        }
    }

    // MARK: - what the page does, told

    private func follow(_ session: Session, _ tab: Tab) {
        tab.$address.removeDuplicates().dropFirst().sink { [weak self, weak session] address in
            guard let self, let session else { return }
            session.loader += 1
            session.isolated.removeAll()
            if session.enabled.contains("Runtime") {
                self.emit(session, "Runtime.executionContextsCleared", [:])
            }
            if session.enabled.contains("Page") {
                self.emit(session, "Page.frameNavigated", ["frame": self.frameInfo(session, url: address?.absoluteString ?? "")])
            }
            if session.enabled.contains("Runtime") {
                self.emit(session, "Runtime.executionContextCreated", ["context": self.contextInfo(session, address: address)])
            }
        }.store(in: &session.bag)
        tab.$loading.removeDuplicates().dropFirst().sink { [weak self, weak session] loading in
            guard let self, let session, session.enabled.contains("Page") else { return }
            if loading {
                self.emit(session, "Page.frameStartedLoading", ["frameId": session.frame])
            } else {
                let stamp = Date().timeIntervalSince1970
                self.emit(session, "Page.domContentEventFired", ["timestamp": stamp])
                self.emit(session, "Page.loadEventFired", ["timestamp": stamp])
                self.emit(session, "Page.frameStoppedLoading", ["frameId": session.frame])
            }
        }.store(in: &session.bag)
    }

    private func frameInfo(_ session: Session, url: String) -> [String: Any] {
        let origin = URL(string: url).flatMap { u in u.scheme.flatMap { s in u.host().map { "\(s)://\($0)" } } } ?? ""
        return ["id": session.frame, "loaderId": session.loaderID, "url": url, "domainAndRegistry": "",
                "securityOrigin": origin, "mimeType": "text/html", "secureContextType": "Secure",
                "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [String]()]
    }

    private func contextInfo(_ session: Session, address: URL?) -> [String: Any] {
        let origin = address.flatMap { u in u.scheme.flatMap { s in u.host().map { "\(s)://\($0)" } } } ?? ""
        return ["id": 1, "origin": origin, "name": "", "uniqueId": session.loaderID + ".1",
                "auxData": ["isDefault": true, "type": "default", "frameId": session.frame]]
    }

    private func emit(_ session: Session, _ method: String, _ params: [String: Any]) {
        enqueue(session.extensionID, ["session": session.id, "method": method, "params": params])
    }

    private func enqueue(_ id: String, _ item: [String: Any]) {
        let queue = queues[id] ?? Queue()
        queues[id] = queue
        // Nobody listening for a long time must not fill memory.
        if queue.items.count >= 2000 { queue.items.removeFirst(500) }
        queue.items.append(item)
        queue.wake?()
    }

    /// What has happened since the last call; waits up to `seconds` when
    /// nothing has. A second caller takes over from the first.
    func poll(extensionID id: String, seconds: Double) async -> [[String: Any]] {
        let queue = queues[id] ?? Queue()
        queues[id] = queue
        if queue.items.isEmpty {
            queue.wake?()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                let finish = {
                    guard !finished else { return }
                    finished = true
                    continuation.resume()
                }
                queue.wake = finish
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(min(max(seconds, 1), 30)))
                    finish()
                }
            }
            queue.wake = nil
        }
        let taken = Array(queue.items.prefix(200))
        queue.items.removeFirst(taken.count)
        return taken
    }

    // MARK: - commands

    func send(session id: String, extensionID: String, method: String, params: [String: Any], sessionId: String) async throws -> Any {
        guard let session = sessions[id], session.extensionID == extensionID, let tab = session.tab else {
            throw ExtensionShims.Unsupported(what: "Debugger is not attached to the tab.")
        }
        if !sessionId.isEmpty { throw Failure(code: -32001, message: "Session with given id not found.") }
        let domain = String(method.prefix(while: { $0 != "." }))
        switch method {
        // Switched on and off; most have nothing to switch.
        case "Page.enable", "Runtime.enable", "DOM.enable", "Network.enable", "Log.enable":
            session.enabled.insert(domain)
            if method == "Runtime.enable" {
                emit(session, "Runtime.executionContextCreated", ["context": contextInfo(session, address: tab.address)])
            }
            return [String: Any]()
        case "Page.disable", "Runtime.disable", "DOM.disable", "Network.disable", "Log.disable":
            session.enabled.remove(domain)
            return [String: Any]()
        case "Page.setLifecycleEventsEnabled", "Page.setInterceptFileChooserDialog", "Page.stopLoading",
             "Emulation.setFocusEmulationEnabled", "Input.cancelDragging", "Target.setAutoAttach",
             "Target.setDiscoverTargets", "Fetch.disable", "Security.enable", "Security.disable",
             "Performance.enable", "Performance.disable", "Runtime.runIfWaitingForDebugger":
            if method == "Page.stopLoading" { tab.stop() }
            return [String: Any]()
        case "Browser.getVersion":
            return ["protocolVersion": "1.3", "product": "Search", "revision": "", "userAgent": "", "jsVersion": ""]
        case "Target.getTargetInfo":
            return ["targetInfo": ["targetId": "tab-" + session.frame, "type": "page", "title": tab.title,
                                   "url": tab.address?.absoluteString ?? "about:blank", "attached": true, "canAccessOpener": false]]
        case "Page.handleJavaScriptDialog":
            throw Failure.server("No dialog is showing")

        case "Page.getFrameTree":
            return ["frameTree": ["frame": frameInfo(session, url: tab.address?.absoluteString ?? "about:blank"),
                                  "childFrames": [Any]()]]
        case "Page.createIsolatedWorld":
            let name = (params["worldName"] as? String) ?? ""
            let context = session.nextContext
            session.nextContext += 1
            let world = WKContentWorld.world(name: "search.debugger." + (name.isEmpty ? "world" : name))
            session.isolated[context] = world
            if session.enabled.contains("Runtime") {
                emit(session, "Runtime.executionContextCreated", ["context": [
                    "id": context, "origin": "", "name": name, "uniqueId": session.loaderID + ".\(context)",
                    "auxData": ["isDefault": false, "type": "isolated", "frameId": session.frame]]])
            }
            return ["executionContextId": context]
        case "Page.navigate":
            return try navigate(session, tab, params)
        case "Page.reload":
            tab.reload(fromOrigin: params["ignoreCache"] as? Bool ?? false)
            return [String: Any]()
        case "Page.getNavigationHistory":
            return history(tab)
        case "Page.navigateToHistoryEntry":
            guard let entry = params["entryId"] as? Int, let list = tab.built?.backForwardList else { throw Failure.invalid("entryId") }
            let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
            guard items.indices.contains(entry) else { throw Failure.server("No entry with passed id") }
            tab.go(to: items[entry])
            return [String: Any]()
        case "Page.getLayoutMetrics":
            return try await layoutMetrics(session, tab)
        case "Page.captureScreenshot":
            return try await screenshot(tab, params)
        case "Page.bringToFront":
            return [String: Any]()

        case "Runtime.evaluate":
            return try await evaluate(session, tab, params)
        case "Runtime.callFunctionOn":
            return try await callFunction(session, tab, params)
        case "Runtime.releaseObject":
            let (world, context) = try inside(object: params["objectId"] as? String, session)
            return try await op(tab, world, context, "release", params)
        case "Runtime.releaseObjectGroup":
            for (context, world) in [(1, WKContentWorld.page)] + session.isolated.map({ ($0.key, $0.value) }) {
                _ = try await op(tab, world, context, "releaseGroup", params)
            }
            return [String: Any]()

        case "DOM.describeNode", "DOM.resolveNode", "DOM.getBoxModel", "DOM.getContentQuads", "DOM.scrollIntoViewIfNeeded":
            let name = ["DOM.describeNode": "describeNode", "DOM.resolveNode": "resolveNode", "DOM.getBoxModel": "boxModel",
                        "DOM.getContentQuads": "quads", "DOM.scrollIntoViewIfNeeded": "scrollIntoView"][method] ?? ""
            let (world, context) = try inside(object: params["objectId"] as? String, session)
            return try await op(tab, world, context, name, params)
        case "DOM.getFrameOwner":
            throw Failure.server("Frame with the given id does not belong to the target.")

        case "Input.dispatchMouseEvent":
            try mouse(session, tab, params)
            return [String: Any]()
        case "Input.dispatchKeyEvent":
            try key(tab, params)
            return [String: Any]()
        case "Input.insertText":
            try await insert(tab, params["text"] as? String ?? "")
            return [String: Any]()
        default:
            throw Failure.missing(method)
        }
    }

    // MARK: - the page

    private func web(_ tab: Tab) -> PageView { tab.web }

    /// An objectId begins with the number of the world that made it.
    private func inside(object objectId: String?, _ session: Session) throws -> (WKContentWorld, Int) {
        guard let objectId, let number = objectId.split(separator: ".").first.flatMap({ Int($0) }) else {
            throw Failure.server("Could not find object with given id")
        }
        return try inside(context: number, session)
    }

    private func inside(context: Int?, _ session: Session) throws -> (WKContentWorld, Int) {
        let number = context ?? 1
        if number == 1 { return (.page, 1) }
        guard let world = session.isolated[number] else { throw Failure.server("Cannot find context with specified id") }
        return (world, number)
    }

    /// Runs `body` in a world, after the helper. What it answers is the
    /// helper's JSON: `{"result": …}` or `{"error": {code, message}}`.
    private func page(_ tab: Tab, _ world: WKContentWorld, _ context: Int, body: String, payload: [String: Any]) async throws -> [String: Any] {
        var full = payload
        full["tag"] = context
        let text = String(decoding: try JSONSerialization.data(withJSONObject: full), as: UTF8.self)
        let answer: Any?
        do {
            answer = try await web(tab).callAsyncJavaScript(ExtensionDebuggerPage.prelude + body, arguments: ["payload": text],
                                                            in: nil, contentWorld: world)
        } catch {
            throw Failure.server(Self.scriptMessage(error))
        }
        guard let json = answer as? String, let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw Failure.server("The page gave no answer") }
        if let error = parsed["error"] as? [String: Any] {
            throw Failure(code: error["code"] as? Int ?? -32000, message: error["message"] as? String ?? "")
        }
        return parsed
    }

    nonisolated static func scriptMessage(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    private func op(_ tab: Tab, _ world: WKContentWorld, _ context: Int, _ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        let reply = try await page(tab, world, context, body: "return await cdp.run(p.name, p.params);",
                                   payload: ["name": name, "params": params])
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func evaluate(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        guard let expression = params["expression"] as? String else { throw Failure.invalid("expression") }
        let (world, context) = try inside(context: params["contextId"] as? Int, session)
        var options = Self.options(params)
        let wantsAwait = options["awaitPromise"] as? Bool == true || params["replMode"] as? Bool == true || expression.contains("await ")
        // As an expression first, which needs no eval, so a page whose
        // policy forbids eval can still be read; then as a script.
        var attempts = [("return await cdp.finish(() => (\n\(expression)\n), p.options);", false)]
        if wantsAwait { attempts.append(("return await cdp.finish(async () => (\n\(expression)\n), p.options);", true)) }
        attempts.append(("return await cdp.finish(() => (0, eval)(p.expression), p.options);", false))
        var last: [String: Any] = [:]
        for (body, awaits) in attempts {
            if awaits { options["awaitPromise"] = true }
            do {
                let reply = try await page(tab, world, context, body: body, payload: ["expression": expression, "options": options])
                return reply
            } catch let failure as Failure where failure.message.hasPrefix("SyntaxError") {
                last = ["result": ["type": "object", "subtype": "error", "className": "SyntaxError", "description": failure.message],
                        "exceptionDetails": ["exceptionId": 0, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0,
                                             "exception": ["type": "object", "subtype": "error", "className": "SyntaxError",
                                                           "description": failure.message]]]
            }
        }
        return last
    }

    private func callFunction(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        guard let declaration = params["functionDeclaration"] as? String else { throw Failure.invalid("functionDeclaration") }
        let found: (WKContentWorld, Int)
        if let objectId = params["objectId"] as? String {
            found = try inside(object: objectId, session)
        } else {
            found = try inside(context: params["executionContextId"] as? Int, session)
        }
        var options = Self.options(params)
        options["objectId"] = params["objectId"] as? String
        options["arguments"] = params["arguments"] as? [[String: Any]] ?? []
        do {
            let reply = try await page(tab, found.0, found.1, body: "return await cdp.callOn((\n\(declaration)\n), p.options);",
                                       payload: ["options": options])
            return reply
        } catch let failure as Failure where failure.message.hasPrefix("SyntaxError") {
            throw Failure.server(failure.message)
        }
    }

    nonisolated static func options(_ params: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for name in ["returnByValue", "awaitPromise", "objectGroup"] {
            if let value = params[name] { out[name] = value }
        }
        return out
    }

    private func layoutMetrics(_ session: Session, _ tab: Tab) async throws -> [String: Any] {
        let reply = try await op(tab, .page, 1, "viewport", [:])
        let width = reply["clientWidth"] as? Double ?? 0, height = reply["clientHeight"] as? Double ?? 0
        let innerWidth = reply["innerWidth"] as? Double ?? width, innerHeight = reply["innerHeight"] as? Double ?? height
        let x = reply["scrollX"] as? Double ?? 0, y = reply["scrollY"] as? Double ?? 0
        let contentWidth = reply["scrollWidth"] as? Double ?? width, contentHeight = reply["scrollHeight"] as? Double ?? height
        let layout: [String: Any] = ["pageX": Int(x), "pageY": Int(y), "clientWidth": Int(width), "clientHeight": Int(height)]
        let visual: [String: Any] = ["offsetX": 0, "offsetY": 0, "pageX": x, "pageY": y,
                                     "clientWidth": innerWidth, "clientHeight": innerHeight, "scale": 1, "zoom": 1]
        let content: [String: Any] = ["x": 0, "y": 0, "width": contentWidth, "height": contentHeight]
        return ["layoutViewport": layout, "visualViewport": visual, "contentSize": content,
                "cssLayoutViewport": layout, "cssVisualViewport": visual, "cssContentSize": content]
    }

    private func navigate(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["url"] as? String, let url = URL(string: text) else { throw Failure.invalid("url") }
        // Not onto Search's own pages, an extension's, or a file: the same
        // line as for attaching.
        guard Self.mayDebug(url) else { throw Failure.server("Cannot navigate to invalid URL") }
        session.loader += 1
        let loader = session.loaderID
        tab.go(to: url)
        return ["frameId": session.frame, "loaderId": loader]
    }

    private func history(_ tab: Tab) -> [String: Any] {
        guard let list = tab.built?.backForwardList else { return ["currentIndex": 0, "entries": [Any]()] }
        let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
        let entries = items.enumerated().map { index, item -> [String: Any] in
            ["id": index, "url": item.url.absoluteString, "userTypedURL": item.initialURL.absoluteString,
             "title": item.title ?? "", "transitionType": "link"]
        }
        return ["currentIndex": list.backList.count, "entries": entries]
    }

    // MARK: - the picture

    /// The page as a picture, as the protocol asks: `format`, `quality`, and
    /// `clip` in the page's own pixels. One picture pixel to a page pixel
    /// (times the clip's scale), not the screen's two.
    private func screenshot(_ tab: Tab, _ params: [String: Any]) async throws -> [String: Any] {
        let view = web(tab)
        guard view.window != nil else { throw Failure.server("Unable to capture screenshot: the tab isn't on screen") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        var scale = 1.0
        var width = Double(view.bounds.width), height = Double(view.bounds.height)
        if let clip = params["clip"] as? [String: Any],
           let x = clip["x"] as? Double, let y = clip["y"] as? Double,
           let w = clip["width"] as? Double, let h = clip["height"] as? Double, w > 0, h > 0 {
            configuration.rect = CGRect(x: x, y: y, width: w, height: h)
            scale = clip["scale"] as? Double ?? 1
            width = w
            height = h
        }
        guard width > 0, height > 0 else { throw Failure.server("Unable to capture screenshot") }
        let pixels = (width: max(1, Int((width * scale).rounded())), height: max(1, Int((height * scale).rounded())))
        configuration.snapshotWidth = NSNumber(value: Double(pixels.width))
        let image: NSImage
        do { image = try await view.takeSnapshot(configuration: configuration) }
        catch { throw Failure.server("Unable to capture screenshot") }
        let format = params["format"] as? String ?? "png"
        let quality = min(max((params["quality"] as? Double ?? 80) / 100, 0.01), 1)
        guard let data = Self.encode(image, pixels: pixels, jpeg: format == "jpeg", quality: quality) else {
            throw Failure.server("Unable to capture screenshot")
        }
        return ["data": data.base64EncodedString()]
    }

    nonisolated static func encode(_ image: NSImage, pixels: (width: Int, height: Int), jpeg: Bool, quality: Double) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.width, pixelsHigh: pixels.height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return jpeg
            ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
            : bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - the hand

    nonisolated static func modifiers(_ bits: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.option) }
        if bits & 2 != 0 { flags.insert(.control) }
        if bits & 4 != 0 { flags.insert(.command) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    /// A mouse event handed to the page's view, as a pointer's is, so the
    /// page sees it trusted. The view has to be in a window: a page with
    /// none is not laid out, and has nothing to click.
    private func mouse(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        guard let type = params["type"] as? String, let x = (params["x"] as? NSNumber)?.doubleValue,
              let y = (params["y"] as? NSNumber)?.doubleValue else { throw Failure.invalid("type, x and y") }
        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let spot = view.convert(local, to: nil)
        let flags = Self.modifiers((params["modifiers"] as? NSNumber)?.intValue ?? 0)
        let button = params["button"] as? String ?? "none"
        let clicks = max(1, (params["clickCount"] as? NSNumber)?.intValue ?? 1)
        session.pointer = CGPoint(x: x, y: y)

        func make(_ type: NSEvent.EventType, clicks: Int, pressure: Swift.Float) -> NSEvent? {
            guard var event = NSEvent.mouseEvent(
                with: type, location: spot, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: pressure
            ) else { return nil }
            if button == "middle", let raw = event.cgEvent {
                raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                event = NSEvent(cgEvent: raw) ?? event
            }
            return event
        }
        // The window the page is in is not asked to be key: the person may
        // be typing elsewhere. The page's view takes the keys only when it
        // is clicked (below), as a click does.
        switch type {
        case "mousePressed":
            let kind: NSEvent.EventType = button == "right" ? .rightMouseDown : button == "middle" ? .otherMouseDown : .leftMouseDown
            session.held |= button == "right" ? 2 : button == "middle" ? 4 : 1
            if let event = make(kind, clicks: clicks, pressure: 1) {
                window.makeFirstResponder(view)
                switch kind {
                case .rightMouseDown: view.rightMouseDown(with: event)
                case .otherMouseDown: view.otherMouseDown(with: event)
                default: view.mouseDown(with: event)
                }
            }
        case "mouseReleased":
            let kind: NSEvent.EventType = button == "right" ? .rightMouseUp : button == "middle" ? .otherMouseUp : .leftMouseUp
            session.held &= ~(button == "right" ? 2 : button == "middle" ? 4 : 1)
            if let event = make(kind, clicks: clicks, pressure: 0) {
                switch kind {
                case .rightMouseUp: view.rightMouseUp(with: event)
                case .otherMouseUp: view.otherMouseUp(with: event)
                default: view.mouseUp(with: event)
                }
            }
        case "mouseMoved":
            if session.held & 1 != 0, let event = make(.leftMouseDragged, clicks: 1, pressure: 1) {
                view.mouseDragged(with: event)
            } else if session.held & 2 != 0, let event = make(.rightMouseDragged, clicks: 1, pressure: 1) {
                view.rightMouseDragged(with: event)
            } else if let event = make(.mouseMoved, clicks: 0, pressure: 0) {
                view.mouseMoved(with: event)
            }
        case "mouseWheel":
            let dx = (params["deltaX"] as? NSNumber)?.doubleValue ?? 0, dy = (params["deltaY"] as? NSNumber)?.doubleValue ?? 0
            // Where the pointer is, in the screen's own terms: an event made
            // here has no window, so AppKit takes this point as the page's.
            let onScreen = window.convertPoint(toScreen: spot)
            let over = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.y)
            func scroll(_ phase: Int64, _ x: Double, _ y: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: Int32(-y), wheel2: Int32(-x), wheel3: 0) else { return }
                cg.location = over
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)  // kCGScrollWheelEventIsContinuous
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)  // kCGScrollWheelEventScrollPhase
                cg.setIntegerValueField(CGEventField(rawValue: 96)!, value: Int64(-y))  // kCGScrollWheelEventPointDeltaAxis1
                cg.setIntegerValueField(CGEventField(rawValue: 97)!, value: Int64(-x))  // kCGScrollWheelEventPointDeltaAxis2
                if let event = NSEvent(cgEvent: cg) { view.scrollWheel(with: event) }
            }
            scroll(1, 0, 0)
            scroll(2, dx, dy)
            scroll(4, 0, 0)
        default:
            throw Failure.invalid("type")
        }
    }

    /// Keys that have a name rather than a character: the Mac's key code,
    /// and the character AppKit gives the press.
    nonisolated static let named: [String: (code: UInt16, characters: String)] = [
        "Enter": (36, "\r"), "Tab": (48, "\t"), "Backspace": (51, "\u{7f}"), "Escape": (53, "\u{1b}"),
        "Delete": (117, "\u{f728}"), "ArrowLeft": (123, "\u{f702}"), "ArrowRight": (124, "\u{f703}"),
        "ArrowDown": (125, "\u{f701}"), "ArrowUp": (126, "\u{f700}"), "Home": (115, "\u{f729}"),
        "End": (119, "\u{f72b}"), "PageUp": (116, "\u{f72c}"), "PageDown": (121, "\u{f72d}"), " ": (49, " "),
    ]

    /// The Mac's key code for a character on a US keyboard.
    nonisolated static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    nonisolated static func keyCode(key: String, text: String?) -> (code: UInt16, characters: String)? {
        if let known = named[key] { return known }
        let characters = (text?.isEmpty == false ? text : nil) ?? key
        guard characters.count == 1, let character = characters.lowercased().first else { return nil }
        return (codes[character] ?? 0, characters)
    }

    /// A key pressed or let go on the page's view. A key with text types it.
    private func key(_ tab: Tab, _ params: [String: Any]) throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        guard let type = params["type"] as? String else { throw Failure.invalid("type") }
        let flags = Self.modifiers((params["modifiers"] as? NSNumber)?.intValue ?? 0)
        let text = params["text"] as? String
        let name = params["key"] as? String ?? text ?? ""
        guard let info = Self.keyCode(key: name, text: text) else {
            // A key with no place on this keyboard still types its text.
            if type == "keyDown" || type == "char", let text, !text.isEmpty { Task { try? await insert(tab, text) } }
            return
        }
        let kind: NSEvent.EventType
        switch type {
        case "keyDown", "rawKeyDown": kind = .keyDown
        case "keyUp": kind = .keyUp
        case "char":
            if let text { Task { try? await insert(tab, text) } }
            return
        default: throw Failure.invalid("type")
        }
        let characters = (text?.isEmpty == false ? text : nil) ?? info.characters
        guard let event = NSEvent.keyEvent(
            with: kind, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: kind == .keyDown && type == "rawKeyDown" && text == nil ? info.characters : characters,
            charactersIgnoringModifiers: info.characters, isARepeat: params["autoRepeat"] as? Bool ?? false, keyCode: info.code
        ) else { return }
        if !(window.firstResponder is NSView && (window.firstResponder as? NSView)?.isDescendant(of: view) == true) {
            window.makeFirstResponder(view)
        }
        if kind == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
    }

    /// Text typed as one piece, as an input method hands it over.
    private func insert(_ tab: Tab, _ text: String) async throws {
        let view = web(tab)
        guard let window = view.window else { throw Failure.server("The tab isn't on screen to take input") }
        if let client = window.firstResponder as? NSTextInputClient, (window.firstResponder as? NSView)?.isDescendant(of: view) == true {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        // The view isn't what has the keys: the page's focused field gets it.
        _ = try await view.callAsyncJavaScript("return document.execCommand('insertText', false, text);",
                                               arguments: ["text": text], in: nil, contentWorld: .page)
    }
}
