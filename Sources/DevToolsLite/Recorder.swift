import AppKit
import UniformTypeIdentifiers
import WebKit

// The recorder: what you do on a page — clicks, typing, keys, scrolls, the
// pages it goes through — written down as steps, played back on the tab,
// and saved as Chrome's Recorder JSON, which @puppeteer/replay and Chrome's
// own Recorder read (the file's shape only; no code of theirs is used).
//
// Recording is a script in the tools' own world, listening in the capture
// phase and sending each step over the tools' handler, which is there only
// while recording (see Plugin.swift). It takes only events the person
// made (isTrusted); what the page itself dispatches isn't a step.
//
// Playing back runs no recorded text as code. Each step is data handed to
// one fixed function in the tools' world, which knows a short list of
// actions: click, double-click, change a field, a key, scroll, wait for an
// element; and Search loads a navigate step's address itself. A file read
// from disk goes through the same checks as a step from the page, and
// anything else in it is refused.

/// One step, as Chrome's Recorder names them.
struct RecordedStep: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case setViewport, navigate, click, doubleClick, change, keyDown, keyUp, scroll, waitForElement
    }

    var id = UUID()
    var kind: Kind
    /// Each entry is one way of finding the element; Chrome's file allows a
    /// list of parts per entry for shadow roots, which this keeps but can't
    /// play.
    var selectors: [[String]] = []
    var url: String?
    var title: String?
    var value: String?
    var key: String?
    var offsetX: Double?
    var offsetY: Double?
    var x: Double?
    var y: Double?
    var width: Int?
    var height: Int?
    /// primary, auxiliary or secondary.
    var button: String?
    /// The step loaded another page (Chrome's assertedEvents navigation):
    /// playing it waits for that page.
    var navigates = false

    static func == (a: RecordedStep, b: RecordedStep) -> Bool {
        a.kind == b.kind && a.selectors == b.selectors && a.url == b.url && a.value == b.value && a.key == b.key
            && a.offsetX == b.offsetX && a.offsetY == b.offsetY && a.x == b.x && a.y == b.y
            && a.width == b.width && a.height == b.height && a.button == b.button && a.navigates == b.navigates
    }

    /// One line for the list.
    var summary: String {
        let target = selectors.first?.first ?? ""
        switch kind {
        case .setViewport: return "Set viewport \(width ?? 0) × \(height ?? 0)"
        case .navigate: return "Navigate to \(url ?? "")"
        case .click: return (button == "secondary" ? "Right-click " : button == "auxiliary" ? "Middle-click " : "Click ") + target
        case .doubleClick: return "Double-click " + target
        case .change: return "Change \(target) to “\(value ?? "")”"
        case .keyDown: return "Key down \(key ?? "")"
        case .keyUp: return "Key up \(key ?? "")"
        case .scroll: return "Scroll to \(Int(x ?? 0)), \(Int(y ?? 0))" + (target.isEmpty ? "" : " in " + target)
        case .waitForElement: return "Wait for " + target
        }
    }

    // MARK: the file's shape

    var json: [String: Any] {
        var out: [String: Any] = ["type": kind.rawValue]
        if kind != .navigate && kind != .setViewport { out["target"] = "main" }
        if !selectors.isEmpty { out["selectors"] = selectors }
        if let url { out["url"] = url }
        if let value { out["value"] = value }
        if let key { out["key"] = key }
        if let offsetX { out["offsetX"] = offsetX }
        if let offsetY { out["offsetY"] = offsetY }
        if let x { out["x"] = x }
        if let y { out["y"] = y }
        if let button, button != "primary" { out["button"] = button }
        if kind == .setViewport {
            out["width"] = width ?? 0
            out["height"] = height ?? 0
            out["deviceScaleFactor"] = 1
            out["isMobile"] = false
            out["hasTouch"] = false
            out["isLandscape"] = false
        }
        if navigates || kind == .navigate {
            var event: [String: Any] = ["type": "navigation"]
            if kind == .navigate, let url { event["url"] = url }
            if let title { event["title"] = title }
            out["assertedEvents"] = [event]
        }
        return out
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case notAStep, unsupported(String), bad(String)

        var description: String {
            switch self {
            case .notAStep: "A step isn't an object with a type"
            case .unsupported(let what): "Not supported: \(what)"
            case .bad(let what): "Not valid: \(what)"
            }
        }
    }

    /// A step from a file or from the page, checked field by field. Only
    /// the fields each kind uses are read, each of the type and size it
    /// should be; a step in a frame, or a kind not listed, is refused.
    init(json raw: Any) throws {
        guard let raw = raw as? [String: Any], let type = raw["type"] as? String else { throw Problem.notAStep }
        guard let kind = Kind(rawValue: type) else { throw Problem.unsupported("a “\(type.prefix(40))” step") }
        self.kind = kind
        if let target = raw["target"] {
            guard (target as? String) == "main" else { throw Problem.unsupported("steps in other targets") }
        }
        if let frame = raw["frame"] {
            guard let list = frame as? [Any], list.isEmpty else { throw Problem.unsupported("steps in frames") }
        }
        func text(_ key: String, limit: Int) throws -> String? {
            guard let value = raw[key] else { return nil }
            guard let string = value as? String, string.utf16.count <= limit else { throw Problem.bad(key) }
            return string
        }
        func number(_ key: String) throws -> Double? {
            guard let value = raw[key] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, abs(number.doubleValue) <= 1_000_000 else { throw Problem.bad(key) }
            return number.doubleValue
        }
        if let list = raw["selectors"] {
            guard let list = list as? [Any], list.count <= 10 else { throw Problem.bad("selectors") }
            selectors = try list.map { entry in
                let parts = (entry as? [Any]) ?? [entry]
                guard !parts.isEmpty, parts.count <= 5 else { throw Problem.bad("selectors") }
                return try parts.map { part in
                    guard let part = part as? String, !part.isEmpty, part.utf16.count <= 2_000 else { throw Problem.bad("selectors") }
                    return part
                }
            }
        }
        switch kind {
        case .navigate:
            guard let address = try text("url", limit: 8_000), let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Problem.bad("url") }
            self.url = address
        case .click, .doubleClick:
            guard !selectors.isEmpty else { throw Problem.bad("selectors") }
            offsetX = try number("offsetX")
            offsetY = try number("offsetY")
            if let button = try text("button", limit: 16) {
                guard ["primary", "auxiliary", "secondary"].contains(button) else { throw Problem.bad("button") }
                self.button = button
            }
        case .change:
            guard !selectors.isEmpty, let value = try text("value", limit: 100_000) else { throw Problem.bad("value") }
            self.value = value
        case .keyDown, .keyUp:
            guard let key = try text("key", limit: 32), !key.isEmpty else { throw Problem.bad("key") }
            self.key = key
        case .scroll:
            x = try number("x") ?? 0
            y = try number("y") ?? 0
        case .waitForElement:
            guard !selectors.isEmpty else { throw Problem.bad("selectors") }
        case .setViewport:
            guard let w = try number("width"), let h = try number("height"), w >= 50, h >= 50, w <= 4096, h <= 4096 else {
                throw Problem.bad("viewport")
            }
            width = Int(w)
            height = Int(h)
        }
        if let events = raw["assertedEvents"] as? [Any] {
            navigates = kind != .navigate && events.contains { ($0 as? [String: Any])?["type"] as? String == "navigation" }
        }
    }

    init(kind: Kind) { self.kind = kind }
}

