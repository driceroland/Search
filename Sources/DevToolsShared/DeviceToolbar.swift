import AppKit
import SwiftUI
import WebKit

// The device toolbar: the page at a phone's or a tablet's size, with its
// user agent, and two menus beside it. Rendering emulates what the page's
// styles ask about the reader (light or dark, reduced motion) and how some
// readers see (colour vision deficiencies, blur). Sensors stand in for the
// Mac's location and give the page an orientation.
//
// What does what:
//   - the size is the page's own frame, so the page's viewport is the
//     device's (innerWidth, media queries) — nothing is faked to the page;
//   - the user agent is WKWebView's customUserAgent, the page reloaded so it
//     is the one the site sees;
//   - light or dark is the page view's appearance, which is what WebKit
//     answers prefers-color-scheme with;
//   - reduced motion, the rendering filters and local-font emulation run
//     in the tools' own world, with the page's styles restored when off;
//   - a location or an orientation can only reach the page through the
//     page's own functions, so that one script stands in the page's world,
//     with the values written into it, nothing else (see Plugin.swift).
// The device pixel ratio isn't emulated: WebKit has no public way to.
//
// The device list is a few of Chrome DevTools' (EmulatedDevices.ts,
// Copyright The Chromium Authors, BSD-3-Clause; see THIRD_PARTY_NOTICES.md).

struct EmulatedDevice: Identifiable, Hashable {
    let title: String
    let width: Int
    let height: Int
    /// The device's pixel ratio, shown only: WebKit can't take it.
    let scale: Double
    let userAgent: String

    var id: String { title }

    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    static func android(_ model: String) -> String {
        "Mozilla/5.0 (Linux; Android 14; \(model)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Mobile Safari/537.36"
    }

    static let all: [EmulatedDevice] = [
        .init(title: "iPhone SE", width: 375, height: 667, scale: 2, userAgent: iPhone),
        .init(title: "iPhone 16", width: 393, height: 852, scale: 3, userAgent: iPhone),
        .init(title: "iPhone 16 Pro Max", width: 440, height: 956, scale: 3, userAgent: iPhone),
        .init(title: "Pixel 9", width: 412, height: 924, scale: 2.625, userAgent: android("Pixel 9")),
        .init(title: "Samsung Galaxy A55", width: 360, height: 800, scale: 2.25, userAgent: android("SM-A556B")),
        .init(title: "Moto G Power", width: 412, height: 823, scale: 1.75, userAgent: android("moto g power (2022)")),
        .init(title: "iPad Mini", width: 768, height: 1024, scale: 2, userAgent: iPad),
        .init(title: "iPad Air", width: 820, height: 1180, scale: 2, userAgent: iPad),
    ]

    static func named(_ title: String) -> EmulatedDevice? { all.first { $0.title == title } }
}

enum ColorSchemeEmulation: String, CaseIterable, Identifiable {
    case none, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "No emulation"
        case .light: "prefers-color-scheme: light"
        case .dark: "prefers-color-scheme: dark"
        }
    }
}

enum VisionDeficiency: String, CaseIterable, Identifiable {
    case none, blurred, protanopia, deuteranopia, tritanopia, achromatopsia
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "No emulation"
        case .blurred: "Blurred vision"
        case .protanopia: "Protanopia (no red)"
        case .deuteranopia: "Deuteranopia (no green)"
        case .tritanopia: "Tritanopia (no blue)"
        case .achromatopsia: "Achromatopsia (no colour)"
        }
    }

    /// The CSS filter on the page's root. The three colour matrices are
    /// Machado, Oliveira and Fernandes's (2009) at full severity.
    var filter: String? {
        switch self {
        case .none: nil
        case .blurred: "blur(2px)"
        case .achromatopsia: "grayscale(1)"
        case .protanopia, .deuteranopia, .tritanopia: "url(#search-developer-vision)"
        }
    }

    var matrix: String? {
        switch self {
        case .protanopia: "0.152286 1.052583 -0.204868 0 0 0.114503 0.786281 0.099216 0 0 -0.003882 -0.048116 1.051998 0 0 0 0 0 1 0"
        case .deuteranopia: "0.367322 0.860646 -0.227968 0 0 0.280085 0.672501 0.047413 0 0 -0.011820 0.042940 0.968881 0 0 0 0 0 1 0"
        case .tritanopia: "1.255528 -0.076749 -0.178779 0 0 -0.078411 0.930809 0.147602 0 0 0.004733 0.691367 0.303900 0 0 0 0 0 1 0"
        default: nil
        }
    }
}

