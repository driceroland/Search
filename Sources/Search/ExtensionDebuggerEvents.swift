import AppKit
import WebKit

// What a page does that no WebKit API reports, told to an extension that
// asked for it: the console, errors nobody caught, requests made, and
// the calls a script makes to a binding the extension put there.
//
// A script in the page's own world watches (WebKit gives the browser no
// other way to see them) and posts what it sees to a handler named for the
// session. The name is made up when the session asks and dropped when it
// ends, so a page doesn't know it. The same scripts carry the extension's own
// (Page.addScriptToEvaluateOnNewDocument, Runtime.addBinding), and all of
// them are taken out of the tab when the session ends.

@available(macOS 15.4, *)
final class DebuggerRelay: NSObject, WKScriptMessageHandler {
    private weak var session: ExtensionDebugger.Session?
    init(_ session: ExtensionDebugger.Session) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let session, let body = message.body as? [String: Any] else { return }
        let main = message.frameInfo.isMainFrame
        let world = message.world
        MainActor.assumeIsolated { ExtensionDebugger.shared.pageMessage(session, body, from: world, fromMainFrame: main) }
    }
}

enum ExtensionDebuggerSensor {
    /// Watches the console, uncaught errors, fetch and XMLHttpRequest, the
    /// resources a page loads and the page itself, for one session.
    static func source(channel: String, key: String) -> String {
        #"""
        (function () {
          const channel = \#(literal(channel));
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[channel];
          if (!handler) return;
          const mark = Symbol.for("search.debugger.sensor." + channel);
          if (window[mark]) return;
          Object.defineProperty(window, mark, { value: true });
          const post = handler.postMessage.bind(handler);
          const send = (m) => { try { post(m); } catch (e) {} };
          const cdp = (\#(ExtensionDebuggerPage.source(key: key)))(1);

          const frames = (stack, skip) => String(stack || "").split("\n").slice(skip).map((line) => {
            const m = /^(.*?)@(.*?):(\d+):(\d+)$/.exec(line.trim());
            return m ? { functionName: m[1], scriptId: "0", url: m[2], lineNumber: Number(m[3]) - 1, columnNumber: Number(m[4]) - 1 } : null;
          }).filter(Boolean).slice(0, 10);

          const kinds = { log: "log", debug: "debug", info: "info", error: "error", warn: "warning", dir: "dir", dirxml: "dirxml",
            table: "table", trace: "trace", clear: "clear", count: "count", assert: "assert",
            group: "startGroup", groupCollapsed: "startGroupCollapsed", groupEnd: "endGroup" };
          for (const name of Object.keys(kinds)) {
            const original = console[name];
            if (typeof original !== "function") continue;
            console[name] = function (...args) {
              try {
                if (name !== "assert" || !args[0]) {
                  const shown = name === "assert" ? args.slice(1) : args;
                  send({ k: "console", type: kinds[name], args: shown.slice(0, 10).map((a) => cdp.remoteArg(a)),
                    stack: frames(new Error().stack, 1), at: Date.now() });
                }
              } catch (e) {}
              return original.apply(this, args);
            };
          }

          addEventListener("error", (e) => {
            if (!(e instanceof ErrorEvent)) return;
            // WebKit reports a script it could not compile, which Runtime.evaluate
            // meets while it tries an expression and then a script, as an error
            // with no text of its own, from nowhere. Nothing is learnt from it.
            if (e.message === "Script error." && !e.filename && !e.lineno && !e.error) return;
            const thrown = e.error;
            send({ k: "exception", text: thrown === undefined || thrown === null ? e.message : "Uncaught", url: e.filename,
              line: Math.max(0, (e.lineno || 1) - 1), column: Math.max(0, (e.colno || 1) - 1),
              exception: thrown === undefined || thrown === null ? null : cdp.remoteArg(thrown),
              stack: frames(thrown && thrown.stack, 0), at: Date.now() });
          });
          addEventListener("unhandledrejection", (e) => {
            send({ k: "exception", text: "Uncaught (in promise)", url: location.href, line: 0, column: 0,
              exception: cdp.remoteArg(e.reason), stack: frames(e.reason && e.reason.stack, 0), at: Date.now() });
          });

          let count = 0;
          const nextId = () => Math.round(performance.timeOrigin) + "." + (++count);
          const absolute = (u) => { try { return new URL(String(u), document.baseURI).href; } catch (e) { return String(u); } };
          const note = (m) => send(Object.assign({ k: "net", at: Date.now() }, m));
          const headersOf = (h) => { const o = {}; try { h.forEach((v, k) => { o[k] = v; }); } catch (e) {} return o; };

          const ownFetch = window.fetch;
          if (typeof ownFetch === "function") {
            window.fetch = function (input, init) {
              const id = nextId();
              const url = absolute(input && input.url ? input.url : input);
              note({ phase: "start", id, url, method: String((init && init.method) || (input && input.method) || "GET").toUpperCase(), type: "Fetch" });
              return ownFetch.apply(this, arguments).then((r) => {
                note({ phase: "response", id, url: r.url || url, status: r.status, statusText: r.statusText, headers: headersOf(r.headers),
                  mime: (r.headers.get("content-type") || "").split(";")[0], type: "Fetch" });
                note({ phase: "done", id });
                return r;
              }, (error) => {
                note({ phase: "fail", id, type: "Fetch", error: String(error && error.message || error), canceled: !!error && error.name === "AbortError" });
                throw error;
              });
            };
          }
          const requests = new WeakMap();
          const open = XMLHttpRequest.prototype.open, sendRequest = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (method, url) {
            requests.set(this, { method: String(method).toUpperCase(), url: absolute(url) });
            return open.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function () {
            const info = requests.get(this);
            if (info) {
              const id = nextId();
              note({ phase: "start", id, url: info.url, method: info.method, type: "XHR" });
              this.addEventListener("readystatechange", () => {
                if (this.readyState !== 2) return;
                const headers = {};
                String(this.getAllResponseHeaders()).trim().split(/\r?\n/).forEach((line) => {
                  const at = line.indexOf(":");
                  if (at > 0) headers[line.slice(0, at).trim().toLowerCase()] = line.slice(at + 1).trim();
                });
                note({ phase: "response", id, url: this.responseURL || info.url, status: this.status, statusText: this.statusText, headers,
                  mime: (headers["content-type"] || "").split(";")[0], type: "XHR" });
              });
              this.addEventListener("loadend", () => {
                if (this.status === 0) note({ phase: "fail", id, type: "XHR", error: "net::ERR_FAILED", canceled: this._searchAborted === true });
                else note({ phase: "done", id });
              });
              this.addEventListener("abort", () => { Object.defineProperty(this, "_searchAborted", { value: true, configurable: true }); });
            }
            return sendRequest.apply(this, arguments);
          };

          const typeOf = (kind) => ({ img: "Image", image: "Image", script: "Script", css: "Stylesheet", link: "Stylesheet",
            iframe: "Document", frame: "Document", video: "Media", audio: "Media", font: "Font", beacon: "Ping" })[kind] || "Other";
          const entry = (e, type) => {
            const id = nextId();
            note({ phase: "start", id, url: e.name, method: "GET", type });
            note({ phase: "response", id, url: e.name, status: e.responseStatus || 0, statusText: "", headers: {}, mime: "", type });
            note({ phase: "done", id });
          };
          try {
            new PerformanceObserver((list) => {
              for (const e of list.getEntries()) {
                if (e.initiatorType === "fetch" || e.initiatorType === "xmlhttprequest") continue;
                entry(e, typeOf(e.initiatorType));
              }
            }).observe({ type: "resource" });
          } catch (e) {}
          const document_ = () => {
            const nav = performance.getEntriesByType("navigation")[0];
            if (nav) entry(Object.assign({}, { name: location.href, responseStatus: nav.responseStatus }), "Document");
          };
          if (document.readyState === "complete") document_();
          else addEventListener("load", document_, { once: true });
        })();
        """#
    }

    /// A function a page can call by `name` with one string: what
    /// Runtime.addBinding puts there.
    static func binding(channel: String, name: String) -> String {
        #"""
        (function () {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\#(literal(channel))];
          if (!handler) return;
          const post = handler.postMessage.bind(handler);
          const name = \#(literal(name));
          Object.defineProperty(window, name, { configurable: true, writable: true, enumerable: false, value: function (payload) {
            if (typeof payload !== "string") throw new TypeError("Illegal invocation");
            post({ k: "binding", name, payload });
          } });
        })();
        """#
    }

    /// A string as JavaScript source.
    static func literal(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - the session's channel and the scripts on the page

@available(macOS 15.4, *)
extension ExtensionDebugger {
    private func controller(_ tab: Tab) -> WKUserContentController { web(tab).configuration.userContentController }

    /// The handler the page's scripts post to; made on first need, and in
    /// every world a script of the session's runs in (a world has handlers
    /// of its own).
    private func ensureChannel(_ session: Session, _ tab: Tab, world: WKContentWorld) {
        if session.relay == nil {
            session.channel = "sd" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            session.relay = DebuggerRelay(session)
        }
        guard let relay = session.relay, !session.relayWorlds.contains(where: { Self.same($0, world) }) else { return }
        controller(tab).add(relay, contentWorld: world, name: session.channel)
        session.relayWorlds.append(world)
    }

    static func same(_ a: WKContentWorld, _ b: WKContentWorld) -> Bool {
        a === b || (a.name != nil && a.name == b.name)
    }

    /// A script that runs in every document the tab loads from now on, and
    /// in the one it shows if `now`.
    @discardableResult
    func install(_ source: String, world: WKContentWorld, mainFrameOnly: Bool, now: Bool, session: Session, tab: Tab) -> WKUserScript {
        ensureChannel(session, tab, world: world)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: mainFrameOnly, in: world)
        controller(tab).addUserScript(script)
        session.scripts.append(script)
        if now {
            let view = web(tab)
            Task { _ = try? await view.evaluateJavaScript(source, in: nil, contentWorld: world) }
        }
        return script
    }

    /// Takes scripts out of the tab. WebKit removes only all at once, so the
    /// others are put back as they were.
    func uninstall(_ doomed: [WKUserScript], session: Session, tab: Tab) {
        guard !doomed.isEmpty else { return }
        let ids = Set(doomed.map(ObjectIdentifier.init))
        let controller = controller(tab)
        let kept = controller.userScripts.filter { !ids.contains(ObjectIdentifier($0)) }
        controller.removeAllUserScripts()
        for script in kept { controller.addUserScript(script) }
        session.scripts.removeAll { ids.contains(ObjectIdentifier($0)) }
    }

    /// The console, errors and requests of the page begin to be told.
    func watch(_ session: Session, _ tab: Tab) {
        guard session.sensor == nil else { return }
        ensureChannel(session, tab, world: .page)
        session.sensor = install(ExtensionDebuggerSensor.source(channel: session.channel, key: session.key), world: .page,
                                 mainFrameOnly: true, now: true, session: session, tab: tab)
    }

    /// Everything a session put on its tab.
    func release(_ session: Session) {
        session.casting?.cancel()
        session.casting = nil
        guard let tab = session.tab, session.relay != nil else { return }
        uninstall(session.scripts, session: session, tab: tab)
        for world in session.relayWorlds {
            controller(tab).removeScriptMessageHandler(forName: session.channel, contentWorld: world)
        }
        session.relayWorlds = []
        session.relay = nil
        session.sensor = nil
        session.documentScripts = [:]
        session.bindings = []
    }

    // MARK: Page.addScriptToEvaluateOnNewDocument, Runtime.addBinding

    func addScript(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws -> [String: Any] {
        guard let source = params["source"] as? String else { throw Failure.invalid("source") }
        let name = params["worldName"] as? String ?? ""
        let world: WKContentWorld = name.isEmpty ? .page : isolatedWorld(session, name)
        let script = install(source, world: world, mainFrameOnly: false, now: params["runImmediately"] as? Bool == true,
                             session: session, tab: tab)
        let identifier = String(session.nextScript)
        session.nextScript += 1
        session.documentScripts[identifier] = script
        return ["identifier": identifier]
    }

    func removeScript(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws {
        guard let identifier = params["identifier"] as? String else { throw Failure.invalid("identifier") }
        guard let script = session.documentScripts.removeValue(forKey: identifier) else {
            throw Failure.server("No script with given id")
        }
        uninstall([script], session: session, tab: tab)
    }

    /// A binding and where it was asked to be: in one context
    /// (`executionContextId`), in the contexts of a name
    /// (`executionContextName`), or, with neither, in the page's own context
    /// and every one the session makes.
    struct Binding {
        let name: String
        let context: Int?
        let contextName: String?
        var scripts: [WKUserScript] = []
        var worlds: [WKContentWorld] = []

        /// Whether it goes into a context, which is `id`, and was asked for as `named`.
        func applies(to id: Int, named: String) -> Bool {
            if let context { return context == id }
            if let contextName { return id != 1 && contextName == named }
            return true
        }
    }

    /// The world of a context the session can name.
    private func world(of context: Int, _ session: Session) -> WKContentWorld? {
        context == 1 ? .page : session.isolated[context]
    }

    /// A world keeps the binding's script across documents, so it takes one copy.
    private func put(_ binding: inout Binding, into world: WKContentWorld, _ session: Session, _ tab: Tab) {
        guard !binding.worlds.contains(where: { Self.same($0, world) }) else { return }
        ensureChannel(session, tab, world: world)
        binding.worlds.append(world)
        binding.scripts.append(install(ExtensionDebuggerSensor.binding(channel: session.channel, name: binding.name),
                                       world: world, mainFrameOnly: true, now: true, session: session, tab: tab))
    }

    func addBinding(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws {
        guard let name = params["name"] as? String, !name.isEmpty else { throw Failure.invalid("name") }
        let id = (params["executionContextId"] as? NSNumber)?.intValue
        let contextName = params["executionContextName"] as? String
        if id != nil && contextName != nil {
            throw Failure.server("executionContextId and executionContextName are mutually exclusive")
        }
        if let id, world(of: id, session) == nil { throw Failure.server("Cannot find context with specified id") }
        guard !session.bindings.contains(where: { $0.name == name && $0.context == id && $0.contextName == contextName }) else { return }
        var binding = Binding(name: name, context: id, contextName: contextName)
        for context in [1] + session.isolated.keys.sorted() where binding.applies(to: context, named: session.contextNames[context] ?? "") {
            if let world = world(of: context, session) { put(&binding, into: world, session, tab) }
        }
        session.bindings.append(binding)
    }

    /// A context the session just made gets the bindings that were asked for
    /// every context of its name.
    func bindContext(_ session: Session, _ tab: Tab, context: Int, name: String) {
        guard let world = world(of: context, session) else { return }
        for index in session.bindings.indices where session.bindings[index].context == nil
            && session.bindings[index].applies(to: context, named: name) {
            put(&session.bindings[index], into: world, session, tab)
        }
    }

    /// The contexts of the old document are gone, and the bindings asked for
    /// one of them alone with them.
    func dropContextBindings(_ session: Session) {
        guard let tab = session.tab else { return }
        let gone = session.bindings.filter { $0.context.map { $0 != 1 } ?? false }
        uninstall(gone.flatMap(\.scripts), session: session, tab: tab)
        session.bindings.removeAll { $0.context.map { $0 != 1 } ?? false }
    }

    func removeBinding(_ session: Session, _ tab: Tab, _ params: [String: Any]) throws {
        guard let name = params["name"] as? String else { throw Failure.invalid("name") }
        let gone = session.bindings.filter { $0.name == name }
        guard !gone.isEmpty else { return }
        uninstall(gone.flatMap(\.scripts), session: session, tab: tab)
        session.bindings.removeAll { $0.name == name }
        let view = web(tab)
        let remove = "delete window[\(ExtensionDebuggerSensor.literal(name))];"
        let worlds = [WKContentWorld.page] + session.isolated.values
        Task { for world in worlds { _ = try? await view.evaluateJavaScript(remove, in: nil, contentWorld: world) } }
    }

    // MARK: what the page says

    func pageMessage(_ session: Session, _ message: [String: Any], from world: WKContentWorld, fromMainFrame: Bool) {
        // What a page posts is the page's to make up: only text, numbers,
        // lists and records go on, so what is told can always be written out.
        guard session.tab != nil, let body = Self.plain(message) as? [String: Any], let kind = body["k"] as? String else { return }
        let milliseconds = body["at"] as? Double ?? Date().timeIntervalSince1970 * 1000
        switch kind {
        case "console" where session.enabled.contains("Runtime"):
            var params: [String: Any] = ["type": body["type"] as? String ?? "log", "args": body["args"] as? [Any] ?? [],
                                         "executionContextId": 1, "timestamp": milliseconds]
            if let frames = body["stack"] as? [[String: Any]], !frames.isEmpty { params["stackTrace"] = ["callFrames": frames] }
            emit(session, "Runtime.consoleAPICalled", params)
        case "exception" where session.enabled.contains("Runtime"):
            var details: [String: Any] = ["exceptionId": session.nextException, "text": body["text"] as? String ?? "Uncaught",
                                          "lineNumber": body["line"] as? Int ?? 0, "columnNumber": body["column"] as? Int ?? 0,
                                          "executionContextId": 1]
            session.nextException += 1
            if let url = body["url"] as? String, !url.isEmpty { details["url"] = url }
            if let exception = body["exception"] as? [String: Any] { details["exception"] = exception }
            if let frames = body["stack"] as? [[String: Any]], !frames.isEmpty { details["stackTrace"] = ["callFrames": frames] }
            emit(session, "Runtime.exceptionThrown", ["timestamp": milliseconds, "exceptionDetails": details])
        case "binding" where session.enabled.contains("Runtime"):
            // Said by the world the binding is in: that is the context, and a
            // binding is heard only where it was put.
            guard fromMainFrame, let name = body["name"] as? String,
                  let context = ([1] + session.isolated.keys).first(where: { id in
                      self.world(of: id, session).map { Self.same($0, world) } ?? false }),
                  session.bindings.contains(where: { $0.name == name && $0.applies(to: context, named: session.contextNames[context] ?? "") })
            else { return }
            emit(session, "Runtime.bindingCalled", ["name": name, "payload": body["payload"] as? String ?? "", "executionContextId": context])
        case "net" where session.enabled.contains("Network") && fromMainFrame:
            network(session, body, seconds: milliseconds / 1000)
        default:
            return
        }
    }

    /// One request, as the protocol tells it: sent, answered, finished or not.
    private func network(_ session: Session, _ body: [String: Any], seconds: Double) {
        guard let phase = body["phase"] as? String, let id = body["id"] as? String else { return }
        let type = body["type"] as? String ?? "Other"
        switch phase {
        case "start":
            let url = body["url"] as? String ?? ""
            emit(session, "Network.requestWillBeSent", [
                "requestId": id, "loaderId": session.loaderID, "documentURL": session.tab?.address?.absoluteString ?? "",
                "request": ["url": url, "method": body["method"] as? String ?? "GET", "headers": [String: String](),
                            "initialPriority": "High", "referrerPolicy": "strict-origin-when-cross-origin"],
                "timestamp": seconds, "wallTime": seconds, "initiator": ["type": "script"], "redirectHasExtraInfo": false, "type": type])
        case "response":
            emit(session, "Network.responseReceived", [
                "requestId": id, "loaderId": session.loaderID, "timestamp": seconds, "type": type, "hasExtraInfo": false,
                "response": ["url": body["url"] as? String ?? "", "status": body["status"] as? Int ?? 0,
                             "statusText": body["statusText"] as? String ?? "", "headers": body["headers"] as? [String: Any] ?? [:],
                             "mimeType": body["mime"] as? String ?? "", "connectionReused": false, "connectionId": 0,
                             "encodedDataLength": 0, "securityState": "unknown"]])
        case "done":
            emit(session, "Network.loadingFinished", ["requestId": id, "timestamp": seconds, "encodedDataLength": 0])
        case "fail":
            emit(session, "Network.loadingFailed", ["requestId": id, "timestamp": seconds, "type": type,
                                                    "errorText": body["error"] as? String ?? "net::ERR_FAILED",
                                                    "canceled": body["canceled"] as? Bool ?? false])
        default:
            return
        }
    }

    // MARK: Page.lifecycleEvent

    func lifecycle(_ session: Session, _ names: [String], loader: Int? = nil) {
        guard session.lifecycle else { return }
        let stamp = Date().timeIntervalSince1970
        let loaderID = loader.map { Self.loaderID(frame: session.frame, $0) } ?? session.loaderID
        for name in names {
            emit(session, "Page.lifecycleEvent", ["frameId": session.frame, "loaderId": loaderID, "name": name, "timestamp": stamp])
        }
    }

    /// WebKit has no word of when a page's network has gone quiet, so it is
    /// taken to be so half a second after the page has loaded and nothing
    /// has sent it elsewhere.
    func lifecycleLoaded(_ session: Session) {
        lifecycle(session, ["DOMContentLoaded", "load", "firstPaint", "firstContentfulPaint", "firstMeaningfulPaintCandidate", "firstMeaningfulPaint"])
        let loader = session.loader
        Task { [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let session, session.loader == loader, session.tab?.loading == false else { return }
            self.lifecycle(session, ["networkAlmostIdle", "networkIdle"])
        }
    }
}