struct Recording: Equatable {
    var title: String
    var steps: [RecordedStep]

    static let largestFile = 5_000_000
    static let mostSteps = 2_000

    var data: Data? {
        try? JSONSerialization.data(withJSONObject: ["title": title, "steps": steps.map(\.json)],
                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// A file of Chrome's Recorder JSON, checked before anything of it is
    /// kept.
    init(file: Data) throws {
        guard file.count <= Self.largestFile,
              let raw = try? JSONSerialization.jsonObject(with: file) as? [String: Any] else {
            throw RecordedStep.Problem.bad("not a recording")
        }
        guard let steps = raw["steps"] as? [Any], steps.count <= Self.mostSteps else { throw RecordedStep.Problem.bad("steps") }
        let title = raw["title"] as? String ?? "Imported recording"
        self.title = String(title.prefix(200))
        self.steps = try steps.map(RecordedStep.init(json:))
    }

    init(title: String, steps: [RecordedStep]) {
        self.title = title
        self.steps = steps
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    weak var session: DevToolsSession?

    enum State: Equatable {
        case idle, recording, playing(Int), played, failed(Int, String)
    }

    @Published private(set) var state = State.idle
    @Published var recording = Recording(title: "", steps: [])
    @Published var notice: String?

    var busy: Bool {
        switch state {
        case .recording, .playing: true
        default: false
        }
    }

    private var playback: Task<Void, Never>?

    // MARK: recording

    func record() {
        guard let session, let web = session.web, !busy else { return }
        notice = nil
        var viewport = RecordedStep(kind: .setViewport)
        viewport.width = Int(web.bounds.width / max(0.1, web.pageZoom))
        viewport.height = Int(web.bounds.height / max(0.1, web.pageZoom))
        var start = RecordedStep(kind: .navigate)
        start.url = web.url?.absoluteString
        start.title = web.title
        let title = "Recording " + Date().formatted(date: .abbreviated, time: .shortened)
        recording = Recording(title: title, steps: start.url.map { _ in [viewport, start] } ?? [viewport])
        state = .recording
        session.listen(true)
        session.rearm()
        Task { _ = await session.call(Self.recordBody) }
    }

    func stop() {
        guard let session else { return }
        switch state {
        case .recording:
            state = .idle
            session.listen(false)
            session.rearm()
            Task { _ = await session.call("if (window.__searchDeveloperRecorder) window.__searchDeveloperRecorder.stop(); return true;") }
        case .playing:
            playback?.cancel()
            playback = nil
            state = .idle
        default:
            break
        }
    }

    func end() {
        stop()
        playback?.cancel()
    }

    func scripts() -> [WKUserScript] {
        guard state == .recording, let session else { return [] }
        return [WKUserScript(source: "(async function() {\(Self.recordBody)\n})();", injectionTime: .atDocumentStart,
                             forMainFrameOnly: true, in: session.world)]
    }

    /// A message from the recording script (already checked as coming from
    /// the tab's main frame in the tools' world).
    func heard(_ body: [String: Any]) {
        guard state == .recording, recording.steps.count < Recording.mostSteps else { return }
        switch body["kind"] as? String {
        case "step":
            guard let raw = body["step"], let step = try? RecordedStep(json: raw),
                  step.kind != .navigate, step.kind != .setViewport else { return }
            append(step)
        case "load":
            guard let address = body["url"] as? String, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme ?? "") else { return }
            loaded(address, title: body["title"] as? String)
        default:
            return
        }
    }

    private var lastInput = Date.distantPast

    private func append(_ step: RecordedStep) {
        lastInput = Date()
        // A field typed into is one step, with what it holds at the end.
        if step.kind == .change, let last = recording.steps.last, last.kind == .change, last.selectors == step.selectors {
            recording.steps[recording.steps.count - 1].value = step.value
            return
        }
        recording.steps.append(step)
    }

    /// A page loaded while recording: the step just before it led there,
    /// or the address changed on its own and is a step of its own.
    private func loaded(_ address: String, title: String?) {
        if let last = recording.steps.last, last.kind == .navigate, last.url == address { return }
        if let index = recording.steps.indices.last, Date().timeIntervalSince(lastInput) < 5,
           [.click, .doubleClick, .keyDown, .keyUp, .change].contains(recording.steps[index].kind) {
            recording.steps[index].navigates = true
            return
        }
        var step = RecordedStep(kind: .navigate)
        step.url = address
        step.title = title.map { String($0.prefix(200)) }
        recording.steps.append(step)
    }

    func remove(_ step: RecordedStep) {
        recording.steps.removeAll { $0.id == step.id }
    }

    // MARK: playing back

    func play() {
        guard let session, !busy, !recording.steps.isEmpty else { return }
        notice = nil
        let steps = recording.steps
        state = .playing(0)
        playback = Task { [weak self] in
            await self?.run(steps, in: session)
        }
    }

    /// Each step in turn; the first that fails stops the run there.
    private func run(_ steps: [RecordedStep], in session: DevToolsSession) async {
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled, let web = session.web else { return }
            state = .playing(index)
            switch step.kind {
            case .setViewport:
                // The size is the device toolbar's, only while it's up.
                if session.device.on, let w = step.width, let h = step.height {
                    session.device.device = nil
                    session.device.width = DeviceEmulation.clamp(w)
                    session.device.height = DeviceEmulation.clamp(h)
                }
            case .navigate:
                guard let address = step.url, let url = URL(string: address) else { continue }
                web.load(URLRequest(url: url))
                await session.settle(timeout: 20)
            default:
                let answer = await session.call(Self.replayBody, ["step": step.json]) as? [String: Any]
                guard answer?["ok"] as? Bool == true else {
                    state = .failed(index, answer?["error"] as? String ?? "The step couldn't run on this page")
                    return
                }
                // A click may start loading a page a moment later.
                try? await Task.sleep(nanoseconds: 150_000_000)
                if step.navigates || web.isLoading { await session.settle(timeout: 20) }
            }
        }
        state = .played
    }

    // MARK: files

    func export() {
        guard let data = recording.data else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.fileName(recording.title) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { notice = "Couldn't save: \(error.localizedDescription)" }
    }

    func importFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(try? Data(contentsOf: url, options: .mappedIfSafe))
    }