/// A place to say the device is at.
struct SensorLocation: Hashable, Identifiable {
    let title: String
    let latitude: Double
    let longitude: Double
    var accuracy: Double = 150
    var id: String { title }

    static let presets: [SensorLocation] = [
        .init(title: "Berlin", latitude: 52.520007, longitude: 13.404954),
        .init(title: "London", latitude: 51.507351, longitude: -0.127758),
        .init(title: "Mumbai", latitude: 19.075984, longitude: 72.877656),
        .init(title: "San Francisco", latitude: 37.774929, longitude: -122.419416),
        .init(title: "Shanghai", latitude: 31.230416, longitude: 121.473701),
        .init(title: "São Paulo", latitude: -23.55052, longitude: -46.633309),
        .init(title: "Tokyo", latitude: 35.689487, longitude: 139.691706),
    ]
}

/// How the device is held, as Chrome's Sensors names the presets.
struct SensorOrientation: Hashable, Identifiable {
    let title: String
    let alpha: Double
    let beta: Double
    let gamma: Double
    var id: String { title }

    static let presets: [SensorOrientation] = [
        .init(title: "Portrait", alpha: 0, beta: 90, gamma: 0),
        .init(title: "Portrait upside down", alpha: 180, beta: -90, gamma: 0),
        .init(title: "Landscape left", alpha: 90, beta: 0, gamma: -90),
        .init(title: "Landscape right", alpha: -90, beta: 0, gamma: 90),
        .init(title: "Display up", alpha: 0, beta: 0, gamma: 0),
        .init(title: "Display down", alpha: 0, beta: 180, gamma: 0),
    ]
}

/// One tab's emulation. All of it holds only while the toolbar is up.
@MainActor
final class DeviceEmulation: ObservableObject {
    /// The stand-in for a tab with no session: never on.
    static let idle = DeviceEmulation()

    weak var session: DevToolsSession?

    @Published var on = false { didSet { if on != oldValue { changed(reload: true) } } }
    /// A device's title, or nil for a size of your own.
    @Published var device: String? { didSet { if device != oldValue { save(); changed(reload: true) } } }
    @Published var width = 390 { didSet { if width != oldValue { save(); session?.invalidate() } } }
    @Published var height = 844 { didSet { if height != oldValue { save(); session?.invalidate() } } }
    @Published var landscape = false { didSet { if landscape != oldValue { session?.invalidate() } } }
    @Published var colorScheme = ColorSchemeEmulation.none { didSet { if colorScheme != oldValue { changed() } } }
    @Published var reducedMotion = false { didSet { if reducedMotion != oldValue { changed() } } }
    @Published var autoDark = false { didSet { if autoDark != oldValue { changed() } } }
    @Published var noLocalFonts = false { didSet { if noLocalFonts != oldValue { changed() } } }
    @Published var vision = VisionDeficiency.none { didSet { if vision != oldValue { changed() } } }
    @Published var location: SensorLocation? { didSet { if location != oldValue { sensorsChanged() } } }
    /// The page is told its position can't be found.
    @Published var locationUnavailable = false { didSet { if locationUnavailable != oldValue { sensorsChanged() } } }
    @Published var orientation: SensorOrientation? { didSet { if orientation != oldValue { sensorsChanged() } } }

    static let key = "device"

