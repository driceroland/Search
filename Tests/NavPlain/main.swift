// A plain WKWebView, no window ever shown, run through the same flows as
// Tests/nav_click.py: typed (load), link, form and spa, for comparison with
// Search (idea 1327). Built and run by nav_click.py --plain.
//
//   swiftc -O Tests/NavPlain/main.swift -o build/nav-plain && build/nav-plain BASE ROUNDS
import AppKit
import WebKit

let args = CommandLine.arguments
let base = args[1]
let rounds = Int(args.count > 2 ? args[2] : "8") ?? 8

NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                      styleMask: [.borderless], backing: .buffered, defer: false)
// PLAIN_FLAGS, comma-separated: Search's own settings, one at a time, to
// see what costs (none did, 26 Nov), and "policy"/"busy", a navigation
// delegate that answers every frame's navigation, and one that also holds
// the main thread 30 ms as each page commits, as a window drawing itself
// again holds it: a page's frames wait for that answer, so its load event
// comes as much later (idea 1327).
let flags = Set((ProcessInfo.processInfo.environment["PLAIN_FLAGS"] ?? "").split(separator: ",").map(String.init))
let config = WKWebViewConfiguration()
func setPref(_ name: String, _ on: Bool) {
    let set = NSSelectorFromString(name)
    guard config.preferences.responds(to: set) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(config.preferences.method(for: set), to: Setter.self)(config.preferences, set, on)
}
if flags.contains("extras") { setPref("_setDeveloperExtrasEnabled:", true) }
if flags.contains("ua") { config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15" }
if flags.contains("popups") { config.preferences.javaScriptCanOpenWindowsAutomatically = true }
if flags.contains("fullscreen") { config.preferences.isElementFullscreenEnabled = true }
if flags.contains("active") { config.preferences.inactiveSchedulingPolicy = .none }
if flags.contains("ext"), #available(macOS 15.4, *) { config.webExtensionController = WKWebExtensionController() }
let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
if flags.contains("inspectable") { web.isInspectable = true }

final class Answering: NSObject, WKNavigationDelegate {
    let hold: useconds_t
    init(hold: useconds_t) { self.hold = hold }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if hold > 0 { usleep(hold) }
    }
}
let answering = Answering(hold: flags.contains("busy") ? 30_000 : 0)
if flags.contains("policy") || flags.contains("busy") { web.navigationDelegate = answering }
window.contentView!.addSubview(web)

var parts: [String: [[Double]]] = [:]
var kind = ""

func now() -> Double { Date().timeIntervalSince1970 * 1000 }

@MainActor func eval(_ js: String) async -> Any? {
    try? await web.evaluateJavaScript(js)
}

@MainActor func landed(_ path: String, since: Double) async -> Double {
    let until = Date().addingTimeInterval(15)
    while Date() < until {
        if let s = await eval("JSON.stringify([location.pathname + location.search, window.__loaded || 0, performance.timeOrigin, (e => [e.requestStart, e.responseStart, e.domInteractive, e.loadEventEnd])(performance.getEntriesByType('navigation')[0])])") as? String,
           let v = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any],
           let at = v[1] as? Double, at > 0, (v[0] as? String)?.hasPrefix(path) == true {
            let origin = v[2] as? Double ?? 0, marks = v[3] as? [Double] ?? []
            parts[kind, default: []].append([origin - since] + marks)
            return at - since
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("no load of \(path)")
}

@MainActor func typed(_ n: Int) async -> Double {
    kind = "typed"
    let t = now()
    web.load(URLRequest(url: URL(string: "\(base)/p/\(n)")!))
    return await landed("/p/\(n)", since: t)
}

@MainActor func click(_ id: String, _ path: String) async -> Double {
    kind = id == "next" ? "link" : "form"
    let t = await eval("(() => { const t = Date.now(); document.getElementById('\(id)').click(); return t })()") as? Double ?? now()
    return await landed(path, since: t)
}

let spaJS = """
(() => {
  window.__gaps = null;
  const t0 = performance.now();
  let last = t0, worst = 0;
  const ch = new MessageChannel();
  const tick = () => {
    const now = performance.now();
    worst = Math.max(worst, now - last); last = now;
    if (now - t0 < 1000) ch.port2.postMessage(0); else window.__gaps = worst;
  };
  document.getElementById('spa').click();
  const done = performance.now() - t0;
  last = performance.now();
  ch.port1.onmessage = tick;
  ch.port2.postMessage(0);
  window.__spaClick = done;
  return 1;
})()
"""

@MainActor func spa() async -> (Double, Double) {
    _ = await eval(spaJS)
    while true {
        if let s = await eval("JSON.stringify([window.__gaps, window.__spaClick])") as? String,
           let v = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any],
           let g = v[0] as? Double, let c = v[1] as? Double {
            return (g, c)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    let m = s.count / 2
    let v = s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    return (v * 10).rounded() / 10
}

Task { @MainActor in
    if rounds == 0 {
        // Experiments: a JSON object of name → script on stdin, each run
        // seven times on a page; the median of what each returned.
        _ = await typed(1)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let exps = (try? JSONSerialization.jsonObject(with: input) as? [String: String]) ?? [:]
        var out: [String: Double] = [:]
        for (name, js) in exps {
            var vals: [Double] = []
            for _ in 0..<7 {
                let r = await eval(js) as? Double
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let v = await eval("window.__exp") as? Double { vals.append(v); _ = await eval("window.__exp = undefined") } else if let r { vals.append(r) }
            }
            out[name] = vals.isEmpty ? -1 : median(vals)
        }
        print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    }
    var n = 0
    _ = await typed(n)
    var res: [String: [Double]] = ["typed": [], "link": [], "form": [], "spa": [], "spaClick": []]
    for r in 0...rounds {
        n += 1; let a = await typed(n)
        n += 1; let b = await click("next", "/p/\(n)")
        let c = await click("b", "/s")
        n += 1; _ = await typed(n)
        let (g, k) = await spa()
        if r == 0 { continue }
        res["typed"]!.append(a); res["link"]!.append(b); res["form"]!.append(c)
        res["spa"]!.append(g); res["spaClick"]!.append(k)
    }
    var out: [String: Any] = res.mapValues(median)
    out["app"] = "plain WKWebView"
    out["parts"] = parts.mapValues { rows in (0..<5).map { i in median(rows.map { $0[i] }) } }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}
NSApplication.shared.run()