    func load(_ data: Data?) {
        guard let data else { notice = "Couldn't read the file"; return }
        do {
            recording = try Recording(file: data)
            state = .idle
            notice = nil
        } catch {
            notice = "Not imported. \(error)"
        }
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: .whitespaces).prefix(80).description
    }

    // MARK: scripts

    /// The recording script, in the tools' world. It listens before the page
    /// can stop an event, and posts each step the person makes.
    static let recordBody = #"""
    if (window.__searchDeveloperRecorder) return true;
    const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchDeveloper;
    if (!channel) return false;
    const post = (message) => { try { channel.postMessage(message); } catch (e) {} };
    const step = (fields) => post({ kind: "step", step: fields });
    const listeners = [];
    const listen = (type, handler) => {
        window.addEventListener(type, handler, { capture: true, passive: true });
        listeners.push([type, handler]);
    };
    const interactive = "a[href], button, input, select, textarea, label, summary, option, [role], [onclick], [tabindex], [contenteditable]";
    const round = (value) => Math.round(value * 100) / 100;
    const deepTarget = (event) => {
        const path = event.composedPath ? event.composedPath() : [];
        for (const node of path) if (node && node.nodeType === 1) return node;
        return event.target && event.target.nodeType === 1 ? event.target : null;
    };
    const acted = (event) => {
        let current = deepTarget(event);
        const start = current;
        for (let depth = 0; current && depth < 6; depth++) {
            try { if (current.matches(interactive)) return current; } catch (e) {}
            current = current.parentElement;
        }
        return start;
    };
    \#(selectorsLibrary)
    const editable = (el) => {
        if (!el) return false;
        const tag = el.localName;
        if (tag === "textarea" || tag === "select") return true;
        if (tag === "input") {
            const type = (el.type || "text").toLowerCase();
            return !["checkbox", "radio", "button", "submit", "reset", "image", "file", "range", "color"].includes(type);
        }
        return !!el.isContentEditable;
    };
    const pointer = (type, event, extra) => {
        if (event.clientX < 0 || event.clientY < 0 || event.clientX > innerWidth || event.clientY > innerHeight) return;
        const el = acted(event);
        if (!el) return;
        const rect = el.getBoundingClientRect();
        step(Object.assign({ type, target: "main", selectors: selectorsFor(el),
            offsetX: round(event.clientX - rect.left), offsetY: round(event.clientY - rect.top) }, extra || {}));
    };
    listen("click", (event) => {
        if (!event.isTrusted || event.detail === 0 || event.button !== 0) return;
        pointer("click", event);
    });
    listen("dblclick", (event) => { if (event.isTrusted && event.button === 0) pointer("doubleClick", event); });
    listen("auxclick", (event) => { if (event.isTrusted && event.button === 1) pointer("click", event, { button: "auxiliary" }); });
    listen("contextmenu", (event) => { if (event.isTrusted) pointer("click", event, { button: "secondary" }); });
    const changed = (event) => {
        if (!event.isTrusted) return;
        let el = deepTarget(event);
        if (!editable(el)) return;
        while (el.isContentEditable && el.parentElement && el.parentElement.isContentEditable) el = el.parentElement;
        const value = el.isContentEditable && !("value" in el) ? el.textContent : el.value;
        step({ type: "change", target: "main", selectors: selectorsFor(el), value: String(value).slice(0, 100000) });
    };
    listen("input", changed);
    listen("change", changed);
    const keys = (type) => (event) => {
        if (!event.isTrusted || event.repeat || event.isComposing) return;
        if (editable(deepTarget(event))) {
            const typing = event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey;
            if (typing || ["Shift", "Control", "Alt", "Meta", "CapsLock", "Backspace", "Delete"].includes(event.key)) return;
        }
        step({ type, target: "main", key: String(event.key).slice(0, 32) });
    };
    listen("keydown", keys("keyDown"));
    listen("keyup", keys("keyUp"));
    const scrolls = new Map();
    listen("scroll", (event) => {
        if (!event.isTrusted) return;
        const el = event.target && event.target.nodeType === 1 && event.target !== document.scrollingElement ? event.target : null;
        const key = el || window;
        clearTimeout(scrolls.get(key));
        scrolls.set(key, setTimeout(() => {
            scrolls.delete(key);
            if (el) step({ type: "scroll", target: "main", selectors: selectorsFor(el), x: round(el.scrollLeft), y: round(el.scrollTop) });
            else step({ type: "scroll", target: "main", x: round(scrollX), y: round(scrollY) });
        }, 300));
    });
    const loaded = () => post({ kind: "load", url: location.href, title: document.title.slice(0, 200) });
    if (document.readyState === "complete") loaded(); else window.addEventListener("load", loaded, { once: true });
    window.__searchDeveloperRecorder = {
        stop() {
            for (const [type, handler] of listeners) window.removeEventListener(type, handler, { capture: true });
            for (const timer of scrolls.values()) clearTimeout(timer);
            window.removeEventListener("load", loaded);
            delete window.__searchDeveloperRecorder;
        },
    };
    return true;
    """#

    /// Selectors as Chrome's Recorder writes them: aria/Name[role="…"],
    /// CSS, xpath//…, text/…; each kept only when it finds the element
    /// itself first. `resolve` finds the element for one, for playback.
    static let selectorsLibrary = #"""
    const squash = (text) => String(text || "").replace(/\s+/g, " ").trim();
    const roleOf = (el) => {
        const role = (el.getAttribute("role") || "").trim().split(/\s+/)[0];
        if (role) return role;
        const tag = el.localName;
        const type = (el.getAttribute("type") || "text").toLowerCase();
        if (tag === "a" || tag === "area") return el.hasAttribute("href") ? "link" : "";
        if (tag === "button" || tag === "summary") return "button";
        if (tag === "input") {
            if (["button", "submit", "reset", "image"].includes(type)) return "button";
            if (type === "checkbox" || type === "radio") return type;
            if (["text", "email", "tel", "url", "password", "search", "number"].includes(type)) return "textbox";
            return "";
        }
        if (tag === "textarea") return "textbox";
        if (tag === "select") return "combobox";
        if (/^h[1-6]$/.test(tag)) return "heading";
        if (tag === "img") return "img";
        if (tag === "option") return "option";
        return "";
    };
    const fromContent = new Set(["button", "link", "heading", "option", "menuitem", "tab", "checkbox", "radio", "switch", "treeitem", "cell"]);
    const nameOf = (el) => {
        const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
        if (ids.length) {
            const text = squash(ids.map((id) => { const t = document.getElementById(id); return t ? t.textContent : ""; }).join(" "));
            if (text) return text;
        }
        const label = squash(el.getAttribute("aria-label"));
        if (label) return label;
        if (el.labels && el.labels.length) {
            const text = squash(Array.from(el.labels).map((l) => l.textContent).join(" "));
            if (text) return text;
        }
        if (el.localName === "img" || (el.localName === "input" && el.type === "image")) {
            const alt = squash(el.getAttribute("alt"));
            if (alt) return alt;
        }
        if (el.localName === "input" && ["button", "submit", "reset"].includes(el.type) && squash(el.value)) return squash(el.value);
        if (fromContent.has(roleOf(el))) {
            const text = squash(el.textContent);
            if (text) return text.slice(0, 100);
        }
        return squash(el.getAttribute("title")) || squash(el.getAttribute("placeholder"));
    };
    const ariaFind = (name, role) => {
        const out = [];
        for (const el of document.querySelectorAll("*")) {
            if (out.length > 1) break;
            if (role && roleOf(el) !== role) continue;
            if (nameOf(el) === name) out.push(el);
        }
        return out;
    };
    const textFind = (text) => {
        let best = null;
        for (const el of document.body ? document.body.querySelectorAll("*") : []) {
            if (squash(el.textContent) !== text) continue;
            if (!best || best.contains(el)) best = el;
        }
        return best;
    };
    const resolve = (selector) => {
        try {
            if (selector.startsWith("aria/")) {
                const match = /^aria\/([\s\S]*?)(?:\[role="([^"]*)"\])?$/.exec(selector);
                const found = match ? ariaFind(match[1], match[2] || "") : [];
                return found[0] || null;
            }
            if (selector.startsWith("xpath/")) {
                return document.evaluate(selector.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
            }
            if (selector.startsWith("text/")) return textFind(selector.slice(5));
            if (selector.startsWith("pierce/")) return document.querySelector(selector.slice(7));
            return document.querySelector(selector);
        } catch (e) {
            return null;
        }
    };
    const cssFor = (el) => {
        if (el.id && document.querySelectorAll("#" + CSS.escape(el.id)).length === 1) return "#" + CSS.escape(el.id);
        for (const attribute of ["data-testid", "data-test", "data-qa", "data-cy", "name"]) {
            const value = el.getAttribute(attribute);
            if (!value) continue;
            const selector = el.localName + "[" + attribute + "='" + value.replace(/'/g, "\\'") + "']";
            try { if (document.querySelectorAll(selector).length === 1) return selector; } catch (e) {}
        }
        const parts = [];
        let current = el;
        while (current && current.nodeType === 1 && current !== document.documentElement && parts.length < 12) {
            if (current.id && document.querySelectorAll("#" + CSS.escape(current.id)).length === 1) {
                parts.unshift("#" + CSS.escape(current.id));
                break;
            }
            let part = current.localName;
            const parent = current.parentElement;
            if (parent) {
                const index = Array.prototype.indexOf.call(parent.children, current) + 1;
                if (parent.children.length > 1) part += ":nth-child(" + index + ")";
            }
            parts.unshift(part);
            try { if (document.querySelectorAll(parts.join(" > ")).length === 1) break; } catch (e) {}
            current = parent;
        }
        return parts.join(" > ");
    };
    const xpathFor = (el) => {
        const parts = [];
        let current = el;
        while (current && current.nodeType === 1) {
            if (current.id && document.querySelectorAll("#" + CSS.escape(current.id)).length === 1) {
                parts.unshift("//*[@id=\"" + current.id.replace(/"/g, "") + "\"]");
                return parts.join("/");
            }
            const parent = current.parentElement;
            const same = parent ? Array.from(parent.children).filter((c) => c.localName === current.localName) : [current];
            parts.unshift(current.localName + (same.length > 1 ? "[" + (same.indexOf(current) + 1) + "]" : ""));
            current = parent;
        }
        return "/" + parts.join("/");
    };
    const selectorsFor = (el) => {
        const out = [];
        const keep = (selector) => {
            if (selector && resolve(selector) === el && !out.some((s) => s[0] === selector)) out.push([selector]);
        };
        const name = nameOf(el);
        if (name && name.length <= 100) {
            const role = roleOf(el);
            keep("aria/" + name + (role ? "[role=\"" + role + "\"]" : ""));
        }
        keep(cssFor(el));
        keep("xpath/" + xpathFor(el));
        const text = squash(el.textContent);
        if (text && text.length <= 64 && el.children.length === 0) keep("text/" + text);
        return out.slice(0, 5);
    };
    """#

    /// One step played, in the tools' world. `step` is data: its type picks
    /// one of the actions below, and nothing in it is run.
    static let replayBody = #"""
    \#(selectorsLibrary)
    const wait = (ms) => new Promise((done) => setTimeout(done, ms));
    const find = async () => {
        const deadline = Date.now() + 5000;
        for (;;) {
            for (const parts of step.selectors || []) {
                if (parts.length !== 1) continue;
                const el = resolve(parts[0]);
                if (el) return el;
            }
            if (Date.now() > deadline) return null;
            await wait(100);
        }
    };
    const missing = { ok: false, error: "Nothing on the page matches the step's selectors" };
    const mouse = (el, type, x, y, button, detail) => el.dispatchEvent(new MouseEvent(type, {
        bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button, detail,
        buttons: type.endsWith("down") ? 1 : 0 }));
    switch (step.type) {
    case "click":
    case "doubleClick": {
        const el = await find();
        if (!el) return missing;
        el.scrollIntoView({ block: "center", inline: "center" });
        const rect = el.getBoundingClientRect();
        const x = rect.left + (typeof step.offsetX === "number" ? step.offsetX : rect.width / 2);
        const y = rect.top + (typeof step.offsetY === "number" ? step.offsetY : rect.height / 2);
        const button = step.button === "auxiliary" ? 1 : step.button === "secondary" ? 2 : 0;
        if (button === 2) { mouse(el, "contextmenu", x, y, 2, 1); return { ok: true }; }
        const clicks = step.type === "doubleClick" ? 2 : 1;
        for (let count = 1; count <= clicks; count++) {
            mouse(el, "mousedown", x, y, button, count);
            if (count === 1 && typeof el.focus === "function") el.focus();
            mouse(el, "mouseup", x, y, button, count);
            if (button === 0) {
                if (typeof el.click === "function") el.click(); else mouse(el, "click", x, y, 0, count);
            } else {
                mouse(el, "auxclick", x, y, button, count);
            }
        }
        if (clicks === 2) mouse(el, "dblclick", x, y, 0, 2);
        return { ok: true };
    }
    case "change": {
        const el = await find();
        if (!el) return missing;
        if (typeof el.focus === "function") el.focus();
        if (el.isContentEditable && !("value" in el)) {
            el.textContent = step.value;
        } else {
            el.value = step.value;
        }
        el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { ok: true };
    }
    case "keyDown":
    case "keyUp": {
        const target = document.activeElement || document.body;
        const type = step.type === "keyDown" ? "keydown" : "keyup";
        const sent = target.dispatchEvent(new KeyboardEvent(type, { key: step.key, bubbles: true, cancelable: true, composed: true }));
        // Return in a field sends its form, as a person's would.
        if (sent && type === "keydown" && step.key === "Enter" && target.form && target.localName === "input") {
            if (typeof target.form.requestSubmit === "function") target.form.requestSubmit(); else target.form.submit();
        }
        return { ok: true };
    }
    case "scroll": {
        if (step.selectors && step.selectors.length) {
            const el = await find();
            if (!el) return missing;
            el.scrollTo(step.x || 0, step.y || 0);
        } else {
            window.scrollTo(step.x || 0, step.y || 0);
        }
        return { ok: true };
    }
    case "waitForElement":
        return (await find()) ? { ok: true } : missing;
    default:
        return { ok: false, error: "Not a step that can be played" };
    }
    """#
}