    /// From automation (Plugin.swift): only the keys given change.
    func set(_ values: [String: Any]) {
        if let on = values["on"] as? Bool { self.on = on }
        if values.keys.contains("device") { device = (values["device"] as? String).flatMap { EmulatedDevice.named($0)?.title } }
        if let w = values["width"] as? Int { width = Self.clamp(w) }
        if let h = values["height"] as? Int { height = Self.clamp(h) }
        if let turned = values["landscape"] as? Bool { landscape = turned }
        if let scheme = (values["colorScheme"] as? String).flatMap(ColorSchemeEmulation.init) { colorScheme = scheme }
        if let motion = values["reducedMotion"] as? Bool { reducedMotion = motion }
        if let dark = values["autoDark"] as? Bool { autoDark = dark }
        if let disabled = values["noLocalFonts"] as? Bool { noLocalFonts = disabled }
        if let seen = (values["vision"] as? String).flatMap(VisionDeficiency.init) { vision = seen }
        if values.keys.contains("location") {
            location = (values["location"] as? String).flatMap { name in SensorLocation.presets.first { $0.title == name } }
        }
        if let unavailable = values["locationUnavailable"] as? Bool { locationUnavailable = unavailable }
        if values.keys.contains("orientation") {
            orientation = (values["orientation"] as? String).flatMap { name in SensorOrientation.presets.first { $0.title == name } }
        }
    }

    var emulated: EmulatedDevice? { device.flatMap(EmulatedDevice.named) }

    /// The page's viewport, in CSS pixels.
    var size: CGSize {
        let w = emulated?.width ?? width
        let h = emulated?.height ?? height
        return landscape ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    var userAgent: String? { on ? emulated?.userAgent : nil }

    var sensing: Bool { on && (location != nil || locationUnavailable || orientation != nil) }

    /// The last choice of device, from a normal tab's toolbar.
    func restore() {
        guard let kept = session?.setting(Self.key) as? [String: Any] else { return }
        device = (kept["device"] as? String).flatMap { EmulatedDevice.named($0)?.title }
        if let w = kept["width"] as? Int { width = Self.clamp(w) }
        if let h = kept["height"] as? Int { height = Self.clamp(h) }
    }

    private func save() {
        var kept: [String: Any] = ["width": width, "height": height]
        if let device { kept["device"] = device }
        session?.keep(kept, Self.key)
    }

    static func clamp(_ value: Int) -> Int { min(4096, max(50, value)) }

    /// What the page view gets: its user agent and appearance, now; the
    /// scripts for its next document, and the same done to this one.
    private var agentSet: String?
    private var sensorsSet = false

    /// Whether anything was put on the page view: nothing to undo otherwise.
    private var applied = false

    private func changed(reload: Bool = false) {
        guard let session, let web = session.web, on || applied else { return }
        applied = on
        let scheme = on ? (autoDark ? ColorSchemeEmulation.dark : colorScheme) : .none
        switch scheme {
        case .dark: web.appearance = NSAppearance(named: .darkAqua)
        case .light: web.appearance = NSAppearance(named: .aqua)
        case .none: web.appearance = nil
        }
        session.rearm()
        Task { await live(session) }
        let agent = userAgent
        if agent != agentSet {
            agentSet = agent
            web.customUserAgent = agent
            if reload, web.url != nil { web.reload() }
        }
        if !on, sensorsSet { sensorsChanged() }
        session.objectWillChange.send()
        session.invalidate()
    }

    /// A sensor set or cleared. Set, it reaches the page now and its next
    /// documents; cleared, the page is loaded again without it, since what
    /// the page's own world was given can't be taken back from it.
    private func sensorsChanged() {
        guard let session, let web = session.web else { return }
        let was = sensorsSet
        sensorsSet = sensing
        session.rearm()
        if sensing, let source = sensorScript() {
            web.evaluateJavaScript(source, in: nil, in: .page) { _ in }
        } else if was, web.url != nil {
            web.reload()
        }
    }

    private static let normalRendering: [String: Any] = [
        "motion": false, "filter": "", "matrix": "", "autoDark": false, "noLocalFonts": false,
    ]

    private var renderingValues: [String: Any] {
        ["motion": reducedMotion, "filter": vision.filter ?? "", "matrix": vision.matrix ?? "",
         "autoDark": autoDark, "noLocalFonts": noLocalFonts]
    }

    /// The rendering scripts run on the page that's up, or undone there.
    private func live(_ session: DevToolsSession) async {
        _ = await session.call(Self.renderingBody, applied ? renderingValues : Self.normalRendering)
    }

    func scripts() -> [WKUserScript] {
        guard on, let session else { return [] }
        var out: [WKUserScript] = []
        if reducedMotion || autoDark || noLocalFonts || vision != .none {
            let values = Self.json(renderingValues)
            let source = """
                (function({motion, filter, matrix, autoDark, noLocalFonts}) {
                \(Self.renderingBody)
                })(\(values));
                """
            out.append(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: session.world))
        }
        if let sensors = sensorScript() {
            out.append(WKUserScript(source: sensors, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        return out
    }

    /// `reloading`: false when the page view is going anyway.
    func end(reloading allowed: Bool = true) {
        guard on || applied || agentSet != nil || sensorsSet else { return }
        let reloading = allowed && (agentSet != nil || sensorsSet)
        applied = false
        if let web = session?.web {
            web.appearance = nil
            web.customUserAgent = nil
            if let session { Task { await live(session) } }
            if reloading, web.url != nil { web.reload() }
        }
        agentSet = nil
        sensorsSet = false
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// The page-world script, with nothing in it but the values set here.
    func sensorScript() -> String? {
        guard sensing else { return nil }
        var position: Any = NSNull()
        if let location {
            position = ["latitude": location.latitude, "longitude": location.longitude, "accuracy": location.accuracy]
        }
        var turn: Any = NSNull()
        if let orientation { turn = ["alpha": orientation.alpha, "beta": orientation.beta, "gamma": orientation.gamma] }
        let values = Self.json(["position": position, "unavailable": locationUnavailable, "orientation": turn])
        return "(function(v) {\(Self.sensorsBody)\n})(\(values));"
    }

    // MARK: scripts

    /// Rendering, in the tools' world. Visiting CSSOM rules lets the package
    /// emulate styles without replacing the site's functions. Each edit is
    /// kept until the option is turned off.
    static let renderingBody = #"""
    if (!window.__searchDeveloperRendering && !motion && !filter && !autoDark && !noLocalFonts) return true;
    const state = window.__searchDeveloperRendering || (window.__searchDeveloperRendering = {
        rules: new Map(), fonts: new Map(),
    });
    state.motion = motion;
    state.noLocalFonts = noLocalFonts;
    state.visionFilter = filter;
    state.autoDark = autoDark;
    const swap = (text) => text
        .replace(/\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)/gi, "(min-width: 0px)")
        .replace(/\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)/gi, "(max-width: -1px)")
        .replace(/\(\s*prefers-reduced-motion\s*\)/gi, "(min-width: 0px)");
    // Split the CSSOM source list at commas outside strings and functions.
    const withoutLocal = (src) => {
        const parts = [];
        let start = 0, depth = 0, quote = "";
        for (let i = 0; i < src.length; i++) {
            const c = src[i];
            if (c === "\\") { i++; continue; }
            if (quote) { if (c === quote) quote = ""; continue; }
            if (c === '"' || c === "'") quote = c;
            else if (c === "(") depth++;
            else if (c === ")") depth--;
            else if (c === "," && !depth) { parts.push(src.slice(start, i)); start = i + 1; }
        }
        parts.push(src.slice(start));
        const kept = parts.map((part) => part.trim()).filter((part) => !/^local\s*\(/i.test(part));
        if (kept.length === parts.length) return src;
        return kept.length ? kept.join(", ") : 'url("data:font/woff2;base64,")';
    };
    const undoFont = (style, edit) => {
        if (style.getPropertyValue("src") === edit.last) style.setProperty("src", edit.source);
    };
    const sweep = () => {
        const sheets = new Set(), fonts = new Set();
        const visit = (rules, depth) => {
            if (!rules || depth > 8) return;
            for (const rule of rules) {
                if (state.motion && rule instanceof CSSMediaRule && !state.rules.has(rule)) {
                    const text = rule.media.mediaText;
                    if (/prefers-reduced-motion/i.test(text)) {
                        state.rules.set(rule, text);
                        try { rule.media.mediaText = swap(text); } catch (e) {}
                    }
                }
                if (state.noLocalFonts && rule instanceof CSSFontFaceRule) {
                    const style = rule.style, source = style.getPropertyValue("src");
                    fonts.add(style);
                    if (state.fonts.get(style)?.last !== source) {
                        const wanted = withoutLocal(source);
                        if (source !== wanted) {
                            style.setProperty("src", wanted);
                            state.fonts.set(style, { source, last: style.getPropertyValue("src") });
                        } else {
                            state.fonts.delete(style);
                        }
                    }
                }
                if (rule instanceof CSSImportRule && rule.styleSheet) walk(rule.styleSheet, depth + 1);
                else if (rule.cssRules) visit(rule.cssRules, depth + 1);
            }
        };
        const walk = (sheet, depth) => {
            if (sheets.has(sheet)) return;
            sheets.add(sheet);
            try { visit(sheet.cssRules, depth); } catch (e) {}
        };
        for (const sheet of [...document.styleSheets, ...document.adoptedStyleSheets]) walk(sheet, 0);
        for (const [style, edit] of state.fonts) {
            if (fonts.has(style)) continue;
            undoFont(style, edit);
            state.fonts.delete(style);
        }
    };
    if (!motion) {
        for (const [rule, text] of state.rules) {
            try { rule.media.mediaText = text; } catch (e) {}
        }
        state.rules.clear();
    }
    if (!noLocalFonts) {
        for (const [style, edit] of state.fonts) undoFont(style, edit);
        state.fonts.clear();
    }
    if (motion || noLocalFonts) {
        sweep();
        if (!state.watch) {
            state.watch = new MutationObserver(sweep);
            state.watch.observe(document.documentElement, { childList: true, subtree: true });
            state.load = sweep;
            document.addEventListener("load", state.load, true);
        }
    } else if (state.watch) {
        state.watch.disconnect();
        document.removeEventListener("load", state.load, true);
        state.watch = null;
        state.load = null;
    }

    const root = document.documentElement;
    if (state.svg) { state.svg.remove(); state.svg = null; }
    if (filter) {
        if (matrix) {
            const ns = "http://www.w3.org/2000/svg";
            const svg = document.createElementNS(ns, "svg");
            svg.setAttribute("aria-hidden", "true");
            svg.setAttribute("style", "position:absolute;width:0;height:0;overflow:hidden");
            const made = document.createElementNS(ns, "filter");
            made.setAttribute("id", "search-developer-vision");
            made.setAttribute("color-interpolation-filters", "linearRGB");
            const colors = document.createElementNS(ns, "feColorMatrix");
            colors.setAttribute("type", "matrix");
            colors.setAttribute("values", matrix);
            made.appendChild(colors);
            svg.appendChild(made);
            root.appendChild(svg);
            state.svg = svg;
        }
    }

    // Give a light page a dark rendering, but keep a site's own dark theme.
    // A constructed stylesheet cancels the inversion on media without a
    // node or attribute that a site's own stylesheet can match.
    const alreadyDark = (root) => {
        if (/\bdark\b/.test(getComputedStyle(root).colorScheme || "")) return true;
        const meta = document.querySelector('meta[name="color-scheme" i]');
        if (/\bdark\b/.test(meta?.content || "")) return true;
        for (const element of [root, document.body]) {
            if (!element) continue;
            const rgb = /rgba?\(([^)]+)\)/.exec(getComputedStyle(element).backgroundColor);
            if (!rgb) continue;
            const [r, g, b, alpha = 1] = rgb[1].split(/[ ,/]+/).filter(Boolean).map(Number);
            if (alpha > 0) return 0.2126 * r + 0.7152 * g + 0.0722 * b < 102;
        }
        return false;
    };
    const matchesFilter = (edit) => edit.style.getPropertyValue("filter") === edit.last
        && edit.style.getPropertyPriority("filter") === "important";
    const syncDark = () => {
        const root = document.documentElement;
        if (!root) return;
        const dark = state.autoDark && !alreadyDark(root);
        const currentSheets = document.adoptedStyleSheets;
        if (dark) {
            if (!state.darkMedia) {
                state.darkMedia = new CSSStyleSheet();
                state.darkMedia.replaceSync("img, video, canvas, iframe, embed, object, [style*='background-image'] "
                    + "{ filter: hue-rotate(180deg) invert(1) !important; }");
            }
            if (!currentSheets.includes(state.darkMedia)) document.adoptedStyleSheets = [...currentSheets, state.darkMedia];
        } else if (state.darkMedia) {
            document.adoptedStyleSheets = currentSheets.filter((sheet) => sheet !== state.darkMedia);
            state.darkMedia = null;
        }

        const style = root.style, next = [state.visionFilter, dark ? "invert(1) hue-rotate(180deg)" : ""]
            .filter(Boolean).join(" ");
        const prior = state.rootFilter;
        if (prior && (prior.style !== style || !next)) {
            if (matchesFilter(prior)) prior.style.setProperty("filter", prior.original, prior.priority);
            state.rootFilter = null;
        }
        if (!next) return;
        if (!state.rootFilter || !matchesFilter(state.rootFilter)) {
            state.rootFilter = { style, original: style.getPropertyValue("filter"), priority: style.getPropertyPriority("filter") };
        }
        if (state.rootFilter.requested !== next) {
            style.setProperty("filter", next, "important");
            state.rootFilter.last = style.getPropertyValue("filter");
            state.rootFilter.requested = next;
        }
    };
    syncDark();
    if (autoDark && !state.darkTimer) state.darkTimer = setInterval(syncDark, 500);
    if (!autoDark && state.darkTimer) {
        clearInterval(state.darkTimer);
        state.darkTimer = null;
    }
    if (!motion && !filter && !autoDark && !noLocalFonts) delete window.__searchDeveloperRendering;
    return true;
    """#

    /// Sensors, in the page's world: the values given and nothing else.
    static let sensorsBody = #"""
    if (v.position || v.unavailable) {
        const fix = () => {
            const p = v.position;
            const coords = { latitude: p.latitude, longitude: p.longitude, accuracy: p.accuracy,
                altitude: null, altitudeAccuracy: null, heading: null, speed: null };
            coords.toJSON = () => Object.assign({}, coords);
            const position = { coords, timestamp: Date.now() };
            position.toJSON = () => ({ coords: coords.toJSON(), timestamp: position.timestamp });
            return position;
        };
        const answer = (success, failure) => setTimeout(() => {
            if (v.unavailable) {
                if (typeof failure === "function") failure({ code: 2, message: "Position unavailable",
                    PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
            } else if (typeof success === "function") {
                success(fix());
            }
        }, 0);
        let watches = 0;
        const own = (name, value) => Object.defineProperty(Geolocation.prototype, name,
            { value, writable: true, configurable: true, enumerable: true });
        if (typeof Geolocation === "function") {
            own("getCurrentPosition", function getCurrentPosition(success, failure) { answer(success, failure); });
            own("watchPosition", function watchPosition(success, failure) { answer(success, failure); return ++watches; });
            own("clearWatch", function clearWatch() {});
        }
    }
    if (v.orientation) {
        const o = v.orientation;
        const fire = () => {
            let event = null;
            try {
                event = new DeviceOrientationEvent("deviceorientation", { alpha: o.alpha, beta: o.beta, gamma: o.gamma, absolute: false });
            } catch (e) {}
            // This WebKit may have no such event, or one that keeps no values.
            if (!event || event.alpha !== o.alpha) {
                event = new Event("deviceorientation");
                for (const key of ["alpha", "beta", "gamma"]) Object.defineProperty(event, key, { value: o[key], enumerable: true });
                Object.defineProperty(event, "absolute", { value: false, enumerable: true });
            }
            window.dispatchEvent(event);
        };
        if (document.readyState === "complete") fire(); else window.addEventListener("load", fire, { once: true });
        setInterval(fire, 1000);
    }
    """#
}

// MARK: - The view

/// The toolbar over the page.
struct DeviceBar: View {
    @ObservedObject var device: DeviceEmulation

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Responsive") { device.device = nil }
                Divider()
                ForEach(EmulatedDevice.all) { item in
                    Button(item.title) { device.device = item.title }
                }
            } label: {
                Text(device.device ?? "Responsive")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if device.emulated == nil {
                SizeField(value: $device.width)
                Text("×").foregroundStyle(Look.muted)
                SizeField(value: $device.height)
            } else {
                Text("\(Int(device.size.width)) × \(Int(device.size.height))")
                    .monospacedDigit()
                    .foregroundStyle(Look.muted)
                    .help("Pixel ratio \(device.emulated.map { String($0.scale) } ?? "1") on the device; the page keeps the Mac's")
            }
            IconButton(icon: "rotate.right", help: "Rotate") { device.landscape.toggle() }

            Spacer(minLength: 0)

            Menu("Rendering") {
                Picker("Color scheme", selection: $device.colorScheme) {
                    ForEach(ColorSchemeEmulation.allCases) { Text($0.title).tag($0) }
                }
                Toggle("prefers-reduced-motion: reduce", isOn: $device.reducedMotion)
                Toggle("Enable automatic dark mode", isOn: $device.autoDark)
                    .help("Requests dark mode and darkens light pages without their own dark theme.")
                Toggle("Disable local fonts", isOn: $device.noLocalFonts)
                    .help("Skips local() sources in accessible @font-face rules.")
                Picker("Vision", selection: $device.vision) {
                    ForEach(VisionDeficiency.allCases) { Text($0.title).tag($0) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu("Sensors") {
                Picker("Location", selection: Binding(
                    get: { device.locationUnavailable ? "unavailable" : device.location?.title ?? "" },
                    set: { title in
                        device.locationUnavailable = title == "unavailable"
                        device.location = SensorLocation.presets.first { $0.title == title }
                    })) {
                    Text("No override").tag("")
                    ForEach(SensorLocation.presets) { Text($0.title).tag($0.title) }
                    Text("Location unavailable").tag("unavailable")
                }
                Picker("Orientation", selection: Binding(
                    get: { device.orientation?.title ?? "" },
                    set: { title in device.orientation = SensorOrientation.presets.first { $0.title == title } })) {
                    Text("No override").tag("")
                    ForEach(SensorOrientation.presets) { Text($0.title).tag($0.title) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            IconButton(icon: "xmark", help: "Close the device toolbar") { device.on = false; device.session.map(closeIfIdle) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Look.ink)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Look.ground)
    }

    private func closeIfIdle(_ session: DevToolsSession) {
        if session.idle, let web = session.web { session.plugin?.toolsIdle(webView: web) }
    }
}

private struct SizeField: View {
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 44)
            .padding(.vertical, 2)
            .background(Look.wash, in: RoundedRectangle(cornerRadius: 4))
            .onAppear { text = String(value) }
            .onChange(of: value) { _, now in text = String(now) }
            .onSubmit {
                if let number = Int(text) { value = DeviceEmulation.clamp(number) }
                text = String(value)
            }
    }
}
